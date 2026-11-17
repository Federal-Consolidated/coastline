"""What the tool tip reaches in a setup, and the fixtures' keep-out and clearance fields. Port of
Model/Reach.swift."""

from __future__ import annotations

import math
import os
from dataclasses import dataclass

import numpy as np

from ...core.codable import Range
from ...core.plan.setup import Workholding
from ...core.safety.fixture_clearance import NUT_RADIUS
from ...core.units import Length
from .smart_plan import StandInVise

TIMING = "COASTLINE_TIMING" in os.environ


@dataclass
class SetupReach:
    """What the tool tip can reach in a setup's work frame. X and Y hold for every tool; Z follows
    from the stick-out."""

    x: Range
    y: Range
    origin_z: float  # the machine Z of work zero with a bare spindle nose
    envelope: object  # AxisBox

    def z_floor(self, stickout: float) -> float:
        return self.envelope.z.lower - self.origin_z - stickout

    def z_ceiling(self, stickout: float) -> float:
        return self.envelope.z.upper - self.origin_z - stickout


def _same_size(p, s) -> bool:
    return math.dist((p.stock_size.x, p.stock_size.y, p.stock_size.z), (float(s[0]), float(s[1]), float(s[2]))) < 0.1


class ReachMixin:
    def reach_in_setup(self, candidates: list, s) -> SetupReach | None:
        """The reach in a setup whose stock is `s`, from the fixtures fitted to that stock (the
        smaller reach holds) or, for a custom fixture, from where it stands the stock."""
        origins = [c.machine_origin for c in candidates if c.fixture.planning is not None and _same_size(c.fixture.planning, s)]
        origins = [o for o in origins if o is not None]
        if not origins and self.setup.holding == Workholding.CUSTOM:
            o = self.machine_origin(0)
            if o is not None:
                origins = [o]
        if not origins:
            return None
        e = self.machine.machine_envelope
        x0, x1, y0, y1 = -math.inf, math.inf, -math.inf, math.inf
        origin_z = -math.inf
        for o in origins:
            x0, x1 = max(x0, e.x.lower - o[0]), min(x1, e.x.upper - o[0])
            y0, y1 = max(y0, e.y.lower - o[1]), min(y1, e.y.upper - o[1])
            origin_z = max(origin_z, float(o[2]))  # the highest work zero: the least depth
        if not (x0 < x1 and y0 < y1):
            return None
        return SetupReach(Range(float(x0), float(x1)), Range(float(y0), float(y1)), origin_z, e)

    def stand_in_reach(self, s, faced_before: float) -> SetupReach | None:
        """The reach in one clamping of an end setup held by the vise to buy."""
        e, t = self.machine.machine_envelope, self.table_geometry
        model = np.array([t.top_x + StandInVise.FLOOR + s[0] / 2, self.travel_centre_y, t.north_z + StandInVise.FACE_PAST + faced_before])
        o = self.machine_origin(0, model_origin=model)
        if o is None:
            return None
        return SetupReach(Range(e.x.lower - o[0], e.x.upper - o[0]), Range(e.y.lower - o[1], e.y.upper - o[1]), float(o[2]), e)

    def within_reach(self, planned: list, reach: SetupReach, stock_depth: float, setup_name: str, material_top: float = 0.0) -> list:
        """Each operation kept to the depth its tool reaches in this setup (with a plan note); an
        operation wholly out of reach is left out."""
        import copy
        noted: set[str] = set()
        face_noted = False
        out = []
        for p in planned:
            ceiling = reach.z_ceiling(p.tool.stickout)
            if ceiling < p.z_top + 3:
                if not face_noted:
                    face_noted = True
                    self.plan_notes.append(f"{setup_name}: standing this way the stock face is {Length.mm(p.z_top + 3 - ceiling)} mm beyond the spindle's Z travel, so this setup is left out; its features stay for another setup.")
                continue
            travel_floor = reach.z_floor(p.tool.stickout) + 0.3
            from ...core.feeds import OperationKind as K
            nut_floor = -math.inf if p.operation.kind == K.FACING else material_top - (p.tool.stickout - 1.3)
            floor = max(travel_floor, nut_floor)
            if not floor > -stock_depth + 0.01:
                out.append(p)
                continue
            wanted = p.z_min if p.z_min is not None else -stock_depth
            if not wanted < floor - 1e-6:
                out.append(p)
                continue
            q = copy.copy(p)
            q.z_min = floor
            why = "its collet nut would meet the stock" if nut_floor > travel_floor else "the machine's Z travel"
            note = f"{setup_name}: the {p.tool.name} reaches {Length.mm(-floor)} mm deep at most ({Length.mm(p.tool.stickout)} mm stick-out: {why})"
            first = p.tool.id not in noted
            noted.add(p.tool.id)
            if q.z_top <= floor + 1e-6:
                if first:
                    self.plan_notes.append(note + f": {p.operation.title} is left to the other setups.")
                continue
            if first:
                self.plan_notes.append(note + "; what lies deeper is left to the other setups.")
            out.append(q)
        return out

    def fixture_keep_out(self, candidates: list, s, margin: float = NUT_RADIUS + 0.5) -> list:
        """Where the fixtures fitted to this stock stand above the stock's back, as XY rectangles
        in the setup's work frame grown by the collet nut's radius: roughing keeps out of them."""
        out = []
        for c in candidates:
            p = c.fixture.planning
            if p is None or not _same_size(p, s):
                continue
            f = self.library_fixture_fields.get(self.fixture_state_key(c.fixture))
            if f is None:
                continue
            block = f.top > -s[2] + 0.05  # anything rising above the stock's back
            nx, ny = f.nx, f.ny
            open_: dict[int, tuple[int, int]] = {}  # span start x → (first row, end x)

            def close(x0, v, y1):
                out.append(((f.min_x + x0 * f.cell - margin, f.min_y + v[0] * f.cell - margin),
                            (f.min_x + v[1] * f.cell + margin, f.min_y + y1 * f.cell + margin)))

            for y in range(ny + 1):
                spans: dict[int, int] = {}
                if y < ny:
                    row = block[y]
                    x = 0
                    while x < nx:
                        if not row[x]:
                            x += 1
                            continue
                        x0 = x
                        while x < nx and row[x]:
                            x += 1
                        spans[x0] = x
                for x0, v in list(open_.items()):
                    if spans.get(x0) != v[1]:
                        close(x0, v, y)
                        del open_[x0]
                for x0, x1 in spans.items():
                    if x0 not in open_:
                        open_[x0] = (y, x1)
        return out

    def fixture_fields(self, candidates: list, s) -> list:
        """The clearance fields of the fixtures fitted to this stock (the setup's work frame)."""
        out = []
        for c in candidates:
            p = c.fixture.planning
            if p is None or not _same_size(p, s):
                continue
            f = self.library_fixture_fields.get(self.fixture_state_key(c.fixture))
            if f is not None:
                out.append(f)
        return out
