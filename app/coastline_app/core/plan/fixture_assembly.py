"""An audited mechanical assembly. Port of Plan/FixtureAssemblyDefinition.swift. Entity paths
are bound to one exact STEP asset; proximity and display names never determine which hardware
moves together."""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from enum import Enum

from .. import codable
from ..codable import jfield
from ..geometry import Vec3


class Role(Enum):
    PHYSICAL = "physical"
    REFERENCE = "reference"


class JointKind(Enum):
    PRISMATIC = "prismatic"
    REVOLUTE = "revolute"
    SCREW = "screw"


@dataclass(frozen=True)
class Joint:
    id: str
    kind: JointKind
    axis: Vec3  # in the assembly's authored reference coordinates
    minimum: float  # linear and screw values are mm; revolute values are radians
    maximum: float
    origin: Vec3 = Vec3()
    reference_value: float = 0.0
    pitch: float | None = None  # positive lead, mm/revolution (screw joints)


@dataclass(frozen=True)
class Component:
    id: str
    name: str
    model_entities: list[str]  # exact zero-based STEP occurrence paths, e.g. 0/3/4
    parent_id: str | None = jfield(None, key="parentID")
    role: Role = Role.PHYSICAL
    joint: Joint | None = None

    def __hash__(self) -> int:
        return hash(self.id)


class AssemblyError(Exception):
    def __init__(self, issues: list[str]) -> None:
        self.issues = issues
        super().__init__("\n".join(issues))


@dataclass
class FixtureAssemblyState:
    """Job-owned mechanical settings, not a claim that hardware has been physically tightened."""

    joint_values: dict[str, float] = field(default_factory=dict)
    mounted: bool = False
    locked_components: set[str] = field(default_factory=set)

    def value(self, joint: Joint) -> float:
        return self.joint_values.get(joint.id, joint.reference_value)

    def to_json(self) -> dict:
        return {"jointValues": dict(self.joint_values), "mounted": self.mounted,
                "lockedComponents": sorted(self.locked_components)}

    @staticmethod
    def from_json(d) -> "FixtureAssemblyState":
        return FixtureAssemblyState({k: float(v) for k, v in (d.get("jointValues") or {}).items()},
                                    bool(d.get("mounted", False)), set(d.get("lockedComponents") or []))


