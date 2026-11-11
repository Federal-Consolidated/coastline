"""Engine entry point: `python -m coastline_engine.server`.

Each handler takes (params, blobs) and returns (result, blobs).
Add new engine features by adding a handler here.
"""

from __future__ import annotations

import itertools
import os
from pathlib import Path

import numpy as np

from . import __version__
from .cad_import import import_part
from .rpc import serve

# Imported parts by id, kept for exact queries (measuring now, CAM later).
PARTS: dict[str, object] = {}
_ids = itertools.count(1)
CACHE_DIR = Path.home() / "Library/Caches/Coastline"


def _mesh_blobs(m):
    return [
        np.ascontiguousarray(m.vertices, "<f4").tobytes(),
        np.ascontiguousarray(m.normals, "<f4").tobytes(),
        np.ascontiguousarray(m.indices, "<u4").tobytes(),
    ]


def _ping(params, blobs):
    import OCP
    import opencamlib

    return {
        "engine": __version__,
        "ocp": getattr(OCP, "__version__", "?"),
        "opencamlib": opencamlib.version(),
    }, []


def _import_part(params, blobs):
    """params: {path, linear_deflection?} → mesh as 3 blobs (vertices, normals, indices)."""
    part = import_part(params["path"], params.get("linear_deflection", 0.01))
    part_id = f"p{next(_ids)}"
    PARTS[part_id] = part
    lo, hi = part.bounds
    m = part.mesh
    return {
        "part_id": part_id,
        "kind": part.kind,
        "exact": part.exact,
        "face_count": part.face_count,
        "bounds_min": lo,
        "bounds_max": hi,
        "vertex_count": len(m.vertices),
        "triangle_count": len(m.indices),
        "warnings": part.warnings,
    }, _mesh_blobs(m)


def _face_info(params, blobs):
    """params: {part_id, point: [x, y, z]} in the part's own coordinates."""
    from .measure import face_info

    part = PARTS.get(params["part_id"])
    if part is None or part.shape is None:
        return {"type": "none", "reason": "no exact geometry"}, []
    return face_info(part.shape, tuple(params["point"])), []


def _fixture_solids(params, blobs):
    """Separate closed solids so overlapping screws/washers are unioned, never XORed,
    when the planner checks whether a fixture fits the remaining material."""
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.TopAbs import TopAbs_FACE, TopAbs_SOLID
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopoDS import TopoDS
    from .cad_import import tessellate

    part = PARTS[params["part_id"]]
    if part.shape is None:
        raise ValueError("Automatic fixture planning needs a closed-solid STEP, IGES or exact Rhino assembly.")
    def count_faces(shape):
        ex, count = TopExp_Explorer(shape, TopAbs_FACE), 0
        while ex.More():
            count += 1
            ex.Next()
        return count
    ex = TopExp_Explorer(part.shape, TopAbs_SOLID)
    solids, out, faces = [], [], 0
    while ex.More():
        solid = TopoDS.Solid(ex.Current())
        if not BRepCheck_Analyzer(solid).IsValid():
            raise ValueError("The fixture contains an invalid solid. Repair the CAD before enabling automatic planning.")
        mesh, _ = tessellate(solid, 0.01)
        lo, hi = mesh.bounds
        n = count_faces(solid)
        solids.append(dict(bounds_min=lo, bounds_max=hi, face_count=n))
        out += _mesh_blobs(mesh)
        faces += n
        ex.Next()
    if not solids or faces != count_faces(part.shape):
        raise ValueError("Every fixture surface must belong to a closed solid; open surfaces cannot define occupied volume.")
    return {"solids": solids}, out


def _fixture_assembly(params, blobs):
    from .fixture_assembly import load_fixture_assembly
    part = PARTS[params["part_id"]]
    parts = load_fixture_assembly(part.path, params["definition"])
    out = []
    for _, mesh in parts:
        out += _mesh_blobs(mesh)
    return {"parts": [metadata for metadata, _ in parts]}, out


