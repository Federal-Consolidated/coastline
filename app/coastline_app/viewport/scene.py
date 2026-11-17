"""What the 3D view shows: triangle meshes and line sets, keyed by id. Port of
Viewport/Sources/Viewport/Scene.swift.

The scene lives on the UI thread. Change a mesh's properties freely: every change marks the
scene changed and the view redraws. The renderer copies what it needs while the UI thread
waits (QQuickRhiItemRenderer.synchronize), so no locking is needed.
"""

from __future__ import annotations

import itertools
from dataclasses import dataclass, field

import numpy as np
from PySide6.QtCore import QObject, Signal

# One toolpath segment as the GPU sees it (layout matches line.vert's per-instance inputs).
# A colour alpha below 255 marks the segment as dashed (rapids).
SEGMENT_DTYPE = np.dtype([("a", "<f4", 3), ("b", "<f4", 3), ("color_a", "u1", 4), ("color_b", "u1", 4)])
assert SEGMENT_DTYPE.itemsize == 32


class PathColor:
    """Toolpath move colours (sRGB 0–255). Move type shows as brightness; rapids also dashed."""

    rapid = (150, 150, 150, 254)
    cut = (238, 238, 238, 255)
    lead = (190, 190, 190, 255)
    plunge = (115, 115, 115, 255)
    envelope = (140, 140, 140, 255)
    axis_x = (230, 70, 70, 255)
    axis_y = (80, 200, 90, 255)
    axis_z = (70, 120, 240, 255)


class SceneColor:
    """The 3D view's palette: greys, with red and yellow for what the operator must not miss."""

    @staticmethod
    def line(v: int, alpha: int = 255) -> tuple[int, int, int, int]:
        return (v, v, v, alpha)

    @staticmethod
    def surface(v: float, alpha: float = 1.0) -> tuple[float, float, float, float]:
        return (v, v, v, alpha)

    @staticmethod
    def luminance(c) -> float:
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]

    edge = (205, 205, 205, 255)
    highlight = (250, 250, 250, 255)
    danger = (255, 40, 35, 255)
    caution = (255, 214, 10, 255)
    part = (0.56, 0.56, 0.56, 1.0)
    dark = (0.30, 0.30, 0.30, 1.0)
    danger_surface = (0.92, 0.10, 0.07, 1.0)
    caution_surface = (0.98, 0.78, 0.10, 1.0)


@dataclass(frozen=True)
class SurfaceMaterial:
    """Surface parameters for realistic shading."""

    metallic: float = 0.0
    roughness: float = 0.5
    pattern: float = 0.0  # 1: extrusion / brushing streaks along `axis`
    edges: float = 1.0  # rounded-edge highlight strength
    axis: tuple[float, float, float] = (0.0, 1.0, 0.0)


SurfaceMaterial.paint = SurfaceMaterial(0, 0.42)  # type: ignore[attr-defined]
SurfaceMaterial.plastic = SurfaceMaterial(0, 0.35)  # type: ignore[attr-defined]
SurfaceMaterial.rubber = SurfaceMaterial(0, 0.9, edges=0.3)  # type: ignore[attr-defined]
SurfaceMaterial.aluminium = SurfaceMaterial(1, 0.32)  # type: ignore[attr-defined]
SurfaceMaterial.chrome = SurfaceMaterial(1, 0.08)  # type: ignore[attr-defined]
SurfaceMaterial.mirror = SurfaceMaterial(1, 0.03)  # type: ignore[attr-defined]
SurfaceMaterial.black_oxide = SurfaceMaterial(0.7, 0.45)  # type: ignore[attr-defined]
SurfaceMaterial.carbide = SurfaceMaterial(1, 0.22)  # type: ignore[attr-defined]

_versions = itertools.count(1)
IDENTITY = np.identity(4)


class _Watched:
    """Attribute changes after construction tell the scene to redraw."""

    _scene: "Scene | None" = None

    def __setattr__(self, name: str, value) -> None:
        object.__setattr__(self, name, value)
        scene = self.__dict__.get("_scene")
        if scene is not None and not name.startswith("_"):
            scene._touch()


