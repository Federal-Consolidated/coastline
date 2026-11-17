"""Everything Coastline knows about a machine. Port of Machine/MachineProfile.swift.

Values are the hard limits that the planner, the post-processor and the safety validator use.
The standard profile is data/machine_profile_standard.json (exported from the Swift app)."""

from __future__ import annotations

import re
from dataclasses import dataclass, replace
from functools import lru_cache

import numpy as np

from .. import codable, data
from ..codable import Range, jfield
from ..geometry import AxisBox, Vec3


@dataclass(frozen=True)
class MachineProfile:
    name: str
    travel: Vec3  # $130–$132
    machine_envelope: AxisBox  # reachable machine coordinates
    max_rate: Vec3  # mm/min, $110–$112
    acceleration: Vec3  # mm/s², $120–$122
    junction_deviation: float  # $11
    arc_tolerance: float  # $12
    spindle_rpm: Range  # the RPM that actually turns the spindle
    spindle_ramp_intermediate_rpm: float
    estimated_spindle_power: float  # W, estimated
    collet_name: str
    max_shank_diameter: float
    max_tool_length: float
    collet_seat_depth: float
    tool_change_moves: list[str]
    max_line_length: int
    planner_blocks: int
    power_on_distance_mode_is_incremental: bool
    edge_finder_tip_diameter: float
    probe_feed: float
    probe_spindle_rpm: float
    t_slot_count: int
    t_slot_nut: str
    physical_envelope: Vec3
    home_position: Vec3 | None = None  # controller position after homing

    def __hash__(self) -> int:
        return hash(self.name)

    @staticmethod
    def standard() -> "MachineProfile":
        return _standard()

    @property
    def max_feed_any_direction(self) -> float:
        """The slowest axis limit: a safe single cap for 3D moves whose direction varies."""
        return min(self.max_rate.x, self.max_rate.y, self.max_rate.z)

    def is_usable_rpm(self, rpm: float) -> bool:
        return rpm in self.spindle_rpm

    @property
    def tool_change_waypoints(self) -> list[np.ndarray]:
        """The machine positions the tool-change moves pass through, in order, from home."""
        e = self.machine_envelope
        position = self.home_position or Vec3(e.x.upper, e.y.upper, e.z.upper)
        p = position.array.copy()
        out = []
        for line in self.tool_change_moves:
            upper = line.upper()
            if "G53" not in upper:
                continue
            for k, axis in enumerate("XYZ"):
                m = re.search(axis + r"(-?[0-9.]+)", upper)
                if m:
                    try:
                        p[k] = float(m.group(1))
                    except ValueError:
                        pass
            out.append(p.copy())
        return out

    @property
    def tool_change_pose(self) -> np.ndarray:
        """Where the tool is changed: the table down, the spindle out (the last waypoint)."""
        w = self.tool_change_waypoints
        return w[-1] if w else np.array([-1.0, -58.0, -60.0])

    def replacing(self, **changes) -> "MachineProfile":
        return replace(self, **changes)

    def to_json(self) -> dict:
        return _to_json(self)

    @staticmethod
    def from_json(d) -> "MachineProfile":
        return codable.decode_dataclass(MachineProfile, d)


def _to_json(p: MachineProfile) -> dict:
    import dataclasses
    out = {}
    for f in dataclasses.fields(p):
        v = getattr(p, f.name)
        if v is not None:
            out[codable.camel(f.name)] = codable.to_json(v)
    return out


@lru_cache(maxsize=1)
def _standard() -> MachineProfile:
    return MachineProfile.from_json(data.load("machine_profile_standard.json"))
