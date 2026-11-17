"""Reviewed fixture mechanisms that fit themselves to the stock: bookends, a C-clamp pair and a
vise. Port of Plan/BookendSetup.swift and Plan/FixtureMechanism.swift."""

from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field

import numpy as np

from .. import codable
from ..codable import Range, jfield
from ..geometry import Vec3
from .format import mm as dfm_mm

MAX_FACE_PAST_TABLE = 25.0  # the most a fitted stock's face stands past the table's edge, mm


class PlacementError(Exception):
    pass


@dataclass
class Table:
    top_x: float
    slot_z: list[float]
    slot_y: Range
    front_z: float
    centre_y: float


def _finite(values, limit: float = 1_000_000) -> bool:
    return all(math.isfinite(v) and abs(v) < limit for v in values)


# ---------------------------------------------------------------- bookends

@dataclass
class BookendDefinition:
    seat_x: float
    slot_z: list[float]
    fixed_contact_y: float
    clamp_contact_y: float
    screw_axis_x: float
    screw_axis_z: float
    stock_back_z: float
    pressure_tip_radius: float
    fixed_nut_y: Range
    clamp_nut_y: Range
    # Older saved definitions omitted contact dimensions: keep them, but require a rebind.
    contact_metadata_complete: bool = True

    def __hash__(self) -> int:
        return hash((self.seat_x, tuple(self.slot_z), self.fixed_contact_y, self.clamp_contact_y))

    @staticmethod
    def from_json(d) -> "BookendDefinition":
        back, radius = d.get("stockBackZ"), d.get("pressureTipRadius")
        return BookendDefinition(
            float(d["seatX"]), [float(v) for v in d["slotZ"]], float(d["fixedContactY"]), float(d["clampContactY"]),
            float(d["screwAxisX"]), float(d["screwAxisZ"]), float(back) if back is not None else 0.0,
            float(radius) if radius is not None else 0.0, Range.from_json(d["fixedNutY"]), Range.from_json(d["clampNutY"]),
            bool(d.get("contactMetadataComplete", True)) and back is not None and radius is not None)

    def to_json(self) -> dict:
        return {"seatX": self.seat_x, "slotZ": list(self.slot_z), "fixedContactY": self.fixed_contact_y,
                "clampContactY": self.clamp_contact_y, "screwAxisX": self.screw_axis_x, "screwAxisZ": self.screw_axis_z,
                "stockBackZ": self.stock_back_z, "pressureTipRadius": self.pressure_tip_radius,
                "contactMetadataComplete": self.contact_metadata_complete,
                "fixedNutY": self.fixed_nut_y.to_json(), "clampNutY": self.clamp_nut_y.to_json()}

    @property
    def validation_issues(self) -> list[str]:
        if not self.contact_metadata_complete:
            return ["This older bookend definition is missing stock-locating and screw-contact dimensions. Reload its audited assembly definition before planning."]
        values = [self.seat_x, self.fixed_contact_y, self.clamp_contact_y, self.screw_axis_x, self.screw_axis_z,
                  self.stock_back_z, self.pressure_tip_radius, self.fixed_nut_y.lower, self.fixed_nut_y.upper,
                  self.clamp_nut_y.lower, self.clamp_nut_y.upper] + list(self.slot_z)
        if not (_finite(values) and len(self.slot_z) == 2 and abs(self.slot_z[1] - self.slot_z[0]) > 0
                and self.fixed_contact_y < self.clamp_contact_y and self.pressure_tip_radius > 0
                and self.fixed_nut_y.lower < self.fixed_nut_y.upper and self.clamp_nut_y.lower < self.clamp_nut_y.upper):
            return ["The bookend mounting/contact definition is invalid."]
        return []


def _contact(point: Vec3, radius: float, normal: str | None = None):
    from .workholding_profile import Contact, ContactNormal
    c = Contact(point=point, radius=radius)
    if normal is not None:
        c.normal = ContactNormal(normal)
    return c


def _stock_matches(stock, size: Vec3) -> bool:
    return float(np.linalg.norm(np.asarray(stock, float) - np.array([size.x, size.y, size.z]))) < 1e-6


