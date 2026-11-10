"""Part analysis in the work frame (tool from +Z): what limits machining this part on the machine.

- smallest inside corner radius around the tool axis (vertical concave cylinders and fillets)
  → the largest end mill that can finish every inside corner;
- smallest concave radius of curvature on freeform faces → the largest ball mill for 3D finishing;
- undercuts: faces turned away from the spindle (other than the part's bottom), which a 3-axis
  machine can't reach from this side;
- thin walls: features thinner than a threshold in any slice (morphological opening);
- depth along the tool axis.

With `access`, also which faces a tool can see at all (line of sight per axis direction), the
floors and holes with the depth of their walls and the stick-out the collet nut needs, and
the part's faces as triangles for highlighting (see `part_access`).
"""

from __future__ import annotations

import math
import os
import struct
import tempfile

import numpy as np
import opencamlib as ocl
import pyclipper
from OCP.BRep import BRep_Tool
from OCP.BRepGProp import BRepGProp
from OCP.BRepLProp import BRepLProp_SLProps
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.GeomAbs import GeomAbs_Cone, GeomAbs_Cylinder, GeomAbs_Plane
from OCP.GProp import GProp_GProps
from OCP.TopAbs import TopAbs_FACE, TopAbs_REVERSED
from OCP.TopExp import TopExp_Explorer
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS

from . import geometry as g
from .features import _analytic, _angles_around, _bounds, _coverage


def _samples(face, n=6):
    """Sample points inside the trimmed face (UV bounds of the trim, then a point-in-face test),
    not over the whole untrimmed surface (a dome is only a cap of its sphere)."""
    from OCP.BRepClass import BRepClass_FaceClassifier
    from OCP.BRepTools import BRepTools
    from OCP.TopAbs import TopAbs_IN, TopAbs_ON
    from OCP.gp import gp_Pnt2d

    surf = BRepAdaptor_Surface(face)
    u0, u1, v0, v1 = BRepTools.UVBounds_s(face)
    for i in range(n):
        for j in range(n):
            u = u0 + (u1 - u0) * (i + 0.5) / n
            v = v0 + (v1 - v0) * (j + 0.5) / n
            state = BRepClass_FaceClassifier(face, gp_Pnt2d(u, v), 1e-6).State()
            if state in (TopAbs_IN, TopAbs_ON):
                yield surf, u, v


def _face_triangles(face) -> np.ndarray:
    loc = TopLoc_Location()
    tri = BRep_Tool.Triangulation_s(face, loc)
    if tri is None:
        return np.zeros((0, 3, 3), np.float32)
    trsf = loc.Transformation()
    pts = np.array([[p.X(), p.Y(), p.Z()] for p in (tri.Node(i).Transformed(trsf) for i in range(1, tri.NbNodes() + 1))])
    idx = np.array([tri.Triangle(i).Get() for i in range(1, tri.NbTriangles() + 1)]) - 1
    if face.Orientation() == TopAbs_REVERSED:
        idx = idx[:, [0, 2, 1]]
    return pts[idx].astype(np.float32)


