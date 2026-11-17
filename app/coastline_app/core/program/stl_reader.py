"""Reads STL meshes (binary or ASCII) for display. Port of Program/STLReader.swift: each triangle
gets its own three vertices and its facet normal; no units in STL, the numbers are taken as mm."""

from __future__ import annotations

import struct
from pathlib import Path

import numpy as np

from ..geometry import Vec3
from ..mesh import MeshData


class EmptySTL(Exception):
    pass


def is_binary(data: bytes) -> bool:
    """Binary STL: an 80-byte header, a count, 50 bytes per triangle (the size decides)."""
    if len(data) < 84:
        return False
    (count,) = struct.unpack_from("<I", data, 80)
    return 84 + count * 50 == len(data)


def _binary(data: bytes) -> np.ndarray:
    (count,) = struct.unpack_from("<I", data, 80)
    rec = np.frombuffer(data, dtype=np.dtype([("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")]), count=count, offset=84)
    return np.array(rec["v"], np.float32)


def _ascii(text: str) -> np.ndarray:
    pts = []
    for line in text.splitlines():
        w = line.split()
        if len(w) == 4 and w[0] == "vertex":
            try:
                pts.append((float(w[1]), float(w[2]), float(w[3])))
            except ValueError:
                continue
    n = len(pts) // 3 * 3
    return np.array(pts[:n], np.float32).reshape(-1, 3, 3)


def read(path: Path) -> MeshData:
    data = Path(path).read_bytes()
    tris = _binary(data) if is_binary(data) else _ascii(data.decode("utf-8", "replace"))
    if not len(tris):
        raise EmptySTL(f"{Path(path).name} has no triangles.")
    a, b, c = tris[:, 0].astype(np.float32), tris[:, 1], tris[:, 2]
    n = np.cross(b - a, c - a)
    length = np.linalg.norm(n, axis=1, keepdims=True)
    n = np.where(length > 0, n / np.where(length > 0, length, 1), n).astype(np.float32)
    vertices = tris.reshape(-1, 3)
    normals = np.repeat(n, 3, axis=0)
    indices = np.arange(len(vertices), dtype=np.uint32)
    lo, hi = vertices.min(axis=0), vertices.max(axis=0)
    return MeshData(vertices, normals, indices, Vec3.of(lo.astype(float)), Vec3.of(hi.astype(float)), False, len(tris))