class BookendSetup:
    """Placement rules for the audited two-base bookend mechanism."""

    FIXED, CLAMP, PRESSURE = "fixed-end", "clamp-end", "pressure-screw"
    FIXED_SLIDE, CLAMP_SLIDE, PRESSURE_EXTENSION = "fixed-slide", "clamp-slide", "pressure-extension"

    def __init__(self, assembly, table: Table, stock) -> None:
        from .fixture_assembly import JointKind
        assembly.validate()
        d = assembly.bookends
        comps = {c.id: c for c in reversed(assembly.components)}
        fixed, clamp, pressure = comps.get(self.FIXED), comps.get(self.CLAMP), comps.get(self.PRESSURE)
        screw = pressure.joint if pressure is not None else None
        ok = (d is not None and not d.validation_issues and fixed is not None and fixed.parent_id is None
              and clamp is not None and clamp.parent_id is None and pressure is not None and pressure.parent_id == self.CLAMP
              and screw is not None and screw.id == self.PRESSURE_EXTENSION and screw.kind is JointKind.SCREW
              and screw.axis == Vec3(0, -1, 0) and screw.minimum >= 0
              and fixed.joint is not None and fixed.joint.id == self.FIXED_SLIDE and fixed.joint.axis == Vec3(0, 1, 0)
              and fixed.joint.kind is JointKind.PRISMATIC
              and clamp.joint is not None and clamp.joint.id == self.CLAMP_SLIDE and clamp.joint.axis == Vec3(0, 1, 0)
              and clamp.joint.kind is JointKind.PRISMATIC
              and fixed.joint.reference_value == 0 and clamp.joint.reference_value == 0)
        if not ok:
            raise PlacementError("This fixture needs its audited bookend mechanism definition.")
        stock = np.asarray(stock, float)
        if not (all(math.isfinite(v) and 0 < v < 10_000 for v in stock)
                and all(math.isfinite(v) for v in (table.top_x, table.front_z, table.centre_y, table.slot_y.lower, table.slot_y.upper))
                and len(table.slot_z) == 2 and all(math.isfinite(v) for v in table.slot_z) and table.slot_y.lower < table.slot_y.upper):
            raise PlacementError("Choose stock and a machine with two measured T-slots before seating the bookends.")
        if abs(abs(d.slot_z[1] - d.slot_z[0]) - abs(table.slot_z[1] - table.slot_z[0])) > 0.02:
            raise PlacementError("The bookend keys do not match this machine's T-slot spacing.")
        if not (d.screw_axis_x - d.pressure_tip_radius >= d.seat_x and d.screw_axis_x + d.pressure_tip_radius <= d.seat_x + stock[0]
                and d.screw_axis_z - d.pressure_tip_radius >= d.stock_back_z and d.screw_axis_z + d.pressure_tip_radius <= d.stock_back_z + stock[2]):
            raise PlacementError("This stock is too small for the side screw to contact its end face while seated against the locating lip.")
        face_past = min(table.slot_z) - min(d.slot_z) + d.stock_back_z + stock[2] - table.front_z
        if face_past > MAX_FACE_PAST_TABLE + 1e-6:
            raise PlacementError(f"The stock is {dfm_mm(stock[2], 0.1)} mm deep this way. Against the bookends' back lip its face would stand {dfm_mm(face_past, 0.1)} mm past the table, into the machine.")
        self.definition, self.assembly, self.table, self.stock, self.screw = d, assembly, table, stock, screw

    def seat(self, profile):
        """Seats the keys, seats the stock against the locating lip and brings both contacts to
        its end faces. Geometric contact only, not a grip/load certification."""
        from .fixture_assembly import FixtureAssemblyState
        from .setup import Facing
        d, s = self.definition, self.stock
        p = copy.deepcopy(profile)
        p.facing, p.spin, p.component_placements = Facing.PLUS_Z, 0, None
        p.stock_size = Vec3(*s)
        p.datum = Vec3(d.seat_x + s[0] / 2, (d.fixed_contact_y + d.clamp_contact_y - self.screw.reference_value) / 2,
                       d.stock_back_z + s[2])
        p.face_past_table = min(self.table.slot_z) - min(d.slot_z) + p.datum.z - self.table.front_z
        state = FixtureAssemblyState(mounted=True)
        state.joint_values[self.FIXED_SLIDE] = p.datum.y - s[1] / 2 - d.fixed_contact_y
        state.joint_values[self.CLAMP_SLIDE] = p.datum.y + s[1] / 2 - d.clamp_contact_y + self.screw.reference_value
        state.joint_values[self.PRESSURE_EXTENSION] = self.screw.reference_value
        p.assembly_state, p.workspace_placed, p.grip_definition_reviewed = state, True, False
        contact_x = d.screw_axis_x - p.datum.x
        radius = min(d.pressure_tip_radius, (d.screw_axis_x - d.seat_x) / 2, (d.seat_x + s[0] - d.screw_axis_x) / 2, s[2] / 4)
        p.contacts = [_contact(Vec3(contact_x, -s[1] / 2, d.screw_axis_z - p.datum.z), radius, "y"),
                      _contact(Vec3(contact_x, s[1] / 2, d.screw_axis_z - p.datum.z), radius, "y")]
        self.validate(p)
        return p

    def value(self, profile, joint_id: str) -> float:
        st = profile.assembly_state
        if st is not None and joint_id in st.joint_values:
            return st.joint_values[joint_id]
        j = next((c.joint for c in self.assembly.components if c.joint is not None and c.joint.id == joint_id), None)
        return j.reference_value if j is not None else 0.0

    def gap(self, p) -> float:
        return (self.definition.clamp_contact_y + self.value(p, self.CLAMP_SLIDE) - self.value(p, self.PRESSURE_EXTENSION)
                - p.datum.y - self.stock[1] / 2)

    def base_range(self, p, component_id: str) -> Range:
        fixed = component_id == self.FIXED
        comp = next((c for c in self.assembly.components if c.id == component_id), None)
        if not (fixed or component_id == self.CLAMP) or comp is None or comp.joint is None:
            raise PlacementError("Select a bookend base to slide along its T-slots.")
        joint = comp.joint
        d, t = self.definition, self.table
        footprint = d.fixed_nut_y if fixed else d.clamp_nut_y
        low = max(joint.minimum, t.slot_y.lower - t.centre_y + p.datum.y - footprint.lower)
        high = min(joint.maximum, t.slot_y.upper - t.centre_y + p.datum.y - footprint.upper)
        if fixed:
            high = min(high, p.datum.y - self.stock[1] / 2 - d.fixed_contact_y)
        else:
            low = max(low, p.datum.y + self.stock[1] / 2 - d.clamp_contact_y + self.value(p, self.PRESSURE_EXTENSION))
        if low > high + 1e-7:
            raise PlacementError("The stock and bookend mounting nuts do not fit within the available T-slot length.")
        return Range(low, max(low, high))

    def pressure_range(self, p) -> Range:
        contact = self.definition.clamp_contact_y + self.value(p, self.CLAMP_SLIDE) - p.datum.y - self.stock[1] / 2
        if contact < self.screw.minimum - 1e-7:
            raise PlacementError("Slide the clamp base clear of the stock before advancing its side screw.")
        return Range(self.screw.minimum, max(self.screw.minimum, min(self.screw.maximum, contact)))

    def sliding(self, profile, component_id: str, to: float):
        if not math.isfinite(to):
            raise PlacementError("Enter a finite slide distance.")
        if profile.assembly_state is None or not profile.assembly_state.mounted:
            raise PlacementError("Seat the bookends on the table first.")
        if component_id in profile.assembly_state.locked_components:
            return profile
        r = self.base_range(profile, component_id)
        p = copy.deepcopy(profile)
        p.assembly_state.joint_values[self.FIXED_SLIDE if component_id == self.FIXED else self.CLAMP_SLIDE] = r.clamp(to)
        if p != profile:
            p.grip_definition_reviewed = False
        return p

    def setting_pressure(self, profile, to: float):
        if not math.isfinite(to):
            raise PlacementError("Enter a finite screw extension.")
        if profile.assembly_state is None or not profile.assembly_state.mounted:
            raise PlacementError("Seat the bookends on the table first.")
        r = self.pressure_range(profile)
        p = copy.deepcopy(profile)
        p.assembly_state.joint_values[self.PRESSURE_EXTENSION] = r.clamp(to)
        if p != profile:
            p.grip_definition_reviewed = False
        return p

    def planning_issues(self, p) -> list[str]:
        """Additional CAM eligibility checks: geometry alone cannot imply a secured setup."""
        try:
            self.validate(p)
        except Exception as e:  # noqa: BLE001
            return [str(e)]
        issues = []
        if p.assembly_state is None or not {self.FIXED, self.CLAMP} <= p.assembly_state.locked_components:
            issues.append("Lock both bookend base positions before planning the cuts.")
        fixed_gap = -self.stock[1] / 2 - (self.definition.fixed_contact_y + self.value(p, self.FIXED_SLIDE) - p.datum.y)
        if fixed_gap > 0.01 or self.gap(p) > 0.01:
            issues.append("Seat both bookends against the stock and advance the side screw to contact.")
        return issues

    def validate(self, p) -> None:
        from .fixture_assembly import FixtureAssemblyState
        from .setup import Facing
        self.assembly.validate(p.assembly_state or FixtureAssemblyState())
        d, t = self.definition, self.table
        if not (p.assembly_state is not None and p.assembly_state.mounted and p.facing is Facing.PLUS_Z and p.spin == 0
                and not p.component_placements and _stock_matches(self.stock, p.stock_size)
                and abs(p.datum.x - d.seat_x - self.stock[0] / 2) < 1e-6 and abs(p.datum.z - d.stock_back_z - self.stock[2]) < 1e-6
                and abs(p.face_past_table - (min(t.slot_z) - min(d.slot_z) + p.datum.z - t.front_z)) < 1e-6):
            raise PlacementError("Seat the bookends to this stock and machine before saving.")
        for cid in (self.FIXED, self.CLAMP):
            r = self.base_range(p, cid)
            v = self.value(p, self.FIXED_SLIDE if cid == self.FIXED else self.CLAMP_SLIDE)
            if not (r.lower - 1e-6 <= v <= r.upper + 1e-6):
                raise PlacementError("A bookend base extends beyond the T-slot or into the stock. Seat it to the stock again.")
        r = self.pressure_range(p)
        v = self.value(p, self.PRESSURE_EXTENSION)
        if not (r.lower - 1e-6 <= v <= r.upper + 1e-6):
            raise PlacementError("The side screw intersects the stock. Release it or seat the bookends again.")


