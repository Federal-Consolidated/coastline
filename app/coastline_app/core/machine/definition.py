"""Portable authored machine data. Loading a definition never selects it for machine control.
Geometry and frame origins are in CAD-world millimetres at model-axis position zero.
Port of Machine/MachineDefinition.swift."""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from enum import Enum
from pathlib import PurePosixPath

from ..codable import Range
from ..geometry import AxisBox, Vec3
from .profile import MachineProfile

FLOAT_MAX = 3.4028234663852886e38
# Renderer arithmetic uses Float, including squared distances: headroom for transforms.
MAXIMUM_COORDINATE_MAGNITUDE = math.sqrt(FLOAT_MAX) / 1024


class MachineDefinitionError(Exception):
    pass


class MachineVerification(Enum):
    DRAFT = "draft"
    DIGITAL = "digital"
    HARDWARE = "hardware"


class MachineCoordinate(Enum):
    X = "x"
    Y = "y"
    Z = "z"

    @property
    def index(self) -> int:
        return "xyz".index(self.value)


class MachineComponentRole(Enum):
    STATIC = "static"
    LINEAR_AXIS = "linearAxis"
    TABLE = "table"
    HEAD = "head"


class MachineAssetRole(Enum):
    GEOMETRY = "geometry"
    FUSION_DEFINITION = "fusionDefinition"
    FUSION_ARCHIVE = "fusionArchive"
    REFERENCE = "reference"


class MachineEvidenceStatus(Enum):
    SOURCE = "source"
    INFERRED = "inferred"
    MEASURED = "measured"
    VERIFIED = "verified"
    UNRESOLVED = "unresolved"


class MachineFindingSeverity(Enum):
    BLOCKING = "blocking"
    WARNING = "warning"
    INFORMATION = "information"


class MachineValidationScope(Enum):
    GEOMETRY = "geometry"
    KINEMATICS = "kinematics"
    SETUP_PLACEMENT = "setupPlacement"
    TOOLING = "tooling"
    CONTROLLER = "controller"
    HARDWARE = "hardware"


class MachineValidationStatus(Enum):
    PASSED = "passed"
    PENDING = "pending"
    FAILED = "failed"


@dataclass
class MachineValidationCheck:
    id: str
    title: str
    scope: MachineValidationScope
    status: MachineValidationStatus
    detail: str
    source_ids: list[str]
    action: str | None = None


@dataclass
class MachineReferenceStock:
    """A digital setup specimen, not the stock selected for a machining job."""

    id: str
    name: str
    frame_id: str
    size: Vec3  # local frame X length, Y width, Z height
    minimum: Vec3 = Vec3.ZERO


@dataclass
class MachineLinearAxis:
    coordinate: MachineCoordinate
    direction: Vec3  # world direction at the reference pose
    model_minimum: float
    model_maximum: float
    model_home: float
    controller_scale: float
    controller_offset: float

    def model_position(self, controller_position: float) -> float:
        return self.controller_scale * controller_position + self.controller_offset

    @property
    def controller_home(self) -> float:
        return (self.model_home - self.controller_offset) / self.controller_scale

    @property
    def controller_range(self) -> Range:
        a = (self.model_minimum - self.controller_offset) / self.controller_scale
        b = (self.model_maximum - self.controller_offset) / self.controller_scale
        return Range(min(a, b), max(a, b))


@dataclass
class MachineComponent:
    id: str
    role: MachineComponentRole
    model_entities: list[str]  # STEP occurrence index paths; the most specific ancestor owns a body
    parent_id: str | None = None
    axis: MachineLinearAxis | None = None
    is_enclosure: bool | None = None  # presentation only


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)


def _dot(a: Vec3, b: Vec3) -> float:
    return a.x * b.x + a.y * b.y + a.z * b.z


def _is_unit(v: Vec3) -> bool:
    return v.is_finite and abs(_dot(v, v) - 1) < 0.000001


def _fits(v: Vec3, multiplier: float = 1) -> bool:
    limit = MAXIMUM_COORDINATE_MAGNITUDE * multiplier
    return v.is_finite and abs(v.x) <= limit and abs(v.y) <= limit and abs(v.z) <= limit


@dataclass
class MachineFrame:
    id: str
    component_id: str
    origin: Vec3
    x_direction: Vec3
    z_direction: Vec3

    @property
    def y_direction(self) -> Vec3:
        return _cross(self.z_direction, self.x_direction)


