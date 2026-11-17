"""The stock as the job leaves it, cut by cut: tri-dexel columns along side A's X, Y and Z. Port
of Sim/StockModel.swift (sweeping, excess checks and meshing are C++, native/src/kernels.cpp).

Every setup's cuts are swept in, in the order they run at the machine, each through its own frame
(SetupSide.to_a); finishing, floors, holes and threads are first checked against it: where the
cutter meets no excess the pass is air, and long stretches of air lift over."""

from __future__ import annotations

import math

import numpy as np

from ... import _kernels as K
from ..plan.setup_side import SetupSide
from ..post.toolpath import Move, Role, ToolpathGeometry
from .dexel import DexelGrid


def plane(k: int) -> tuple[int, int]:
    """The two in-plane axes of the grid whose columns run along axis k."""
    return (1, 2) if k == 0 else (0, 2) if k == 1 else (0, 1)


def cutter_for(tool) -> "K.Cutter":
    """The cutting part of a tool as the model sweeps it: radius, how far above the tip the full
    radius starts (a ball's radius, a drill's cone), and the flutes' length."""
    from ..inventory.items import ToolKind
    radius = tool.diameter / 2
    length = max(tool.flute_length, 0.1)
    corner, half = 0.0, 0.0
    if tool.kind is ToolKind.BALL_END_MILL:
        tip, start = 1, radius
    elif tool.kind is ToolKind.BULL_NOSE_END_MILL and tool.corner_radius > 1e-6:
        corner = min(tool.corner_radius, radius)
        tip, start = 2, corner
    elif tool.kind in (ToolKind.DRILL, ToolKind.SPOT_DRILL, ToolKind.CHAMFER_MILL, ToolKind.ENGRAVER):
        half = min(max((tool.angle if tool.angle is not None else 118) / 2, 5), 89) * math.pi / 180
        tip, start = 3, radius / math.tan(half)
    else:
        tip, start = 0, 0.0
    return K.Cutter(tip, radius, start, length, length, corner, half)