def _machine_model(params, blobs):
    """Legacy {path}, or portable {manifestPath, machinePosition?}, with three blobs per part.

    Profile meshes remain at their authored reference pose. Per-component translations
    describe the requested controller position; no legacy frame assumptions are added.
    """
    from .machine_model import MODEL_POSE, SPINDLE_NOSE, TABLE_TOP_X, TSLOT_Z, load_machine, load_profile_machine

    if "manifestPath" in params:
        if "path" in params:
            raise ValueError("Choose a machine manifest or a legacy STEP path, not both.")
        parts, definition = load_profile_machine(params["manifestPath"], params.get("cache_dir", CACHE_DIR))
        out = []
        for part in parts:
            out += _mesh_blobs(part.mesh)
        return {
            "parts": [{"group": p.group, "role": p.role, "color": list(p.color)} for p in parts],
            "profile": definition.metadata(),
            "group_translations": definition.translations(params.get("machinePosition")),
            "reference_pose": params.get("machinePosition") is None,
        }, out

    parts = load_machine(params["path"], params.get("cache_dir", CACHE_DIR))
    out = []
    for p in parts:
        out += _mesh_blobs(p.mesh)
    return {
        "parts": [{"group": p.group, "role": p.role, "color": list(p.color)} for p in parts],
        "spindle_nose": list(SPINDLE_NOSE),
        "table_top_x": TABLE_TOP_X,
        "tslot_z": list(TSLOT_Z),
        "model_pose": list(MODEL_POSE),
    }, out


def _work_transform(params) -> np.ndarray:
    return np.asarray(params["transform"], float).reshape(4, 4)  # row-major part → work


def _features(params, blobs):
    """params: {part_id, transform} → holes along the tool axis and flat up-facing floors."""
    from .cam import geometry as g
    from .cam.features import find_features, transformed

    part = PARTS[params["part_id"]]
    if part.shape is None:
        return {"holes": [], "floors": [], "exact": False}, []
    m = _work_transform(params)
    geo = g.PartGeometry(part.mesh.vertices, part.mesh.indices, m)
    f = find_features(transformed(part.shape, m), geo.zmin)
    return {"holes": f["holes"], "floors": [{"z": fl["z"], "area": fl["area"], "width": _inscribed(fl["paths"])} for fl in f["floors"]],
            "part_z": [geo.zmin, geo.zmax], "pockets": _pocket_widths(geo), "exact": True}, []


def _inscribed(paths) -> float:
    """The widest circle that fits a region (pyclipper paths), mm (its diameter)."""
    from .cam import geometry as g
    if not paths:
        return 0.0
    lo, hi = 0.0, 50.0
    for _ in range(14):
        mid = (lo + hi) / 2
        if g.offset(paths, -mid):
            lo = mid
        else:
            hi = mid
    return round(2 * lo, 3)


def _pocket_widths(geo) -> list:
    """The widest circle that fits each pocket in the part's outline (through holes and
    recesses: holes in the silhouette at the bottom and halfway up), mm, narrowest first."""
    from .cam import geometry as g
    out = []
    for z in ((geo.zmin + geo.zmax) / 2,):  # halfway up: through holes and deep recesses, once each
        _, holes = g.outer_and_holes(geo.shadow(z))
        for h in holes:
            lo, hi = 0.0, 50.0
            for _ in range(14):  # the largest inward offset that leaves something: the inscribed radius
                mid = (lo + hi) / 2
                if g.offset([h], -mid):
                    lo = mid
                else:
                    hi = mid
            out.append(round(2 * lo, 3))
    return sorted(out)


# Curved faces' footprint per (part, work transform): which areas 3D finishing has to cover.
_FREEFORM: dict = {}


def _windowed(feats, window, g):
    """The holes whose centre and the floors whose outline lie inside window (x0, y0, x1, y1)."""
    if not window:
        return feats
    x0, y0, x1, y1 = map(float, window)
    def inside(x, y):
        return x0 - 1e-6 <= x <= x1 + 1e-6 and y0 - 1e-6 <= y <= y1 + 1e-6
    floors = []
    for f in feats["floors"]:
        pts = [p for path in f["paths"] for p in g.to_mm(path)]
        if pts and all(inside(p[0], p[1]) for p in pts):
            floors.append(f)
    return {"holes": [h for h in feats["holes"] if inside(h["x"], h["y"])], "floors": floors}


