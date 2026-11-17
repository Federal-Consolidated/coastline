"""The immutable machine assignment of a planning job. Asset fingerprints travel with the
definition; local file paths and permission to operate hardware do not.
Port of Machine/PlanningMachineReference.swift."""

from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass
from enum import Enum

from .. import codable
from .definition import MachineDefinition, MachineDefinitionError, MachineDefinitionReference
from .profile import MachineProfile


class Kind(Enum):
    LEGACY = "legacy"
    PROFILE = "profile"


@dataclass(frozen=True)
class PlanningMachineReference:
    kind: Kind
    definition: MachineDefinition | None = None
    legacy_profile: MachineProfile | None = None

    @staticmethod
    def legacy() -> "PlanningMachineReference":
        """Projects written before machine selection existed keep these values."""
        return PlanningMachineReference(Kind.LEGACY, None, MachineProfile.standard())

    @staticmethod
    def of(definition: MachineDefinition) -> "PlanningMachineReference":
        definition.validate()
        return PlanningMachineReference(Kind.PROFILE, definition, None)

    @property
    def is_legacy(self) -> bool:
        return self.kind is Kind.LEGACY

    @property
    def reference(self) -> MachineDefinitionReference:
        return self.definition.reference if self.definition is not None else MachineDefinitionReference("coastline.legacy-desktop", 1)

    @property
    def display_name(self) -> str:
        return self.definition.name if self.definition is not None else "Legacy Desktop CNC"

    @property
    def profile(self) -> MachineProfile:
        return self.definition.profile if self.definition is not None else self.legacy_profile

    def resolve(self, packages: list) -> object | None:
        """The installed package with exactly this definition. None: the legacy machine."""
        d = self.definition
        if d is None:
            return None
        candidates = [p for p in packages if p.definition.reference == self.reference]
        if not candidates:
            raise MachineDefinitionError(f"This job needs {d.name} revision {d.revision}. Install its original machine profile package to open the job; a different machine will not be substituted.")
        if not all(p.definition == d for p in candidates):
            raise MachineDefinitionError(f"{d.name} revision {d.revision} differs from the profile saved with this job. Restore the original package, or deliberately change the job's machine and regenerate its toolpaths.")
        return candidates[0]

    def fingerprint(self) -> str:
        """Stable identity for planning and caches, including limits and asset hashes."""
        return hashlib.sha256(codable.encode(self, pretty=False, sort_keys=True, escape_slashes=False)).hexdigest()

    def to_json(self) -> dict:
        out = {"kind": self.kind.value}
        if self.definition is not None:
            out["definition"] = codable.to_json(self.definition)
        if self.legacy_profile is not None:
            out["legacyProfile"] = codable.to_json(self.legacy_profile)
        return out

    @staticmethod
    def from_json(d) -> "PlanningMachineReference":
        kind = Kind(d["kind"])
        definition = codable.from_json(MachineDefinition, d["definition"]) if d.get("definition") is not None else None
        legacy = codable.from_json(MachineProfile, d["legacyProfile"]) if d.get("legacyProfile") is not None else None
        if kind is Kind.PROFILE:
            if definition is None or legacy is not None:
                raise MachineDefinitionError("A job's machine profile must contain exactly one definition snapshot.")
            definition.validate()
        else:
            if definition is not None or legacy is None:
                raise MachineDefinitionError("A legacy job must retain its original machine limits.")
            _validate_legacy(legacy)
        return PlanningMachineReference(kind, definition, legacy)


def _validate_legacy(p: MachineProfile) -> None:
    vectors = [p.travel, p.max_rate, p.acceleration, p.physical_envelope]
    ranges = [p.machine_envelope.x, p.machine_envelope.y, p.machine_envelope.z]
    nonnegative = [p.junction_deviation, p.arc_tolerance, p.estimated_spindle_power, p.spindle_ramp_intermediate_rpm,
                   p.collet_seat_depth, p.probe_feed, p.probe_spindle_rpm, p.edge_finder_tip_diameter]
    ok = (bool(p.name)
          and all(v.is_finite and v.x > 0 and v.y > 0 and v.z > 0 for v in vectors)
          and all(math.isfinite(r.lower) and math.isfinite(r.upper) and r.lower < r.upper for r in ranges)
          and math.isfinite(p.spindle_rpm.lower) and math.isfinite(p.spindle_rpm.upper)
          and 0 < p.spindle_rpm.lower <= p.spindle_rpm.upper
          and math.isfinite(p.max_shank_diameter) and p.max_shank_diameter > 0
          and math.isfinite(p.max_tool_length) and p.max_tool_length > 0
          and all(math.isfinite(v) and v >= 0 for v in nonnegative)
          and p.max_line_length > 0 and p.planner_blocks > 0 and p.t_slot_count >= 0
          and (p.home_position is None or (p.home_position.is_finite and p.machine_envelope.contains(p.home_position))))
    if not ok:
        raise MachineDefinitionError("The saved legacy machine limits are invalid.")
