"""Every move of a job laid out in time, for playback, scrubbing and inspection. Port of
Post/Timeline.swift; times come from a simulation of grbl's planner."""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from .toolpath import Motion, Move, Role, ToolpathGeometry


@dataclass
class Entry:
    start: tuple[float, float, float]
    move: Move
    operation: int  # index into the job's operation list
    t_start: float  # seconds from the start of the job
    t_end: float
    gcode_line: int | None  # 1-based line in the operation's program, if the move produced one
    program: int  # index of the program (tool) this move belongs to


class ToolpathTimeline:
    def __init__(self, paths: list | None = None, program_of: list[int] | None = None,
                 lines: list[list[int | None]] | None = None, machine=None) -> None:
        self.entries: list[Entry] = []
        if paths is None:
            return
        program_of = program_of or []
        lines = lines or []
        flat = []
        pos = None
        for oi, path in enumerate(paths):
            for mi, m in enumerate(path.moves):
                flat.append((oi, mi, pos if pos is not None else m.position, m))
                pos = m.position
        times = planner_seconds([(f[2], f[3]) for f in flat], machine)
        t = 0.0
        for k, (oi, mi, start, m) in enumerate(flat):
            dt = times[k]
            line = lines[oi][mi] if oi < len(lines) and mi < len(lines[oi]) else None
            self.entries.append(Entry(start, m, oi, t, t + dt, line, program_of[oi] if oi < len(program_of) else 0))
            t += dt

    @property
    def duration(self) -> float:
        return self.entries[-1].t_end if self.entries else 0.0

    def index(self, t: float) -> int:
        """Index of the entry playing at time t (binary search)."""
        if not self.entries:
            return 0
        lo, hi = 0, len(self.entries) - 1
        while lo < hi:
            mid = (lo + hi) // 2
            if self.entries[mid].t_end < t:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def position(self, t: float) -> tuple[float, float, float]:
        """Tool tip position at time t."""
        if not self.entries:
            return (0.0, 0.0, 0.0)
        e = self.entries[self.index(t)]
        span = max(e.t_end - e.t_start, 1e-9)
        f = min(max((t - e.t_start) / span, 0.0), 1.0)
        pts = [e.start] + ToolpathGeometry.points(e.move, e.start, 0.1)
        k = f * (len(pts) - 1)
        i = min(int(k), len(pts) - 2)
        r = k - i
        a, b = pts[i], pts[i + 1]
        return (a[0] + (b[0] - a[0]) * r, a[1] + (b[1] - a[1]) * r, a[2] + (b[2] - a[2]) * r)


def planner_seconds(moves: list, machine=None) -> list[float]:
    """Seconds per move as grbl's planner would run them: arcs split into chords, a speed limit at
    every junction from the junction deviation (grbl's formula), a backward and a forward pass so
    every entry speed is reachable with the machine's acceleration, then trapezoidal profiles."""
    from ..machine.profile import MachineProfile
    machine = machine or MachineProfile.standard()
    a = max(machine.acceleration.x, 1.0)
    jd = max(machine.junction_deviation, 0.001)
    rapid_v = machine.max_feed_any_direction / 60
    owners, lens, vs, dirs = [], [], [], []
    for k, (start, m) in enumerate(moves):
        v = rapid_v if m.role == Role.RAPID else max(m.feed, 1.0) / 60
        pts = [start]
        pts += [m.position] if m.motion == Motion.LINE else ToolpathGeometry.points(m, start, 0.1)
        for p, q in zip(pts, pts[1:]):
            dx, dy, dz = q[0] - p[0], q[1] - p[1], q[2] - p[2]
            ln = math.sqrt(dx * dx + dy * dy + dz * dz)
            if ln > 1e-6:
                owners.append(k)
                lens.append(ln)
                vs.append(v)
                dirs.append((dx / ln, dy / ln, dz / ln))
    times = [0.0] * len(moves)
    n = len(lens)
    if n == 0:
        return times
    entry = [0.0] * (n + 1)
    for i in range(1, n):
        d0, d1 = dirs[i - 1], dirs[i]
        c = -(d0[0] * d1[0] + d0[1] * d1[1] + d0[2] * d1[2])
        if c > 0.999999:
            vj2 = 0.0  # reversal
        elif c < -0.999999:
            vj2 = math.inf  # straight on
        else:
            sin_half = math.sqrt((1 - c) / 2)
            vj2 = a * jd * sin_half / (1 - sin_half)
        entry[i] = min(vj2, vs[i - 1] * vs[i - 1], vs[i] * vs[i])
    for i in range(n - 1, -1, -1):
        entry[i] = min(entry[i], entry[i + 1] + 2 * a * lens[i])
    for i in range(n):
        entry[i + 1] = min(entry[i + 1], entry[i] + 2 * a * lens[i])
    for i in range(n):
        v0, v1, vm, L = math.sqrt(entry[i]), math.sqrt(entry[i + 1]), vs[i], lens[i]
        da = max(vm * vm - v0 * v0, 0.0) / (2 * a)
        dd = max(vm * vm - v1 * v1, 0.0) / (2 * a)
        if da + dd <= L:
            t = (vm - v0) / a + (vm - v1) / a + (L - da - dd) / vm
        else:
            vp = math.sqrt((2 * a * L + v0 * v0 + v1 * v1) / 2)
            t = max(vp - v0, 0.0) / a + max(vp - v1, 0.0) / a
        times[owners[i]] += t
    return times


def duration(m: Move, start, last_dir: list, accel: float, machine) -> float:
    """Seconds for one move: length over feed plus a stop-and-go allowance at sharp corners.
    `last_dir` is a one-element list holding the previous direction (or None)."""
    ln = ToolpathGeometry.length(m, start)
    v = machine.max_feed_any_direction if m.role == Role.RAPID else max(m.feed, 1.0)
    t = ln / v * 60
    dx, dy, dz = m.x - start[0], m.y - start[1], m.z - start[2]
    n = math.sqrt(dx * dx + dy * dy + dz * dz)
    if n > 1e-9:
        d = (dx / n, dy / n, dz / n)
        ld = last_dir[0]
        if ld is not None and ld[0] * d[0] + ld[1] * d[1] + ld[2] * d[2] < 0.7:
            t += 2 * v / accel * 60
        last_dir[0] = d
    return t