@dataclass
class MachineMountingSlot:
    id: str
    origin: Vec3  # in the named mounting frame, mm
    direction: Vec3
    length: float
    opening_width: float
    cavity_width: float
    cavity_depth: float
    lip_thickness: float


@dataclass
class MachineMountingInterface:
    id: str
    frame_id: str
    kind: str
    slots: list[MachineMountingSlot]


@dataclass
class MachineAsset:
    path: str
    role: MachineAssetRole
    sha256: str


@dataclass
class MachineSource:
    id: str
    title: str
    path: str | None = None  # a declared package asset


@dataclass
class MachineEvidence:
    topic: str
    status: MachineEvidenceStatus
    source_ids: list[str]
    detail: str


@dataclass
class MachineFinding:
    id: str
    severity: MachineFindingSeverity
    summary: str
    detail: str


@dataclass(frozen=True)
class MachineDefinitionReference:
    id: str
    revision: int


@dataclass
class MachineDefinition:
    schema_version: int
    id: str
    revision: int
    name: str
    units: str
    process: str
    controller: str
    verification: MachineVerification
    profile: MachineProfile
    assets: list[MachineAsset]
    components: list[MachineComponent]
    frames: list[MachineFrame]
    mounting_interfaces: list[MachineMountingInterface]
    sources: list[MachineSource]
    evidence: list[MachineEvidence]
    findings: list[MachineFinding]
    manufacturer: str | None = None
    post_processor_id: str | None = None  # explicit Coastline output adapter
    checks: list[MachineValidationCheck] | None = None  # optional in schema 1
    reference_stock: MachineReferenceStock | None = None

    @property
    def reference(self) -> MachineDefinitionReference:
        return MachineDefinitionReference(self.id, self.revision)

    @property
    def blocking_findings(self) -> list[MachineFinding]:
        return [f for f in self.findings if f.severity is MachineFindingSeverity.BLOCKING]

    @property
    def validation_checks(self) -> list[MachineValidationCheck]:
        return self.checks or []

    def validation_status(self, scope: MachineValidationScope) -> MachineValidationStatus:
        scoped = [c for c in self.validation_checks if c.scope is scope]
        if any(c.status is MachineValidationStatus.FAILED for c in scoped):
            return MachineValidationStatus.FAILED
        if scoped and all(c.status is MachineValidationStatus.PASSED for c in scoped):
            return MachineValidationStatus.PASSED
        return MachineValidationStatus.PENDING

    @property
    def supports_digital_setup(self) -> bool:
        return all(self.validation_status(s) is MachineValidationStatus.PASSED
                   for s in (MachineValidationScope.GEOMETRY, MachineValidationScope.KINEMATICS, MachineValidationScope.SETUP_PLACEMENT))

    @property
    def controller_home_position(self) -> Vec3:
        """From the axis homes and controller mappings, not envelope corners."""
        r = [0.0, 0.0, 0.0]
        for c in self.components:
            if c.axis is not None:
                r[c.axis.coordinate.index] = c.axis.controller_home
        return Vec3(*r)

    @property
    def controller_envelope(self) -> AxisBox:
        """Authored travel mapped into controller coordinates (not the live soft limits)."""
        ranges = {}
        for c in self.components:
            if c.axis is not None:
                ranges[c.axis.coordinate] = c.axis.controller_range
        zero = Range(0, 0)
        return AxisBox(ranges.get(MachineCoordinate.X, zero), ranges.get(MachineCoordinate.Y, zero), ranges.get(MachineCoordinate.Z, zero))

    def _component(self, cid: str) -> MachineComponent | None:
        return next((c for c in self.components if c.id == cid), None)

    def _frame(self, fid: str) -> MachineFrame | None:
        return next((f for f in self.frames if f.id == fid), None)

    def world_translation(self, component_id: str, controller_position: Vec3) -> Vec3:
        """Additive translations: a child inherits every moving ancestor (Z rides on Y)."""
        if not controller_position.is_finite:
            raise MachineDefinitionError("Machine position must be finite.")
        result, current, visited = Vec3.ZERO, component_id, set()
        while current is not None:
            component = self._component(current)
            if current in visited or component is None:
                raise MachineDefinitionError(f"Invalid machine component chain at '{current}'.")
            visited.add(current)
            if component.axis is not None:
                a = component.axis
                q = a.model_position(controller_position[a.coordinate.index])
                result = result + a.direction * q
                if not (math.isfinite(q) and _fits(result, 8)):
                    raise MachineDefinitionError("Machine motion exceeds the supported numeric range.")
            current = component.parent_id
        return result

    def world_origin(self, frame_id: str, controller_position: Vec3) -> Vec3:
        frame = self._frame(frame_id)
        if frame is None:
            raise MachineDefinitionError(f"Unknown machine frame '{frame_id}'.")
        result = frame.origin + self.world_translation(frame.component_id, controller_position)
        if not _fits(result, 8):
            raise MachineDefinitionError("Machine frame exceeds the supported numeric range.")
        return result

    def world_direction(self, local: Vec3, frame_id: str) -> Vec3:
        """A frame-local direction in CAD world axes (basis vectors, not controller axis letters)."""
        frame = self._frame(frame_id)
        if not _fits(local) or frame is None:
            raise MachineDefinitionError(f"Unknown frame or invalid local direction for '{frame_id}'.")
        result = frame.x_direction * local.x + frame.y_direction * local.y + frame.z_direction * local.z
        if not _fits(result, 8):
            raise MachineDefinitionError("Frame direction exceeds the supported numeric range.")
        return result

    def world_point(self, local: Vec3, frame_id: str, controller_position: Vec3 | None = None) -> Vec3:
        """A frame-local point in world mm. No position: the authored CAD pose q = 0."""
        frame = self._frame(frame_id)
        if frame is None:
            raise MachineDefinitionError(f"Unknown machine frame '{frame_id}'.")
        origin = self.world_origin(frame_id, controller_position) if controller_position is not None else frame.origin
        result = origin + self.world_direction(local, frame_id)
        if not _fits(result, 8):
            raise MachineDefinitionError("Frame point exceeds the supported numeric range.")
        return result

    def reference_stock_corners(self, controller_position: Vec3 | None = None) -> list[Vec3]:
        """Eight corners ordered by X/Y/Z bits in the reference specimen's local frame."""
        s = self.reference_stock
        if s is None:
            return []
        out = []
        for corner in range(8):
            p = Vec3(s.minimum.x + (0 if corner & 1 == 0 else s.size.x),
                     s.minimum.y + (0 if corner & 2 == 0 else s.size.y),
                     s.minimum.z + (0 if corner & 4 == 0 else s.size.z))
            out.append(self.world_point(p, s.frame_id, controller_position))
        return out

    # ------------------------------------------------------------ validation

    def validate(self) -> None:
        """Structural validation, separate from the authored verification claim and findings."""
        from ..post.grbl_post import ADAPTER_ID

        def require(condition: bool, message: str) -> None:
            if not condition:
                raise MachineDefinitionError(message)

        def unique(values: list[str], label: str) -> None:
            require(all(v.strip() for v in values) and len(set(values)) == len(values),
                    f"{label} must have unique, nonempty identifiers.")

        require(self.schema_version == 1, f"Unsupported machine profile schema {self.schema_version}; expected 1.")
        require(re.search(r"^[a-z0-9][a-z0-9._-]{0,79}$", self.id) is not None,
                "Machine ID must be a short lowercase identifier using letters, numbers, '.', '_' or '-'.")
        require(self.revision > 0, "Machine revision must be positive.")
        require(bool(self.name.strip()), "Machine name is required.")
        require(self.units == "mm", f"Unsupported machine units '{self.units}'; schema 1 uses millimetres.")
        require(self.process == "milling", f"Unsupported process '{self.process}'; this version supports three-axis milling.")
        require(self.controller == "grbl", f"Unsupported controller '{self.controller}'; this version supports GRBL profile review.")
        if self.post_processor_id is not None:
            require(self.post_processor_id == ADAPTER_ID, f"Unsupported Coastline post processor '{self.post_processor_id}'.")
        require(0 < len(self.components) <= 128, "Machine must have 1–128 components.")
        unique([c.id for c in self.components], "Components")
        unique([f.id for f in self.frames], "Frames")
        unique([m.id for m in self.mounting_interfaces], "Mounting interfaces")
        unique([s.id for s in self.sources], "Sources")
        unique([f.id for f in self.findings], "Findings")
        component_ids = {c.id for c in self.components}
        axes = [c.axis for c in self.components if c.axis is not None]
        require(len(axes) == 3 and {a.coordinate for a in axes} == set(MachineCoordinate),
                "A supported machine needs exactly one linear X, Y and Z axis.")
        require(sum(c.role is MachineComponentRole.TABLE for c in self.components) == 1
                and sum(c.role is MachineComponentRole.HEAD for c in self.components) == 1,
                "A supported machine needs one table and one head.")
        bindings: set[str] = set()
        for c in self.components:
            require(c.parent_id is None or c.parent_id in component_ids, f"Unknown parent of '{c.id}'.")
            require((c.role is MachineComponentRole.LINEAR_AXIS) == (c.axis is not None), "Only linear-axis components may define axis motion.")
            for b in c.model_entities:
                require(re.search(r"^(0|[1-9][0-9]*)(/(0|[1-9][0-9]*))*$", b) is not None,
                        f"Component '{c.id}' must bind STEP occurrence index paths.")
                require(b not in bindings, f"STEP occurrence '{b}' is assigned more than once.")
                bindings.add(b)
            a = c.axis
            if a is not None:
                name = a.coordinate.value.upper()
                require(_is_unit(a.direction), f"Axis {name} direction must be a finite unit vector.")
                values = [a.model_minimum, a.model_maximum, a.model_home, a.controller_scale, a.controller_offset]
                require(all(math.isfinite(v) for v in values), f"Axis {name} contains a non-finite value.")
                require(all(abs(v) <= MAXIMUM_COORDINATE_MAGNITUDE for v in [a.model_minimum, a.model_maximum, a.model_home, a.controller_offset]),
                        f"Axis {name} exceeds the supported preview numeric range.")
                require(a.model_minimum < a.model_maximum and a.model_minimum <= a.model_home <= a.model_maximum,
                        f"Axis {name} must have an ordered range containing home.")
                require(abs(abs(a.controller_scale) - 1) < 0.000001, "Axis controller scale must be +1 or −1; units are millimetres.")
            self.world_translation(c.id, Vec3.ZERO)  # rejects cycles, including static-only ones
        require(bool(bindings), "Machine components need explicit STEP occurrence bindings.")
        for i in range(len(axes)):
            for j in range(i + 1, len(axes)):
                require(abs(_dot(axes[i].direction, axes[j].direction)) < 0.000001,
                        "The supported three-axis machine requires orthogonal linear axes.")

        def ancestors(role: MachineComponentRole) -> set[str]:
            result: set[str] = set()
            current = next((c.id for c in self.components if c.role is role), None)
            while current is not None and current not in result:
                result.add(current)
                comp = self._component(current)
                current = comp.parent_id if comp is not None else None
            return result

        table_chain, head_chain = ancestors(MachineComponentRole.TABLE), ancestors(MachineComponentRole.HEAD)
        for c in self.components:
            if c.axis is not None:
                require((c.id in table_chain) != (c.id in head_chain),
                        f"Axis '{c.id}' must move either the table or head; shared or disconnected motion is unsupported.")
        for f in self.frames:
            require(f.component_id in component_ids, f"Frame '{f.id}' references an unknown component.")
            require(f.origin.is_finite and _is_unit(f.x_direction) and _is_unit(f.z_direction)
                    and abs(_dot(f.x_direction, f.z_direction)) < 0.000001,
                    f"Frame '{f.id}' needs a finite origin and orthogonal unit directions.")
            require(_fits(f.origin), f"Frame '{f.id}' exceeds the supported preview numeric range.")

        def frame_on(role) -> bool:
            return any(any(c.id == f.component_id and c.role is role for c in self.components) for f in self.frames)

        require(frame_on(MachineComponentRole.TABLE) and frame_on(MachineComponentRole.HEAD),
                "Machine needs reference frames on both the table and head.")
        frame_ids = {f.id for f in self.frames}
        for m in self.mounting_interfaces:
            require(m.frame_id in frame_ids, f"Mount '{m.id}' references an unknown frame.")
            require(m.kind == "tSlots", f"Unsupported mounting interface '{m.kind}'.")
            require(0 < len(m.slots) <= 64, "T-slot interface needs 1–64 slots.")
            unique([s.id for s in m.slots], f"Slots in '{m.id}'")
            for s in m.slots:
                require(s.origin.is_finite and _is_unit(s.direction), f"Slot '{s.id}' needs a finite origin and unit direction.")
                require(_fits(s.origin), f"Slot '{s.id}' origin exceeds the supported preview numeric range.")
                dims = [s.length, s.opening_width, s.cavity_width, s.cavity_depth, s.lip_thickness]
                require(all(math.isfinite(v) and v > 0 for v in dims), f"Slot '{s.id}' dimensions must be finite and positive.")
                require(all(v <= MAXIMUM_COORDINATE_MAGNITUDE for v in dims), f"Slot '{s.id}' dimensions exceed the supported preview numeric range.")
                require(s.opening_width < s.cavity_width, f"Slot '{s.id}' cavity must be wider than its opening.")
        require(0 < len(self.assets) <= 32 and len({a.path for a in self.assets}) == len(self.assets),
                "Machine assets must have unique paths (maximum 32).")
        require(sum(a.role is MachineAssetRole.GEOMETRY for a in self.assets) == 1, "Machine package requires exactly one STEP geometry asset.")
        for a in self.assets:
            require(re.search(r"^[a-fA-F0-9]{64}$", a.sha256) is not None, f"Asset '{a.path}' needs a SHA-256 fingerprint.")
            if a.role is MachineAssetRole.GEOMETRY:
                require(PurePosixPath(a.path).suffix[1:].lower() in ("step", "stp"), "Machine geometry must be STEP.")
        source_ids, asset_paths = {s.id for s in self.sources}, {a.path for a in self.assets}
        for s in self.sources:
            require(s.path is None or s.path in asset_paths, f"Source '{s.id}' must reference a declared asset.")
        for e in self.evidence:
            require(bool(e.topic) and bool(e.detail) and all(i in source_ids for i in e.source_ids),
                    "Evidence must name its topic, detail and valid sources.")
        unique([c.id for c in self.validation_checks], "Validation checks")
        require(len(self.validation_checks) <= 64, "A profile may contain at most 64 validation checks.")
        for c in self.validation_checks:
            require(bool(c.title) and bool(c.detail) and bool(c.source_ids) and all(i in source_ids for i in c.source_ids),
                    "Validation checks need a title, result and valid evidence sources.")
            if c.status is not MachineValidationStatus.PASSED:
                require(bool((c.action or "").strip()), f"Unresolved validation check '{c.id}' needs a concrete next action.")
        s = self.reference_stock
        if s is not None:
            require(bool(s.id) and bool(s.name) and s.frame_id in frame_ids, "Reference stock needs a name, identifier and valid frame.")
            require(_fits(s.minimum) and _fits(s.size) and s.size.x > 0 and s.size.y > 0 and s.size.z > 0,
                    "Reference stock dimensions must be finite and positive.")
            frame = self._frame(s.frame_id)
            owner = self._component(frame.component_id)
            require(owner is not None and owner.role is MachineComponentRole.TABLE, "Reference stock must attach to the table's seating frame.")
            self.reference_stock_corners()
        p = self.profile
        require(p.travel.is_finite and p.max_rate.is_finite and p.acceleration.is_finite and p.physical_envelope.is_finite,
                "Machine capability vectors must be finite.")
        for k in range(3):
            require(p.travel[k] > 0 and p.max_rate[k] > 0 and p.acceleration[k] > 0 and p.physical_envelope[k] > 0,
                    "Travel, rates, acceleration and physical envelope must be positive.")
        env = p.machine_envelope
        require(all(math.isfinite(r.lower) and math.isfinite(r.upper) and r.lower < r.upper for r in (env.x, env.y, env.z)),
                "Machine control envelope must contain finite, ordered ranges.")
        require(p.home_position is not None and p.home_position.is_finite, "Machine profile needs an explicit controller home position.")
        home = self.controller_home_position
        hp = p.home_position
        require(abs(hp.x - home.x) < 0.0001 and abs(hp.y - home.y) < 0.0001 and abs(hp.z - home.z) < 0.0001,
                "Profile home does not match the kinematic axis homes and controller mapping.")
        require(env.contains(home), "Controller home must lie inside the declared control envelope.")
        authored = self.controller_envelope
        require(authored.contains((env.x.lower, env.y.lower, env.z.lower)) and authored.contains((env.x.upper, env.y.upper, env.z.upper)),
                "Control envelope exceeds the mapped authored axis travel.")
        rpm = p.spindle_rpm
        require(math.isfinite(rpm.lower) and math.isfinite(rpm.upper) and rpm.lower > 0 and rpm.lower <= rpm.upper,
                "Spindle usable RPM range must be finite and positive.")
        require(all(math.isfinite(v) and v >= 0 for v in [p.max_shank_diameter, p.max_tool_length, p.collet_seat_depth, p.probe_feed,
                                                          p.probe_spindle_rpm, p.edge_finder_tip_diameter, p.junction_deviation,
                                                          p.arc_tolerance, p.estimated_spindle_power, p.spindle_ramp_intermediate_rpm]),
                "Machine capability values must be finite and nonnegative.")
        require(p.max_shank_diameter > 0 and p.max_tool_length > 0 and p.max_line_length > 0 and p.planner_blocks > 0 and p.t_slot_count >= 0,
                "Tool and controller limits must be positive.")
