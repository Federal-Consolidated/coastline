"""Points, axes and ranges in millimetres (Swift: RealTimeStatus.swift's Point3/Axis, ClosedRange)."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class LengthUnit(Enum):
    MILLIMETERS = "mm"
    INCHES = "in"


class Axis(Enum):
    X = "X"
    Y = "Y"
    Z = "Z"

    @staticmethod
    def from_letter(letter: str) -> "Axis | None":
        """`GetAxisValue(point, char)`: accepts upper or lower case."""
        return {"x": Axis.X, "y": Axis.Y, "z": Axis.Z}.get(letter.lower()) if len(letter) == 1 else None


AXES = (Axis.X, Axis.Y, Axis.Z)


@dataclass(frozen=True)
class Point3:
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0

    def __add__(self, o: "Point3") -> "Point3":
        return Point3(self.x + o.x, self.y + o.y, self.z + o.z)

    def __sub__(self, o: "Point3") -> "Point3":
        return Point3(self.x - o.x, self.y - o.y, self.z - o.z)

    def __getitem__(self, axis: Axis) -> float:
        return {Axis.X: self.x, Axis.Y: self.y, Axis.Z: self.z}[axis]

    def replacing(self, axis: Axis, value: float) -> "Point3":
        return Point3(value if axis is Axis.X else self.x, value if axis is Axis.Y else self.y,
                      value if axis is Axis.Z else self.z)

    def __str__(self) -> str:
        return f"({self.x}, {self.y}, {self.z})"


Point3.ZERO = Point3()  # type: ignore[attr-defined]


@dataclass(frozen=True)
class Range:
    """A closed range lower…upper."""

    lower: float
    upper: float

    def __contains__(self, v: float) -> bool:
        return self.lower <= v <= self.upper

    def clamp(self, v: float) -> float:
        return min(max(v, self.lower), self.upper)