class SceneMesh(_Watched):
    """A triangle mesh (part, stock, fixture, machine). Vertices (n, 3) float32, indices uint32."""

    def __init__(self, id: str, vertices, normals, indices, color=SceneColor.part, transform=None,
                 pickable: bool = False) -> None:
        v = np.ascontiguousarray(np.asarray(vertices, "<f4").reshape(-1, 3))
        n = np.ascontiguousarray(np.asarray(normals, "<f4").reshape(-1, 3))
        i = np.ascontiguousarray(np.asarray(indices, "<u4").reshape(-1))
        object.__setattr__(self, "id", id)
        object.__setattr__(self, "vertices", v)
        object.__setattr__(self, "normals", n if len(n) == len(v) else np.tile(np.array([0, 0, 1], "<f4"), (len(v), 1)))
        object.__setattr__(self, "indices", i)
        object.__setattr__(self, "version", next(_versions))  # geometry version: bumped when rewritten
        object.__setattr__(self, "bounds_min", v.min(0) if len(v) else np.zeros(3, "<f4"))
        object.__setattr__(self, "bounds_max", v.max(0) if len(v) else np.zeros(3, "<f4"))
        object.__setattr__(self, "pickable", pickable)
        object.__setattr__(self, "_tree", None)
        self.color = tuple(color)
        self.material = SurfaceMaterial()
        self.transform = IDENTITY if transform is None else np.asarray(transform, float)
        self.visible = True
        self.depth_bias = 0.0  # > 0 wins against a face it touches, < 0 loses (fixtures, machine)
        self.on_top = False  # drawn last, over everything (handles)
        self.unlit = False  # flat colour (handles, overlays)
        self.group: str | None = None  # motion group: the scene's transform for it applies on top
        self.xray_through = False  # x-ray toolpaths show through this mesh (the stock)

    @property
    def translucent(self) -> bool:
        return self.color[3] < 0.999

    def update_vertices(self, vertices, normals=None) -> None:
        """Rewrites the vertices in place (same count): the simulated stock as it is cut."""
        v = np.ascontiguousarray(np.asarray(vertices, "<f4").reshape(-1, 3))
        object.__setattr__(self, "vertices", v)
        if normals is not None:
            object.__setattr__(self, "normals", np.ascontiguousarray(np.asarray(normals, "<f4").reshape(-1, 3)))
        object.__setattr__(self, "bounds_min", v.min(0) if len(v) else np.zeros(3, "<f4"))
        object.__setattr__(self, "bounds_max", v.max(0) if len(v) else np.zeros(3, "<f4"))
        object.__setattr__(self, "_tree", None)
        self.version = next(_versions)

    def intersect(self, origin, direction) -> tuple[float, np.ndarray] | None:
        """Ray–mesh hit in world space (before the group transform): distance and local point."""
        if not self.pickable or not len(self.indices):
            return None
        inv = np.linalg.inv(self.transform)
        o = (inv @ np.array([*origin, 1.0]))[:3]
        d = (inv @ np.array([*direction, 0.0]))[:3]
        if self._tree is None:
            from ..core.safety.collision import TriangleTree
            tri = self.vertices.astype(float)[self.indices.reshape(-1, 3)]
            object.__setattr__(self, "_tree", TriangleTree(tri))
        hit = self._tree.raycast(o, d)
        if hit is None:
            return None
        t = float(hit)
        return t, o + d * t


class SceneLines(_Watched):
    """A set of line segments (a toolpath, a box's edges, axes)."""

    def __init__(self, id: str, segments: np.ndarray) -> None:
        if segments.dtype != SEGMENT_DTYPE:
            raise TypeError("segments must use SEGMENT_DTYPE")
        object.__setattr__(self, "id", id)
        object.__setattr__(self, "segments", np.ascontiguousarray(segments))
        object.__setattr__(self, "version", next(_versions))
        self.visible = True
        self.group: str | None = None
        self.xray = 0.0  # > 0: also drawn faintly through the stock
        self.visible_count = len(segments)  # playback: only the first n segments draw

    @property
    def count(self) -> int:
        return len(self.segments)


def polyline_segments(points: np.ndarray, colors: np.ndarray | tuple) -> np.ndarray:
    """Segments joining consecutive points. colors: one RGBA per segment, or one for all."""
    points = np.asarray(points, np.float32)
    out = np.empty(max(len(points) - 1, 0), SEGMENT_DTYPE)
    out["a"], out["b"] = points[:-1], points[1:]
    out["color_a"] = out["color_b"] = colors
    return out


