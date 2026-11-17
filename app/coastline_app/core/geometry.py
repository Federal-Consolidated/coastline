"""Points, vectors and boxes in millimetres (Swift: `Vec3`, `AxisBox`, simd helpers).

`Vec3` is the saved value type ({"x","y","z"} in JSON). Algorithms use numpy arrays for
SIMD3/simd matrices: matrices keep simd's meaning, `M[:, k]` is column k and `M @ v` is `M * v`.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from .codable import Range


@dataclass(frozen=True)
class Vec3:
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0

    def __add__(self, o: "Vec3") -> "Vec3":
        return Vec3(self.x + o.x, self.y + o.y, self.z + o.z)

    def __sub__(self, o: "Vec3") -> "Vec3":
        return Vec3(self.x - o.x, self.y - o.y, self.z - o.z)

    def __mul__(self, k: float) -> "Vec3":
        return Vec3(self.x * k, self.y * k, self.z * k)

    __rmul__ = __mul__

    def __truediv__(self, k: float) -> "Vec3":
        return Vec3(self.x / k, self.y / k, self.z / k)

    def __neg__(self) -> "Vec3":
        return Vec3(-self.x, -self.y, -self.z)

    def __getitem__(self, i: int) -> float:
        return (self.x, self.y, self.z)[i]

    def __iter__(self):
        return iter((self.x, self.y, self.z))

    def __str__(self) -> str:
        return f"({_swift(self.x)}, {_swift(self.y)}, {_swift(self.z)})"

    @property
    def array(self) -> np.ndarray:
        return np.array([self.x, self.y, self.z], float)

    @staticmethod
    def of(v) -> "Vec3":
        return Vec3(float(v[0]), float(v[1]), float(v[2]))

    def replacing(self, axis: int, value: float) -> "Vec3":
        v = [self.x, self.y, self.z]
        v[axis] = value
        return Vec3(*v)

    @property
    def length(self) -> float:
        return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z)

    @property
    def is_finite(self) -> bool:
        return all(math.isfinite(v) for v in (self.x, self.y, self.z))

    def to_json(self) -> dict:
        return {"x": self.x, "y": self.y, "z": self.z}

    @staticmethod
    def from_json(d) -> "Vec3":
        return Vec3(float(d["x"]), float(d["y"]), float(d["z"]))


Vec3.ZERO = Vec3()  # type: ignore[attr-defined]


def _swift(v: float) -> str:
    """Swift's `Double.description`: `1.0`, `0.1`, `1e-07`."""
    v = float(v)
    if math.isfinite(v) and v.is_integer() and abs(v) < 1e16:
        return f"{v:.1f}"
    return repr(v)


@dataclass(frozen=True)
class AxisBox:
    """An inclusive range per axis, in machine coordinates (mm)."""

    x: Range
    y: Range
    z: Range

    def contains(self, p, margin: float = 0.0) -> bool:
        px, py, pz = p[0], p[1], p[2]
        return (self.x.lower + margin <= px <= self.x.upper - margin
                and self.y.lower + margin <= py <= self.y.upper - margin
                and self.z.lower + margin <= pz <= self.z.upper - margin)

    def axis(self, k: int) -> Range:
        return (self.x, self.y, self.z)[k]


# ---------------------------------------------------------------- simd helpers

def vec(x, y=None, z=None) -> np.ndarray:
    if y is None:
        return np.asarray(x, float).reshape(3)
    return np.array([x, y, z], float)


def length(v) -> float:
    return float(math.sqrt(float(np.dot(v, v))))


def distance(a, b) -> float:
    return length(np.asarray(a, float) - np.asarray(b, float))


def normalize(v) -> np.ndarray:
    v = np.asarray(v, float)
    n = length(v)
    return v / n if n > 0 else v * np.nan


def dot(a, b) -> float:
    return float(np.dot(a, b))


def cross(a, b) -> np.ndarray:
    return np.cross(np.asarray(a, float), np.asarray(b, float))


def columns(*cols) -> np.ndarray:
    """simd_doubleNxN(columns: …)"""
    return np.column_stack([np.asarray(c, float) for c in cols])


def identity3() -> np.ndarray:
    return np.identity(3)


def transform_point(m: np.ndarray, p) -> np.ndarray:
    """(m * SIMD4(p, 1)).xyz"""
    p = np.asarray(p, float)
    return (m @ np.array([p[0], p[1], p[2], 1.0]))[:3]


def transform_vector(m: np.ndarray, v) -> np.ndarray:
    v = np.asarray(v, float)
    return (m @ np.array([v[0], v[1], v[2], 0.0]))[:3]


def affine(rotation: np.ndarray, translation) -> np.ndarray:
    m = np.identity(4)
    m[:3, :3] = rotation
    m[:3, 3] = np.asarray(translation, float)
    return m


def swift_round(v: float) -> float:
    """Swift `.rounded()`: half away from zero."""
    return math.floor(v + 0.5) if v >= 0 else -math.floor(-v + 0.5)
