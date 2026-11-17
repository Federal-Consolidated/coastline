"""The setups from the stock's other sides (upper, lower side, the ends). Port of
Model/SideSetups.swift."""

from __future__ import annotations

import copy
import uuid

import numpy as np

from ...core import feeds as FeedsEngine
from ...core.engine.cam import PlannedOperation
from ...core.feeds import OperationKind as K
from ...core.inventory.items import ToolKind
from ...core.plan import side_cuts as SideCuts
from ...core.plan.dfm import Category
from ...core.plan.operation import DEFAULT_MIN_POCKET, Operation
from ...core.plan.plan_coverage import PlanCoverage, is_cut
from ...core.plan.setup_side import SetupSide


def side_bore_id(side: int, tool) -> str:
    """A side setup's boring with one tool: the same id every time (the cache knows it again)."""
    t = uuid.UUID(tool.id).bytes
    return str(uuid.UUID(bytes=bytes([0x5E, 0xB0, 0, side & 0xFF]) + t[4:])).upper()


def end_keep_out(part_y: tuple[float, float], s) -> list:
    """Keep-out over the end pieces in a long-face setup's frame: everything past the part's
    length (that setup's work Y), out to 50 mm past the stock."""
    x0, x1 = -s[0] / 2 - 50, s[0] / 2 + 50
    out = []
    if part_y[1] < s[1] / 2 - 0.5:
        out.append(((x0, part_y[1]), (x1, s[1] / 2 + 50)))
    if part_y[0] > -s[1] / 2 + 0.5:
        out.append(((x0, -s[1] / 2 - 50), (x1, part_y[0])))
    return out


def setup_title(side: int, two_sided: bool) -> str:
    """"Setup · upper side" for a side setup's programs; side A and B keep their names."""
    if side == 0:
        return "Side A" if two_sided else "Setup 1"
    if side == 1:
        return "Side B (flipped)"
    return f"Setup · {SetupSide.words(side)} toward the spindle"


class SideSetupsMixin:
    setup_title = staticmethod(setup_title)
    side_bore_id = staticmethod(side_bore_id)
    end_keep_out = staticmethod(end_keep_out)

    def side_setup_sides(self, part, stock) -> list[int]:
        """The side setups the part check proposes (SetupSide 2…5), in the order the job makes
        them. Only with automatic workholding from the library."""
        if not (self.setup.plan_from_fixture_library and self.automatic_workholding):
            return []
        findings = self.dfm_findings(self.inventory)
        if findings is None:
            return []
        sides = [k for k in (SetupSide.index(s) for s in PlanCoverage.propose(findings)) if k is not None
                 and k >= 2 and self.setup.for_side(k, part.bounds_min, part.bounds_max, stock) is not None]
        # The end pieces come off from the ends, features there or not.
        for side in (4, 5):
            if (self.end_piece_thickness(side) > 0.5 and side not in sides
                    and self.setup.for_side(side, part.bounds_min, part.bounds_max, stock) is not None):
                sides.append(side)
        return sides

    def end_piece_thickness(self, side: int) -> float:
        """How much stock the end setup from `side` faces off before the part's end, mm."""
        if side < 4 or self.part is None or self.stock is None:
            return 0.0
        e = self.end_pieces(self.part, self.stock)
        if e is None:
            return 0.0
        return e[1] if side == 4 else e[0]

    def side_setup_plans(self, base: list, part, stock) -> list[tuple[int, object, list]]:
        """Each side setup with what it cuts: the plan's operations kept to a window around the
        features the part check sends to that side."""
        findings = self.dfm_findings(self.inventory)
        access = self.analysis.access if self.analysis is not None else None
        if findings is None or access is None:
            return []
        a = self.setup.stock_size(stock)
        roughers = [p for p in base if p.operation.kind == K.ADAPTIVE]
        margin = (max((p.tool.diameter for p in roughers), default=6.35)) / 2 + 1
        out = []
        for side in self.side_setup_sides(part, stock):
            s = self.setup.for_side(side, part.bounds_min, part.bounds_max, stock)
            if s is None:
                continue
            name = SetupSide.names[side]
            bounds = [b for b in (access.bounds_for_faces(f.faces) for f in findings
                                  if is_cut(f) and f.category != Category.NOT_SUPPORTED and name in f.sides) if b is not None]
            # An end setup first faces its end piece off down to the part's end, over the whole
            # face, with the plan's largest roughing tool; its features are cut from there.
            end_piece = self.end_piece_thickness(side)
            facing = []
            material = stock.material
            rougher = None
            for p in roughers:  # max(by:) keeps the first of equals
                if rougher is None or rougher.diameter < p.tool.diameter:
                    rougher = p.tool
            if end_piece > 0.5 and material is not None and rougher is not None:
                op = Operation(K.FACING, tool_id=rougher.id, face_depth=end_piece)
                p = PlannedOperation(op, rougher, FeedsEngine.compute(rougher, material, K.FACING, self.machine))
                p.z_top = 0.0
                p.z_min = -end_piece
                facing = [p]
            w = SideCuts.window(bounds, side, a, margin)
            if w is None:
                if facing:
                    out.append((side, s, facing))
                continue
            planned = SideCuts.operations(base, w, SetupSide.stock_size(a, side))
            # Holes from this side are bored (helical), each by the larger flat end mill that fits
            # it, then the smaller.
            if not any(p.operation.kind in (K.BORE, K.DRILL) for p in planned) and material is not None:
                flats = []
                for p in base:
                    if p.tool.kind == ToolKind.FLAT_END_MILL and not any(abs(t.diameter - p.tool.diameter) < 0.05 for t in flats):
                        flats.append(p.tool)
                for tool in sorted(flats, key=lambda t: -t.diameter):
                    op = Operation(K.BORE, tool_id=tool.id)
                    op.id = side_bore_id(side, tool)
                    p = PlannedOperation(op, tool, FeedsEngine.compute(tool, material, K.BORE, self.machine))
                    p.z_top = 0.0
                    p.z_min = w.z_min
                    p.window = (w.min, w.max)
                    planned.append(p)
            # The features start at the faced surface, not in the end piece facing has taken.
            if end_piece > 0.5:
                for p in planned:
                    p.z_top = min(p.z_top, -end_piece)
            planned = facing + planned
            # Each roughing tool works only what the larger ones before it left (as on side A).
            for k, p in enumerate(planned):
                if p.operation.kind == K.ADAPTIVE:
                    p.rest_from = [(q.tool.diameter, q.operation.min_pocket if q.operation.min_pocket is not None else DEFAULT_MIN_POCKET,
                                    q.operation.leave_radial) for q in planned[:k]
                                   if q.operation.kind == K.ADAPTIVE and q.tool.diameter > p.tool.diameter + 1e-6]
            if planned:
                out.append((side, s, planned))
        return out

    def end_pieces(self, part, stock) -> tuple[float, float] | None:
        """The stock past the part's ends along its length (work Y in side A's frame), mm at the
        −Y and +Y ends, with library workholding. None when there is less than a facing pass."""
        if not self.setup.plan_from_fixture_library:
            return None
        s = self.setup.stock_size(stock)
        lo, hi = self.setup.rotated_part_bounds(part.bounds_min, part.bounds_max)
        half = (hi[1] - lo[1]) / 2
        low, high = s[1] / 2 + self.setup.part_offset_y - half, s[1] / 2 - self.setup.part_offset_y - half
        if max(low, high) <= 0.5:
            return None
        return max(float(low), 0.0), max(float(high), 0.0)
