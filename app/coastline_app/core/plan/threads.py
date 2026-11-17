"""ISO metric coarse threads and thread milling settings. Port of Plan/Threads.swift. A milled
internal thread goes into a hole made at the tap-drill size (major − pitch); the cutter's centre
runs on a helix of radius (major − cutter) / 2, rising one pitch a turn."""

from __future__ import annotations

from dataclasses import dataclass

from ..codable import Range
from ..geometry import swift_round
from ..units import format_number


@dataclass(frozen=True)
class ThreadSpec:
    name: str
    major: float  # nominal (major) diameter, mm
    pitch: float  # mm per turn

    @property
    def id(self) -> str:
        return self.name

    @property
    def tap_drill(self) -> float:
        """The hole to make first: the usual tap drill, major − pitch."""
        return swift_round((self.major - self.pitch) * 100) / 100

    @property
    def minor(self) -> float:
        """The basic minor diameter of the nut thread (D1 = D − 1.0825 P)."""
        return self.major - 1.082532 * self.pitch

    @property
    def profile_depth(self) -> float:
        return (self.major - self.tap_drill) / 2

    @property
    def title(self) -> str:
        return f"{self.name} × {format_number(self.pitch, 2, 1)}"

    @property
    def hole_range(self) -> Range:
        return Range(self.minor - 0.05, self.tap_drill + 0.08)

    def fits(self, hole: float) -> bool:
        return hole in self.hole_range

    def can_be_cut(self, tool) -> bool:
        """A single-form cutter smaller than the hole, with a profile for this pitch (or any)."""
        from ..inventory.items import ToolKind
        return (tool.kind is ToolKind.THREAD_MILL and tool.diameter < self.tap_drill - 0.05 and tool.diameter < self.major
                and (tool.thread_pitch is None or abs(tool.thread_pitch - self.pitch) < 0.01))

    @staticmethod
    def named(name: str) -> "ThreadSpec | None":
        return next((t for t in METRIC_COARSE if t.name == name), None)

    @staticmethod
    def likely(hole: float) -> "ThreadSpec | None":
        """The thread a hole of this diameter was most likely made for."""
        fits = [t for t in METRIC_COARSE if t.fits(hole)]
        return min(fits, key=lambda t: abs(t.tap_drill - hole)) if fits else None


METRIC_COARSE = [ThreadSpec("M1.6", 1.6, 0.35), ThreadSpec("M2", 2, 0.4), ThreadSpec("M2.5", 2.5, 0.45),
                 ThreadSpec("M3", 3, 0.5), ThreadSpec("M4", 4, 0.7), ThreadSpec("M5", 5, 0.8),
                 ThreadSpec("M6", 6, 1.0), ThreadSpec("M8", 8, 1.25)]


@dataclass
class ThreadMilling:
    """Which thread, and how deep (None: the hole's full depth, as far as the cutter reaches)."""

    spec: str
    depth: float | None = None

    @property
    def thread(self) -> ThreadSpec | None:
        return ThreadSpec.named(self.spec)
