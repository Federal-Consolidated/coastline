"""Assigns generated cutting operations to owned library fixtures. Cut order is kept, and dynamic
programming minimizes re-clampings. No cut is silently left out when every fixture obstructs it.
Port of the planner half of Plan/LibraryWorkholding.swift (LibraryWorkholdingPlanner, StockRemoval)."""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from ..feeds import OperationKind as K
from ..geometry import swift_round
from ..inventory.items import ClampAxis, ToolKind
from ..post.toolpath import Motion, Move, Role, ToolpathGeometry
from ..safety.fixture_clearance import NUT_RADIUS, FixtureClearance, FixtureField
from ..sim.dexel import DexelGrid, ToolShape, ToolShapeKind
from ..units import Length
from .setup_side import SetupSide
from .workholding_profile import LibraryWorkholdingPlan, LibraryWorkholdingStep


@dataclass
class Cut:
    key: str
    side: int
    operation: object
    tool: object
    moves: list[Move]


@dataclass
class Candidate:
    fixture: object
    field: FixtureField
    occupied: DexelGrid
    machine_origin: np.ndarray | None = None  # bare spindle nose (stick-out 0) at work zero, machine coords
    model_signature: str | None = None


def _round_int(v: np.ndarray) -> np.ndarray:
    """Swift's `Int(x.rounded())`: half away from zero."""
    return (np.sign(v) * np.floor(np.abs(v) + 0.5)).astype(np.int64)


def _to_a_affine(side: int, stock, flip_axis: int | None):
    """SetupSide.to_a as (matrix, before, after): to_a(p) = M @ (p − before) + after."""
    a = np.asarray(stock, float)
    s = SetupSide.stock_size(a, side)
    return SetupSide.rotation(side, flip_axis).T, np.array([0, 0, -s[2] / 2]), np.array([0, 0, -a[2] / 2])


class StockRemoval:
    """Material removed from the stock, in side-A work coordinates, on three dexel grids: columns
    along A's X (grid 0, plane Y–Z), Y (grid 1, plane X–Z) and Z (grid 2, plane X–Y)."""

    def __init__(self, stock, cell: float, grids: list[DexelGrid] | None = None) -> None:
        s = np.asarray(stock, float)
        self.stock, self.cell = s, cell
        self.grids = grids or [DexelGrid((-s[1] / 2, -s[2]), (s[1] / 2, 0), cell),
                               DexelGrid((-s[0] / 2, -s[2]), (s[0] / 2, 0), cell),
                               DexelGrid((-s[0] / 2, -s[1] / 2), (s[0] / 2, s[1] / 2), cell)]

    def copy(self) -> "StockRemoval":
        return StockRemoval(self.stock, self.cell, [g.copy() for g in self.grids])

    @staticmethod
    def tool_axis(side: int) -> tuple[int, float]:
        """The A axis a side's tool lies along, and whether its shank points along +."""
        d = SetupSide.rotation(side).T @ np.array([0.0, 0.0, 1.0])
        k = max(range(3), key=lambda i: abs(d[i]))
        return k, (1.0 if d[k] > 0 else -1.0)

    @staticmethod
    def split(q, k: int) -> tuple[tuple[float, float], float]:
        if k == 0:
            return (q[1], q[2]), q[0]
        if k == 1:
            return (q[0], q[2]), q[1]
        return (q[0], q[1]), q[2]

    def span(self, k: int) -> tuple[float, float]:
        s = self.stock
        return ((-s[0] / 2, s[0] / 2), (-s[1] / 2, s[1] / 2), (-s[2], 0.0))[k]

    def sweep(self, a, b, k: int, sign: float, tool: ToolShape) -> None:
        """The tool from tip a to tip b (side-A frame), its body along axis k (`sign`: toward +)."""
        pa, wa = self.split(a, k)
        pb, wb = self.split(b, k)
        if sign < 0:
            wa -= tool.length
            wb -= tool.length
        lo, hi = self.span(k)
        if not (min(wa, wb) <= hi and max(wa, wb) + tool.length >= lo):
            return
        wa = min(max(wa, lo - tool.length), hi)
        wb = min(max(wb, lo - tool.length), hi)
        self.grids[k].sweep((pa[0], pa[1], wa), (pb[0], pb[1], wb), tool)

    def removed_any(self, q: np.ndarray) -> bool:
        """Whether material at any of the points q (N×3, side-A frame) is gone, within a cell."""
        q = np.asarray(q, float).reshape(-1, 3)
        if not len(q):
            return False
        planes = {0: (1, 2, 0), 1: (0, 2, 1), 2: (0, 1, 2)}
        for k in range(3):
            g = self.grids[k]
            u, v, w = planes[k]
            ox, oy = g.origin
            cols = _round_int((q[:, u] - ox) / self.cell)
            rows = _round_int((q[:, v] - oy) / self.cell)
            if g.near(cols, rows, q[:, w], self.cell).any():
                return True
        return False


