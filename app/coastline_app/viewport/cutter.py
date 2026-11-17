"""Cutters as they look: helical flutes, the tip (flat, ball, bull nose, cone, drill point) and the
shank. Port of Viewport/CutterGeometry.swift and Model/ToolModels.swift."""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from .scene import SceneColor, SceneMesh, SurfaceMaterial


@dataclass
class CutterShape:
    diameter: float
    flute_length: float
    shank_diameter: float
    length: float
    flutes: int
    helix: float = 35.0
    tip: tuple = ("flat",)  # ("flat",) ("ball",) ("bull", rc) ("cone", half_angle, tip_d) ("drill", point_angle)

    def meshes(self):
        """(flutes, shank): each (positions (n, 3), normals (n, 3), indices)."""
        R, rs = self.diameter / 2, self.shank_diameter / 2
        n = max(self.flutes, 1)
        segments = max(24 * n, 72)
        fl = min(self.flute_length, self.length - 1)
        kind = self.tip[0]

        def envelope(z):
            if kind == "flat":
                return np.full_like(z, R)
            if kind == "ball":
                return np.where(z >= R, R, np.sqrt(np.maximum(R * R - (R - z) ** 2, 0)))
            if kind == "bull":
                rc = min(max(self.tip[1], 0.01), R)
                return np.where(z >= rc, R, R - rc + np.sqrt(np.maximum(rc * rc - (rc - z) ** 2, 0)))
            if kind == "cone":
                return np.minimum(self.tip[2] / 2 + z * math.tan(math.radians(self.tip[1])), R)
            return np.minimum(z * math.tan(math.radians(self.tip[1] / 2)), R)

        runout = max(self.diameter * 0.9, 1.0)
        full = 0.42 if kind == "drill" else 0.33

        def depth(z):
            return np.where(z <= fl, full, full * np.maximum(1 - (z - fl) / runout, 0))

        def profile(phi):
            land = 0.16
            u = phi - np.floor(phi)
            t = np.clip((u - land) / (1 - land), 0, 1)
            return np.where(u < land, 0, np.sin(math.pi * t ** 0.65) ** 1.3)

        twist = math.tan(math.radians(self.helix)) / max(R, 0.1)
        tip_zone = {"ball": R, "flat": 0.0}.get(kind)
        if tip_zone is None:
            if kind == "bull":
                tip_zone = min(self.tip[1], R)
            elif kind == "cone":
                tip_zone = (R - self.tip[2] / 2) / max(math.tan(math.radians(self.tip[1])), 0.05)
            else:
                tip_zone = R / max(math.tan(math.radians(self.tip[1] / 2)), 0.05)
        zs = [0.0]
        tip_steps = 14 if tip_zone > 0 else 0
        for i in range(1, tip_steps + 1):
            f = i / tip_steps
            z = R * (1 - math.cos(f * math.pi / 2)) if kind == "ball" else tip_zone * f
            zs.append(min(z, fl + runout))
        along = max(int((fl + runout - zs[-1]) / max(self.diameter / 14, 0.05)), 8)
        z0 = zs[-1]
        zs += [z0 + (fl + runout - z0) * i / along for i in range(1, along + 1)]
        z = np.array(zs)
        env, d = envelope(z), depth(z)
        body = np.where(z > fl, env + (rs - env) * np.minimum((z - fl) / runout, 1), env)
        th = 2 * math.pi * np.arange(segments) / segments
        phi = (th[None, :] + z[:, None] * twist) * n / (2 * math.pi)
        r = np.maximum(body[:, None] * (1 - d[:, None] * profile(phi)), 0.0005)
        fp = np.stack([r * np.cos(th)[None, :], r * np.sin(th)[None, :], np.broadcast_to(z[:, None], r.shape)], axis=-1).reshape(-1, 3)
        fi = _connect(len(zs), segments)
        centre = len(fp)
        fp = np.vstack([fp, [[0, 0, 0]]])
        k = np.arange(segments)
        fi = np.concatenate([fi, np.stack([np.full(segments, centre), (k + 1) % segments, k], axis=1).reshape(-1)])
        # Shank: from the end of the run-out to the end, with a small chamfer at the top.
        z_start = fl + runout
        z_end = max(self.length, z_start + 1)
        chamfer = min(0.3, rs * 0.2)
        rings = [(z_start, rs), (z_end - chamfer, rs), (z_end, rs - chamfer)]
        sp = np.concatenate([np.column_stack([rr * np.cos(th), rr * np.sin(th), np.full(segments, zz)]) for zz, rr in rings])
        si = _connect(3, segments)
        top = len(sp)
        sp = np.vstack([sp, [[0, 0, z_end]]])
        si = np.concatenate([si, np.stack([2 * segments + k, 2 * segments + (k + 1) % segments, np.full(segments, top)], axis=1).reshape(-1)])
        return (fp, _smooth_normals(fp, fi), fi.astype(np.uint32)), (sp, _smooth_normals(sp, si), si.astype(np.uint32))