class StockModel:
    def __init__(self, stock, cell: float = 0.5, part_vertices=None, indices=None, flip_axis: int | None = None) -> None:
        self.stock = np.asarray(stock, float)
        self.cell = cell
        self.flip_axis = flip_axis
        v = np.asarray(part_vertices if part_vertices is not None else [], np.float32).reshape(-1)
        i = np.asarray(indices if indices is not None else [], np.uint32).reshape(-1)
        self._m = K.StockModel(float(self.stock[0]), float(self.stock[1]), float(self.stock[2]), float(cell), v, i)

    def copy(self) -> "StockModel":
        """An independent copy (a snapshot of the stock as it is now)."""
        c = StockModel.__new__(StockModel)
        c.stock, c.cell, c.flip_axis = self.stock.copy(), self.cell, self.flip_axis
        c._m = self._m.copy()
        return c

    def span(self, k: int) -> tuple[float, float]:
        s = self.stock
        return (-s[0] / 2, s[0] / 2) if k == 0 else (-s[1] / 2, s[1] / 2) if k == 1 else (-s[2], 0.0)

    def tool_axis(self, side: int) -> tuple[int, float]:
        """The A axis a side's tool lies along, and the way its shank points (+1 toward +)."""
        d = SetupSide.rotation(side, self.flip_axis).T @ np.array([0.0, 0.0, 1.0])
        k = int(np.argmax(np.abs(d)))
        return k, (1.0 if d[k] > 0 else -1.0)

    def to_a(self, p, side: int) -> np.ndarray:
        return SetupSide.to_a(p, side, self.stock, self.flip_axis)

    def _to_a_many(self, points: np.ndarray, side: int) -> np.ndarray:
        a = self.stock
        s = SetupSide.stock_size(a, side)
        r = SetupSide.rotation(side, self.flip_axis)
        return (points - np.array([0, 0, -s[2] / 2])) @ r + np.array([0, 0, -a[2] / 2])

    def sweep(self, moves: list[Move], side: int, tool, slice: float | None = None) -> None:
        """Sweeps a setup's cutting moves (its work frame) into the stock. Across the tool axis only
        the flutes' lowest `slice` mm (at least two cells) are swept."""
        c = cutter_for(tool)
        if slice is not None:
            c.cross_length = min(c.length, max(slice + self.cell, 2 * self.cell) + c.start)
        j, sign = self.tool_axis(side)
        cell = self.cell
        points: list[tuple[float, float, float]] = []  # side frame, merged within 0.4 mm
        breaks: list[int] = []  # indices where a new run starts (after a rapid)
        previous = moves[0].position if moves else (0.0, 0.0, 0.0)
        frm = previous
        segs: list[tuple] = []
        for m in moves:
            if m.role != Role.RAPID:
                angle = min(0.08, math.sqrt(0.8 * cell / max(math.hypot(m.i, m.j), cell)))
                pts = ToolpathGeometry.points(m, previous, angle)
                last = len(pts) - 1
                for n, p in enumerate(pts):
                    d = math.dist(frm, p)
                    if d >= 0.4 or n == last:
                        if d > 1e-9:
                            segs.append((frm, p))
                        frm = p
            else:
                frm = m.position
            previous = m.position
        if not segs:
            return
        arr = np.array(segs, float)  # (n, 2, 3)
        a = self._to_a_many(arr[:, 0], side)
        b = self._to_a_many(arr[:, 1], side)
        counts = np.maximum(1, np.ceil(np.abs(b[:, j] - a[:, j]) / cell).astype(int))
        if counts.max() == 1:
            pieces = np.hstack([a, b])
        else:
            rows = []
            for ai, bi, n in zip(a, b, counts):
                for k in range(n):
                    rows.append(np.concatenate([ai + (bi - ai) * (k / n), ai + (bi - ai) * ((k + 1) / n)]))
            pieces = np.array(rows)
        self._m.sweep(np.ascontiguousarray(pieces), j, sign, c)

    def lift_air(self, moves: list[Move], side: int, tool, minimum: float = 4, step: float = 0.5, safe_z: float = 3,
                 slice: float | None = None, plunge_feed: float = 0.0) -> tuple[list[Move], float]:
        """The moves with every stretch of air longer than `minimum` mm lifted over: the tool
        rises to safe_z, crosses, and comes down where there is stock again. Returns the moves
        and the skipped cutting length."""
        from ..safety.fixture_clearance import FixtureClearance
        if not moves:
            return moves, 0.0
        first = moves[0]
        c = cutter_for(tool)
        if slice is not None:
            c.length = min(c.length, max(slice + self.cell, 2 * self.cell) + c.start)
        j, sign = self.tool_axis(side)
        samples: list[tuple[tuple[float, float, float], int]] = []
        previous = first.position
        for k, m in enumerate(moves):
            if k > 0 and m.role != Role.RAPID:
                for q in FixtureClearance.samples(previous, m, step):
                    samples.append((q, k))
            previous = m.position
        if not samples:
            return moves, 0.0
        pts = np.array([s[0] for s in samples], float)
        air = ~self._m.meets_excess(np.ascontiguousarray(self._to_a_many(pts, side)), j, sign, c, 0.03)
        lifted = [False] * len(samples)
        i = 0
        while i < len(samples):
            if not air[i]:
                i += 1
                continue
            e, length = i, 0.0
            while e + 1 < len(samples) and air[e + 1]:
                length += math.dist(samples[e][0], samples[e + 1][0])
                e += 1
            if length >= minimum:
                for t in range(i, e + 1):
                    lifted[t] = True
            i = e + 1
        if not any(lifted):
            return moves, 0.0
        out = [first]
        skipped, up, s = 0.0, False, 0
        last = first.position
        for k in range(1, len(moves)):
            m = moves[k]
            if m.role == Role.RAPID:
                if up:
                    out.append(Move(Role.RAPID, x=m.x, y=m.y, z=max(m.z, safe_z)))
                    up = False
                out.append(m)
                last = m.position
                continue
            mine = []
            while s < len(samples) and samples[s][1] == k:
                mine.append((samples[s][0], lifted[s]))
                s += 1
            if not any(l for _, l in mine) and not up:
                out.append(m)
                last = m.position
                continue
            for p, lift in mine:
                if lift:
                    if not up:
                        out.append(Move(Role.RAPID, x=last[0], y=last[1], z=safe_z))
                        up = True
                    skipped += math.dist(last, p)
                elif up:
                    out.append(Move(Role.RAPID, x=p[0], y=p[1], z=safe_z))
                    out.append(Move(Role.PLUNGE, x=p[0], y=p[1], z=p[2], feed=plunge_feed))
                    up = False
                else:
                    out.append(Move(m.role, x=p[0], y=p[1], z=p[2], feed=m.feed))
                last = p
        if up:
            out.append(Move(Role.RAPID, x=last[0], y=last[1], z=safe_z))
        return out, skipped

    def meets_excess(self, points_a, side: int, tool, slice: float | None = None, tol: float = 0.03) -> np.ndarray:
        """Per point (side A frame): does the cutter with its tip there meet stock still to cut?"""
        c = cutter_for(tool)
        if slice is not None:
            c.length = min(c.length, max(slice + self.cell, 2 * self.cell) + c.start)
        j, sign = self.tool_axis(side)
        return self._m.meets_excess(np.ascontiguousarray(np.asarray(points_a, float).reshape(-1, 3)), j, sign, c, tol)

    def material(self, axis: int) -> DexelGrid:
        """The stock still there along axis k's columns (the part included)."""
        return DexelGrid._wrap(self._m.material(axis))

    def material_along(self, axis: int, through) -> list[tuple[float, float]]:
        return self._m.material_along(axis, float(through[0]), float(through[1]), float(through[2]))

    def removed(self, k: int) -> DexelGrid:
        return DexelGrid._wrap(self._m.removed(k))

    def part(self, k: int) -> DexelGrid:
        return DexelGrid._wrap(self._m.part(k))


def dexel_mesh(grid: DexelGrid, axis: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """A closed mesh of a dexel grid's spans along `axis` (side A's frame)."""
    return K.dexel_mesh(grid._g, axis)
