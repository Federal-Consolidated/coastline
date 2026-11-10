import io
import math

import numpy as np
from pathlib import Path

import pytest

from coastline_engine.cad_import import import_part
from coastline_engine.measure import face_info
from coastline_engine.rpc import read_frame, serve, write_frame
from coastline_engine.server import HANDLERS

RES = Path(__file__).resolve().parents[2] / "resources"


def test_3dm_is_now_exact_with_tight_bounds():
    part = import_part(RES / "samples/end_mill_quarter_inch.3dm")
    assert part.exact and part.shape is not None
    lo, hi = part.bounds
    size = sorted(h - l for l, h in zip(lo, hi))
    assert size == pytest.approx([6.35, 6.35, 63.5], abs=0.01)
    assert not part.warnings


def test_face_info_finds_the_end_mill_shank_cylinder():
    part = import_part(RES / "samples/end_mill_quarter_inch.3dm")
    lo, hi = part.bounds
    # A point just outside the shank, halfway along the tool (tool axis is Y in this file).
    cx, cz = (lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2
    info = face_info(part.shape, (cx + 5, (lo[1] + hi[1]) / 2, cz))
    assert info["type"] in ("cylinder", "freeform")
    if info["type"] == "cylinder":
        assert info["radius"] == pytest.approx(3.175, abs=0.01)


def test_face_info_on_clamp_planes():
    part = import_part(RES / "fixtures/universal_clamp_v96.step")
    lo, hi = part.bounds
    info = face_info(part.shape, (lo[0] - 1, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2))
    assert info["type"] in ("plane", "cylinder")
    assert info["distance"] < 5


def test_machine_model_groups_and_axes(tmp_path):
    from coastline_engine.machine_model import load_machine

    parts = load_machine(RES / "machine/machine.step", tmp_path)
    groups = {p.group for p in parts}
    assert groups == {"static", "x", "y", "z"}
    assert any(p.role == "enclosure" for p in parts)
    total = sum(len(p.mesh.indices) for p in parts)
    assert 200_000 < total < 1_500_000
    # Cached second load returns the same meshes.
    again = load_machine(RES / "machine/machine.step", tmp_path)
    assert sum(len(p.mesh.indices) for p in again) == total


def test_rpc_import_returns_part_id_and_face_info():
    inp = io.BytesIO()
    write_frame(inp, {"id": 1, "method": "import_part", "params": {"path": str(RES / "fixtures/universal_clamp_v96.step")}})
    inp.seek(0)
    out = io.BytesIO()
    serve(HANDLERS, inp, out)
    out.seek(0)
    h, _ = read_frame(out)
    pid = h["result"]["part_id"]
    lo = h["result"]["bounds_min"]
    inp = io.BytesIO()
    write_frame(inp, {"id": 2, "method": "face_info", "params": {"part_id": pid, "point": [lo[0] - 1, lo[1] + 5, lo[2] + 5]}})
    inp.seek(0)
    out = io.BytesIO()
    serve(HANDLERS, inp, out)
    out.seek(0)
    h2, _ = read_frame(out)
    assert h2["result"]["type"] != "none"


# ---------------------------------------------------------------- mesher failures

def _thread_flank():
    """A modelled thread's flank: a ruled B-spline between two 20-turn helices (degree 9 along
    them), as threads come from CAD."""
    import math
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
    from OCP.GeomAPI import GeomAPI_PointsToBSpline
    from OCP.GeomAbs import GeomAbs_C2
    from OCP.GeomFill import GeomFill
    from OCP.collections import Array1_gp_Pnt
    from OCP.gp import gp_Pnt

    def helix(radius, turns=20, pitch=0.907, n=600):
        a = Array1_gp_Pnt(1, n)
        for k in range(n):
            t = 2 * math.pi * turns * k / (n - 1)
            a.SetValue(k + 1, gp_Pnt(radius * math.cos(t), radius * math.sin(t), pitch * t / (2 * math.pi)))
        return GeomAPI_PointsToBSpline(a, 9, 9, GeomAbs_C2, 1e-3).Curve()

    return BRepBuilderAPI_MakeFace(GeomFill.Surface_s(helix(5.7), helix(6.35)), 1e-6).Face()


def test_a_free_form_face_off_its_surface_is_meshed_again_on_a_grid():
    """OCCT's mesher leaves some thread flanks with triangles across whole turns: material in
    the bore where there is none. Such a face is found and meshed again as a UV grid on its
    surface."""
    from OCP.BRep import BRep_Tool
    from OCP.BRepMesh import BRepMesh_IncrementalMesh
    from OCP.TopLoc import TopLoc_Location

    from coastline_engine.cad_import import _grid, _off_surface

    face = _thread_flank()
    BRepMesh_IncrementalMesh(face, 0.05, False, 0.3, True)
    tri = BRep_Tool.Triangulation_s(face, TopLoc_Location())
    v = np.array([[tri.Node(i).X(), tri.Node(i).Y(), tri.Node(i).Z()] for i in range(1, tri.NbNodes() + 1)], np.float32)
    t = np.array([[a - 1 for a in tri.Triangle(i).Get()] for i in range(1, tri.NbTriangles() + 1)], np.uint32)
    # As the mesher's own: no triangle far off. One across half a turn (the failure) is found.
    assert not _off_surface(face, tri, v, t, limit=0.2)
    far = int(np.argmax(np.linalg.norm(v[:, :2] - v[0, :2], axis=1)[: tri.NbNodes() // 40]))
    broken = t.copy()
    broken[0] = (0, far, far + 1)
    assert _off_surface(face, tri, v, broken)
    # The grid: every vertex on the surface, every triangle within 0.05 mm of it, none across the bore.
    gv, gt = _grid(face, 0.01)
    centres = gv[gt].mean(axis=1)
    assert np.hypot(centres[:, 0], centres[:, 1]).min() > 5.6
    radius = np.hypot(gv[:, 0], gv[:, 1])
    assert radius.min() > 5.69 and radius.max() < 6.36
    assert len(gt) < 200_000
    # The triangles face the same way as the mesher's (the surface's own u x v).
    def normals(vv, tt):
        return np.cross(vv[tt[:, 1]] - vv[tt[:, 0]], vv[tt[:, 2]] - vv[tt[:, 0]])
    mine, theirs = normals(gv.astype(float), gt.astype(int)), normals(v.astype(float), t.astype(int))
    for k in range(0, len(t), max(len(t) // 20, 1)):
        c = v[t[k]].mean(axis=0)
        j = int(np.argmin(np.linalg.norm(centres - c, axis=1)))
        assert np.dot(mine[j], theirs[k]) > 0
