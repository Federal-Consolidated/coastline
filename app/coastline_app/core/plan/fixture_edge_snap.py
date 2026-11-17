"""Magnetic alignment of fixture pieces to the stock: an editing aid that aligns model faces and
edges; it does not certify a grip or clearance. Port of Plan/FixtureEdgeSnap.swift."""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from ..geometry import swift_round


@dataclass
class Face:
    id: str
    axis: int
    min: np.ndarray
    max: np.ndarray
    area: float
    is_bounds: bool


@dataclass(frozen=True)
class Constraint:
    component_id: str
    face_id: str
    axis: int
    upper: bool

    @property
    def label(self) -> str:
        return {(0, False): "Stock bottom edge", (0, True): "Stock top edge", (1, False): "Stock left end",
                (1, True): "Stock right end", (2, False): "Stock back edge"}.get((self.axis, self.upper), "Stock front edge")


@dataclass
class SnapResult:
    profile: object
    constraints: list[Constraint]


def faces(mesh) -> list[Face]:
    """Flat faces of a piece, precomputed once so dragging never traverses the CAD triangles."""
    v, idx = mesh.vertices, mesh.indices
    if len(idx) % 3 or (len(idx) and int(idx.max()) >= len(v)):
        return []
    tri = v.astype(float)[idx.reshape(-1, 3)] if len(idx) else np.zeros((0, 3, 3))
    buckets: dict[str, list] = {}
    if len(tri):
        finite = np.all(np.isfinite(tri) & (np.abs(tri) < 10_000_000), axis=(1, 2))
        lo, hi = tri.min(axis=1), tri.max(axis=1)
        area = np.linalg.norm(np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0]), axis=1) / 2
        for t in np.nonzero(finite & (area > 1e-6))[0]:
            for axis in range(3):
                if hi[t, axis] - lo[t, axis] < 1e-4:
                    key = f"{axis}:{int(swift_round((lo[t, axis] + hi[t, axis]) * 5000))}"
                    b = buckets.get(key)
                    if b is None:
                        buckets[key] = [axis, lo[t].copy(), hi[t].copy(), float(area[t])]
                    else:
                        b[1] = np.minimum(b[1], lo[t])
                        b[2] = np.maximum(b[2], hi[t])
                        b[3] += float(area[t])
    result = [Face(k, b[0], b[1], b[2], b[3], False) for k, b in sorted(buckets.items()) if b[3] >= 0.5]
    lo = mesh.bounds_min.array
    hi = mesh.bounds_max.array
    if np.all(np.isfinite(lo)) and np.all(np.isfinite(hi)):
        for axis in range(3):
            if any(f.axis == axis for f in result):
                continue
            for upper in (False, True):
                a, b = lo.copy(), hi.copy()
                a[axis] = hi[axis] if upper else lo[axis]
                b[axis] = a[axis]
                result.append(Face(f"bounds:{axis}:{'true' if upper else 'false'}", axis, a, b, 0.0, True))
    return result


def snap(profile, geometry, component_id: str | None, stock, tolerance, axes: set[int] = frozenset({0, 1, 2}),
         previous: list[Constraint] = ()) -> SnapResult:
    result = SnapResult(profile, [])
    stock = np.asarray(stock, float)
    tolerance = np.asarray(tolerance, float)
    if not (all(math.isfinite(v) and 0 < v <= 10_000 for v in stock) and all(math.isfinite(v) and 0 <= v < 1000 for v in tolerance)):
        return result
    stock_min = np.array([-stock[0] / 2, -stock[1] / 2, -stock[2]])
    stock_max = np.array([stock[0] / 2, stock[1] / 2, 0.0])
    candidates: dict[int, list] = {}
    for component in geometry.components:
        if component_id is not None and component.id != component_id:
            continue
        t = geometry.transform(component, profile)
        for face in component.snap_faces:
            direction = t[:3, face.axis]
            d = np.abs(direction)
            axis = int(np.argmax(d))
            if not (d[axis] > 0.999 and axis in axes and tolerance[axis] > 0):
                continue
            corners = np.array([[face.max[0] if c & 1 else face.min[0], face.max[1] if c & 2 else face.min[1],
                                 face.max[2] if c & 4 else face.min[2], 1.0] for c in range(8)])
            pts = (t @ corners.T).T[:, :3]
            lo, hi = pts.min(axis=0), pts.max(axis=0)
            if not (np.all(np.isfinite(lo)) and np.all(np.isfinite(hi))):
                continue
            if not all(hi[o] >= stock_min[o] - max(tolerance[o], 1e-4) and lo[o] <= stock_max[o] + max(tolerance[o], 1e-4)
                       for o in range(3) if o != axis):
                continue
            coordinate = (lo[axis] + hi[axis]) / 2
            for upper in (False, True):
                delta = (stock_max[axis] if upper else stock_min[axis]) - coordinate
                constraint = Constraint(component.id, face.id, axis, upper)
                latched = constraint in previous
                if abs(delta) > tolerance[axis] * (1.6 if latched else 1):
                    continue
                candidates.setdefault(axis, []).append((constraint, delta, face.area, face.is_bounds))
    correction = np.zeros(3)
    for axis in range(3):
        items = candidates.get(axis)
        if not items:
            continue
        best = items[0]
        for c in items[1:]:
            if _before(c, best, previous):
                best = c
        correction[axis] = best[1]
        result.constraints.append(best[0])
    if float(np.linalg.norm(correction)) > 1e-9:
        result.profile = geometry.moved(profile, component_id, correction)
    return result


def _before(a, b, previous) -> bool:
    al, bl = a[0] in previous, b[0] in previous
    if al != bl:
        return al
    if abs(abs(a[1]) - abs(b[1])) > 1e-5:
        return abs(a[1]) < abs(b[1])
    if a[3] != b[3]:
        return not a[3]
    if a[2] != b[2]:
        return a[2] > b[2]
    if a[0].component_id != b[0].component_id:
        return a[0].component_id < b[0].component_id
    return a[0].face_id < b[0].face_id
