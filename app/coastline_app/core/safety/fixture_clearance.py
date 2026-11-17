"""Fixture clearance: everything that holds the work as seen from the spindle, and checks of a
toolpath against it with the tool's real shape (cutter, shank, collet nut). Port of
Safety/FixtureClearance.swift; the field is C++ (native/src/kernels.cpp)."""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from ... import _kernels as K
from ..geometry import swift_round
from ..post.toolpath import Motion, Move, Role
from ..units import Length

NUT_RADIUS = 8.0  # ER-11 collet nut: Ø16 mm
NUT_LENGTH = 18.0  # ~18 mm long in front of the spindle


class FixtureField:
    """For each cell of the work-frame XY plane, the highest fixture Z (toward the spindle). The tool
    at (x, y) with its tip at z only touches a fixture whose top within its radius is above z."""

    def __init__(self, triangles, region_min, region_max, cell: float = 0.25) -> None:
        t = np.asarray(triangles, float).reshape(-1, 3)
        self._f = K.FixtureField(np.ascontiguousarray(t), float(region_min[0]), float(region_min[1]),
                                 float(region_max[0]), float(region_max[1]), float(cell))

    min_x = property(lambda s: s._f.min_x)
    min_y = property(lambda s: s._f.min_y)
    cell = property(lambda s: s._f.cell)
    nx = property(lambda s: s._f.nx)
    ny = property(lambda s: s._f.ny)

    @property
    def is_empty(self) -> bool:
        return self._f.empty()

    @property
    def top(self) -> np.ndarray:
        """(ny, nx) highest fixture Z (−inf where there's none)."""
        return self._f.top()

    def dilated(self, radius: float) -> np.ndarray:
        return self._f.dilated(radius)

    def intrusions(self, points, z0s: list[float], radii: list[float], margin: float) -> np.ndarray:
        return self._f.intrusions(np.ascontiguousarray(np.asarray(points, float).reshape(-1, 3)), list(z0s), list(radii), margin)

    def keep_out(self, above: float, block: float = 1.0) -> list[tuple[tuple[float, float], tuple[float, float]]]:
        """Where fixtures rise above work Z `above`, as rectangles on a `block`-mm grid (runs merged
        along X per row): keep-out areas for toolpaths that cut deeper."""
        cell, nx, ny = self.cell, self.nx, self.ny
        k = max(int(swift_round(block / cell)), 1)
        bx, by = (nx + k - 1) // k, (ny + k - 1) // k
        hot = self.top > above
        out = []
        for j in range(by):
            run = None
            rows = hot[j * k:min((j + 1) * k, ny)]
            for i in range(bx + 1):
                hit = bool(rows[:, i * k:min((i + 1) * k, nx)].any()) if i < bx else False
                if hit and run is None:
                    run = i
                if not hit and run is not None:
                    out.append(((self.min_x + (run * k - 0.5) * cell, self.min_y + (j * k - 0.5) * cell),
                                (self.min_x + (min(i * k, nx) - 0.5) * cell, self.min_y + (min((j + 1) * k, ny) - 0.5) * cell)))
                    run = None
        return out


@dataclass
class Hit:
    move_index: int
    position: tuple[float, float, float]  # tool tip, work frame
    part: str  # "cutter", "shank" or "collet nut"
    depth: float  # how far into the fixture (plus the margin), mm

    def to_json(self) -> dict:
        return {"moveIndex": self.move_index, "position": list(self.position), "part": self.part, "depth": self.depth}

    @staticmethod
    def from_json(d) -> "Hit":
        p = d["position"]
        return Hit(int(d["moveIndex"]), (float(p[0]), float(p[1]), float(p[2])), d["part"], float(d["depth"]))


