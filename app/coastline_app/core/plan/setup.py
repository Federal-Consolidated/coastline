"""One setup: how the part sits in the stock and how the stock sits in the machine.
Port of Plan/Setup.swift.

Work frame (the WCS the G-code uses), aligned with the machine axes: +X up (the table's vertical
travel), +Y to the operator's right (gantry), +Z along the spindle toward the tool (the tool comes
from +Z and cuts toward −Z); origin: the centre of the stock's top face (the face toward the
spindle), so Z = 0 is the stock surface and the part is below it.
"""

from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field
from enum import Enum

import numpy as np

from .. import codable
from ..codable import Range, jfield
from ..geometry import affine, columns, identity3
from ..units import Length


class Workholding(Enum):
    """A fixture of the user's own: its geometry isn't modelled, so it is outside the collision checks."""

    CUSTOM = "custom"


class Facing(Enum):
    """Which part axis points at the spindle (becomes +Z of the work frame)."""

    PLUS_Z = "plusZ"
    MINUS_Z = "minusZ"
    PLUS_X = "plusX"
    MINUS_X = "minusX"
    PLUS_Y = "plusY"
    MINUS_Y = "minusY"

    @property
    def title(self) -> str:
        return {"plusZ": "+Z (top)", "minusZ": "−Z (bottom)", "plusX": "+X", "minusX": "−X", "plusY": "+Y",
                "minusY": "−Y"}[self.value]


FACINGS = list(Facing)


@dataclass
class CustomFixture:
    """Placement and setup notes for workholding outside the fixture library."""

    name: str = "Vise / custom fixture"
    height: float = 0.0
    face_protrusion: float = 2.0
    notes: str = ""


def quarter_rotation(axis, quarter_turns: int) -> np.ndarray:
    """Exact quarter-turn rotation (entries are −1, 0 or 1)."""
    q = ((quarter_turns % 4) + 4) % 4
    c = (1.0, 0.0, -1.0, 0.0)[q]
    s = (0.0, 1.0, 0.0, -1.0)[q]
    x, y, z = (float(v) for v in axis)
    return np.array([
        [c + x * x * (1 - c), x * y * (1 - c) - z * s, x * z * (1 - c) + y * s],
        [y * x * (1 - c) + z * s, c + y * y * (1 - c), y * z * (1 - c) - x * s],
        [z * x * (1 - c) - y * s, z * y * (1 - c) + x * s, c + z * z * (1 - c)],
    ])