# ---------------------------------------------------------------- C-clamp pair

@dataclass
class ClampPairDefinition:
    seat_x: float  # table top: the stock's lower face
    front_z: float  # the table's spindle-side edge
    pad_z: float
    pad_radius: float
    pad_x: float
    pad_y: list[float]  # pad centre across the table for clamp A and B at the authored pose
    frame_half_width: float

    def __hash__(self) -> int:
        return hash((self.seat_x, self.front_z, self.pad_z))

    @property
    def validation_issues(self) -> list[str]:
        values = [self.seat_x, self.front_z, self.pad_z, self.pad_radius, self.pad_x, self.frame_half_width] + list(self.pad_y)
        if not (_finite(values) and len(self.pad_y) == 2 and self.pad_y[0] < self.pad_y[1] and self.pad_radius > 0
                and self.frame_half_width > 0 and self.pad_x > self.seat_x and self.pad_z < self.front_z):
            return ["The C-clamp mounting/contact definition is invalid."]
        return []


class ClampPairSetup:
    """A pair of C-clamps that hook under the table and press the stock down onto it."""

    CLAMPS, SCREWS = ["clamp-a", "clamp-b"], ["screw-a", "screw-b"]
    SLIDES, ADVANCES = ["clamp-a-slide", "clamp-b-slide"], ["screw-a-advance", "screw-b-advance"]

    def __init__(self, assembly, table: Table, stock) -> None:
        from .fixture_assembly import JointKind
        assembly.validate()
        d = assembly.clamp_pair
        comps = {}
        for c in assembly.components:
            comps.setdefault(c.id, c)
        screw = comps[self.SCREWS[0]].joint if self.SCREWS[0] in comps else None
        if d is None or d.validation_issues or screw is None:
            raise PlacementError("This fixture needs its reviewed C-clamp definition.")
        for k in range(2):
            clamp, s = comps.get(self.CLAMPS[k]), comps.get(self.SCREWS[k])
            ok = (clamp is not None and clamp.parent_id is None and clamp.joint is not None and clamp.joint.id == self.SLIDES[k]
                  and clamp.joint.kind is JointKind.PRISMATIC and clamp.joint.axis == Vec3(0, 1, 0) and clamp.joint.reference_value == 0
                  and s is not None and s.parent_id == self.CLAMPS[k] and s.joint is not None and s.joint.id == self.ADVANCES[k]
                  and s.joint.kind is JointKind.SCREW and s.joint.axis == Vec3(-1, 0, 0) and s.joint.reference_value == 0
                  and s.joint.minimum == screw.minimum and s.joint.maximum == screw.maximum)
            if not ok:
                raise PlacementError("This fixture needs its reviewed C-clamp definition.")
        stock = np.asarray(stock, float)
        if not (all(math.isfinite(v) and 0 < v < 10_000 for v in stock)
                and all(math.isfinite(v) for v in (table.top_x, table.front_z, table.centre_y, table.slot_y.lower, table.slot_y.upper))):
            raise PlacementError("Choose stock and a machine with a measured table before fitting the C-clamps.")
        tallest = d.pad_x - screw.minimum - d.seat_x
        if stock[0] > tallest + 1e-6:
            raise PlacementError(f"The stock is {dfm_mm(stock[0], 0.1)} mm tall. The C-clamps open to {dfm_mm(tallest, 0.1)} mm above the table.")
        deep = d.front_z - d.pad_z + d.pad_radius
        if stock[2] < deep:
            raise PlacementError(f"The stock is {dfm_mm(stock[2], 0.1)} mm deep. The C-clamp pads need {dfm_mm(deep, 0.1)} mm.")
        wide = 2 * (d.pad_radius + 1) + 2 * d.frame_half_width + 1
        if stock[1] < wide:
            raise PlacementError(f"The stock is {dfm_mm(stock[1], 0.1)} mm long. Two C-clamps need {dfm_mm(wide, 0.1)} mm.")
        self.definition, self.assembly, self.table, self.stock, self.screw = d, assembly, table, stock, screw

    @property
    def contact_advance(self) -> float:
        """The stock's top face above the pad at the authored pose: how far each screw advances."""
        return self.definition.pad_x - (self.definition.seat_x + self.stock[0])

    def value(self, p, joint: str) -> float:
        return (p.assembly_state.joint_values.get(joint, 0.0) if p.assembly_state is not None else 0.0)

    def pad_y(self, p, k: int) -> float:
        return self.definition.pad_y[k] + self.value(p, self.SLIDES[k])

    def seat(self, profile):
        from .fixture_assembly import FixtureAssemblyState
        from .setup import Facing
        d, s = self.definition, self.stock
        p = copy.deepcopy(profile)
        p.facing, p.spin, p.component_placements = Facing.PLUS_Z, 0, None
        p.stock_size = Vec3(*s)
        p.datum = Vec3(d.seat_x + s[0] / 2, (d.pad_y[0] + d.pad_y[1]) / 2, d.front_z)
        p.face_past_table = p.datum.z - d.front_z
        gap = 2 * d.frame_half_width + 1
        inset = max(d.pad_radius + 1, min(20, (s[1] - gap) / 2))
        state = FixtureAssemblyState(mounted=True)
        state.joint_values[self.SLIDES[0]] = p.datum.y - s[1] / 2 + inset - d.pad_y[0]
        state.joint_values[self.SLIDES[1]] = p.datum.y + s[1] / 2 - inset - d.pad_y[1]
        for jid in self.ADVANCES:
            state.joint_values[jid] = self.contact_advance
        p.assembly_state, p.workspace_placed, p.grip_definition_reviewed = state, True, False
        p.contacts = self.contacts(p)
        self.validate(p)
        return p

    def contacts(self, p) -> list:
        d, s = self.definition, self.stock
        z = d.pad_z - p.datum.z
        radius = min(d.pad_radius, s[1] / 4)
        out = []
        for k in range(2):
            y = self.pad_y(p, k) - p.datum.y
            out += [_contact(Vec3(s[0] / 2, y, z), radius, "x"), _contact(Vec3(-s[0] / 2, y, z), radius, "x")]
        return out

    def range(self, p, joint: str) -> Range:
        d, t = self.definition, self.table
        if joint in self.ADVANCES:
            return Range(self.screw.minimum, max(self.screw.minimum, min(self.screw.maximum, self.contact_advance)))
        if joint not in self.SLIDES:
            raise PlacementError("Unknown C-clamp control.")
        k = self.SLIDES.index(joint)
        low = p.datum.y - self.stock[1] / 2 + d.pad_radius
        high = p.datum.y + self.stock[1] / 2 - d.pad_radius
        table_low = t.slot_y.lower - t.centre_y + p.datum.y + d.frame_half_width
        table_high = t.slot_y.upper - t.centre_y + p.datum.y - d.frame_half_width
        low, high = max(low, table_low), min(high, table_high)
        gap = 2 * d.frame_half_width + 1
        if k == 0:
            high = min(high, self.pad_y(p, 1) - gap)
        else:
            low = max(low, self.pad_y(p, 0) + gap)
        if low > high + 1e-7:
            raise PlacementError("The C-clamps don't fit along this stock on the table.")
        return Range(low - d.pad_y[k], max(low, high) - d.pad_y[k])

    def setting(self, profile, joint: str, to: float):
        if not math.isfinite(to):
            raise PlacementError("Enter a finite value.")
        if profile.assembly_state is None or not profile.assembly_state.mounted:
            raise PlacementError("Fit the C-clamps to the stock first.")
        r = self.range(profile, joint)
        p = copy.deepcopy(profile)
        p.assembly_state.joint_values[joint] = r.clamp(to)
        p.contacts = self.contacts(p)
        if p != profile:
            p.grip_definition_reviewed = False
        return p

    def validate(self, p) -> None:
        from .fixture_assembly import FixtureAssemblyState
        from .setup import Facing
        self.assembly.validate(p.assembly_state or FixtureAssemblyState())
        d = self.definition
        if not (p.assembly_state is not None and p.assembly_state.mounted and p.facing is Facing.PLUS_Z and p.spin == 0
                and not p.component_placements and _stock_matches(self.stock, p.stock_size)
                and abs(p.datum.x - d.seat_x - self.stock[0] / 2) < 1e-6 and abs(p.datum.z - d.front_z) < 1e-6):
            raise PlacementError("Fit the C-clamps to this stock again.")
        for joint in self.SLIDES + self.ADVANCES:
            r, v = self.range(p, joint), self.value(p, joint)
            if not (r.lower - 1e-6 <= v <= r.upper + 1e-6):
                raise PlacementError("A C-clamp is off the stock or into it. Fit them again.")

    def planning_issues(self, p) -> list[str]:
        try:
            self.validate(p)
        except Exception as e:  # noqa: BLE001
            return [str(e)]
        if any(abs(self.value(p, a) - self.contact_advance) > 0.01 for a in self.ADVANCES):
            return ["Tighten both C-clamp screws to the stock."]
        return []


