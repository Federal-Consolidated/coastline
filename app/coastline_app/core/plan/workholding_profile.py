"""A reusable definition for one assembled state of a jig, and the library workholding plan.
Port of the data types in Plan/LibraryWorkholding.swift (the planner is in library_workholding.py).

CAD alone cannot establish grip, load capacity, or an adjustable jaw's position: those are
supplied once by the fixture's owner."""

from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field
from enum import Enum

import numpy as np

from ..codable import jfield
from ..geometry import Vec3, affine
from ..ids import new_id
from .fixture_assembly import FixtureAssemblyState
from .setup import Facing, Setup


class ContactNormal(Enum):
    X = "x"
    Y = "y"
    Z = "z"


@dataclass
class Contact:
    """Centre and radius of a material patch the fixture needs, in stock work coordinates."""

    id: str = field(default_factory=new_id)
    point: Vec3 = Vec3()
    radius: float = 1.0
    normal: ContactNormal | None = None


@dataclass
class ComponentPlacement:
    """Translation and quarter-turn orientation in the imported CAD coordinates."""

    id: str
    offset: Vec3 = Vec3()
    facing: Facing = Facing.PLUS_Z
    spin: int = 0


@dataclass
class FixturePlanningProfile:
    enabled: bool = False
    stock_size: Vec3 = Vec3()  # assembled stock dimensions in the work frame
    datum: Vec3 = Vec3()  # stock work zero in the model's original coordinates
    facing: Facing = Facing.PLUS_Z
    spin: int = 0
    face_past_table: float = 2.0
    allows_roughing: bool = False
    contacts: list[Contact] = field(default_factory=list)
    grip_definition_reviewed: bool = False
    component_placements: list[ComponentPlacement] | None = None
    component_model_signature: str | None = None
    component_layout_id: str | None = jfield(None, key="componentLayoutID")
    workspace_placed: bool | None = None
    assembly_state: FixtureAssemblyState | None = None

    def copy(self) -> "FixturePlanningProfile":
        return copy.deepcopy(self)

    def turned(self, about: int, quarter_turns: int) -> "FixturePlanningProfile":
        """Rotate the assembled fixture about the stock datum in work coordinates."""
        if about not in (0, 1, 2):
            return self
        s = Setup()
        s.facing, s.spin = self.facing, self.spin
        t = s.turned(about, quarter_turns)
        r = self.copy()
        r.facing, r.spin = t.facing, t.spin
        r.grip_definition_reviewed = False
        return r

    def moved(self, in_work: Vec3) -> "FixturePlanningProfile":
        """Nudge the fixture in machine/work directions while keeping the stock preview fixed."""
        if not in_work.is_finite:
            return self
        s = Setup()
        s.facing, s.spin = self.facing, self.spin
        local = s.part_rotation.T @ in_work.array
        r = self.copy()
        r.datum = Vec3(self.datum.x - local[0], self.datum.y - local[1], self.datum.z - local[2])
        r.grip_definition_reviewed = False
        return r

    @property
    def definition_issues(self) -> list[str]:
        issues: list[str] = []
        if not self.enabled:
            issues.append("Not enabled for automatic planning.")
        values = (self.stock_size.x, self.stock_size.y, self.stock_size.z)
        if any(not math.isfinite(v) or v <= 0 or v > 10_000 for v in values):
            issues.append("Set the stock dimensions represented by this assembled jig.")
        if not all(math.isfinite(v) and abs(v) < 1_000_000 for v in (self.datum.x, self.datum.y, self.datum.z, self.face_past_table)):
            issues.append("The datum and placement must be finite and within supported modelling coordinates.")
        if len(self.contacts) < 2:
            issues.append("Define at least two grip/support patches.")
        if any(not (c.point.is_finite and math.isfinite(c.radius)) or c.radius <= 0 for c in self.contacts):
            issues.append("Grip patches need finite coordinates and a positive radius.")
        if not self.grip_definition_reviewed:
            issues.append("Review the grip/support definition and cutting-load suitability.")
        if self.workspace_placed is True and (self.component_model_signature is None or self.component_layout_id is None):
            issues.append("Recheck the model for the saved workspace placement.")
        pieces = self.component_placements
        if pieces:
            if self.component_model_signature is None or self.component_layout_id is None:
                issues.append("Recheck the assembly model for the saved piece positions.")
            if len({p.id for p in pieces}) != len(pieces) or any(
                    not all(math.isfinite(v) and abs(v) < 1_000_000 for v in (p.offset.x, p.offset.y, p.offset.z)) or not 0 <= p.spin < 4
                    for p in pieces):
                issues.append("The assembly has invalid piece positions.")
        return issues

    @property
    def model_to_work(self) -> np.ndarray:
        s = Setup()
        s.facing, s.spin = self.facing, self.spin
        r = s.part_rotation
        return affine(r, -(r @ self.datum.array))


