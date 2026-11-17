"""Holding tabs that hold: side B's tabs are made from side A's simulated result and the finished
job is checked the same way. Port of Model/TabCheck.swift."""

from __future__ import annotations

import math

import numpy as np

from ...core.codable import Range
from ...core.inventory.checks import Issue, Severity
from ...core.plan.holding_tabs import TabFrame
from ...core.sim.heightmap import Heightmap
from ..tasks import Sleep, Work

THROUGH_MAX_EXCESS = 3.0  # a one-sided part cut free on tabs: the bar at most this much thicker
THROUGH_OVERSHOOT = 0.3  # side B cuts this far past the split when it frees the part on tabs
THROUGH_SKIN = 0.5  # one side cut through: what roughing leaves over the bar's back


def simulate(ops, size) -> Heightmap:
    """The stock after these toolpaths (each with its tool), simulated."""
    hm = Heightmap((-size[0] / 2, -size[1] / 2, -size[2]), (size[0] / 2, size[1] / 2, 0), 250_000)
    pos = None
    for paths, tool in ops:
        for p in paths:
            for m in p.moves:
                hm.apply(m, pos if pos is not None else m.position, tool.diameter / 2, tool.corner_radius)
                pos = m.position
    return hm


def connected_to_edge(material: np.ndarray) -> np.ndarray:
    """Cells of `material` (rows, cols) 4-connected to the grid's edge."""
    rows, cols = material.shape
    mat = material.reshape(-1).tolist()
    frame = [False] * (rows * cols)
    stack = []
    for r in range(rows):
        for c in range(cols):
            if r == 0 or c == 0 or r == rows - 1 or c == cols - 1:
                i = r * cols + c
                if mat[i] and not frame[i]:
                    frame[i] = True
                    stack.append(i)
    while stack:
        i = stack.pop()
        r, c = divmod(i, cols)
        for rr, cc in ((r, c + 1), (r, c - 1), (r + 1, c), (r - 1, c)):
            if 0 <= rr < rows and 0 <= cc < cols:
                j = rr * cols + cc
                if mat[j] and not frame[j]:
                    frame[j] = True
                    stack.append(j)
    return np.array(frame, bool).reshape(rows, cols)


def tab_frame(a: Heightmap, thickness: float, tab_bottom: float, flip_axis: int | None = None) -> TabFrame:
    """The frame at the tabs' height in side B's work frame: the cells where side A left material
    through the tabs' bottom, connected to the stock's edge."""
    cols, rows = a.cols, a.rows
    need = np.float32(-thickness - tab_bottom - 0.05)
    h = a.heights
    ox, oy = a.origin
    roll_y = flip_axis == 1
    r = np.arange(rows)
    c = np.arange(cols)
    y = oy + r * a.cell
    x = ox + c * a.cell
    ra = r if roll_y else _round_clamp((-y - oy) / a.cell, rows)
    ca = _round_clamp((-x - ox) / a.cell, cols) if roll_y else c
    material = h[np.ix_(ra, ca)] >= need
    return TabFrame.make(a.origin, a.cell, cols, rows, connected_to_edge(material).reshape(-1).tolist())


def _round_clamp(v: np.ndarray, n: int) -> np.ndarray:
    rounded = np.where(v >= 0, np.floor(v + 0.5), np.ceil(v - 0.5))  # half away from zero
    return np.clip(rounded.astype(int), 0, n - 1)


def one_sided_frame(b: Heightmap, level: float) -> TabFrame:
    material = b.heights.astype(float) >= level
    return TabFrame.make(b.origin, b.cell, b.cols, b.rows, connected_to_edge(material).reshape(-1).tolist())


def tab_extent(t):
    """How far the tab runs out from its centre on the outline, and its sides across."""
    if len(t.corners) < 3 or math.hypot(*t.normal) <= 1e-9:
        return None
    n = np.asarray(t.normal, float) / math.hypot(*t.normal)
    along = np.array([-n[1], n[0]])
    corners = np.asarray(t.corners, float) - np.asarray(t.centre, float)
    out, side = corners @ n, corners @ along
    lo, hi = float(side.min()), float(side.max())
    if not hi > lo:
        return None
    return n, float(out.max()), Range(lo, hi)


def tabs_hold(tabs, a: Heightmap | None, b: Heightmap, thickness: float, z: Range, flip_axis: int | None = None) -> list[bool]:
    """For each placed tab: whether it holds in the finished job."""
    frame = tab_frame(a, thickness, z.lower, flip_axis) if a is not None else one_sided_frame(b, (z.lower + z.upper) / 2)
    mid = (z.lower + z.upper) / 2

    def surface(hm: Heightmap, p) -> float:
        c = int(_round_clamp(np.array([(p[0] - hm.origin[0]) / hm.cell]), hm.cols)[0])
        r = int(_round_clamp(np.array([(p[1] - hm.origin[1]) / hm.cell]), hm.rows)[0])
        return hm.height(c, r)

    out = []
    for t in tabs:
        g = tab_extent(t)
        if g is None:
            out.append(False)
            continue
        n, length, across = g
        along = np.array([-n[1], n[0]])
        centre = np.asarray(t.centre, float)
        ok = True
        s = 0.6
        while s < length - 0.4:
            q = centre + n * s
            qa = (-q[0], q[1]) if flip_axis == 1 else (q[0], -q[1])
            from_a = -thickness - surface(a, qa) if a is not None else -thickness
            if not (from_a <= mid + 1e-3 and mid <= surface(b, q) + 1e-3):
                ok = False
                break
            s += 0.5
        if ok:
            end = centre + n * (length - 0.75)
            ok = all(frame.is_frame(end + along * v) for v in (across.lower + 0.25, (across.lower + across.upper) / 2, across.upper - 0.25))
        out.append(ok)
    return out


