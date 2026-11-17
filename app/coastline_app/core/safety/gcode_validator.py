"""Independent safety check of a finished G-code file against the machine and the setup. Port of
Safety/GCodeValidator.swift. It reads the text (not Coastline's internal toolpath), so a bug
anywhere upstream is still caught before the file reaches the sender. Errors block export."""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field

import numpy as np

from ..inventory.checks import Issue, Severity
from ..post.grbl_post import fmt
from ..post.toolpath import Motion, Move, Role, ToolpathGeometry

_COMMENT = re.compile(r"\([^)]*\)")
_NUMBER = re.compile(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")


@dataclass
class Context:
    stock_min: tuple[float, float, float]  # stock box in the work frame (Z top = 0)
    stock_max: tuple[float, float, float]
    tool: object
    safe_z: float = 1.0  # rapids moving in X/Y must be at or above this Z
    allow_through_cut: bool = False  # cutting below the stock bottom (into the fixture)
    air_cut: bool = False  # an air-cut copy: moves run with the spindle off, above the work
    material_top: float = 0.0  # top of the material actually there (work Z)


@dataclass
class Report:
    issues: list[Issue]
    cut_length: float
    rapid_length: float
    min_z: float
    extent_min: tuple[float, float, float]
    extent_max: tuple[float, float, float]
    line_count: int

    @property
    def passed(self) -> bool:
        return not any(i.severity is Severity.ERROR for i in self.issues)


def _int(v: float) -> int:
    return int(v)


def _g(v: float) -> str:
    """Swift's `\\(v)` for a Double (e.g. 38.2, 1.0)."""
    return f"{v:.1f}" if float(v).is_integer() and abs(v) < 1e16 else repr(float(v))


class GCodeValidator:
    def __init__(self, machine=None) -> None:
        from ..machine.profile import MachineProfile
        self.machine = machine or MachineProfile.standard()

    def validate(self, gcode: str, c: Context) -> Report:
        machine = self.machine
        issues: list[Issue] = []

        def add(s: Severity, line: int, msg: str) -> None:
            key = msg[:40]  # each kind of problem once, with its first line number
            if not any(key in i.message for i in issues):
                issues.append(Issue(s, f"Line {line}: {msg}"))

        absolute = metric = spindle_on = False
        rpm = feed = 0.0
        motion = "G0"
        pos = [0.0, 0.0, 1e6]  # unknown start: the sender runs programs from a retracted spindle
        known_z = False
        cut_length = rapid_length = 0.0
        min_z = math.inf
        lo = [math.inf] * 3
        hi = [-math.inf] * 3
        r = c.tool.diameter / 2
        lines = gcode.split("\n")
        for index, raw in enumerate(lines):
            n = index + 1
            if len(raw) > machine.max_line_length:
                add(Severity.ERROR, n, f"longer than {machine.max_line_length} characters; grbl rejects it (error 11).")
            code = _COMMENT.sub("", raw).upper()
            if not code.strip(" \t"):
                continue
            words: list[tuple[str, float]] = []
            i = 0
            while i < len(code):
                while i < len(code) and code[i] in " \t":
                    i += 1
                if i >= len(code):
                    break
                letter = code[i]
                i += 1
                if letter == "$":
                    break  # grbl system command
                while i < len(code) and code[i] in " \t":
                    i += 1
                m = _NUMBER.match(code, i)
                if m is None:
                    add(Severity.ERROR, n, f"can't read '{code}'.")
                    break
                words.append((letter, float(m.group(0))))
                i = m.end()
            target = list(pos)
            has_axis = is_g53 = False
            arc = None
            for l, v in words:
                if l == "G":
                    if v in (0, 1, 2, 3):
                        motion = f"G{int(v)}"
                    elif v == 90:
                        absolute = True
                    elif v == 91:
                        absolute = False
                        add(Severity.ERROR, n, "G91 incremental mode: Coastline programs must stay absolute.")
                    elif v == 21:
                        metric = True
                    elif v == 20:
                        add(Severity.ERROR, n, "G20 inches: Coastline programs are in mm.")
                    elif v == 53:
                        is_g53 = True
                    elif v in (17, 54, 4, 40, 91.1, 94):
                        pass
                    elif v == 93:
                        add(Severity.ERROR, n, "G93 inverse-time feed: Coastline programs require G94 feed per minute.")
                    elif v in (28, 30, 43, 92):
                        add(Severity.ERROR, n, f"G{int(v)} isn't used on the machine and can move to unexpected places.")
                    elif v in (81, 82, 83, 73):
                        add(Severity.ERROR, n, f"canned cycle G{int(v)}: grbl doesn't support it.")
                    else:
                        add(Severity.WARNING, n, f"unusual code G{_g(v)}.")
                elif l == "M":
                    if v == 3:
                        spindle_on = True
                    elif v == 5:
                        spindle_on = False
                    elif v == 4:
                        add(Severity.WARNING, n, "M4 reverse spindle is only for probing.")
                    elif v == 6:
                        add(Severity.ERROR, n, "M6: the machine has no tool changer; tool changes are guided steps.")
                    elif v in (30, 2):
                        add(Severity.INFO, n, f"M{int(v)} program end; the maker's post ends with M5 instead.")
                elif l == "S":
                    rpm = v
                    if v != 0 and not machine.is_usable_rpm(v):
                        add(Severity.ERROR, n, f"S{int(v)} is outside the machine's {int(machine.spindle_rpm.lower)}–{int(machine.spindle_rpm.upper)} RPM.")
                elif l == "F":
                    feed = v
                elif l == "X":
                    target[0], has_axis = v, True
                elif l == "Y":
                    target[1], has_axis = v, True
                elif l == "Z":
                    target[2], has_axis, known_z = v, True, True
                elif l == "I":
                    arc = (v, arc[1] if arc else 0.0)
                elif l == "J":
                    arc = (arc[0] if arc else 0.0, v)
            if is_g53:
                # A G53 Z move is a machine-coordinate retract: afterwards the tool is fully up.
                if any(l == "Z" for l, _ in words):
                    pos[2] = 1e6
                    known_z = True
                continue
            if not has_axis:
                continue
            if not absolute:
                add(Severity.ERROR, n, "motion before G90: grbl starts in G91, so this would move relative.")
            if not metric:
                add(Severity.ERROR, n, "motion before G21 (mm).")
            d = (target[0] - pos[0], target[1] - pos[1], target[2] - pos[2])
            dist = math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
            if motion == "G0":
                rapid_length += dist
                moves_xy = abs(d[0]) > 1e-6 or abs(d[1]) > 1e-6
                in_footprint = (c.stock_min[0] - r < target[0] < c.stock_max[0] + r
                                and c.stock_min[1] - r < target[1] < c.stock_max[1] + r)
                safe = c.safe_z - 0.001  # written to 0.001 mm: a rapid at the safe height may read a hair under
                if known_z and min(pos[2], target[2]) < safe and in_footprint and (moves_xy or target[2] < safe):
                    add(Severity.ERROR, n, f"rapid move below the safe height (Z{fmt(c.safe_z)}) over the stock. Rapids into material break tools.")
            else:
                if (not spindle_on or rpm == 0) and not c.air_cut:
                    add(Severity.ERROR, n, "cutting move with the spindle stopped.")
                if feed <= 0:
                    add(Severity.ERROR, n, "cutting move without a feed rate.")
                if feed > machine.max_rate.y + 1e-6:
                    add(Severity.ERROR, n, f"F{int(feed)} is faster than the machine can move ({int(machine.max_rate.y)} mm/min).")
                elif dist > 0 and feed * abs(d[0]) / dist > machine.max_rate.x + 1e-6:
                    add(Severity.WARNING, n, f"X component of F{int(feed)} exceeds X's {int(machine.max_rate.x)} mm/min; grbl will slow it.")
                if motion in ("G2", "G3"):
                    if arc is None:
                        add(Severity.ERROR, n, "arc without I/J.")
                        pos = target
                        continue
                    rs = math.sqrt(arc[0] * arc[0] + arc[1] * arc[1])
                    cx, cy = pos[0] + arc[0], pos[1] + arc[1]
                    re_ = math.sqrt((target[0] - cx) ** 2 + (target[1] - cy) ** 2)
                    if abs(rs - re_) > 0.005 + rs * 1e-4:
                        add(Severity.ERROR, n, f"arc end isn't on the arc (radius {fmt(rs)} vs {fmt(re_)}); grbl raises error 33.")
                    m = Move(Role.CUT, Motion.ARC_CW if motion == "G2" else Motion.ARC_CCW, target[0], target[1], target[2], arc[0], arc[1])
                    cut_length += ToolpathGeometry.length(m, pos)
                else:
                    cut_length += dist
                min_z = min(min_z, target[2])
                lo = [min(a, b) for a, b in zip(lo, target)]
                hi = [max(a, b) for a, b in zip(hi, target)]
            pos = target
        if min_z < math.inf:
            if not c.allow_through_cut and min_z < c.stock_min[2] - 1e-6:
                issues.append(Issue(Severity.ERROR, f"Cuts to Z{fmt(min_z)}, below the stock bottom (Z{fmt(c.stock_min[2])}): it would cut into the fixture."))
            depth = c.material_top - min_z
            tool = c.tool
            from ..inventory.items import ToolKind
            if depth > tool.stickout - 1:
                issues.append(Issue(Severity.ERROR, f"Cuts {fmt(depth)} mm deep, but the tool only sticks out {fmt(tool.stickout)} mm: the collet nut would hit the work."))
            elif tool.kind is ToolKind.THREAD_MILL and depth > tool.flute_length + 1e-6:
                issues.append(Issue(Severity.INFO, f"Threads reach {fmt(depth)} mm below the stock face; the thread mill's {fmt(tool.flute_length)} mm reach counts from each hole's top."))
            elif tool.kind.cuts_sideways and depth > tool.flute_length + 1e-6:
                if tool.shank_diameter > tool.diameter + 0.02:
                    issues.append(Issue(Severity.INFO, f"Reaches {fmt(depth)} mm deep, below its {fmt(tool.flute_length)} mm flutes, only where its shank clears the part."))
                else:
                    issues.append(Issue(Severity.WARNING, f"Cuts {fmt(depth)} mm deep with {fmt(tool.flute_length)} mm flutes: the shank rubs deep walls (friction and heat)."))
            span = [h - l for h, l in zip(hi, lo)]
            t = machine.travel
            if span[0] > t.x or span[1] > t.y or span[2] > t.z:
                issues.append(Issue(Severity.ERROR, f"The toolpath spans {fmt(span[0])} × {fmt(span[1])} × {fmt(span[2])} mm, more than the machine's travel."))
            margin = r + 6
            if (lo[0] < c.stock_min[0] - margin or hi[0] > c.stock_max[0] + margin
                    or lo[1] < c.stock_min[1] - margin or hi[1] > c.stock_max[1] + margin):
                issues.append(Issue(Severity.WARNING, f"Cutting moves reach more than {fmt(margin)} mm outside the stock. Check that the clamps are clear."))
        if "G53 G0 G90 Z-1." not in gcode:
            issues.append(Issue(Severity.WARNING, "No full Z retract (G53 G0 G90 Z-1.) at the start/end."))
        return Report(issues, cut_length, rapid_length, min_z, tuple(lo), tuple(hi), len(lines))


def time_estimate_seconds(paths: list, machine=None) -> float:
    """Path time from the grbl planner simulation (TimeEstimate.seconds)."""
    from ..post.timeline import ToolpathTimeline
    return ToolpathTimeline(paths, [], [], machine).duration