@dataclass
class LibraryWorkholdingStep:
    number: int
    side: int
    fixture: Fixture
    cut_keys: list[str]
    operations: list[str]
    reasons: list[str]
    model_signature: str | None = None
    reviewed: bool = False
    id: str = field(default_factory=new_id)

    @property
    def title(self) -> str:
        return f"Setup {self.number} · {self.fixture.name}"

    @property
    def instructions(self) -> str:
        from .setup_side import SetupSide
        fixture = self.fixture
        patches = fixture.planning.contacts if fixture.planning is not None else []
        turn = f"Turn the stock so its {SetupSide.words(self.side)} faces the spindle. " if self.side >= 2 else ""
        side = 0 if self.side >= 2 else self.side
        a = fixture.assembly
        if a is not None and a.bookends is not None:
            placement = ("Place the stock against the fixed end and locating lip. Slide the bookend bases into position, secure both bases to the table, then advance the side screw to contact. Verify the stock is seated and the mounting hardware is secure. "
                         if side == 0 else
                         "Release the side screw, flip the stock, and reseat it against the fixed end and locating lip. Keep the bases mounted in their reviewed positions, then advance the side screw to contact. Verify seating, secure gripping and the work datum before continuing. ")
        elif a is not None and a.clamp_pair is not None:
            placement = ("Lay the stock on the table with its face at the table's front edge. Hook a C-clamp under the table near each end of the stock and tighten both pads onto its top. "
                         if side == 0 else
                         "Loosen both C-clamps, flip the stock, and lay it back with its face at the table's front edge. Tighten both pads onto its top. ")
        elif a is not None and a.vise is not None:
            placement = ("Bolt the vise to the T-slot. Put the stock on the vise floor against the fixed jaw, with its face sticking out past the jaws as shown, and close the vise. "
                         if side == 0 else
                         "Open the vise, flip the stock, and seat it on the floor against the fixed jaw as before. Close the vise. ")
        else:
            placement = f"Use {fixture.name}. "
        return (turn + placement + fixture.notes + "\n\n"
                + ("" if not patches else f"Keep its {len(patches)} defined grip/support patches engaged. ")
                + "Establish X0 Y0 at the stock-face centre and Z0 at its original face; account for material already faced away."
                + ("\n\nThis fixture has no model yet: no clearance check was made against it. Keep the jaws behind the depth this setup cuts."
                   if fixture.model_path is None else
                   "\n\nCutter, shank and holder paths were checked against the placed CAD assembly. Confirm secure gripping, mounting, and material connectivity; geometric contact checks do not prove clamping force or rigidity."))


@dataclass
class LibraryWorkholdingPlan:
    steps: list[LibraryWorkholdingStep] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)
    reordered: bool | None = None  # the user put the steps in their own order

    @property
    def complete(self) -> bool:
        return bool(self.steps) and not self.issues

    @property
    def reviewed(self) -> bool:
        return self.complete and all(s.reviewed for s in self.steps)

    def step(self, key: str) -> LibraryWorkholdingStep | None:
        return next((s for s in self.steps if key in s.cut_keys), None)


from ..inventory.items import Fixture  # noqa: E402