def analyse(shape_work, geo: g.PartGeometry, thin_threshold: float = 0.8, access: bool = False,
            nut_radius: float = 8.0) -> dict:
    """`access`: also return "access" (part_access) and "access_triangles" (blob 1).
    `nut_radius`: the collet nut's radius, for the holder depths."""
    BRepMesh_IncrementalMesh(shape_work, 0.02, False, 0.3, True)
    concave_radii = []
    corner_angles: dict = {}  # concave Z cylinders by (x, y, r) → [radius, angles round the axis…]
    cylinder_spans: dict = {}  # the same keys → [axis x, axis y, z lo, z hi]
    cone_radii = []  # Z-axis cones (drill points, countersinks): (x, y, z lo, z hi, concave radii)
    faces = [] if access else None
    undercut_area = 0.0
    # Faces 2.5D operations can't finish: anything but planes square to the tool axis and
    # cylinders along it (domes, fillets, chamfers, freeform NURBS).
    freeform_area = 0.0
    # Area by what finishes it: flat floors (planes square to the tool), walls (along the tool
    # axis), and freeform area that is steep (> 45°) — waterline territory.
    flat_area = 0.0
    wall_area = 0.0
    steep_area = 0.0
    undercut_tris = []
    zmin = geo.zmin
    exp = TopExp_Explorer(shape_work, TopAbs_FACE)
    while exp.More():
        face = TopoDS.Face(exp.Current())
        exp.Next()
        reversed_ = face.Orientation() == TopAbs_REVERSED
        sign = -1.0 if reversed_ else 1.0
        surf, kind = _analytic(face)
        props = GProp_GProps()
        BRepGProp.SurfaceProperties_s(face, props)
        area = props.Mass()

        is_free = False
        if kind == GeomAbs_Plane:
            nz = abs(surf.Plane().Axis().Direction().Z())
            if 0.001 < nz < 0.999:
                is_free = True
            elif nz >= 0.999:
                flat_area += area
            else:
                wall_area += area
        elif kind == GeomAbs_Cylinder:
            if abs(surf.Cylinder().Axis().Direction().Z()) < 0.999:
                is_free = True
            else:
                wall_area += area
        else:
            is_free = True
        if is_free:
            freeform_area += area

        # Inside corners around the tool axis: concave (REVERSED) cylinders parallel to Z. A
        # full hole isn't a corner (a hole any smaller tool can bore): grouped by axis and
        # radius, and dropped below when it goes all the way round (as features.find_features).
        if kind == GeomAbs_Cylinder:
            cyl = surf.Cylinder()
            ax = cyl.Axis().Direction()
            if abs(ax.Z()) > 0.999 and reversed_:
                loc = cyl.Location()
                key = (round(loc.X(), 3), round(loc.Y(), 3), round(cyl.Radius(), 3))
                corner_angles.setdefault(key, [cyl.Radius()]).extend(_angles_around(face, loc.X(), loc.Y()))
                blo, bhi = _bounds(face)
                span = cylinder_spans.setdefault(key, [loc.X(), loc.Y(), blo[2], bhi[2]])
                span[2], span[3] = min(span[2], blo[2]), max(span[3], bhi[2])

        # Sample normals (undercuts) and curvature (concave freeform radius).
        face_radii = concave_radii
        if kind == GeomAbs_Cone and abs(surf.Cone().Axis().Direction().Z()) > 0.999:
            # Kept apart until the holes are known: see below.
            origin = surf.Cone().Axis().Location()
            blo, bhi = _bounds(face)
            cone_radii.append((origin.X(), origin.Y(), blo[2], bhi[2], []))
            face_radii = cone_radii[-1][4]
        down = False
        steep_samples = [0, 0]
        sight = [] if faces is not None else None  # (point, outward normal) for line of sight
        for s, u, v in _samples(face):
            p = BRepLProp_SLProps(s, u, v, 2, 1e-6)
            if not p.IsNormalDefined():
                continue
            n = p.Normal()
            nz = sign * n.Z()
            pt = s.Value(u, v)
            if sight is not None:
                sight.append((pt.X(), pt.Y(), pt.Z(), sign * n.X(), sign * n.Y(), nz))
            if nz < -0.05 and pt.Z() > zmin + 0.02:
                down = True
            if is_free and nz > 0:
                steep_samples[0] += 1
                if nz < 0.7071:  # steeper than 45°
                    steep_samples[1] += 1
            if kind not in (GeomAbs_Plane, GeomAbs_Cylinder) and p.IsCurvatureDefined():
                # OCCT signs curvature against the surface normal: with the normal turned to
                # face out of the material, positive means concave (a pocket a ball mill must
                # fit into). Verified on a spherical dimple (concave) and a dome (convex).
                for k in (p.MinCurvature(), p.MaxCurvature()):
                    kk = sign * k
                    if kk > 1e-6:
                        face_radii.append(1.0 / kk)
        if steep_samples[0]:
            steep_area += area * steep_samples[1] / steep_samples[0]
        if down:
            undercut_area += area
            undercut_tris.append(_face_triangles(face))
        if faces is not None:
            faces.append({"face": face, "area": float(area), "plane": kind == GeomAbs_Plane, "surf": surf,
                          "sign": sign, "kind": "plane" if kind == GeomAbs_Plane else
                          "cylinder" if kind == GeomAbs_Cylinder else "other", "samples": sight})
    corner_radii = [a[0] for a in corner_angles.values() if _coverage(a[1:]) < 300.0]
    # A hole's drill point or countersink is cut by the drill's or chamfer mill's own shape, not
    # finished with a ball mill; its curvature only grows toward the tip (a 6.35 drill point read
    # as R0.51). Coaxial with a full hole, as features.find_features groups them, it doesn't count.
    full_holes = [cylinder_spans[k] for k, a in corner_angles.items() if _coverage(a[1:]) >= 300.0]
    for x, y, zlo, zhi, radii in cone_radii:
        if not any(math.hypot(x - hx, y - hy) < 1e-3 and zhi >= hzlo - 1e-3 and zlo <= hzhi + 1e-3
                   for hx, hy, hzlo, hzhi in full_holes):
            concave_radii.extend(radii)

    # Thin walls: an opening (shrink then grow by t/2) removes features thinner than t. It also
    # rounds every sharp outside corner, losing a sliver of 0.21·(t/2)² at 90°: not a wall (a
    # plain box read as a 0.47 mm wall), so only pieces larger than (t/2)² count.
    def thin_loss(paths, t):
        opened = g.offset(g.offset(paths, -t / 2), t / 2)
        pc = pyclipper.Pyclipper()
        pc.AddPaths(paths, pyclipper.PT_SUBJECT, True)
        if opened:
            pc.AddPaths(opened, pyclipper.PT_CLIP, True)
        lost = pc.Execute(pyclipper.CT_DIFFERENCE, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
        sliver = (t / 2 * g.SCALE) ** 2
        return sum(pyclipper.Area(p) for p in lost if abs(pyclipper.Area(p)) > sliver)

    thinnest = None
    for z in np.linspace(geo.zmin + 0.05, geo.zmax - 0.05, 6):
        region = geo.region(float(z))
        if not region:
            continue
        if thin_loss(region, thin_threshold) / g.SCALE**2 > 0.05:
            lo, hi = 0.05, thin_threshold
            for _ in range(10):
                mid = (lo + hi) / 2
                if thin_loss(region, mid) / g.SCALE**2 > 0.05:
                    hi = mid
                else:
                    lo = mid
            thinnest = hi if thinnest is None else min(thinnest, hi)

    # Parting level: where the cross-section is largest. A two-sided job splits here.
    parting, best_area = geo.zmin, -1.0
    for z in np.linspace(geo.zmin + 0.02, geo.zmax - 0.02, 24):
        a = sum(pyclipper.Area(p) for p in geo.region(float(z))) / g.SCALE**2
        if a > best_area + 1e-6:
            parting, best_area = float(z), a

    # Volume, and how round the silhouette is (1 = a disc: spiral finishing suits it).
    vprops = GProp_GProps()
    BRepGProp.VolumeProperties_s(shape_work, vprops)
    volume = abs(vprops.Mass())
    sil = geo.shadow(geo.zmin)
    circularity = 0.0
    if sil:
        pts = np.vstack([g.to_mm(p) for p in sil])
        c = pts.mean(0)
        rmax = float(np.max(np.linalg.norm(pts - c, axis=1)))
        area = sum(pyclipper.Area(p) for p in sil) / g.SCALE**2
        circularity = float(area / (np.pi * rmax * rmax)) if rmax > 0 else 0.0

    tris = np.concatenate(undercut_tris) if undercut_tris else np.zeros((0, 3, 3), np.float32)
    return {
        "min_corner_radius": float(min(corner_radii)) if corner_radii else None,
        "min_concave_radius": float(min(concave_radii)) if concave_radii else None,
        "undercut_area": float(undercut_area),
        "thinnest_wall": float(thinnest) if thinnest is not None else None,
        "depth": float(geo.zmax - geo.zmin),
        "parting_z": float(parting),
        "freeform_area": float(freeform_area),
        "flat_area": float(flat_area),
        "wall_area": float(wall_area),
        "steep_area": float(steep_area),
        "volume": float(volume),
        "circularity": circularity,
        "zmax": float(geo.zmax),
        "undercut_triangles": tris,
    } | (_access_or_error(shape_work, geo, faces, nut_radius) if faces is not None else {})


def _access_or_error(shape_work, geo, faces, nut_radius) -> dict:
    """The access pass must never cost the part its basic analysis: on failure, no "access"
    (the app shows it as not checked) and the reason in "access_error"."""
    try:
        return part_access(shape_work, geo, faces, nut_radius)
    except Exception as e:  # noqa: BLE001 — any geometry failure
        import sys
        import traceback
        traceback.print_exc(file=sys.stderr)
        return {"access_error": str(e) or type(e).__name__, "access_triangles": np.zeros((0, 3, 3), np.float32)}


def freeform_footprint(shape_work, z_min: float | None = None) -> list:
    """Where 3D finishing has work, seen from above: the XY footprint (pyclipper paths) of the
    faces 2.5D operations can't finish (anything but floors square to the tool and walls along
    it). Flat floors and vertical walls belong to the floor and contour passes. `z_min`: only
    faces reaching above it (the side's depth window)."""
    BRepMesh_IncrementalMesh(shape_work, 0.05, False, 0.5, True)
    polys = []
    exp = TopExp_Explorer(shape_work, TopAbs_FACE)
    while exp.More():
        face = TopoDS.Face(exp.Current())
        exp.Next()
        surf, kind = _analytic(face)
        if kind == GeomAbs_Plane:
            nz = abs(surf.Plane().Axis().Direction().Z())
            if not (0.001 < nz < 0.999):
                continue
        elif kind == GeomAbs_Cylinder and abs(surf.Cylinder().Axis().Direction().Z()) >= 0.999:
            continue
        tris = _face_triangles(face)
        if not len(tris):
            continue
        if z_min is not None:
            tris = tris[tris[:, :, 2].max(axis=1) > z_min]
        for t in tris:
            p = g.to_int(t[:, :2].astype(float))
            if abs(pyclipper.Area(p)) > 0:
                polys.append(p if pyclipper.Orientation(p) else p[::-1])
    if not polys:
        return []
    pc = pyclipper.Pyclipper()
    pc.AddPaths(polys, pyclipper.PT_SUBJECT, True)
    return pc.Execute(pyclipper.CT_UNION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)


# --------------------------------------------------------------------------- access

# Line of sight is judged at sample points just off each face (along its outward normal): a
# sample is visible from a direction when the ray from it that way misses the finished part.
# A tool can only reach what it can see, but seeing is not reaching: tool length, shank and
# holder are checked separately (floors, holes), and holding the part is not checked at all.
SIGHT_OFFSET = 0.2     # mm off the face, so the ray never starts inside its own surface
SIGHT_PROBE = 0.02     # mm, diameter of the drop-cutter used as a ray
SIGHT_SLACK = 0.05     # mm the part may stand above a sample and still count as clear (mesh chords)
# Fraction of a face's samples that may disagree with the verdict: samples next to a trim
# graze the neighbouring faces. A face has at most 36 samples, so one stray sample is allowed.
ACCESS_TOLERANCE = 0.05
HEIGHT_STEP = 0.5      # mm grid for wall and holder heights (as surface3d.min_stickout)
WALL_BAND = 1.0        # mm round a floor that counts as its wall
TRIANGLE_BUDGET = 300_000  # face triangles sent for highlighting; past it, only the named faces

AXES = ("+z", "-z", "+x", "-x", "+y", "-y")
# Rotations that turn each direction to +Z: dropping a probe there looks along the direction.
_TURN = {
    "+z": np.eye(3),
    "-z": np.diag([1.0, -1.0, -1.0]),
    "+x": np.array([[0.0, 0, -1], [0, 1, 0], [1, 0, 0]]),
    "-x": np.array([[0.0, 0, 1], [0, 1, 0], [-1, 0, 0]]),
    "+y": np.array([[1.0, 0, 0], [0, 0, -1], [0, 1, 0]]),
    "-y": np.array([[1.0, 0, 0], [0, 0, 1], [0, -1, 0]]),
}
_RANK = {"this": 0, "opposite": 1, "other": 2, "none": 3}


def _stl(tris: np.ndarray):
    """An OpenCAMLib surface from (n, 3, 3) triangles, through a binary STL: far quicker than
    adding the triangles one by one from Python."""
    rec = np.zeros(len(tris), dtype=[("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")])
    rec["v"] = tris
    fd, path = tempfile.mkstemp(suffix=".stl")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(b"\0" * 80 + struct.pack("<I", len(tris)) + rec.tobytes())
        surf = ocl.STLSurf()
        ocl.STLReader(path, surf)
    finally:
        os.unlink(path)
    return surf


class _Sight:
    """The part turned so one direction points to +Z: a thin drop-cutter there casts rays."""

    def __init__(self, tris: np.ndarray, direction: str):
        self.turn = _TURN[direction]
        v = tris.reshape(-1, 3) @ self.turn.T
        self.floor = float(v[:, 2].min()) - 1.0
        self.stl = _stl(v.reshape(-1, 3, 3))

    def drop(self, xy: np.ndarray, diameter: float = SIGHT_PROBE) -> np.ndarray:
        if len(xy) == 0:
            return np.zeros(0)
        cutter = ocl.CylCutter(diameter, 1000)  # referenced until run() is done
        bdc = ocl.BatchDropCutter()
        bdc.setSTL(self.stl)
        bdc.setCutter(cutter)
        for x, y in xy:
            bdc.appendPoint(ocl.CLPoint(float(x), float(y), self.floor))
        bdc.run()
        return np.maximum(np.array([p.z for p in bdc.getCLPoints()]), self.floor)

    def clear(self, pts: np.ndarray) -> np.ndarray:
        """Which work-frame points see out along the direction (nothing of the part beyond)."""
        q = pts @ self.turn.T
        return self.drop(q[:, :2]) <= q[:, 2] + SIGHT_SLACK


def _fallback_samples(face) -> list:
    """Triangle centres (largest first) when the UV grid misses a small trimmed face."""
    tris = _face_triangles(face).astype(float)
    if not len(tris):
        return []
    n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    area = np.linalg.norm(n, axis=1)
    out = []
    for i in np.argsort(-area)[:12]:
        if area[i] > 1e-12:
            c = tris[i].mean(0)
            out.append((*c, *(n[i] / area[i])))
    return out


def _boundary(info: dict, pmin, pmax, tol: float = 1e-3):
    """A planar face on the part's own bounding box, outward along an axis: ("+x", offset)."""
    if not info["plane"]:
        return None, None
    d = info["surf"].Plane().Axis().Direction()
    n = np.array([d.X(), d.Y(), d.Z()]) * info["sign"]
    lo, hi = info["min"], info["max"]
    for a, name in enumerate("xyz"):
        if n[a] > 0.999 and abs(lo[a] - pmax[a]) < tol and abs(hi[a] - pmax[a]) < tol:
            return "+" + name, float(pmax[a])
        if n[a] < -0.999 and abs(lo[a] - pmin[a]) < tol and abs(hi[a] - pmin[a]) < tol:
            return "-" + name, float(pmin[a])
    return None, None


def _inside(paths: list, pts: np.ndarray) -> np.ndarray:
    """Points inside pyclipper paths (outer loops and holes, even-odd)."""
    from .surface3d import _inside as inside_poly
    out = np.zeros(len(pts), bool)
    for p in paths:
        if len(p) >= 3:
            out ^= inside_poly(g.to_mm(p), pts)
    return out


def _window_max(H: np.ndarray, k: int) -> np.ndarray:
    """Highest value within k cells (a square window, cut at the grid's edge), every cell."""
    from numpy.lib.stride_tricks import sliding_window_view
    out = H
    for axis in (0, 1):
        pad = [(0, 0), (0, 0)]
        pad[axis] = (k, k)
        out = sliding_window_view(np.pad(out, pad, constant_values=-1e9), 2 * k + 1, axis=axis).max(axis=-1)
    return out


class _Heights:
    """The finished part's top on local grids (one batched drop for every grid): the walls
    round a floor and what the collet nut must clear over it."""

    def __init__(self, geo, sight: _Sight, boxes: list, nut_radius: float):
        from .surface3d import part_heights
        self.k = int(math.ceil((nut_radius + 1) / HEIGHT_STEP))  # the nut's window, as min_stickout
        margin = (self.k + 1) * HEIGHT_STEP + WALL_BAND
        self.grids, pts = [], []
        for lo, hi in boxes:
            xs = np.arange(lo[0] - margin, hi[0] + margin + HEIGHT_STEP, HEIGHT_STEP)
            ys = np.arange(lo[1] - margin, hi[1] + margin + HEIGHT_STEP, HEIGHT_STEP)
            X, Y = np.meshgrid(xs, ys, indexing="ij")
            self.grids.append((xs, ys, X.shape))
            pts.append(np.c_[X.ravel(), Y.ravel()])
        allpts = np.vstack(pts) if pts else np.zeros((0, 2))
        H = part_heights(geo, allpts, drop=lambda q: sight.drop(q, 0.05)) if len(allpts) else np.zeros(0)
        self.H, k0 = [], 0
        for xs, ys, shape in self.grids:
            n = shape[0] * shape[1]
            self.H.append(H[k0:k0 + n].reshape(shape))
            k0 += n

    def grid(self, i: int):
        xs, ys, shape = self.grids[i]
        X, Y = np.meshgrid(xs, ys, indexing="ij")
        return xs, ys, np.c_[X.ravel(), Y.ravel()], self.H[i]

    def floor(self, i: int, paths: list, z: float) -> tuple[float, float, float]:
        """(wall depth, holder depth, enclosed) for a floor at z: the highest material within
        WALL_BAND of it; the shortest stick-out keeping the nut 1 mm above the part with the tip
        anywhere on it; the share of the ring round it where a wall rises over 0.5 mm (1: a
        closed pocket, 0: a step open all round)."""
        xs, ys, P, H = self.grid(i)
        flat = H.ravel()
        band = _inside(g.offset(paths, WALL_BAND), P) & (flat > -1e8)
        wall = max(float(flat[band].max()) - z, 0.0) if band.any() else 0.0
        tips = _inside(paths, P)
        ring = _inside(g.offset(paths, WALL_BAND), P) & ~tips
        enclosed = float(np.mean(flat[ring] > z + 0.5)) if ring.any() else 0.0
        if not tips.any():  # narrower than the grid: the cells nearest its outline
            tips = np.zeros(len(P), bool)
            for p in paths:
                for x, y in g.to_mm(p):
                    tips[int(round((x - xs[0]) / HEIGHT_STEP)) * len(ys) + int(round((y - ys[0]) / HEIGHT_STEP))] = True
        W = _window_max(H, self.k).ravel()
        return wall, max(float(W[tips].max()) - z + 1.0, 0.0), enclosed

    def point(self, i: int, x: float, y: float, z: float) -> float:
        """Holder depth with the tip at (x, y, z), as min_stickout measures it."""
        xs, ys, _, H = self.grid(i)
        a, b = int(round((x - xs[0]) / HEIGHT_STEP)), int(round((y - ys[0]) / HEIGHT_STEP))
        win = H[max(a - self.k, 0):a + self.k + 1, max(b - self.k, 0):b + self.k + 1]
        return max(float(win.max()) - z + 1.0, 0.0)


def _depth_from(side: str, lo, hi, pmin, pmax) -> float:
    """How far in from the part's outside on `side` the far end of a box lies, mm: how deep a
    tool coming from that side must reach."""
    k = "xyz".index(side[1])
    return float(pmax[k] - lo[k]) if side[0] == "+" else float(hi[k] - pmin[k])


def _cover(idx, P, vis, done, pmin, pmax, planned=()) -> list:
    """The sides a tool must come from to cut a region's samples (indices into P): what +Z sees
    is cut from the setup as it is; then what the `planned` sides see (side B when both sides
    are machined); every other sample from the nearest side that sees it, so each side's reach
    is as short as it can be. Each side with the share of samples it takes and how deep the
    deepest of them lies from the part's outside on that side, mm; planned sides first, then
    the largest share."""
    pts = P[idx]

    def depth(d):
        k = "xyz".index(d[1])
        return pmax[k] - pts[:, k] if d[0] == "+" else pts[:, k] - pmin[k]

    def entry(d, take):
        return {"side": d, "share": round(int(take.sum()) / len(idx), 3),
                "depth": round(max(float(np.max(depth(d)[take])), 0.0), 3)}

    left = ~(done["+z"][idx] & vis["+z"][idx])
    out = []
    for d in planned:
        take = left & done[d][idx] & vis[d][idx]
        if take.any():
            out.append(entry(d, take))
            left &= ~take
    nearest = np.full(len(idx), -1)
    best = np.full(len(idx), np.inf)
    for j, d in enumerate(AXES[1:]):
        seen_d = left & done[d][idx] & vis[d][idx]
        dd = depth(d)
        closer = seen_d & (dd < best - 1e-9)
        nearest[closer], best[closer] = j, dd[closer]
    rest = [entry(d, nearest == j) for j, d in enumerate(AXES[1:]) if np.any(nearest == j)]
    return out + sorted(rest, key=lambda e: -e["share"])


def _thread(fs: list, pmin, pmax) -> dict | None:
    """A modelled thread: a bore's faces (cylinders of more than one radius, helical or other
    freeform faces, rings square to it) all round one line along a main axis. Line of sight
    can't see past its crests, so its faces read blocked; it is cut along its axis with a thread
    mill or a tap. Returns the axis sides with how deep the thread's far end is from each (open
    sides first: the bore reaches the part's outside there), its diameters and length; or None."""
    cyl = []
    for f in fs:
        if f["kind"] == "cylinder":
            c = f["surf"].Cylinder()
            a = c.Axis()
            p, d = a.Location(), a.Direction()
            cyl.append((np.array([p.X(), p.Y(), p.Z()]), np.array([d.X(), d.Y(), d.Z()]), c.Radius()))
    if not cyl:
        return None
    k = int(np.argmax(np.abs(cyl[0][1])))
    o = [j for j in range(3) if j != k]
    centre = cyl[0][0][o]
    if any(abs(d[k]) < 0.999 or np.linalg.norm(p[o] - centre) > 0.05 for p, d, _ in cyl):
        return None
    for f in fs:
        if f["kind"] == "plane":
            n = f["surf"].Plane().Axis().Direction()
            if abs((n.X(), n.Y(), n.Z())[k]) < 0.999:
                return None
    radii = [r for _, _, r in cyl]
    helix = any(f["kind"] == "other" for f in fs)
    if not helix and (len(cyl) < 4 or max(radii) - min(radii) < 0.05):
        return None
    lo = np.min([f["min"] for f in fs], axis=0)
    hi = np.max([f["max"] for f in fs], axis=0)
    across = (hi - lo)[o]
    # Round and centred on the axis: the helical faces stay within the thread's envelope.
    if abs(across[0] - across[1]) > 0.1 * max(across) or np.max(np.abs((lo + hi)[o] / 2 - centre)) > 0.1:
        return None
    major = max(2 * max(radii), float(max(across)))
    minor = 2 * min(radii)
    if major - minor < 0.15:
        return None
    axis = "xyz"[k]
    sides = []
    for s in ("+" + axis, "-" + axis):
        bound = pmax[k] if s[0] == "+" else pmin[k]
        end = hi[k] if s[0] == "+" else lo[k]
        sides.append({"side": s, "depth": round(_depth_from(s, lo, hi, pmin, pmax), 4),
                      "open": bool(abs(end - bound) <= 0.05)})
    sides.sort(key=lambda s: (not s["open"], s["depth"]))
    return {"sides": sides, "major": round(major, 4), "minor": round(minor, 4),
            "length": round(float(hi[k] - lo[k]), 4)}


def part_access(shape_work, geo: g.PartGeometry, faces: list, nut_radius: float = 8.0) -> dict:
    """What a tool can see from each axis direction, and the depths that limit tools.

    `faces`: per B-rep face (TopExp_Explorer order) the sample points and normals analyse()
    collected. Returns {"access": the RPC's access record, "access_triangles": blob 1}.
    Access per face: "this" = seen from +Z; "opposite" = every sample seen from +Z or -Z;
    "other" = some seen only from a side; "none" = some seen from no axis direction (within
    ACCESS_TOLERANCE of the samples)."""
    from OCP.TopAbs import TopAbs_EDGE
    from OCP.TopExp import TopExp
    from OCP.collections import IndexedMap_TopoDS_Shape_TopTools_ShapeMapHasher as ShapeMap
    from OCP.Bnd import Bnd_Box
    from OCP.BRepBndLib import BRepBndLib

    from .features import _bounds, find_features
    from ..server import _inscribed

    box = Bnd_Box()
    BRepBndLib.AddOptimal_s(shape_work, box, False, False)
    c0, c1 = box.CornerMin(), box.CornerMax()
    pmin, pmax = np.array([c0.X(), c0.Y(), c0.Z()]), np.array([c1.X(), c1.Y(), c1.Z()])

    owner, pts, on = [], [], []
    for i, f in enumerate(faces):
        f["min"], f["max"] = _bounds(f["face"])
        f["boundary"], f["offset"] = _boundary(f, pmin, pmax)
        samples = f["samples"] if len(f["samples"]) >= 3 else f["samples"] + _fallback_samples(f["face"])
        for x, y, z, nx, ny, nz in samples:
            pts.append((x + SIGHT_OFFSET * nx, y + SIGHT_OFFSET * ny, z + SIGHT_OFFSET * nz))
            on.append((x, y, z))
            owner.append(i)
    P = np.asarray(pts, float).reshape(-1, 3)
    on_face = np.asarray(on, float).reshape(-1, 3)  # the samples themselves, for depths
    owner = np.asarray(owner, int)
    tris = geo.mesh.vertices[geo.mesh.faces]
    sights = {d: _Sight(tris, d) for d in ("+z", "-z")}
    vis = {d: np.zeros(len(P), bool) for d in AXES}
    done = {d: np.zeros(len(P), bool) for d in AXES}
    for d in ("+z", "-z"):
        vis[d][:] = sights[d].clear(P)
        done[d][:] = True

    count = np.bincount(owner, minlength=len(faces)).astype(float)

    def frac(mask):
        return np.bincount(owner, weights=mask.astype(float), minlength=len(faces)) / np.maximum(count, 1)

    blocked_z = frac(~(vis["+z"] | vis["-z"]))
    seen_top = frac(vis["+z"])
    # Side directions only where +Z and -Z leave samples unseen; then for every face not seen
    # from +Z, so a region's directions are known for all its faces.
    if np.any((blocked_z > ACCESS_TOLERANCE) & (count > 0)):
        pick = np.flatnonzero(seen_top[owner] < 1 - ACCESS_TOLERANCE)
        for d in AXES[2:]:
            sights[d] = _Sight(tris, d)
            vis[d][pick] = sights[d].clear(P[pick])
            done[d][pick] = True
    blocked_all = frac(~np.any([vis[d] for d in AXES], axis=0))
    seen = {d: frac(vis[d]) for d in AXES}
    known = {d: (frac(~done[d]) == 0) & (count > 0) for d in AXES}  # every sample of the face asked
    out_faces = []
    for i, f in enumerate(faces):
        visible = {d: round(float(seen[d][i]), 3) for d in AXES if known[d][i]}
        if count[i] == 0 or seen_top[i] >= 1 - ACCESS_TOLERANCE:
            acc = "this"
        elif blocked_z[i] <= ACCESS_TOLERANCE:
            acc = "opposite"
        elif blocked_all[i] <= ACCESS_TOLERANCE:
            acc = "other"
        else:
            acc = "none"
        f["access"] = acc
        out_faces.append({"index": i, "area": f["area"], "kind": f["kind"], "boundary": f["boundary"],
                          "plane_offset": f["offset"], "access": acc, "visible": visible})

    # Regions: faces not seen from +Z (other than the part's outer faces), joined by shared
    # edges, only between faces with the same access and, for side access, the same nearest
    # open side: one blocked face (a thread's crest) must not make the windows and bores it
    # touches "none" too. Each face's own edges, numbered in one edge map (walking OCCT's
    # ancestor lists from Python costs milliseconds per edge).
    wanted = {i for i, f in enumerate(faces) if f["access"] != "this" and f["boundary"] is None}

    def side_key(i):
        f = faces[i]
        if f["access"] != "other":
            return f["access"]
        full = [d for d in AXES[2:] if known[d][i] and seen[d][i] >= 1 - ACCESS_TOLERANCE]
        if not full:
            return "other*"  # no one side sees all of it: a group of its own kind
        return "other" + min(full, key=lambda d: _depth_from(d, f["min"], f["max"], pmin, pmax))

    key = {i: side_key(i) for i in wanted}
    parent = {i: i for i in wanted}

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    emap = ShapeMap()
    TopExp.MapShapes_s(shape_work, TopAbs_EDGE, emap)
    first_face: dict = {}  # edge number → the first wanted face met on it
    for i in sorted(wanted):
        ex = TopExp_Explorer(faces[i]["face"], TopAbs_EDGE)
        while ex.More():
            e = emap.FindIndex(ex.Current())
            j = first_face.setdefault((e, key[i]), i)
            if j != i:
                parent[root(i)] = root(j)
            ex.Next()
    groups: dict = {}
    for i in sorted(wanted):
        groups.setdefault(root(i), []).append(i)
    def make_region(members, thread=None):
        own = np.isin(owner, members)
        acc = max((faces[i]["access"] for i in members), key=_RANK.get)
        dirs = [] if acc == "none" else [d for d in AXES if own.any() and done[d][own].all()
                                         and vis[d][own].mean() >= 1 - ACCESS_TOLERANCE]
        region = {"faces": members, "area": float(sum(faces[i]["area"] for i in members)), "access": acc,
                  "directions": dirs,
                  "min": np.min([faces[i]["min"] for i in members], axis=0).tolist(),
                  "max": np.max([faces[i]["max"] for i in members], axis=0).tolist()}
        region["sides"] = _cover(np.flatnonzero(own), on_face, vis, done, pmin, pmax)
        region["sides_two"] = _cover(np.flatnonzero(own), on_face, vis, done, pmin, pmax, planned=("-z",))
        if thread is None and acc in ("none", "other"):
            thread = _thread([faces[i] for i in members], pmin, pmax)
        if thread:
            region["thread"] = thread
        return region

    regions = [make_region(members) for members in groups.values()]
    # A thread's helical flanks read blocked while its crests and roots may read seen from an
    # end: a blocked free-form region and the regions it touches within its length and width
    # are one thread when together they make one (_thread: coaxial, round, centred).
    edges_of = {}
    for i in wanted:
        ex = TopExp_Explorer(faces[i]["face"], TopAbs_EDGE)
        while ex.More():
            edges_of.setdefault(i, set()).add(emap.FindIndex(ex.Current()))
            ex.Next()
    gone = set()
    for k, r in enumerate(regions):
        if k in gone or "thread" in r or r["access"] != "none" or not any(faces[i]["kind"] == "other" for i in r["faces"]):
            continue
        lo, hi = np.array(r["min"]) - 0.5, np.array(r["max"]) + 0.5
        mine = set().union(*(edges_of.get(i, set()) for i in r["faces"]))
        near = [n for n, q in enumerate(regions) if n != k and n not in gone and "thread" not in q
                and np.all(np.array(q["min"]) >= lo) and np.all(np.array(q["max"]) <= hi)
                and any(edges_of.get(i, set()) & mine for i in q["faces"])]
        if not near:
            continue
        members = sorted(r["faces"] + [i for n in near for i in regions[n]["faces"]])
        thread = _thread([faces[i] for i in members], pmin, pmax)
        if thread:
            regions[k] = make_region(members, thread)
            gone.update(near)
    regions = [r for n, r in enumerate(regions) if n not in gone]
    regions.sort(key=lambda r: r["faces"][0])

    # Floors and holes, with how deep their walls are and the stick-out the nut needs.
    feats = find_features(shape_work, geo.zmin, with_faces=True)
    floors = [fl for fl in feats["floors"] if fl["z"] < pmax[2] - 1e-3 and faces[fl["face"]]["access"] == "this"]
    holes = feats["holes"]
    boxes = [(fl["min"], fl["max"]) for fl in floors] + [((h["x"], h["y"]), (h["x"], h["y"])) for h in holes]
    heights = _Heights(geo, sights["+z"], boxes, nut_radius)
    out_floors = []
    for i, fl in enumerate(floors):
        wall, holder, enclosed = heights.floor(i, fl["paths"], fl["z"])
        out_floors.append({"face": fl["face"], "z": fl["z"], "area": faces[fl["face"]]["area"],
                           "width": _inscribed(fl["paths"]), "wall_depth": round(wall, 4),
                           "holder_depth": round(holder, 4), "enclosed": round(enclosed, 3),
                           "min": fl["min"], "max": fl["max"]})
    out_holes = []
    for i, h in enumerate(holes):
        acc = max((faces[j]["access"] for j in h["faces"]), key=_RANK.get, default="this")
        out_holes.append({"faces": h["faces"], "x": h["x"], "y": h["y"], "diameter": h["diameter"],
                          "z_top": h["z_top"], "z_bottom": h["z_bottom"], "through": h["through"], "access": acc,
                          "holder_depth": round(heights.point(len(floors) + i, h["x"], h["y"], h["z_bottom"]), 4)})

    # Triangles for highlighting, per face (work frame).
    per_face = [_face_triangles(f["face"]) for f in faces]
    named = {i for r in regions for i in r["faces"]} | {f["face"] for f in out_floors} \
        | {j for h in out_holes for j in h["faces"]} | {i for i, f in enumerate(faces) if f["boundary"]}
    keep = range(len(faces)) if sum(len(t) for t in per_face) <= TRIANGLE_BUDGET else sorted(named)
    ranges, chunks, first = [], [], 0
    for i in keep:
        t = per_face[i]
        if len(t):
            ranges.append([i, first, len(t)])
            chunks.append(t)
            first += len(t)
    tri_out = np.concatenate(chunks).astype(np.float32) if chunks else np.zeros((0, 3, 3), np.float32)
    return {"access": {"faces": out_faces, "regions": regions, "floors": out_floors, "holes": out_holes,
                       "part_min": pmin.tolist(), "part_max": pmax.tolist(), "face_triangles": ranges},
            "access_triangles": tri_out}