def segments(pairs, colors) -> np.ndarray:
    """Segments from (N, 2, 3) end points, one colour each or one for all."""
    p = np.asarray(pairs, np.float32).reshape(-1, 2, 3)
    out = np.empty(len(p), SEGMENT_DTYPE)
    out["a"], out["b"] = p[:, 0], p[:, 1]
    out["color_a"] = out["color_b"] = colors
    return out


def box_segments(lo, hi, color) -> np.ndarray:
    """The 12 edges of an axis-aligned box."""
    c = [(lo[0] if i & 1 == 0 else hi[0], lo[1] if i & 2 == 0 else hi[1], lo[2] if i & 4 == 0 else hi[2]) for i in range(8)]
    edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
    return segments([(c[a], c[b]) for a, b in edges], color)


def axes_segments(length: float) -> np.ndarray:
    out = segments([((0, 0, 0), (length, 0, 0)), ((0, 0, 0), (0, length, 0)), ((0, 0, 0), (0, 0, length))], PathColor.cut)
    out["color_a"][0] = out["color_b"][0] = PathColor.axis_x
    out["color_a"][1] = out["color_b"][1] = PathColor.axis_y
    out["color_a"][2] = out["color_b"][2] = PathColor.axis_z
    return out


def box_mesh(id: str, lo, hi, color, transform=None) -> SceneMesh:
    """An axis-aligned box, flat-shaded (each face its own normals)."""
    lo, hi = [float(v) for v in lo], [float(v) for v in hi]
    faces = [((1, 0, 0), [(hi[0], lo[1], lo[2]), (hi[0], hi[1], lo[2]), (hi[0], hi[1], hi[2]), (hi[0], lo[1], hi[2])]),
             ((-1, 0, 0), [(lo[0], hi[1], lo[2]), (lo[0], lo[1], lo[2]), (lo[0], lo[1], hi[2]), (lo[0], hi[1], hi[2])]),
             ((0, 1, 0), [(hi[0], hi[1], lo[2]), (lo[0], hi[1], lo[2]), (lo[0], hi[1], hi[2]), (hi[0], hi[1], hi[2])]),
             ((0, -1, 0), [(lo[0], lo[1], lo[2]), (hi[0], lo[1], lo[2]), (hi[0], lo[1], hi[2]), (lo[0], lo[1], hi[2])]),
             ((0, 0, 1), [(lo[0], lo[1], hi[2]), (hi[0], lo[1], hi[2]), (hi[0], hi[1], hi[2]), (lo[0], hi[1], hi[2])]),
             ((0, 0, -1), [(lo[0], hi[1], lo[2]), (hi[0], hi[1], lo[2]), (hi[0], lo[1], lo[2]), (lo[0], lo[1], lo[2])])]
    p, n, t = [], [], []
    for normal, corners in faces:
        base = len(p)
        p += corners
        n += [normal] * 4
        t += [base, base + 1, base + 2, base, base + 2, base + 3]
    return SceneMesh(id, p, n, t, color, transform)