# ---------------------------------------------------------------- vise

@dataclass
class ViseDefinition:
    seat_x: float  # the vise floor
    fixed_jaw_y: float  # fixed jaw face (facing +Y)
    moving_jaw_y: float  # moving jaw face at the authored pose (facing −Y)
    jaw_x: list[float]
    jaw_z: list[float]
    slot_z: list[float]  # the T-slot the vise bolts to
    nut_y: list[float]  # its nuts' extent along the slot
    front_z: float  # the table's spindle-side edge

    def __hash__(self) -> int:
        return hash((self.seat_x, self.fixed_jaw_y, self.moving_jaw_y))

    @property
    def validation_issues(self) -> list[str]:
        values = [self.seat_x, self.fixed_jaw_y, self.moving_jaw_y, self.front_z] + list(self.jaw_x) + list(self.jaw_z) + list(self.slot_z) + list(self.nut_y)
        if not (_finite(values) and len(self.jaw_x) == 2 and len(self.jaw_z) == 2 and len(self.slot_z) == 1 and len(self.nut_y) == 2
                and self.jaw_x[0] < self.jaw_x[1] and self.jaw_z[0] < self.jaw_z[1] and self.nut_y[0] < self.nut_y[1]
                and self.fixed_jaw_y < self.moving_jaw_y):
            return ["The vise mounting/contact definition is invalid."]
        return []