def eligibility(fixture, stock) -> list[str]:
    s = [float(v) for v in stock]
    if not all(math.isfinite(v) and 0 < v <= 10_000 for v in s):
        return ["Invalid stock dimensions."]
    if fixture.quantity <= 0:
        return ["Not owned or unavailable (quantity is zero)."]
    if fixture.assembly is not None and fixture.assembly.planning_issues:
        return list(fixture.assembly.planning_issues)
    profile = fixture.planning
    if profile is None:
        return ["Define how this fixture holds stock in Fixtures."]
    issues = list(profile.definition_issues)
    if not fixture.model_path:
        issues.append("Attach the actual assembled CAD model.")
    if not math.isfinite(fixture.height) or fixture.height < 0 or fixture.height > 10_000:
        issues.append("Stock height above the table must be finite and within the supported range.")
    size = profile.stock_size
    if math.dist((size.x, size.y, size.z), s) > 0.1:
        issues.append(f"The CAD assembly is defined for {size}, not this stock. Define the matching assembled state.")
    r = fixture.grip_range
    if r is not None:
        d = s[0] if fixture.clamp_axis is ClampAxis.X else s[1]
        if fixture.clamp_axis is not ClampAxis.NONE and d not in r:
            issues.append("Stock is outside the fixture's grip range.")
    return issues


def _path_bounds(moves: list[Move]) -> tuple[np.ndarray, np.ndarray]:
    """Exact axis-aligned bounds of XY arcs, including extrema between endpoints."""
    lo, hi = np.full(3, math.inf), np.full(3, -math.inf)
    previous = moves[0].position if moves else (0.0, 0.0, 0.0)
    for m in moves:
        p = np.array(m.position)
        lo, hi = np.minimum(lo, p), np.maximum(hi, p)
        if m.motion is not Motion.LINE:
            cx, cy = previous[0] + m.i, previous[1] + m.j
            r = math.hypot(previous[0] - cx, previous[1] - cy)
            start = math.atan2(previous[1] - cy, previous[0] - cx)
            end = math.atan2(m.y - cy, m.x - cx)
            ccw = m.motion is Motion.ARC_CCW
            if ccw:
                while end <= start + 1e-9:
                    end += 2 * math.pi
            else:
                while end >= start - 1e-9:
                    end -= 2 * math.pi
            for a in (0.0, math.pi / 2, math.pi, 3 * math.pi / 2):
                theta = a
                if ccw:
                    while theta < start:
                        theta += 2 * math.pi
                else:
                    while theta > start:
                        theta -= 2 * math.pi
                if min(start, end) - 1e-9 <= theta <= max(start, end) + 1e-9:
                    q = np.array([cx + r * math.cos(theta), cy + r * math.sin(theta), m.z])
                    lo, hi = np.minimum(lo, q), np.maximum(hi, q)
        previous = m.position
    return lo, hi