@dataclass
class Setup:
    # nil: Coastline plans the workholding from the fixture library.
    holding: Workholding | None = None
    plan_from_fixture_library: bool = False
    custom_fixture: CustomFixture = field(default_factory=CustomFixture)
    fixture_assemblies: list[Fixture] | None = None  # job-owned fixture definitions
    # Workholding available to this job. None: automatic library selection; []: none.
    selected_fixture_ids: list[str] | None = None
    facing: Facing = Facing.PLUS_Z
    spin: int = 0  # quarter turns about the tool axis (0…3)
    stock_axes: list[int] = field(default_factory=lambda: [1, 0, 2])
    top_allowance: float = 0.5  # material left above the part, to face off first
    part_offset_x: float = 0.0
    part_offset_y: float = 0.0
    part_scale: float = 1.0
    flipped: bool = False  # side B of a two-sided job
    flip_axis: int | None = None  # None/0: about X (ends swap); 1: about Y (rolls over)

    def copy(self) -> "Setup":
        return copy.deepcopy(self)

    def selecting_holding(self, method: Workholding) -> "Setup":
        s = self.copy()
        s.plan_from_fixture_library = False
        s.holding = method
        return s

    # ---- coding (tolerant: older sessions miss newer keys, may name removed holding methods)
    @staticmethod
    def from_json(d: dict) -> "Setup":
        from ..inventory.items import Fixture
        s = Setup()
        s.plan_from_fixture_library = bool(d.get("planFromFixtureLibrary", False))
        if d.get("fixtureAssemblies") is not None:
            s.fixture_assemblies = codable.from_json(list[Fixture], d["fixtureAssemblies"])
        if d.get("selectedFixtureIDs") is not None:
            s.selected_fixture_ids = [str(v) for v in d["selectedFixtureIDs"]]
        try:
            s.holding = Workholding(d["holding"]) if d.get("holding") is not None else None
        except ValueError:
            s.holding = None
        if d.get("customFixture") is not None:
            s.custom_fixture = codable.from_json(CustomFixture, d["customFixture"])
        if d.get("facing") is not None:
            s.facing = Facing(d["facing"])
        s.spin = int(d.get("spin", 0))
        if d.get("stockAxes") is not None:
            s.stock_axes = [int(v) for v in d["stockAxes"]]
        s.top_allowance = float(d.get("topAllowance", 0.5))
        s.part_offset_x = float(d.get("partOffsetX", 0))
        s.part_offset_y = float(d.get("partOffsetY", 0))
        s.flipped = bool(d.get("flipped", False))
        s.flip_axis = int(d["flipAxis"]) if d.get("flipAxis") is not None else None
        s.part_scale = float(d.get("partScale", 1))
        return s

    def to_json(self) -> dict:
        out = {"planFromFixtureLibrary": self.plan_from_fixture_library, "customFixture": codable.to_json(self.custom_fixture),
               "facing": self.facing.value, "spin": self.spin, "stockAxes": list(self.stock_axes),
               "topAllowance": self.top_allowance, "partOffsetX": self.part_offset_x, "partOffsetY": self.part_offset_y,
               "flipped": self.flipped, "partScale": self.part_scale}
        if self.fixture_assemblies is not None:
            out["fixtureAssemblies"] = codable.to_json(self.fixture_assemblies)
        if self.selected_fixture_ids is not None:
            out["selectedFixtureIDs"] = list(self.selected_fixture_ids)
        if self.holding is not None:
            out["holding"] = self.holding.value
        if self.flip_axis is not None:
            out["flipAxis"] = self.flip_axis
        return out

    # ---- part transform
    @staticmethod
    def rotation(axis, quarter_turns: int) -> np.ndarray:
        return quarter_rotation(axis, quarter_turns)

    @property
    def part_rotation(self) -> np.ndarray:
        """Rotation from part coordinates into the work frame."""
        f = self.facing
        if f is Facing.PLUS_Z:
            base = identity3()
        elif f is Facing.MINUS_Z:
            base = quarter_rotation((1, 0, 0), 2)
        elif f is Facing.PLUS_X:
            base = quarter_rotation((0, 1, 0), -1)
        elif f is Facing.MINUS_X:
            base = quarter_rotation((0, 1, 0), 1)
        elif f is Facing.PLUS_Y:
            base = quarter_rotation((1, 0, 0), 1)
        else:
            base = quarter_rotation((1, 0, 0), -1)
        r = quarter_rotation((0, 0, 1), self.spin) @ base
        if self.flipped:
            from .setup_side import SetupSide
            return SetupSide.rotation(1, self.flip_axis) @ r
        return r

    def turned(self, about: int, quarter_turns: int) -> "Setup":
        """The part turned about a work axis (0 = X, 1 = Y, 2 = Z), as the orientation
        (facing + spin) that gives exactly that rotation."""
        unit = [0.0, 0.0, 0.0]
        unit[about] = 1.0
        plain = self.copy()
        plain.flipped = False
        want = quarter_rotation(unit, quarter_turns) @ plain.part_rotation
        out = self.copy()
        for f in FACINGS:
            for spin in range(4):
                t = plain.copy()
                t.facing, t.spin = f, spin
                if np.all(np.linalg.norm(t.part_rotation - want, axis=0) < 1e-9):
                    out.facing, out.spin = f, spin
                    return out
        return out

    def side_b(self, part_min, part_max, stock) -> "Setup":
        """Side B of this setup for the same stock: turned front-to-back. The part keeps its
        place in the stock: its top is now as far below the new face as its bottom was above
        the old stock bottom."""
        b = self.copy()
        b.flipped = True
        size = self.stock_size(stock)
        thickness = size[2]
        rlo, rhi = self.rotated_part_bounds(part_min, part_max)
        b.top_allowance = thickness - self.top_allowance - (rhi[2] - rlo[2])
        b.flip_axis = 1 if size[1] > size[0] + 1e-6 else 0
        if b.flip_axis == 1:
            b.part_offset_x = -self.part_offset_x
        else:
            b.part_offset_y = -self.part_offset_y
        return b

    def side_b_z(self, z: float, stock) -> float:
        """Maps a side-A work Z to side B (−T − z)."""
        return -self.stock_size(stock)[2] - z

    def rotated_part_bounds(self, part_min, part_max) -> tuple[np.ndarray, np.ndarray]:
        lo, hi = np.asarray(part_min, float), np.asarray(part_max, float)
        r = self.part_rotation * self.part_scale
        corners = np.array([[hi[0] if i & 1 else lo[0], hi[1] if i & 2 else lo[1], hi[2] if i & 4 else lo[2]] for i in range(8)])
        rotated = corners @ r.T
        return rotated.min(axis=0), rotated.max(axis=0)

    def part_to_work(self, part_min, part_max) -> np.ndarray:
        """Rotation, then the translation that puts the part's top `top_allowance` below
        Z = 0 and centres it in X/Y plus the offsets."""
        rlo, rhi = self.rotated_part_bounds(part_min, part_max)
        t = np.array([self.part_offset_x - (rlo[0] + rhi[0]) / 2, self.part_offset_y - (rlo[1] + rhi[1]) / 2,
                      -self.top_allowance - rhi[2]])
        return affine(self.part_rotation * self.part_scale, t)

    # ---- stock
    def stock_size(self, stock) -> np.ndarray:
        return self.raw_stock_size(stock)

    def raw_stock_size(self, stock) -> np.ndarray:
        e = stock.envelope
        e = (e.x, e.y, e.z)
        return np.array([e[self.stock_axes[0]], e[self.stock_axes[1]], e[self.stock_axes[2]]], float)

    def stock_box(self, stock) -> tuple[np.ndarray, np.ndarray]:
        s = self.stock_size(stock)
        return np.array([-s[0] / 2, -s[1] / 2, -s[2]]), np.array([s[0] / 2, s[1] / 2, 0.0])

    def stock_triangles(self, stock_size) -> np.ndarray:
        from ..safety.collision import Collision
        s = stock_size
        return Collision.box_triangles(np.array([-s[0] / 2, -s[1] / 2, -s[2]]), np.array([s[0] / 2, s[1] / 2, 0.0]))

    def placement_limits(self, part_min, part_max, stock, tool_diameter: float = 6.35) -> tuple[Range, Range, Range]:
        lo, hi = self.rotated_part_bounds(part_min, part_max)
        size = hi - lo
        raw = self.stock_size(stock)
        mx, my = max((raw[0] - size[0]) / 2, 0.0), max((raw[1] - size[1]) / 2, 0.0)
        return Range(-mx, mx), Range(-my, my), Range(0.0, max(raw[2] - size[2], 0.0))

    @staticmethod
    def default_stock_axes(stock) -> list[int]:
        """Thinnest dimension toward the spindle, longest along Y."""
        e = (stock.envelope.x, stock.envelope.y, stock.envelope.z)
        order = sorted(range(3), key=lambda k: e[k])  # thin, mid, long (stable like Swift's sort)
        return [order[1], order[2], order[0]]

    @staticmethod
    def default_orientation(part_min, part_max) -> tuple[Facing, int]:
        """Thinnest part dimension along the tool axis, longest along Y."""
        size = np.asarray(part_max, float) - np.asarray(part_min, float)
        thin = min(range(3), key=lambda k: size[k])
        facing = (Facing.PLUS_X, Facing.PLUS_Y, Facing.PLUS_Z)[thin]
        best = (facing, 0)
        for spin in range(4):
            s = Setup()
            s.facing, s.spin = facing, spin
            rlo, rhi = s.rotated_part_bounds(part_min, part_max)
            if rhi[1] - rlo[1] >= rhi[0] - rlo[0] - 1e-9:
                best = (facing, spin)
                break
        return best

    def for_side(self, side: int, part_min, part_max, stock) -> "Setup | None":
        """This side-A setup turned so `side` (SetupSide index) faces the spindle, for the same
        stock: the part keeps its place in the stock. None when it can't be turned (side B)."""
        from .setup_side import SetupSide
        if side == 0:
            return self
        if side == 1:
            return self.side_b(part_min, part_max, stock)
        if not 2 <= side <= 5 or self.flipped:
            return None
        a = self.stock_size(stock)
        axis = 1 if side < 4 else 0
        quarter = {2: -1, 3: 1, 4: 1, 5: -1}[side]
        out = self.turned(axis, quarter)
        m = SetupSide.axis_map(side)
        out.stock_axes = [self.stock_axes[k] for k in m]
        mat = self.part_to_work(part_min, part_max)
        lo, hi = np.asarray(part_min, float), np.asarray(part_max, float)
        nlo, nhi = np.full(3, np.inf), np.full(3, -np.inf)
        for i in range(8):
            c = np.array([hi[0] if i & 1 else lo[0], hi[1] if i & 2 else lo[1], hi[2] if i & 4 else lo[2], 1.0])
            w = mat @ c
            p = SetupSide.from_a(w[:3], side, a)
            nlo, nhi = np.minimum(nlo, p), np.maximum(nhi, p)
        out.part_offset_x = (nlo[0] + nhi[0]) / 2
        out.part_offset_y = (nlo[1] + nhi[1]) / 2
        out.top_allowance = -nhi[2]
        return out