class ViseSetup:
    """A vise bolted to one T-slot: the stock sits on its floor against the fixed jaw."""

    BODY, JAW, JAW_ADVANCE = "vise-body", "moving-jaw", "jaw-advance"

    def __init__(self, assembly, table: Table, stock) -> None:
        from .fixture_assembly import JointKind
        assembly.validate()
        d = assembly.vise
        comps = {}
        for c in assembly.components:
            comps.setdefault(c.id, c)
        body, jaw = comps.get(self.BODY), comps.get(self.JAW)
        joint = jaw.joint if jaw is not None else None
        if not (d is not None and not d.validation_issues and body is not None and body.parent_id is None and body.joint is None
                and jaw is not None and jaw.parent_id == self.BODY and joint is not None and joint.id == self.JAW_ADVANCE
                and joint.kind is JointKind.SCREW and joint.axis == Vec3(0, -1, 0) and joint.reference_value == 0):
            raise PlacementError("This fixture needs its reviewed vise definition.")
        stock = np.asarray(stock, float)
        if not (all(math.isfinite(v) and 0 < v < 10_000 for v in stock)
                and all(math.isfinite(v) for v in (table.top_x, table.front_z, table.centre_y, table.slot_y.lower, table.slot_y.upper))):
            raise PlacementError("Choose stock and a machine with measured T-slots before fitting the vise.")
        expected = d.slot_z[0] + (table.front_z - d.front_z)
        slot = min(table.slot_z, key=lambda z: abs(z - expected)) if table.slot_z else None
        if slot is None or abs(slot - expected) > 1:
            raise PlacementError("The vise's mounting nuts don't line up with this machine's T-slots.")
        opening = Range(d.moving_jaw_y - joint.maximum - d.fixed_jaw_y, d.moving_jaw_y - joint.minimum - d.fixed_jaw_y)
        if stock[1] not in opening:
            raise PlacementError(f"The stock is {dfm_mm(stock[1], 0.1)} mm across. The vise holds {dfm_mm(opening.lower, 0.1)}–{dfm_mm(opening.upper, 0.1)} mm.")
        if stock[0] < 2:
            raise PlacementError("The stock is too thin for the vise jaws.")
        self.definition, self.assembly, self.table, self.stock = d, assembly, table, stock
        self.jaw_joint, self.slot_offset = joint, slot - d.slot_z[0]

    @property
    def height(self) -> float:
        """The vise floor's height above the table."""
        return self.definition.seat_x - self.table.top_x

    @property
    def contact_advance(self) -> float:
        return self.definition.moving_jaw_y - self.definition.fixed_jaw_y - self.stock[1]

    @property
    def grip(self) -> float:
        """How deep the jaws hold the stock: two-thirds of it, up to the jaws' depth."""
        return min(self.definition.jaw_z[1] - self.definition.jaw_z[0], max(3.0, self.stock[2] * 2 / 3))

    def seat(self, profile):
        from .fixture_assembly import FixtureAssemblyState
        from .setup import Facing
        d, s = self.definition, self.stock
        p = copy.deepcopy(profile)
        p.facing, p.spin, p.component_placements = Facing.PLUS_Z, 0, None
        p.stock_size = Vec3(*s)
        jaws_past_table = d.jaw_z[1] + self.slot_offset - self.table.front_z
        standout = min(max(0.0, s[2] - self.grip), max(0.0, MAX_FACE_PAST_TABLE - jaws_past_table))
        front = d.jaw_z[1] + standout
        p.datum = Vec3(d.seat_x + s[0] / 2, d.fixed_jaw_y + s[1] / 2, front)
        p.face_past_table = front + self.slot_offset - self.table.front_z
        state = FixtureAssemblyState(mounted=True)
        state.joint_values[self.JAW_ADVANCE] = self.contact_advance
        p.assembly_state, p.workspace_placed, p.grip_definition_reviewed = state, True, False
        p.contacts = self.contacts(p)
        self.validate(p)
        return p

    def contacts(self, p) -> list:
        d, s = self.definition, self.stock
        x0 = max(d.jaw_x[0], d.seat_x) - p.datum.x
        x1 = min(d.jaw_x[1], d.seat_x + s[0]) - p.datum.x
        z0 = max(d.jaw_z[0], p.datum.z - s[2]) - p.datum.z
        z1 = min(d.jaw_z[1], p.datum.z) - p.datum.z
        x, z = (x0 + x1) / 2, (z0 + z1) / 2
        r = max(0.5, min((x1 - x0) / 2, (z1 - z0) / 2, 6))
        floor_r = max(0.5, min(s[1] / 4, (z1 - z0) / 2, 6))
        return [_contact(Vec3(x, -s[1] / 2, z), r, "y"), _contact(Vec3(x, s[1] / 2, z), r, "y"),
                _contact(Vec3(-s[0] / 2, 0, z), floor_r, "x")]

    def range(self, p, joint: str) -> Range:
        if joint != self.JAW_ADVANCE:
            raise PlacementError("Unknown vise control.")
        j = self.jaw_joint
        return Range(j.minimum, max(j.minimum, min(j.maximum, self.contact_advance)))

    def setting(self, profile, joint: str, to: float):
        if not math.isfinite(to):
            raise PlacementError("Enter a finite value.")
        if profile.assembly_state is None or not profile.assembly_state.mounted:
            raise PlacementError("Fit the vise to the stock first.")
        r = self.range(profile, joint)
        p = copy.deepcopy(profile)
        p.assembly_state.joint_values[joint] = r.clamp(to)
        if p != profile:
            p.grip_definition_reviewed = False
        return p

    def validate(self, p) -> None:
        from .fixture_assembly import FixtureAssemblyState
        from .setup import Facing
        self.assembly.validate(p.assembly_state or FixtureAssemblyState())
        d, t = self.definition, self.table
        if not (p.assembly_state is not None and p.assembly_state.mounted and p.facing is Facing.PLUS_Z and p.spin == 0
                and not p.component_placements and _stock_matches(self.stock, p.stock_size)
                and abs(p.datum.x - d.seat_x - self.stock[0] / 2) < 1e-6 and abs(p.datum.y - d.fixed_jaw_y - self.stock[1] / 2) < 1e-6
                and abs(p.face_past_table - (p.datum.z + self.slot_offset - t.front_z)) < 1e-6):
            raise PlacementError("Fit the vise to this stock again.")
        low = d.nut_y[0] - p.datum.y + t.centre_y
        high = d.nut_y[1] - p.datum.y + t.centre_y
        if low < t.slot_y.lower - 1e-6 or high > t.slot_y.upper + 1e-6:
            raise PlacementError("The vise's nuts run past the end of the T-slot.")
        r = self.range(p, self.JAW_ADVANCE)
        v = p.assembly_state.joint_values.get(self.JAW_ADVANCE, 0.0)
        if not (r.lower - 1e-6 <= v <= r.upper + 1e-6):
            raise PlacementError("The moving jaw is into the stock. Open it or fit the vise again.")

    def planning_issues(self, p) -> list[str]:
        try:
            self.validate(p)
        except Exception as e:  # noqa: BLE001
            return [str(e)]
        if abs(p.assembly_state.joint_values.get(self.JAW_ADVANCE, 0.0) - self.contact_advance) > 0.01:
            return ["Close the vise on the stock."]
        return []


