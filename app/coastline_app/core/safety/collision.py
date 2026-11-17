"""Collision engine for the objects on the bed: fixtures, the stock and the machine, as their real
triangle meshes. Port of Safety/Collision.swift (the tree and triangle tests are C++).

Touching isn't colliding: a pair of triangles only counts when each passes through the other's
plane by more than `tolerance` on both sides and their crossing segments overlap."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from ... import _kernels as K


class TriangleTree:
    """A bounding-volume tree over triangles (model coordinates), for collision queries."""

    def __init__(self, triangles) -> None:
        t = np.ascontiguousarray(np.asarray(triangles, float).reshape(-1, 3))
        self._t = K.TriangleTree(t)

    @property
    def triangle_count(self) -> int:
        return self._t.triangle_count

    @property
    def bounds(self):
        return self._t.bounds

    def intersect(self, other: "TriangleTree", tolerance: float):
        """(depth, point) where the two meshes pass through each other, or None."""
        return self._t.intersect(other._t, tolerance)

    def raycast(self, p, d) -> float | None:
        return self._t.raycast(float(p[0]), float(p[1]), float(p[2]), float(d[0]), float(d[1]), float(d[2]))

    def contains(self, p) -> bool:
        return self._t.contains(float(p[0]), float(p[1]), float(p[2]))

    def distance(self, p, below: float = float("inf")) -> float:
        return self._t.distance(float(p[0]), float(p[1]), float(p[2]), below)

    def touches(self, other: "TriangleTree", offset, tolerance: float = 0.05) -> bool:
        """Whether this mesh and `other` moved by `offset` pass through each other."""
        return self._t.touches(other._t, float(offset[0]), float(offset[1]), float(offset[2]), tolerance)


@dataclass
class Body:
    """One rigid object. Bodies with the same `group` are one assembly and aren't tested
    against each other."""

    name: str
    tree: TriangleTree
    group: str = ""

    def __post_init__(self) -> None:
        if not self.group:
            self.group = self.name

    @staticmethod
    def from_triangles(name: str, triangles, group: str | None = None) -> "Body":
        return Body(name, TriangleTree(triangles), group or name)

    @staticmethod
    def box(name: str, lo, hi, group: str | None = None) -> "Body":
        return Body.from_triangles(name, Collision.box_triangles(lo, hi), group)


@dataclass(frozen=True)
class Contact:
    a: str
    b: str
    depth: float  # how deep they go into each other, mm
    point: tuple[float, float, float]  # the deepest point found


class Collision:
    @staticmethod
    def check(bodies: list[Body], tolerance: float = 0.05, skip=lambda a, b: False) -> list[Contact]:
        """Every pair of bodies that share volume, deepest first."""
        out = []
        for i in range(len(bodies)):
            for j in range(i + 1, len(bodies)):
                a, b = bodies[i], bodies[j]
                if a.group == b.group or skip(a, b):
                    continue
                r = a.tree.intersect(b.tree, tolerance)
                if r is None:
                    continue
                out.append(Contact(a.name, b.name, r[0], tuple(r[1])))
        return sorted(out, key=lambda c: -c.depth)

    @staticmethod
    def box_triangles(a, b) -> np.ndarray:
        """The 12 triangles of a box (36 points), outward winding."""
        c = [np.array([b[0] if i & 1 else a[0], b[1] if i & 2 else a[1], b[2] if i & 4 else a[2]], float) for i in range(8)]
        faces = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
        return np.array([c[i] for f in faces for i in (f[0], f[1], f[2], f[0], f[2], f[3])])

    @staticmethod
    def triangles(a, b, tol: float):
        """Two triangles (3×3 each): the overlap segment (p, q) if they pass through each other."""
        return K.tri_tri(np.asarray(a, float), np.asarray(b, float), tol)