@dataclass
class FixtureAssemblyDefinition:
    id: str
    revision: int
    model_sha256: str = jfield(key="modelSHA256")
    components: list[Component] = field(default_factory=list)
    schema_version: int = 1
    bookends: BookendDefinition | None = None
    clamp_pair: ClampPairDefinition | None = None
    vise: ViseDefinition | None = None
    is_assembled: bool = True  # exploded/reference CAD may be previewed but not approved for machining

    reference_table_origin: Vec3 | None = None
    planning_limitation: str | None = None

    def __hash__(self) -> int:
        return hash((self.id, self.revision, self.model_sha256))

    @staticmethod
    def from_json(d) -> "FixtureAssemblyDefinition":
        if "schemaVersion" not in d:
            raise codable.DecodeError("FixtureAssemblyDefinition: missing key 'schemaVersion'")
        return FixtureAssemblyDefinition(
            id=d["id"], revision=int(d["revision"]), model_sha256=d["modelSHA256"],
            components=codable.from_json(list[Component], d["components"]), schema_version=int(d["schemaVersion"]),
            bookends=BookendDefinition.from_json(d["bookends"]) if d.get("bookends") is not None else None,
            clamp_pair=codable.from_json(ClampPairDefinition, d["clampPair"]) if d.get("clampPair") is not None else None,
            vise=codable.from_json(ViseDefinition, d["vise"]) if d.get("vise") is not None else None,
            is_assembled=bool(d.get("isAssembled", True)),
            planning_limitation=d.get("planningLimitation"),
            reference_table_origin=codable.from_json(Vec3, d["referenceTableOrigin"]) if d.get("referenceTableOrigin") is not None else None)

    def to_json(self) -> dict:
        out = {"schemaVersion": self.schema_version, "id": self.id, "revision": self.revision,
               "modelSHA256": self.model_sha256, "components": codable.to_json(self.components),
               "isAssembled": self.is_assembled}
        if self.planning_limitation is not None:
            out["planningLimitation"] = self.planning_limitation
        if self.reference_table_origin is not None:
            out["referenceTableOrigin"] = codable.to_json(self.reference_table_origin)
        if self.bookends is not None:
            out["bookends"] = self.bookends.to_json()
        if self.clamp_pair is not None:
            out["clampPair"] = codable.to_json(self.clamp_pair)
        if self.vise is not None:
            out["vise"] = codable.to_json(self.vise)
        return out

    @property
    def planning_issues(self) -> list[str]:
        if self.planning_limitation is not None:
            return [self.planning_limitation]
        return [] if self.is_assembled else [
            "This CAD is an exploded/reference view. An assembled fixture definition is required before planning cuts."]

    @property
    def validation_issues(self) -> list[str]:
        issues: list[str] = []
        if self.schema_version != 1:
            issues.append(f"Unsupported fixture assembly format {self.schema_version}.")
        if not self.id.strip() or self.revision < 1:
            issues.append("The assembly needs an ID and positive revision.")
        if not re.fullmatch(r"[0-9a-fA-F]{64}", self.model_sha256):
            issues.append("The assembly needs the exact CAD SHA-256.")
        if self.reference_table_origin is not None and not all(math.isfinite(v) and abs(v) <= 1e6 for v in self.reference_table_origin):
            issues.append("Invalid fixture table origin.")
        if not self.components or len(self.components) > 256:
            issues.append("The assembly must have 1–256 components.")
        ids = {c.id for c in self.components}
        if len(ids) != len(self.components) or "" in ids:
            issues.append("Component IDs must be unique and nonempty.")
        paths: set[str] = set()
        joints: set[str] = set()
        by_id = {}
        for c in self.components:
            by_id.setdefault(c.id, c)
        for c in self.components:
            if not c.name.strip():
                issues.append(f"Component {c.id} needs a name.")
            if c.parent_id is not None and (c.parent_id not in ids or c.parent_id == c.id):
                issues.append(f"Component {c.id} has an invalid parent.")
            ancestors, parent = {c.id}, c.parent_id
            while parent is not None:
                if parent in ancestors:
                    issues.append("The assembly component hierarchy has a cycle.")
                    break
                ancestors.add(parent)
                parent = by_id[parent].parent_id if parent in by_id else None
            if not c.model_entities and not any(o.parent_id == c.id for o in self.components):
                issues.append(f"Component {c.id} has no CAD bodies or children.")
            for path in c.model_entities:
                if not re.fullmatch(r"[0-9]+(/[0-9]+)*", path) or path in paths:
                    issues.append("CAD occurrence paths must be exact, unique indexed paths.")
                paths.add(path)
            j = c.joint
            if j is None:
                continue
            if not j.id or j.id in joints:
                issues.append("Joint IDs must be unique and nonempty.")
            joints.add(j.id)
            a = (j.axis.x, j.axis.y, j.axis.z)
            if not all(math.isfinite(v) for v in a) or abs(math.sqrt(sum(v * v for v in a)) - 1) > 1e-6:
                issues.append(f"Joint {j.id} needs a unit axis.")
            limits = (j.origin.x, j.origin.y, j.origin.z, j.minimum, j.maximum, j.reference_value)
            if (not all(math.isfinite(v) and abs(v) <= 1_000_000 for v in limits) or j.minimum > j.maximum
                    or j.reference_value < j.minimum or j.reference_value > j.maximum):
                issues.append(f"Joint {j.id} has invalid limits or reference position.")
            if j.kind is JointKind.SCREW:
                if not (j.pitch is not None and math.isfinite(j.pitch) and 0.000001 <= j.pitch <= 1_000):
                    issues.append(f"Screw joint {j.id} needs a finite pitch between 0.000001 and 1000 mm.")
            elif j.pitch is not None:
                issues.append("Only screw joints may have a pitch.")
        if not any(c.role is Role.PHYSICAL and c.model_entities for c in self.components):
            issues.append("The assembly has no physical fixture bodies.")
        for mech in (self.bookends, self.clamp_pair, self.vise):
            if mech is not None:
                issues += mech.validation_issues
        if sum(m is not None for m in (self.bookends, self.clamp_pair, self.vise)) > 1:
            issues.append("An assembly has one mechanism.")
        return sorted(set(issues))

    def state_issues(self, state: FixtureAssemblyState) -> list[str]:
        issues = self.validation_issues
        joints = [c.joint for c in self.components if c.joint is not None]
        for jid, value in state.joint_values.items():
            joint = next((j for j in joints if j.id == jid), None)
            if joint is None:
                issues.append(f"Unknown assembly joint {jid}.")
                continue
            if not math.isfinite(value) or value < joint.minimum or value > joint.maximum:
                issues.append(f"Joint {jid} must be within {_swift(joint.minimum)}…{_swift(joint.maximum)}.")
        physical = {c.id for c in self.components if c.role is Role.PHYSICAL}
        if not state.locked_components <= physical:
            issues.append("The assembly locks refer to unknown or reference components.")
        return issues

    def validate(self, state: FixtureAssemblyState | None = None) -> None:
        issues = self.state_issues(state or FixtureAssemblyState())
        if issues:
            raise AssemblyError(issues)


def _swift(v: float) -> str:
    return f"{v:.1f}" if float(v).is_integer() and abs(v) < 1e16 else repr(float(v))


@dataclass
class FixtureAssemblyPart:
    """One closed solid of one exact CAD occurrence."""

    component_id: str
    entity_path: str
    solid_index: int
    mesh: object  # engine MeshData


from .fixture_mechanism import BookendDefinition, ClampPairDefinition, ViseDefinition  # noqa: E402