def _connect(rings: int, segments: int) -> np.ndarray:
    i = np.arange(rings - 1)[:, None]
    k = np.arange(segments)[None, :]
    a = i * segments + k
    b = i * segments + (k + 1) % segments
    c, d = b + segments, a + segments
    return np.stack([a, b, c, a, c, d], axis=-1).reshape(-1)


def _smooth_normals(p: np.ndarray, idx: np.ndarray) -> np.ndarray:
    t = idx.reshape(-1, 3)
    n = np.cross(p[t[:, 1]] - p[t[:, 0]], p[t[:, 2]] - p[t[:, 0]])
    acc = np.zeros_like(p)
    for c in range(3):
        np.add.at(acc, t[:, c], n)
    ln = np.linalg.norm(acc, axis=1)
    out = np.tile(np.array([0, 0, 1.0]), (len(p), 1))
    ok = ln > 1e-12
    out[ok] = acc[ok] / ln[ok, None]
    return out


def cylinder(r: float, z0: float, z1: float, segments: int = 32):
    """A capped cylinder along Z: (positions, normals, indices)."""
    a = np.arange(segments + 1) / segments * 2 * math.pi
    ring = np.column_stack([np.cos(a), np.sin(a)])
    p = np.empty((2 * (segments + 1), 3))
    p[0::2, :2], p[0::2, 2] = ring * r, z0
    p[1::2, :2], p[1::2, 2] = ring * r, z1
    n = np.zeros_like(p)
    n[0::2, :2], n[1::2, :2] = ring, ring
    base = 2 * np.arange(segments)[:, None]
    idx = (base + np.array([0, 2, 1, 1, 2, 3])).reshape(-1)
    ps, ns, ids = [p], [n], [idx]
    count = len(p)
    for z, s in ((z0, -1.0), (z1, 1.0)):
        c = np.vstack([[0, 0, z], np.column_stack([ring * r, np.full(segments + 1, z)])])
        ps.append(c)
        ns.append(np.tile([0, 0, s], (len(c), 1)))
        k = np.arange(segments)
        tri = np.stack([np.zeros(segments, int), k + 1, k + 2], axis=1) if s > 0 else np.stack([np.zeros(segments, int), k + 2, k + 1], axis=1)
        ids.append(tri.reshape(-1) + count)
        count += len(c)
    return np.concatenate(ps), np.concatenate(ns), np.concatenate(ids).astype(np.uint32)


def cutter_shape(tool) -> CutterShape:
    k = tool.kind.value
    if k == "ballEndMill":
        tip = ("ball",)
    elif k == "bullNoseEndMill":
        tip = ("bull", tool.corner_radius)
    elif k in ("chamferMill", "engraver"):
        tip = ("cone", tool.angle if tool.angle is not None else 45, tool.tip_diameter)
    elif k == "spotDrill":
        tip = ("cone", (tool.angle if tool.angle is not None else 90) / 2, 0.0)
    elif k == "drill":
        tip = ("drill", tool.angle if tool.angle is not None else 118)
    else:
        tip = ("flat",)
    helix = 30 if k == "drill" else (30 if tool.flutes <= 2 else 38)
    return CutterShape(tool.diameter, max(tool.flute_length, 0.5), max(tool.shank_diameter, 0.5), tool.stickout + 15,
                       2 if k == "drill" else max(tool.flutes, 1), helix, tip)


def flute_color(tool):
    c = tool.coating.value
    v = {"tiN": 0.70, "zrN": 0.76, "tiAlN": 0.18, "alTiN": 0.18, "alCrN": 0.32, "dlc": 0.10, "diamond": 0.10,
         "unspecified": 0.55, "other": 0.55}.get(c)
    if v is None:
        v = 0.50 if tool.tool_material.value == "hss" else 0.60
    return SceneColor.surface(v)


def tool_meshes(tool, id: str) -> list[SceneMesh]:
    """Scene meshes for the flutes and the shank (tip at the origin, axis +Z)."""
    from ..core.plan.edge_finding import is_edge_finder
    if is_edge_finder(tool):
        tp, tn, ti = cylinder(tool.diameter / 2, 0, 9)
        parts = [cylinder(1.6, 9, 10.5), cylinder(tool.shank_diameter / 2, 10.5, tool.stickout)]
        bp = np.concatenate([p for p, _, _ in parts])
        bn = np.concatenate([n for _, n, _ in parts])
        bi = np.concatenate([parts[0][2], parts[1][2] + len(parts[0][0])])
        tip = SceneMesh(id, tp, tn, ti, SceneColor.surface(0.86))
        tip.material = SurfaceMaterial.chrome
        body = SceneMesh(id + ".shank", bp, bn, bi, SceneColor.surface(0.76))
        body.material = SurfaceMaterial.chrome
        return [tip, body]
    (fp, fn, fi), (sp, sn, si) = cutter_shape(tool).meshes()
    f = SceneMesh(id, fp, fn, fi, flute_color(tool))
    f.material = SurfaceMaterial(metallic=1, roughness=0.22 if tool.coating.value == "none" else 0.3)
    s = SceneMesh(id + ".shank", sp, sn, si, SceneColor.surface(0.60))
    s.material = SurfaceMaterial(metallic=1, roughness=0.14)
    return [f, s]