class FixtureClearance:
    NUT_RADIUS = NUT_RADIUS
    NUT_LENGTH = NUT_LENGTH

    @staticmethod
    def sections(tool) -> list[tuple[float, float, float, str]]:
        """Tool sections from the tip: (from, to, radius, name), mm."""
        flutes = min(tool.flute_length, tool.stickout)
        return [(0.0, flutes, tool.diameter / 2, "cutter"),
                (flutes, tool.stickout, max(tool.shank_diameter, tool.diameter) / 2, "shank"),
                (tool.stickout, tool.stickout + NUT_LENGTH, NUT_RADIUS, "collet nut")]

    @staticmethod
    def samples(start, m: Move, step: float) -> list[tuple[float, float, float]]:
        """Points along a move from `start`, at most `step` apart (arcs followed in XY)."""
        sx, sy, sz = start[0], start[1], start[2]
        ex, ey, ez = m.x, m.y, m.z
        if m.motion == Motion.LINE:
            n = max(math.ceil(math.sqrt((ex - sx) ** 2 + (ey - sy) ** 2 + (ez - sz) ** 2) / step), 1)
            return [(sx + (ex - sx) * k / n, sy + (ey - sy) * k / n, sz + (ez - sz) * k / n) for k in range(1, n + 1)]
        cx, cy = sx + m.i, sy + m.j
        r = math.hypot(sx - cx, sy - cy)
        a0, a1 = math.atan2(sy - cy, sx - cx), math.atan2(ey - cy, ex - cx)
        if m.motion == Motion.ARC_CCW:
            while a1 <= a0 + 1e-9:
                a1 += 2 * math.pi
        else:
            while a1 >= a0 - 1e-9:
                a1 -= 2 * math.pi
        n = max(math.ceil(abs(a1 - a0) * r / step), 1)
        out = []
        for k in range(1, n + 1):
            f = k / n
            a = a0 + (a1 - a0) * f
            out.append((cx + r * math.cos(a), cy + r * math.sin(a), sz + (ez - sz) * f))
        return out

    @staticmethod
    def _all_samples(moves: list[Move], step: float) -> tuple[np.ndarray, np.ndarray]:
        """Every move's sample points (the first move: its end) and each point's move index."""
        pts, owners = [moves[0].position], [0]
        prev = moves[0].position
        for k in range(1, len(moves)):
            m = moves[k]
            for p in FixtureClearance.samples(prev, m, step):
                pts.append(p)
                owners.append(k)
            prev = m.position
        return np.array(pts, float), np.array(owners, int)

    @staticmethod
    def _intrusions(field: FixtureField, tool, points: np.ndarray, margin: float) -> np.ndarray:
        secs = FixtureClearance.sections(tool)
        return field.intrusions(points, [s[0] for s in secs], [s[2] for s in secs], margin)

    @staticmethod
    def check(moves: list[Move], tool, field: FixtureField, margin: float = 0.5, limit: int = 50) -> list[Hit]:
        """The first hits (at most `limit`, one per move) where the tool comes within `margin`."""
        if field.is_empty or not moves:
            return []
        secs = FixtureClearance.sections(tool)
        pts, owners = FixtureClearance._all_samples(moves, field.cell)
        intr = FixtureClearance._intrusions(field, tool, pts, margin)
        hits: list[Hit] = []
        seen_move = -1
        hit_rows = np.nonzero((intr > 0).any(axis=1))[0]
        for i in hit_rows:
            k = int(owners[i])
            if k == seen_move:
                continue
            row = intr[i]
            s = int(np.nonzero(row > 0)[0][0])
            hits.append(Hit(k, tuple(float(v) for v in pts[i]), secs[s][3], float(row[s])))
            seen_move = k
            if len(hits) >= limit:
                break
        return hits

    @staticmethod
    def required_setback(moves: list[Move], tool, field: FixtureField, margin: float = 0.5) -> float:
        """How far every fixture would have to move back for this path to keep `margin`."""
        if field.is_empty or not moves:
            return 0.0
        pts, _ = FixtureClearance._all_samples(moves, field.cell)
        intr = FixtureClearance._intrusions(field, tool, pts, margin)
        finite = intr[np.isfinite(intr)]
        return max(0.0, float(finite.max())) if finite.size else 0.0

    @staticmethod
    def clip(moves: list[Move], tool, field: FixtureField, margin: float = 0.5, safe_z: float = 3,
             plunge_feed: float = 0.0) -> tuple[list[Move], float]:
        """The moves with every stretch where the tool would come within `margin` of a fixture
        lifted out. Returns the new moves and how much cutting (mm) was skipped."""
        if field.is_empty or not moves:
            return moves, 0.0
        secs = FixtureClearance.sections(tool)
        z0s, radii = [s[0] for s in secs], [s[2] for s in secs]
        step = max(field.cell, 0.25)

        def blocked_many(points) -> np.ndarray:
            if not len(points):
                return np.zeros(0, bool)
            return (field.intrusions(points, z0s, radii, margin) > 0).any(axis=1)

        out: list[Move] = []
        skipped = 0.0
        prev = moves[0].position
        lifted = False
        for k, m in enumerate(moves):
            if k == 0 or m.role == Role.RAPID:
                if lifted:
                    out.append(Move(Role.RAPID, x=m.x, y=m.y, z=max(m.z, safe_z)))
                    if m.z < safe_z:
                        out.append(Move(Role.RAPID, x=m.x, y=m.y, z=m.z))
                    lifted = False
                else:
                    out.append(m)
                prev = m.position
                continue
            pts = FixtureClearance.samples(prev, m, step)
            flags = blocked_many([prev] + pts)
            if not flags.any() and not lifted:
                out.append(m)
                prev = m.position
                continue
            last = prev
            for p, b in zip(pts, flags[1:]):
                if b:
                    if not lifted:
                        out.append(Move(Role.RAPID, x=last[0], y=last[1], z=safe_z))
                        lifted = True
                    skipped += math.dist(p, last)
                elif lifted:
                    out.append(Move(Role.RAPID, x=p[0], y=p[1], z=safe_z))
                    out.append(Move(Role.PLUNGE, x=p[0], y=p[1], z=p[2], feed=plunge_feed))
                    lifted = False
                else:
                    out.append(Move(m.role, x=p[0], y=p[1], z=p[2], feed=m.feed))
                last = p
            prev = m.position
        if lifted and out:
            l = out[-1]
            out.append(Move(Role.RAPID, x=l.x, y=l.y, z=safe_z))
        return out, skipped

    @staticmethod
    def describe(hits: list[Hit]) -> str | None:
        """A sentence for the safety report."""
        if not hits:
            return None
        worst = hits[0]
        for h in hits[1:]:
            if worst.depth < h.depth:
                worst = h
        p = worst.position
        places = "1 place" if len(hits) == 1 else f"{len(hits)}+ places"
        return (f"The {worst.part} comes within the safety margin of a clamp or stop ({places}, worst {Length.mm(worst.depth)} mm in, "
                f"near X{Length.mm(p[0])} Y{Length.mm(p[1])} Z{Length.mm(p[2])}).")


def box_triangles(a, b) -> np.ndarray:
    """The 12 triangles of a box (36 points), as FixtureField.boxTriangles."""
    c = [np.array([b[0] if i & 1 else a[0], b[1] if i & 2 else a[1], b[2] if i & 4 else a[2]], float) for i in range(8)]
    faces = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
    return np.array([c[i] for f in faces for i in (f[0], f[1], f[2], f[0], f[2], f[3])])