class TabCheckMixin:
    @property
    def one_sided_through_excess(self) -> float | None:
        if self.twoSided or self.part is None or self.stock is None:
            return None
        lo, hi = self.setup.rotated_part_bounds(self.part.bounds_min, self.part.bounds_max)
        e = self.setup.stock_size(self.stock)[2] - (hi[2] - lo[2])
        if not (e >= -0.01 and e <= THROUGH_MAX_EXCESS + 1e-9):
            return None
        return max(float(e), 0.0)

    @property
    def cuts_through_with_tabs(self) -> bool:
        return self.holdWithTabs and self.one_sided_through_excess is not None

    @property
    def part_on_bar_back(self) -> float:
        if self.twoSided or self.cuts_through_with_tabs or self.part is None or self.stock is None:
            return 0.0
        lo, hi = self.setup.rotated_part_bounds(self.part.bounds_min, self.part.bounds_max)
        return max(float(self.setup.stock_size(self.stock)[2] - self.setup.top_allowance - (hi[2] - lo[2])), 0.0)

    @property
    def tab_side(self) -> int:
        return 1 if self.twoSided else 0

    def one_sided_tab_range(self, stock) -> Range:
        at = -self.setup.stock_size(stock)[2]
        return Range(at - THROUGH_OVERSHOOT, at + self.tabs.height)

    def tab_range(self, side_b, stock, split: float) -> Range:
        at = side_b.side_b_z(split, stock)
        return Range(at - THROUGH_OVERSHOOT, at + self.tabs.height)

    def await_tab_frame(self, run, si: int):
        """A task step: before side B's jobs (tabs only), waits for side A's clearing and puts the
        frame from it into side B's tab spec."""
        try:
            sp = run.sides[si]
            if si <= 0 or sp.tab_spec is None or sp.tab_spec.frame is not None or self.stock is None:
                return
            a = run.sides[0]
            needed = [k for k, p in enumerate(a.planned) if not p.operation.kind.is_3d and p.operation.kind.value != "engrave"]
            while not self.cancel_generation and not all(run.done[0][k] is not None or any(f[0] == 0 and f[1] == k for f in run.failed) for k in needed):
                yield Sleep(0.1)
            if self.cancel_generation or sp.tab_spec.frame is not None:
                return
            if run.frame is not None:
                sp.tab_spec.frame = run.frame
                return
            ops = [(run.done[0][k], a.planned[k].tool) for k in needed if run.done[0][k] is not None]
            size, bottom, flip = self.setup.stock_size(self.stock), sp.tab_bottom, self.setup_for(1).flip_axis
            f = yield Work(lambda: tab_frame(simulate(ops, size), size[2], bottom, flip), lane="sim")
            run.frame = f
            sp.tab_spec.frame = f
        finally:
            sp = run.sides[si]
            if (sp.tab_spec is not None and sp.tab_spec.frame is not None) or self.cancel_generation or self.stock is None:
                run.frame_ready = True

    @property
    def tab_z(self) -> Range | None:
        if self.placed_tab_z is not None:
            return self.placed_tab_z
        if self.stock is None:
            return None
        if self.cuts_through_with_tabs:
            return self.one_sided_tab_range(self.stock)
        split = self.split_z
        if split is None:
            return None
        return self.tab_range(self.setup_for(1), self.stock, split)

    def tabs_hold_check(self):
        """A task step: the finished job's tabs checked (None: no tabs in this job)."""
        z = self.tab_z
        if not ((self.twoSided and self.holdWithTabs) or self.cuts_through_with_tabs) or self.stock is None or z is None:
            return None
        rb = next((r for r in self.side_results if r.side == self.tab_side), None)
        if rb is None:
            return None
        ra = next((r for r in self.side_results if r.side == 0), None) if self.twoSided else None
        if self.twoSided and ra is None:
            return None
        size, flip, tabs = self.setup.stock_size(self.stock), self.setup_for(1).flip_axis, list(self.placed_tabs)

        def ops(r):
            return [([r.paths[k]], r.planned[k].tool) for k in range(len(r.paths)) if k < len(r.planned)]

        oa, ob = (ops(ra) if ra is not None else None), ops(rb)

        def run():
            a = simulate(oa, size) if oa is not None else None
            return tabs_hold(tabs, a, simulate(ob, size), size[2], z, flip)

        result = yield Work(run, lane="sim")
        return result

    def check_tabs(self):
        """A task step: a job held by tabs fails its last program when a tab doesn't hold, or
        when there are none."""
        if not ((self.twoSided and self.holdWithTabs) or self.cuts_through_with_tabs):
            return
        idx = [i for i, p in enumerate(self.programs) if p.side == self.tab_side]
        if not idx:
            return
        pi = idx[-1]
        if not self.placed_tabs:
            how = "Use a full web (Setup ▸ Sides) or larger stock." if self.twoSided else "Turn Hold with tabs off (Setup ▸ Sides): the part then stays on the back of the bar."
            self.programs[pi].report.issues.append(Issue(Severity.ERROR, f"No holding tab could be placed: the last cut would free the part. {how}"))
            return
        held = yield from self.tabs_hold_check()
        if held is None:
            return
        loose = [i for i, h in enumerate(held) if not h]
        if not loose or pi >= len(self.programs):
            return
        n = len(loose)
        self.programs[pi].report.issues.append(Issue(Severity.ERROR,
            f"Holding tab{'' if n == 1 else 's'} {', '.join(str(i + 1) for i in loose)} {'doesn' if n == 1 else 'don'}'t reach stock that stays: the part would come loose in the last cut. Use a full web (Setup ▸ Sides) or larger stock."))
