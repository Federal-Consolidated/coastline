"""Toolpath moves, operation toolpaths and their geometry. Port of Post/Toolpath.swift."""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from enum import IntEnum

import numpy as np


class Role(IntEnum):
    RAPID = 0
    CUT = 1
    PLUNGE = 2
    RAMP = 3
    LEAD = 4
    LINK = 5


class Motion(IntEnum):
    LINE = 0
    ARC_CW = 1
    ARC_CCW = 2


class Move:
    """One move of a toolpath, in the work frame (mm). `i`, `j`: arc centre offset from the start
    point (G17 plane). `feed`: mm/min (ignored for rapids)."""

    __slots__ = ("role", "motion", "x", "y", "z", "i", "j", "feed")

    def __init__(self, role: Role, motion: Motion = Motion.LINE, x: float = 0.0, y: float = 0.0, z: float = 0.0,
                 i: float = 0.0, j: float = 0.0, feed: float = 0.0) -> None:
        self.role, self.motion = role, motion
        self.x, self.y, self.z, self.i, self.j, self.feed = x, y, z, i, j, feed

    @property
    def position(self) -> tuple[float, float, float]:
        return (self.x, self.y, self.z)

    def __eq__(self, o: object) -> bool:
        return isinstance(o, Move) and (self.role, self.motion, self.x, self.y, self.z, self.i, self.j, self.feed) == \
            (o.role, o.motion, o.x, o.y, o.z, o.i, o.j, o.feed)

    def __repr__(self) -> str:
        return (f"Move({self.role.name}, {self.motion.name}, x={self.x}, y={self.y}, z={self.z}"
                + (f", i={self.i}, j={self.j}" if self.motion else "") + (f", feed={self.feed}" if self.feed else "") + ")")

    def copy(self) -> "Move":
        return Move(self.role, self.motion, self.x, self.y, self.z, self.i, self.j, self.feed)


def moves_from_array(rows: np.ndarray) -> list[Move]:
    """Rows [role, motion, x, y, z, i, j, feed] (the engine's blob layout) → moves."""
    out = []
    roles = {int(r): r for r in Role}
    motions = {int(m): m for m in Motion}
    for r in np.asarray(rows, float).reshape(-1, 8).tolist():
        out.append(Move(roles.get(int(r[0]), Role.CUT), motions.get(int(r[1]), Motion.LINE), r[2], r[3], r[4], r[5], r[6], r[7]))
    return out


def moves_to_array(moves: list[Move]) -> np.ndarray:
    return np.array([[m.role, m.motion, m.x, m.y, m.z, m.i, m.j, m.feed] for m in moves], float).reshape(-1, 8)


@dataclass
class OperationToolpath:
    """The toolpath of one operation, as returned by the engine."""

    operation_id: str
    moves: list[Move]
    warnings: list[str] = field(default_factory=list)
    # Expected things the plan already handles: shown quietly, not as warnings.
    notes: list[str] = field(default_factory=list)
    min_stickout: float | None = None  # shortest stick-out that keeps the collet nut clear, mm

    @staticmethod
    def decode(operation_id: str, blob: bytes, warnings: list[str]) -> "OperationToolpath":
        """The engine's blob: float32 rows [role, motion, x, y, z, i, j, feed]."""
        f = np.frombuffer(blob, "<f4")
        rows = f[: len(f) // 8 * 8].astype(float).reshape(-1, 8)
        return OperationToolpath(operation_id, moves_from_array(rows), list(warnings))


class ToolpathGeometry:
    """Toolpath geometry helpers shared by the viewer, time estimates and checks."""

    @staticmethod
    def points(m: Move, start, segment_angle: float = 0.1) -> list[tuple[float, float, float]]:
        """Points along a move from `start`, arcs subdivided to `segment_angle` radians."""
        if m.motion == Motion.LINE:
            return [(m.x, m.y, m.z)]
        sx, sy, sz = start[0], start[1], start[2]
        cx, cy = sx + m.i, sy + m.j
        r = math.sqrt((sx - cx) ** 2 + (sy - cy) ** 2)
        a0 = math.atan2(sy - cy, sx - cx)
        a1 = math.atan2(m.y - cy, m.x - cx)
        if m.motion == Motion.ARC_CCW:
            while a1 <= a0 + 1e-9:
                a1 += 2 * math.pi
        else:
            while a0 <= a1 + 1e-9:
                a0 += 2 * math.pi
        sweep = a1 - a0
        n = max(math.ceil(abs(sweep) / segment_angle), 2)
        out = []
        for k in range(1, n + 1):
            t = k / n
            a = a0 + sweep * t
            out.append((cx + r * math.cos(a), cy + r * math.sin(a), sz + (m.z - sz) * t))
        return out

    @staticmethod
    def length(m: Move, start) -> float:
        """Length of a move, mm."""
        px, py, pz = start[0], start[1], start[2]
        total = 0.0
        for q in ToolpathGeometry.points(m, start, 0.05):
            total += math.sqrt((q[0] - px) ** 2 + (q[1] - py) ** 2 + (q[2] - pz) ** 2)
            px, py, pz = q
        return total