def plan(cuts: list[Cut], candidates: list[Candidate], stock, machine=None, flip_axis: int | None = None) -> LibraryWorkholdingPlan:
    from ..machine.profile import MachineProfile
    machine = machine or MachineProfile.standard()
    result = LibraryWorkholdingPlan()
    stock = np.asarray(stock, float)

    def finite(values, limit) -> bool:
        return all(math.isfinite(v) and abs(v) <= limit for v in values)

    ok = all(math.isfinite(v) and 0 < v <= 10_000 for v in stock) and all(
        all(math.isfinite(v) and 0 < v <= 1_000 for v in (c.tool.diameter, c.tool.stickout, c.tool.flute_length, c.tool.shank_diameter))
        and all(finite((m.x, m.y, m.z, m.i, m.j, m.feed), 100_000) for m in c.moves) for c in cuts)
    if not ok:
        result.issues = ["Invalid stock, tool or toolpath values; no fixture plan was produced."]
        return result
    if not cuts:
        result.issues = ["There are no generated cuts to assign."]
        return result
    sides = {c.side for c in cuts}
    fixtures = sorted((c for c in candidates
                       if not c.field.is_empty and any(not eligibility(c.fixture, SetupSide.stock_size(stock, s)) for s in sides)),
                      key=lambda c: c.fixture.id)
    if not fixtures:
        result.issues = ["No owned fixture has a complete planning definition and usable CAD geometry for this stock."]
        return result
    fits_side = [{s: not eligibility(c.fixture, SetupSide.stock_size(stock, s)) for s in sides} for c in fixtures]
    # Removed material in side-A stock coordinates; material is never reset to a fresh blank at
    # a fixture change, flip or turn.
    cell = max(0.2, float(stock.max()) / 400)
    removal = StockRemoval(stock, cell)
    cleared = removal.grids[2].copy()
    affines = {}

    def to_a_many(points: np.ndarray, side: int) -> np.ndarray:
        if side not in affines:
            affines[side] = _to_a_affine(side, stock, flip_axis)
        m, before, after = affines[side]
        return (np.asarray(points, float).reshape(-1, 3) - before) @ m.T + after

    def stock_point(p, side: int) -> np.ndarray:
        return to_a_many(np.asarray(p, float), side)[0]

    def contacts_remain(fixture, side: int, rem: StockRemoval) -> bool:
        if fixture.planning is None:
            return False
        s = SetupSide.stock_size(stock, side)
        lo, hi = np.array([-s[0] / 2, -s[1] / 2, -s[2]]), np.array([s[0] / 2, s[1] / 2, 0.0])
        samples = []
        for patch in fixture.planning.contacts:
            point = np.array([patch.point.x, patch.point.y, patch.point.z], float)
            normal = {"x": 0, "y": 1}.get(patch.normal.value if patch.normal is not None else "z", 2)
            radius = patch.radius
            if not all(lo[k] <= point[k] <= hi[k] for k in range(3)):
                return False
            # Contact lies on a surface; sample the material just inside it.
            if abs(point[normal] - lo[normal]) < cell:
                point[normal] = lo[normal] + cell
            elif abs(point[normal] - hi[normal]) < cell:
                point[normal] = hi[normal] - cell
            u, v = (1, 2) if normal == 0 else (0, 2) if normal == 1 else (0, 1)
            if not (point[u] - radius >= lo[u] and point[u] + radius <= hi[u] and point[v] - radius >= lo[v] and point[v] + radius <= hi[v]):
                return False
            steps = max(int(math.ceil(2 * radius / cell)), 2)
            t = -radius + 2 * radius * np.arange(steps + 1) / steps
            du, dv = np.meshgrid(t, t, indexing="ij")
            inside = du * du + dv * dv <= radius * radius + 1e-9
            pts = np.repeat(point[None, :], int(inside.sum()), axis=0)
            pts[:, u] += du[inside]
            pts[:, v] += dv[inside]
            samples.append(pts)
        if not samples:
            return True
        return not rem.removed_any(to_a_many(np.concatenate(samples), side))

    occupied_flat = [c.occupied.flat() for c in fixtures]

    def fits_remaining_stock(i: int, side: int, clear: DexelGrid) -> bool:
        occ = fixtures[i].occupied
        offsets, spans = occupied_flat[i]
        counts = np.diff(offsets)
        cells = np.repeat(np.arange(len(counts)), counts)
        if not len(cells):
            return True
        cols, rows = cells % occ.cols, cells // occ.cols
        ox, oy = occ.origin
        x, y = ox + cols * occ.cell, oy + rows * occ.cell
        slo, shi = spans[:, 0].astype(float), spans[:, 1].astype(float)
        if side >= 2:
            # Turned: no cleared air is credited; the fixture stays out of the stock box.
            s = SetupSide.stock_size(stock, side)
            within = (np.abs(x) < s[0] / 2) & (np.abs(y) < s[1] / 2)
            bad = np.minimum(shi, 0) - 0.1 > np.maximum(slo, -s[2]) + 0.1
            return not (within & bad).any()
        p = to_a_many(np.stack([x, y, np.zeros_like(x)], axis=1), side)
        c = _round_int((p[:, 0] - clear.origin[0]) / clear.cell)
        r = _round_int((p[:, 1] - clear.origin[1]) / clear.cell)
        a = np.maximum(slo, -stock[2]) + 0.1
        b = np.minimum(shi, 0) - 0.1
        keep = (c >= 0) & (r >= 0) & (c < clear.cols) & (r < clear.rows) & ~(b <= a)
        if not keep.any():
            return True
        a, b = a[keep], b[keep]
        lo, hi = (a, b) if side == 0 else (-stock[2] - b, -stock[2] - a)
        return bool(clear.covered(r[keep] * clear.cols + c[keep], lo, hi).all())

    allowed: list[list[bool]] = []
    fields = [c.field for c in fixtures]
    e = machine.machine_envelope
    for cut in cuts:
        bmin, bmax = _path_bounds(cut.moves)
        before = removal.copy()
        cleared_before = cleared.copy()
        axis_k, axis_sign = StockRemoval.tool_axis(cut.side)
        previous = cut.moves[0].position if cut.moves else (0.0, 0.0, 0.0)
        shape = ToolShape(ToolShapeKind.FLAT, cut.tool.diameter / 2 + cell * 0.85, cut.tool.stickout)
        flat_radius = cut.tool.diameter / 2 - cell * 0.85
        flat = ToolShape(ToolShapeKind.FLAT, flat_radius, cut.tool.flute_length) if flat_radius > 0.01 else None
        credit = cut.side < 2 and flat is not None and cut.tool.kind is ToolKind.FLAT_END_MILL
        for m in cut.moves:
            if m.role is not Role.RAPID:
                angle = min(0.08, math.sqrt(0.8 * cell / max(math.hypot(m.i, m.j), cell)))
                for point in ToolpathGeometry.points(m, previous, angle):
                    pa, pb = stock_point(previous, cut.side), stock_point(point, cut.side)
                    removal.sweep(pa, pb, axis_k, axis_sign, shape)
                    # Only credit cavities certainly cleared by horizontal flat-cutter passes.
                    if credit and abs(point[2] - previous[2]) < 1e-6:
                        if cut.side == 1:
                            pa, pb = pa - np.array([0, 0, flat.length]), pb - np.array([0, 0, flat.length])
                        cleared.sweep(pa, pb, flat)
                    previous = point
            previous = m.position
        row, rejection = [], []
        for i, candidate in enumerate(fixtures):
            fixture = candidate.fixture
            heavy = cut.operation.kind in (K.ADAPTIVE, K.FACING)
            travel = None
            if candidate.machine_origin is not None:
                offset = np.asarray(candidate.machine_origin, float) + np.array([0, 0, cut.tool.stickout])
                a, b = bmin + offset, bmax + offset
                worst = None
                for name, lo, hi, rng in (("X", a[0], b[0], e.x), ("Y", a[1], b[1], e.y), ("Z", a[2], b[2], e.z)):
                    over = max(rng.lower - lo, hi - rng.upper, 0)
                    if over > 1e-6 and over > (worst[1] if worst else 0):
                        worst = (name, over)
                if worst is not None:
                    travel = (f"the {cut.tool.name} would go {Length.mm(worst[1])} mm past the machine's {worst[0]} travel "
                              f"(its moves span X {Length.mm(bmin[0])}…{Length.mm(bmax[0])}, Z {Length.mm(bmin[2])}…{Length.mm(bmax[2])})")
            reaches = travel is None
            f = fields[i]
            pad = max(cut.tool.diameter / 2, cut.tool.shank_diameter / 2, NUT_RADIUS) + 0.5
            covered = (bmin[0] - pad >= f.min_x and bmax[0] + pad <= f.min_x + (f.nx - 1) * f.cell
                       and bmin[1] - pad >= f.min_y and bmax[1] + pad <= f.min_y + (f.ny - 1) * f.cell)
            sized = fits_side[i].get(cut.side) is True
            holds = sized and contacts_remain(fixture, cut.side, before) and contacts_remain(fixture, cut.side, removal)
            fits = sized and fits_remaining_stock(i, cut.side, cleared_before)
            hits = FixtureClearance.check(cut.moves, cut.tool, f, limit=1) if sized else []
            roughing = fixture.planning is not None and fixture.planning.allows_roughing
            good = sized and (not heavy or roughing) and reaches and covered and fits and holds and not hits
            row.append(good)
            if not good:
                if not sized:
                    why = "not fitted to the stock this way round"
                elif heavy and not roughing:
                    why = "not defined for roughing/facing"
                elif not reaches:
                    why = travel or "outside machine travel"
                elif not covered:
                    why = "tool motion leaves the checked CAD region"
                elif not fits:
                    why = "fixture intersects material still present at this setup"
                elif not holds:
                    why = "grip/support material is absent or removed by the cuts"
                else:
                    why = f"{hits[0].part if hits else 'tool'} clearance collision"
                rejection.append(f"{fixture.name}: {why}")
        allowed.append(row)
        if not any(row):
            where = "side A" if cut.side == 0 else "side B" if cut.side == 1 else SetupSide.words(cut.side)
            result.issues.append(f"{cut.operation.title} ({where}): " + "; ".join(rejection))
    if result.issues:
        return result
    n, infinity = len(fixtures), math.inf
    cost = [1 if allowed[0][j] else infinity for j in range(n)]
    parents = [[-1] * n for _ in cuts]
    for k in range(1, len(cuts)):
        nxt = [infinity] * n
        for j in range(n):
            if not allowed[k][j]:
                continue
            for i in range(n):
                if cost[i] == infinity:
                    continue
                change = 0 if i == j and cuts[k].side == cuts[k - 1].side else 1
                if cost[i] + change < nxt[j]:
                    nxt[j] = cost[i] + change
                    parents[k][j] = i
        cost = nxt
    best = min(range(n), key=lambda j: cost[j])
    if cost[best] == infinity:
        result.issues = ["No complete fixture sequence covers every operation."]
        return result
    choices = [0] * len(cuts)
    for k in range(len(cuts) - 1, -1, -1):
        choices[k] = best
        if k > 0:
            best = parents[k][best]
    for k, cut in enumerate(cuts):
        fixture = fixtures[choices[k]].fixture
        last = result.steps[-1] if result.steps else None
        if last is not None and last.fixture.id == fixture.id and last.side == cut.side:
            last.cut_keys.append(cut.key)
            if cut.operation.title not in last.operations:
                last.operations.append(cut.operation.title)
        else:
            result.steps.append(LibraryWorkholdingStep(
                len(result.steps) + 1, cut.side, fixture, [cut.key], [cut.operation.title], [
                    "Owned fixture; assembled stock size and grip definition match.",
                    "Generated cutter, shank and holder paths clear its CAD geometry.",
                    "Defined contact patches remain in the accumulated stock simulation.",
                    "The assembly fits the sampled remaining stock at this point in the job.",
                    "Starts the sequence." if not result.steps else "Re-clamp and establish work zero before continuing.",
                ], fixtures[choices[k]].model_signature))
    return result