def _generate(params, blobs):
    """params: {part_id, transform, stock_min, stock_max, safe_z, ops: [...], tabs?} → one move blob
    per operation (float32 rows: role, motion, x, y, z, i, j, feed)."""
    from .cam import geometry as g
    from .cam import ops as O
    from .cam.features import find_features, transformed
    from .cam.toolpath import Toolpath

    part = PARTS[params["part_id"]]
    if os.environ.get("COASTLINE_OP_DUMP"):  # debugging: replay a job offline
        import pickle
        with open(os.environ["COASTLINE_OP_DUMP"] + f"_{params['ops'][0]['kind']}_{len(os.listdir(os.path.dirname(os.environ['COASTLINE_OP_DUMP']) or '.'))}.pkl", "wb") as fh:
            pickle.dump({"params": params, "path": part.path}, fh)
    m = _work_transform(params)
    geo = g.PartGeometry(part.mesh.vertices, part.mesh.indices, m)
    smin, smax = params["stock_min"], params["stock_max"]
    safe = float(params.get("safe_z", 3.0))
    feats = {"holes": [], "floors": []}
    kinds = {o["kind"] for o in params["ops"]}
    if part.shape is not None and kinds & {"floor", "drill", "bore", "adaptive", "thread"}:
        feats = find_features(transformed(part.shape, m), geo.zmin)
    floor_z = [f["z"] for f in feats["floors"]]
    # Holding tabs at the bottom of a through-cut: {count, width, height, z_bottom}.
    tab_out = []
    lift = None
    skin_top = None
    if params.get("tabs"):
        import pyclipper
        from .cam import tabs as T
        tp_ = params["tabs"]
        zb, h = float(tp_["z_bottom"]), float(tp_["height"])
        # Past the roughing channel into the frame; the app sends one length for the whole side
        # (every operation must see the same tabs).
        reach = float(tp_.get("reach") or (max([float(o["tool"]["diameter"]) for o in params["ops"]] + [3.0]) * 1.6 + 3.75))
        placed = T.place_tabs(geo, zb + h / 2, int(tp_["count"]), float(tp_["width"]), reach,
                              stock=((smin[0], smin[1]), (smax[0], smax[1])),
                              frame=T.Frame(tp_["frame"]) if tp_.get("frame") and not os.environ.get("COASTLINE_NO_TAB_FRAME") else None,
                              avoid=[tuple(map(float, a)) for a in tp_.get("avoid") or []],
                              within_x=tuple(map(float, tp_["within_x"])) if tp_.get("within_x") else None)
        # No further than the stock: past its edge a tab is air (and the finishing would ride
        # on it into the clamped strips).
        stock_box = g.to_int(g.rect(smin[0] + 0.2, smin[1] + 0.2, smax[0] - 0.2, smax[1] - 0.2))
        for t in placed:
            pc = pyclipper.Pyclipper()
            pc.AddPath(g.to_int(t["poly"]), pyclipper.PT_SUBJECT, True)
            pc.AddPath(stock_box, pyclipper.PT_CLIP, True)
            inside = pc.Execute(pyclipper.CT_INTERSECTION, pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
            if inside:
                t["poly"] = g.to_mm(max(inside, key=lambda q: abs(pyclipper.Area(q))))
        lift_mode = bool(tp_.get("lift"))
        if lift_mode:
            # One side, cut through: tabs are gaps the contour lifts over (not part geometry
            # the tools go round), bridging the slot into the skin the roughing left.
            lift = (placed, zb, zb + h)
        else:
            T.attach(geo, placed, zb - 1.0, zb + h)
        tab_out = [{"centre": t["centre"], "normal": t["normal"], "poly": t["poly"].tolist()} for t in placed]
    drill_ds = [float(o["tool"]["diameter"]) for o in params["ops"] if o["kind"] == "drill"]

    results, out = [], []
    all_feats = feats
    for raw in params["ops"]:
        op = O.Op(raw)
        # The approach height follows the clearance (below the original face after a facing).
        tp = Toolpath(safe_z=safe, approach_z=min(1.0, safe - 2.0))
        k = op.kind
        # A setup from a side cuts only its own features: holes and floors inside its window
        # (work X/Y min, max). Roughing is kept to it by keep-out rectangles.
        feats = _windowed(all_feats, raw.get("window"), g)
        if k == "facing":
            O.facing(op, smin, smax, tp)
        elif k == "adaptive":
            O.adaptive(op, geo, smin, smax, floor_z, tp, z_top=op.z_top)
        elif k == "contour":
            if lift is not None:
                skin_top = float(params["tabs"].get("skin_top")) if params["tabs"].get("skin_top") is not None else None
            O.contour(op, geo, smin, tp, z_top=op.z_top, lift=lift, skin_top=skin_top, stock_max=smax)
        elif k == "floor":
            O.floors(op, feats["floors"], tp)
        elif k == "drill":
            hs = [h for h in feats["holes"] if abs(h["diameter"] - op.tool_d) <= 0.05]
            O.drill(op, hs, tp, float(raw["tool"].get("angle") or 118))
        elif k in ("parallel", "waterline", "steep_shallow", "scallop", "spiral", "radial", "rest"):
            from .cam import surface3d as S3
            if k != "rest" and part.shape is not None:
                key = (params["part_id"], tuple(np.round(m.ravel(), 6)))
                if key not in _FREEFORM:
                    from .cam.analysis import freeform_footprint
                    _FREEFORM[key] = freeform_footprint(transformed(part.shape, m))
                op.params = dict(op.params or {}, freeform_mask=_FREEFORM[key])
            S3.finish(op, geo, smin, smax, tp, k, op.params)
        elif k == "engrave":
            from .cam import surface3d as S3
            S3.engrave(op, geo, tp, raw.get("curves") or [], float(raw.get("engrave_depth", 0.15)))
        elif k == "thread":
            th = raw.get("thread") or {}
            hs = [h for h in feats["holes"] if float(th.get("hole_min", 0)) <= h["diameter"] <= float(th.get("hole_max", 0))]
            if not hs:
                tp.warnings.append(f"No hole to thread: an M{th.get('major', 0):g} thread needs a hole of about "
                                   f"\u2300{float(th.get('hole_max', 0.08)) - 0.08:.2f} mm.")
            O.thread(op, hs, tp, float(th["major"]), float(th["pitch"]), float(th["depth"]) if th.get("depth") else None)
        elif k == "bore" and raw.get("holes") is not None:
            O.bore(op, list(raw["holes"]), tp)  # given circles (reference bores), not the part's
        elif k == "bore":
            hs = [h for h in feats["holes"]
                  if h["diameter"] > op.tool_d + 0.1 and not any(abs(h["diameter"] - d) <= 0.05 for d in drill_ds)]
            st = params["tabs"].get("skin_top") if (lift is not None and params.get("tabs")) else None
            O.bore(op, hs, tp, skin_top=float(st) if st is not None else None)
        else:
            tp.warnings.append(f"{k} isn't available yet.")
        arr = tp.array()
        # Holder clearance: the shortest stick-out that keeps the ER-11 nut clear of the part and
        # of the uncut frame around the clearing band.
        need = None
        if len(arr) and k not in ("facing",):
            from .cam import surface3d as S3
            band, _ = g.outer_and_holes(g.offset(geo.shadow(geo.zmin), op.band if op.band is not None else op.tool_d + 1.0))
            need = float(S3.min_stickout(geo, arr, op.frame_top, band))
            if op.stickout and need > op.stickout + 1e-6:
                tp.warnings.append(f"The collet nut would hit the work: this needs at least {need:.1f} mm stick-out "
                                   f"(set {op.stickout:.1f} mm).")
        results.append({"id": op.id, "moves": len(arr), "warnings": tp.warnings, "min_stickout": need})
        out.append(arr.astype("<f4").tobytes())
    return {"ops": results, "part_z": [geo.zmin, geo.zmax],
            "holes": len(feats["holes"]), "floors": len(feats["floors"]), "tabs": tab_out}, out


def _analyse(params, blobs):
    """params: {part_id, transform, thin_threshold?, access?, nut_radius?} → limits for machining
    from +Z, plus undercut triangles (blob 0). With access: also "access" (line of sight per
    face, regions, floors and holes with wall and holder depths; cam/analysis.part_access) and
    the faces' triangles (blob 1, ranges in access.face_triangles)."""
    from .cam import geometry as g
    from .cam.analysis import analyse
    from .cam.features import transformed

    part = PARTS[params["part_id"]]
    if part.shape is None:
        return {"exact": False}, [b""]
    m = _work_transform(params)
    geo = g.PartGeometry(part.mesh.vertices, part.mesh.indices, m)
    access = bool(params.get("access", False))
    r = analyse(transformed(part.shape, m), geo, float(params.get("thin_threshold", 0.8)),
                access=access, nut_radius=float(params.get("nut_radius", 8.0)))
    out = [np.ascontiguousarray(r.pop("undercut_triangles"), "<f4").tobytes()]
    if access:
        out.append(np.ascontiguousarray(r.pop("access_triangles"), "<f4").tobytes())
    return dict(r, exact=True), out


def _recognise(params, blobs):
    """Named features (quiddity) for a STEP file by path: slow on busy parts, so the app asks a
    separate engine process."""
    from .cam.recognition import recognise
    return recognise(params["path"]), []


HANDLERS = {
    "recognise": _recognise,
    "ping": _ping,
    "import_part": _import_part,
    "face_info": _face_info,
    "fixture_solids": _fixture_solids,
    "fixture_assembly": _fixture_assembly,
    "machine_model": _machine_model,
    "features": _features,
    "generate": _generate,
    "analyse": _analyse,
}


def main() -> None:
    # stdout carries the RPC frames. Native code (FreeCAD's Adaptive, OCCT) prints progress to
    # stdout, which would corrupt them, so the frames get a private copy of fd 1 and fd 1 is
    # pointed at stderr for everyone else.
    import os
    import sys

    from .watchdog import exit_with_parent
    exit_with_parent()
    rpc_out = os.fdopen(os.dup(1), "wb", buffering=0)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    serve(HANDLERS, sys.stdin.buffer, rpc_out)


if __name__ == "__main__":
    main()