# ---------------------------------------------------------------- the mechanism

@dataclass(frozen=True)
class Control:
    """One adjustable joint, for the placement controls."""

    id: str
    title: str
    component_id: str
    pitch: float | None  # a screw, shown in turns of its pitch; else a slide in mm
    tightens: bool  # its value grows toward the stock


class FixtureMechanism:
    MAX_FACE_PAST_TABLE = MAX_FACE_PAST_TABLE

    def __init__(self, impl) -> None:
        self.impl = impl  # BookendSetup | ClampPairSetup | ViseSetup

    @property
    def is_bookends(self) -> bool:
        return isinstance(self.impl, BookendSetup)

    @staticmethod
    def has(assembly) -> bool:
        return assembly is not None and (assembly.bookends is not None or assembly.clamp_pair is not None or assembly.vise is not None)

    @staticmethod
    def make(fixture, table: Table, stock) -> "FixtureMechanism | None":
        """None when the fixture has no reviewed mechanism; raises when it has one and the
        stock doesn't fit it."""
        a = fixture.assembly
        if a is None:
            return None
        if a.bookends is not None:
            return FixtureMechanism(BookendSetup(a, table, stock))
        if a.clamp_pair is not None:
            return FixtureMechanism(ClampPairSetup(a, table, stock))
        if a.vise is not None:
            return FixtureMechanism(ViseSetup(a, table, stock))
        return None

    @property
    def height(self) -> float:
        return self.impl.height if isinstance(self.impl, ViseSetup) else 0.0

    @property
    def controls(self) -> list[Control]:
        if isinstance(self.impl, ClampPairSetup):
            pitch = self.impl.screw.pitch
            S = ClampPairSetup
            return [Control(S.SLIDES[0], "Clamp A position", S.CLAMPS[0], None, False),
                    Control(S.ADVANCES[0], "Clamp A screw", S.SCREWS[0], pitch, True),
                    Control(S.SLIDES[1], "Clamp B position", S.CLAMPS[1], None, False),
                    Control(S.ADVANCES[1], "Clamp B screw", S.SCREWS[1], pitch, True)]
        if isinstance(self.impl, ViseSetup):
            return [Control(ViseSetup.JAW_ADVANCE, "Vise jaw", ViseSetup.JAW, self.impl.jaw_joint.pitch, True)]
        return []

    def seat(self, p):
        seated = self.impl.seat(p)
        if isinstance(self.impl, BookendSetup):
            seated.assembly_state.locked_components = {BookendSetup.FIXED, BookendSetup.CLAMP}
        return seated

    def validate(self, p) -> None:
        self.impl.validate(p)

    def planning_issues(self, p) -> list[str]:
        return self.impl.planning_issues(p)

    def value(self, p, joint: str) -> float:
        return p.assembly_state.joint_values.get(joint, 0.0) if p.assembly_state is not None else 0.0

    def range(self, p, joint: str) -> Range:
        if isinstance(self.impl, BookendSetup):
            raise PlacementError("Use the bookend controls.")
        return self.impl.range(p, joint)

    def setting(self, p, joint: str, to: float):
        if isinstance(self.impl, BookendSetup):
            raise PlacementError("Use the bookend controls.")
        return self.impl.setting(p, joint, to)

    @staticmethod
    def automatic(fixture, table: Table, stock):
        """The fixture fitted to this stock for an automatic plan. Its mechanism sets the
        contacts, so the grip definition counts as reviewed; every setup is still reviewed
        before export."""
        from .library_fixture_geometry import LibraryFixtureGeometry
        from .workholding_profile import FixturePlanningProfile
        mechanism = FixtureMechanism.make(fixture, table, stock)
        if mechanism is None:
            return None
        f = copy.deepcopy(fixture)
        p = f.planning if f.planning is not None else FixturePlanningProfile()
        roughing = p.allows_roughing if mechanism.is_bookends else True
        p = mechanism.seat(p)
        for k, contact in enumerate(p.contacts):  # the same fit gives the same fixture
            contact.id = "00000000-0000-4000-8000-%012X" % k
        p.enabled = True
        p.allows_roughing = roughing
        p.grip_definition_reviewed = True
        p.component_model_signature = f.assembly.model_sha256.lower() if f.assembly is not None else None
        p.component_layout_id = LibraryFixtureGeometry.layout_id(f.assembly) if f.assembly is not None else None
        f.planning = p
        f.height = mechanism.height
        return f
