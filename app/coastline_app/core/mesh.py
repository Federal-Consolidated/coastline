"""An indexed triangle mesh in mm, as sent by the engine (Swift: MeshData in EngineClient.swift).
Vertices and normals are (n, 3) float32 arrays, indices a flat uint32 array (three per triangle)."""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .geometry import Vec3


@dataclass
class MeshData:
    vertices: np.ndarray
    normals: np.ndarray
    indices: np.ndarray
    bounds_min: Vec3
    bounds_max: Vec3
    exact: bool = False
    face_count: int = 0
    part_id: str = ""  # the engine's handle for exact queries; empty for non-part meshes
    warnings: list[str] = field(default_factory=list)

    @staticmethod
    def make(vertices, normals, indices, exact: bool = False, face_count: int = 0, part_id: str = "",
             warnings: list[str] | None = None) -> "MeshData":
        v = np.ascontiguousarray(np.asarray(vertices, np.float32).reshape(-1, 3))
        n = np.ascontiguousarray(np.asarray(normals, np.float32).reshape(-1, 3))
        i = np.ascontiguousarray(np.asarray(indices, np.uint32).reshape(-1))
        if len(v):
            lo, hi = v.min(axis=0).astype(float), v.max(axis=0).astype(float)
        else:
            lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
        return MeshData(v, n, i, Vec3.of(lo), Vec3.of(hi), exact, face_count, part_id, list(warnings or []))

    @property
    def vertex_count(self) -> int:
        return len(self.vertices)

    @property
    def triangle_count(self) -> int:
        return len(self.indices) // 3

    @property
    def size(self) -> Vec3:
        return self.bounds_max - self.bounds_min

    def triangles(self) -> np.ndarray:
        """(m, 3, 3) float64 corner positions."""
        return self.vertices.astype(float)[self.indices.reshape(-1, 3)]


def merge(meshes: list[MeshData], transforms: list[np.ndarray]) -> MeshData:
    """Meshes moved by their 4×4 transforms into one mesh (normals rotated, not renormalized)."""
    vs, ns, ids = [], [], []
    offset = 0
    lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
    faces = 0
    for mesh, t in zip(meshes, transforms):
        t = np.asarray(t, float)
        r = t[:3, :3]
        v = mesh.vertices.astype(float) @ r.T + t[:3, 3]
        if len(v):
            lo, hi = np.minimum(lo, v.min(axis=0)), np.maximum(hi, v.max(axis=0))
        n = mesh.normals.astype(float)
        if len(n) == len(v):
            n = n @ r.T
        else:
            n = np.tile([0.0, 0.0, 1.0], (len(v), 1))
        vs.append(v.astype(np.float32))
        ns.append(n.astype(np.float32))
        ids.append(mesh.indices.astype(np.uint32) + np.uint32(offset))
        offset += len(v)
        faces += mesh.face_count
    vertices = np.concatenate(vs) if vs else np.zeros((0, 3), np.float32)
    normals = np.concatenate(ns) if ns else np.zeros((0, 3), np.float32)
    indices = np.concatenate(ids) if ids else np.zeros(0, np.uint32)
    return MeshData(vertices, normals, indices, Vec3.of(lo), Vec3.of(hi), True, faces)