class SetupChecks:
    """Fit checks for a setup. Plain-language results, like the inventory checks."""

    @staticmethod
    def check(setup: Setup, part_min, part_max, stock, machine=None) -> list:
        from ..inventory.checks import Issue, Severity
        from ..machine.profile import MachineProfile
        machine = machine or MachineProfile.standard()
        issues = []
        m = setup.part_to_work(part_min, part_max)
        rlo, rhi = setup.rotated_part_bounds(part_min, part_max)
        shift = m[:3, 3]
        plo, phi = rlo + shift, rhi + shift
        bmin, bmax = setup.stock_box(stock)
        names = ["X (vertical)", "Y (left–right)"]
        for axis in range(2):
            slack = min(plo[axis] - bmin[axis], bmax[axis] - phi[axis])
            if slack < -1e-6:
                issues.append(Issue(Severity.ERROR, f"The part sticks out of the stock in {names[axis]} by {Length.mm(-slack)} mm. Use bigger stock, turn the part, or move it."))
            elif slack < 1e-6:
                issues.append(Issue(Severity.INFO, f"The part meets an existing stock face in {names[axis]}. No extra stock is required on a face that stays as supplied."))
            elif slack < 3:
                issues.append(Issue(Severity.INFO, f"{Length.mm(slack)} mm of stock around the part in {names[axis]}. Tool and fixture clearance is checked on the generated paths."))
        depth = phi[2] - plo[2] + setup.top_allowance
        thickness = bmax[2] - bmin[2]
        if depth > thickness + 1e-6:
            issues.append(Issue(Severity.ERROR, f"The part ({Length.mm(phi[2] - plo[2])} mm deep plus {Length.mm(setup.top_allowance)} mm to face) is thicker than the stock ({Length.mm(thickness)} mm)."))
        elif thickness - depth < 2:
            issues.append(Issue(Severity.INFO, "The part reaches the stock's back face. Any cut that frees it needs independent support or holding tabs."))
        size = setup.stock_size(stock)
        if size[0] > machine.travel.x:
            issues.append(Issue(Severity.ERROR, f"The stock is {Length.mm(size[0])} mm tall in X; the machine only travels {Length.mm(machine.travel.x)} mm vertically."))
        if size[1] > machine.travel.y:
            issues.append(Issue(Severity.ERROR, f"The stock is {Length.mm(size[1])} mm wide in Y; the machine travels {Length.mm(machine.travel.y)} mm."))
        if phi[2] - plo[2] > 25:
            issues.append(Issue(Severity.INFO, f"The part is {Length.mm(phi[2] - plo[2])} mm deep along the spindle. Deep walls need long tools; the planner will check reach per tool."))
        return issues


from ..inventory.items import Fixture  # noqa: E402  (type hint; imported last to avoid a cycle)
