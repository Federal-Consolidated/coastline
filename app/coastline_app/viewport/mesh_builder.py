"""Simple shapes for handles and markers (port of Viewport/MeshBuilder.swift's builders)."""

from __future__ import annotations

import math

import numpy as np

from .scene import SceneMesh


class MeshBuilder:
    def __init__(self) -> None:
        self.p: list = []
        self.n: list = []
        self.i: list = []

    def _base(self) -> int:
        return sum(len(x) for x in self.p)

    def add(self, p, n, idx) -> None:
        base = self._base()
        self.p.append(np.asarray(p, float).reshape(-1, 3))
        self.n.append(np.asarray(n, float).reshape(-1, 3))
        self.i.append(np.asarray(idx, np.int64).reshape(-1) + base)

    def cylinder(self, r: float, z0: float, z1: float, segments: int = 32, caps: bool = True) -> None:
        a = np.arange(segments + 1) / segments * 2 * math.pi
        ring = np.column_stack([np.cos(a), np.sin(a), np.zeros(segments + 1)])
        p = np.empty((2 * (segments + 1), 3))
        p[0::2], p[1::2] = ring * r, ring * r
        p[0::2, 2], p[1::2, 2] = z0, z1
        n = np.repeat(ring, 2, axis=0)
        k = 2 * np.arange(segments)[:, None]
        self.add(p, n, (k + np.array([0, 2, 1, 1, 2, 3])).reshape(-1))
        if caps:
            self.disc(r, z0, -1, segments)
            self.disc(r, z1, 1, segments)

    def disc(self, r: float, z: float, s: float, segments: int = 32) -> None:
        a = np.arange(segments + 1) / segments * 2 * math.pi
        p = np.vstack([[0, 0, z], np.column_stack([r * np.cos(a), r * np.sin(a), np.full(segments + 1, z)])])
        n = np.tile([0, 0, s], (len(p), 1))
        k = np.arange(segments)
        tri = np.stack([np.zeros(segments, int), k + 1, k + 2] if s > 0 else [np.zeros(segments, int), k + 2, k + 1], axis=1)
        self.add(p, n, tri.reshape(-1))

    def cone(self, r0: float, z0: float, r1: float, z1: float, segments: int = 32) -> None:
        a = np.arange(segments + 1) / segments * 2 * math.pi
        slope = (r0 - r1) / max(z1 - z0, 1e-4)
        n1 = np.column_stack([np.cos(a), np.sin(a), np.full(segments + 1, slope)])
        n1 /= np.linalg.norm(n1, axis=1, keepdims=True)
        p = np.empty((2 * (segments + 1), 3))
        p[0::2] = np.column_stack([r0 * np.cos(a), r0 * np.sin(a), np.full(segments + 1, z0)])
        p[1::2] = np.column_stack([r1 * np.cos(a), r1 * np.sin(a), np.full(segments + 1, z1)])
        k = 2 * np.arange(segments)[:, None]
        self.add(p, np.repeat(n1, 2, axis=0), (k + np.array([0, 2, 1, 1, 2, 3])).reshape(-1))

    def ball_end(self, r: float, tip: float, segments: int = 24) -> None:
        rings = segments // 2
        phi = np.arange(rings + 1) / rings * (math.pi / 2)
        a = np.arange(segments + 1) / segments * 2 * math.pi
        P, A = np.meshgrid(phi, a, indexing="ij")
        n = np.stack([np.sin(P) * np.cos(A), np.sin(P) * np.sin(A), -np.cos(P)], axis=-1).reshape(-1, 3)
        p = np.array([0, 0, tip + r]) + n * r
        w = segments + 1
        j, i = np.meshgrid(np.arange(rings), np.arange(segments), indexing="ij")
        q = (j * w + i).reshape(-1, 1)
        self.add(p, n, (q + np.array([0, 1, w, 1, w + 1, w])).reshape(-1))

    def torus(self, R: float, t: float, segments: int = 96, sides: int = 10) -> None:
        u = np.arange(segments + 1) / segments * 2 * math.pi
        v = np.arange(sides + 1) / sides * 2 * math.pi
        U, V = np.meshgrid(u, v, indexing="ij")
        c = np.stack([np.cos(U), np.sin(U), np.zeros_like(U)], axis=-1)
        n = c * np.cos(V)[..., None] + np.stack([np.zeros_like(V), np.zeros_like(V), np.sin(V)], axis=-1)
        p = c * R + n * t
        w = sides + 1
        i, j = np.meshgrid(np.arange(segments), np.arange(sides), indexing="ij")
        a = (i * w + j).reshape(-1, 1)
        self.add(p.reshape(-1, 3), n.reshape(-1, 3), (a + np.array([0, w, 1, 1, w, w + 1])).reshape(-1))

    def mesh(self, id: str, color, transform=None) -> SceneMesh:
        return SceneMesh(id, np.concatenate(self.p), np.concatenate(self.n), np.concatenate(self.i).astype(np.uint32), color, transform)
