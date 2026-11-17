"""Small matrix helpers shared by the workspace (Transforms.swift and simd idioms)."""

from __future__ import annotations

import numpy as np


def translation(t) -> np.ndarray:
    m = np.identity(4)
    m[:3, 3] = np.asarray(t, float)[:3]
    return m


def box_corners(lo, hi) -> np.ndarray:
    return np.array([[lo[0] if i & 1 == 0 else hi[0], lo[1] if i & 2 == 0 else hi[1], lo[2] if i & 4 == 0 else hi[2]] for i in range(8)], float)


def transform_points(m, pts) -> np.ndarray:
    p = np.asarray(pts, float).reshape(-1, 3)
    return p @ np.asarray(m, float)[:3, :3].T + np.asarray(m, float)[:3, 3]


def world_bounds(scene, mesh) -> tuple[np.ndarray, np.ndarray]:
    t = scene.group_transform(mesh.group) @ mesh.transform
    w = transform_points(t, box_corners(mesh.bounds_min, mesh.bounds_max))
    return w.min(0), w.max(0)


def srgb_to_linear(c) -> tuple[float, float, float]:
    return tuple(float(v) ** 2.2 for v in c)