class Scene(QObject):
    """Everything the viewport draws. Mutate on the UI thread."""

    changed = Signal()
    frameRequested = Signal()

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.meshes: dict[str, SceneMesh] = {}
        self.lines: dict[str, SceneLines] = {}
        self._clip_plane = np.zeros(4)
        self.group_transforms: dict[str, np.ndarray] = {}
        self.group_for_id = lambda id: None  # motion group for new meshes and lines (set by the app)
        self.bias_for_id = _default_bias

    # ---- changes

    def _touch(self) -> None:
        self.changed.emit()

    @property
    def clip_plane(self) -> np.ndarray:
        """Section plane (world): normal xyz, offset w. Zero normal: off."""
        return self._clip_plane

    @clip_plane.setter
    def clip_plane(self, value) -> None:
        self._clip_plane = np.asarray(value, float)
        self._touch()

    def set_group_transform(self, group: str, m) -> None:
        self.group_transforms[group] = np.asarray(m, float)
        self._touch()

    def group_transform(self, group: str | None) -> np.ndarray:
        return self.group_transforms.get(group, IDENTITY) if group is not None else IDENTITY

    def add(self, item):
        """Adds (or replaces) a SceneMesh or SceneLines by id."""
        if item.group is None:
            object.__setattr__(item, "group", self.group_for_id(item.id))
        if isinstance(item, SceneMesh):
            if item.depth_bias == 0:
                object.__setattr__(item, "depth_bias", self.bias_for_id(item.id))
            self.lines.pop(item.id, None)
            self.meshes.pop(item.id, None)
            self.meshes[item.id] = item
        else:
            self.meshes.pop(item.id, None)
            self.lines.pop(item.id, None)
            self.lines[item.id] = item
        object.__setattr__(item, "_scene", self)
        self._touch()
        return item

    def set_mesh(self, key: str, vertices, normals, indices, color=SceneColor.part, model=None, pickable: bool = False) -> SceneMesh:
        return self.add(SceneMesh(key, vertices, normals, indices, color, model, pickable))

    def set_lines(self, key: str, segments: np.ndarray, model=None) -> SceneLines:
        return self.add(SceneLines(key, segments))

    def set_visible_segments(self, key: str, count: int) -> None:
        """Playback: draw only the first `count` segments (no re-upload)."""
        lines = self.lines[key]
        lines.visible_count = max(0, min(count, lines.count))

    def remove(self, key: str) -> None:
        m = self.meshes.pop(key, None)
        ln = self.lines.pop(key, None)
        for item in (m, ln):
            if item is not None:
                object.__setattr__(item, "_scene", None)
        if m is not None or ln is not None:
            self._touch()

    def remove_prefix(self, prefix: str) -> None:
        for key in [k for k in (*self.meshes, *self.lines) if k.startswith(prefix)]:
            self.remove(key)

    def clear(self) -> None:
        for item in (*self.meshes.values(), *self.lines.values()):
            object.__setattr__(item, "_scene", None)
        self.meshes.clear()
        self.lines.clear()
        self._touch()

    def mesh(self, key: str) -> SceneMesh | None:
        return self.meshes.get(key)

    def line_set(self, key: str) -> SceneLines | None:
        return self.lines.get(key)

    # ---- queries

    def pick(self, origin, direction) -> tuple[str, np.ndarray, np.ndarray] | None:
        """Nearest pickable, visible mesh hit by a world-space ray: (id, world point, local point)."""
        best = None
        for m in self.meshes.values():
            if not (m.visible and m.pickable):
                continue
            g = np.linalg.inv(self.group_transform(m.group))
            o = (g @ np.array([*origin, 1.0]))[:3]
            d = (g @ np.array([*direction, 0.0]))[:3]
            hit = m.intersect(o, d)
            if hit is not None and (best is None or hit[0] < best[0]):
                best = (hit[0], m.id, hit[1])
        if best is None:
            return None
        t, key, local = best
        return key, np.asarray(origin, float) + np.asarray(direction, float) * t, local

    def visible_bounds(self) -> tuple[np.ndarray, np.ndarray] | None:
        """Bounds of all visible meshes, transformed."""
        los, his = [], []
        for m in self.meshes.values():
            if m.visible and len(m.vertices):
                lo, hi = _transform_box(m.bounds_min, m.bounds_max, self.group_transform(m.group) @ m.transform)
                los.append(lo)
                his.append(hi)
        if not los:
            return None
        return np.min(los, axis=0), np.max(his, axis=0)

    def bounds(self) -> tuple[np.ndarray, np.ndarray] | None:
        """World-space bounding box of everything visible (meshes and lines), or None."""
        los, his = [], []
        vb = self.visible_bounds()
        if vb is not None:
            los.append(vb[0])
            his.append(vb[1])
        for ln in self.lines.values():
            if ln.visible and ln.count:
                a, b = ln.segments["a"], ln.segments["b"]
                lo, hi = _transform_box(np.minimum(a.min(0), b.min(0)), np.maximum(a.max(0), b.max(0)), self.group_transform(ln.group))
                los.append(lo)
                his.append(hi)
        if not los:
            return None
        return np.min(los, axis=0), np.max(his, axis=0)

    def request_frame(self) -> None:
        self.frameRequested.emit()


def _default_bias(id: str) -> float:
    if id.startswith("fixture.") or id.startswith("machine."):
        return -1.0
    if id in ("part", "undercuts") or id.startswith("cutface"):
        return 1.0
    return 0.0


def _transform_box(lo, hi, model) -> tuple[np.ndarray, np.ndarray]:
    corners = np.array([[x, y, z, 1.0] for x in (lo[0], hi[0]) for y in (lo[1], hi[1]) for z in (lo[2], hi[2])])
    world = (np.asarray(model) @ corners.T).T[:, :3]
    return world.min(0), world.max(0)
