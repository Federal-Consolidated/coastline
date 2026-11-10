"""Line of sight, floors and holes for DFM, on the reference coupon (known answers).

The coupon (resources/samples/dfm_coupon.step, scripts/make-dfm-coupon.py) is analysed as the
app does: the default orientation turns its feature face to +Z, top at Z = 0.
"""

import importlib.util
import json
from pathlib import Path

import numpy as np
import pytest
from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder
from OCP.gp import gp_Ax2, gp_Dir, gp_Pnt

from coastline_engine.cad_import import ImportedPart, import_part, tessellate
from coastline_engine.cam import geometry as g
from coastline_engine.cam.analysis import analyse
from coastline_engine.server import PARTS, _analyse

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("make_dfm_coupon", ROOT / "scripts/make-dfm-coupon.py")
coupon = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(coupon)

LEGACY_KEYS = {"min_corner_radius", "min_concave_radius", "undercut_area", "thinnest_wall", "depth", "parting_z",
               "freeform_area", "flat_area", "wall_area", "steep_area", "volume", "circularity", "zmax", "exact"}


def _run(part, m, **params):
    PARTS["dfm"] = part
    try:
        return _analyse(dict(part_id="dfm", transform=np.asarray(m).ravel().tolist(), **params), [])
    finally:
        PARTS.pop("dfm", None)


@pytest.fixture(scope="module")
def part():
    return import_part(coupon.OUT)


@pytest.fixture(scope="module")
def work(part):
    lo, hi = part.bounds
    return coupon.work_transform(lo, hi, coupon.default_axis(lo, hi))


@pytest.fixture(scope="module")
def result(part, work):
    r, blobs = _run(part, work, access=True, nut_radius=8.0)
    return r, blobs


def _floor(a, width):
    found = [f for f in a["floors"] if abs(f["width"] - width) < 0.05]
    assert len(found) == 1, a["floors"]
    return found[0]


def test_coupon_is_the_owned_block_size_with_features_on_the_default_face(part):
    lo, hi = part.bounds
    assert np.allclose(np.subtract(hi, lo), [203.2, 50.8, 50.8], atol=1e-6)
    assert coupon.default_axis(lo, hi) == coupon.FEATURE_AXIS == 1
    rebuilt, _ = tessellate(coupon.build(), 0.05)  # the builder still makes the same block
    assert np.allclose(rebuilt.bounds[1], hi, atol=1e-4) and np.allclose(rebuilt.bounds[0], lo, atol=1e-4)


def test_without_access_the_result_is_as_before(part, work):
    r, blobs = _run(part, work)
    assert set(r) == LEGACY_KEYS and len(blobs) == 1


def test_result_is_plain_json_with_one_triangle_range_per_face(result):
    r, blobs = result
    json.dumps(r, allow_nan=False)
    a = r["access"]
    assert len(blobs) == 2
    tris = np.frombuffer(blobs[1], "<f4").reshape(-1, 3, 3)
    assert sum(n for _, _, n in a["face_triangles"]) == len(tris)
    ranges = {i: (first, n) for i, first, n in a["face_triangles"]}
    named = {i for reg in a["regions"] for i in reg["faces"]} | {f["face"] for f in a["floors"]} \
        | {i for h in a["holes"] for i in h["faces"]} | {f["index"] for f in a["faces"] if f["boundary"]}
    assert named <= set(ranges)
    # The back recess's triangles are where its region says (work frame).
    reg = next(x for x in a["regions"] if x["access"] == "opposite")
    pts = np.concatenate([tris[ranges[i][0]:ranges[i][0] + ranges[i][1]].reshape(-1, 3) for i in reg["faces"]])
    assert np.all(pts >= np.array(reg["min"]) - 0.01) and np.all(pts <= np.array(reg["max"]) + 0.01)
    assert np.allclose(a["part_min"], [-25.4, -101.6, -50.8], atol=1e-6)
    assert np.allclose(a["part_max"], [25.4, 101.6, 0.0], atol=1e-6)


def test_the_six_outer_faces_are_boundaries(result):
    a = result[0]["access"]
    b = {f["boundary"]: f for f in a["faces"] if f["boundary"]}
    assert sorted(b) == sorted(["+x", "-x", "+y", "-y", "+z", "-z"])
    assert len([f for f in a["faces"] if f["boundary"]]) == 6
    for name, f in b.items():
        axis = "xyz".index(name[1])
        want = a["part_max"][axis] if name[0] == "+" else a["part_min"][axis]
        assert f["plane_offset"] == pytest.approx(want, abs=1e-6) and f["kind"] == "plane"
    assert b["-z"]["access"] == "opposite"
    assert all(b[n]["access"] == "this" for n in ("+z", "+x", "-x", "+y", "-y"))


def test_floors_have_width_wall_and_holder_depth(result):
    a = result[0]["access"]
    assert len(a["floors"]) == 3, "F1, F2, F3; not the top, the closed cavity or the side groove"
    for width, depth in ((20.0, 8.0), (6.0, 30.0), (2.0, 8.0)):  # F1, F2, F3
        f = _floor(a, width)
        assert f["z"] == pytest.approx(-depth, abs=1e-6)
        assert f["wall_depth"] == pytest.approx(depth, abs=0.05)
        assert f["holder_depth"] == pytest.approx(depth + 1, abs=0.05)
        assert a["faces"][f["face"]]["access"] == "this"
    assert _floor(a, 20.0)["area"] == pytest.approx(30 * 20 - (4 - np.pi) * 16, abs=0.01)


def test_drilled_hole(result):
    a = result[0]["access"]
    assert len(a["holes"]) == 1
    h = a["holes"][0]
    assert h["diameter"] == pytest.approx(6.35, abs=1e-6)
    assert h["z_top"] == pytest.approx(0, abs=1e-6) and h["z_bottom"] == pytest.approx(-20, abs=1e-6)
    assert not h["through"] and h["access"] == "this"
    assert h["holder_depth"] == pytest.approx(21, abs=0.05)
    assert sorted(a["faces"][i]["kind"] for i in h["faces"]) == ["cylinder", "other"], "the wall and the drill point"
    assert result[0]["min_concave_radius"] is None, "the drill point is the drill's shape, not a curve for a ball mill"


def test_regions_back_recess_closed_cavity_and_side_groove(result):
    a = result[0]["access"]
    regs = {r["access"]: r for r in a["regions"]}
    assert len(a["regions"]) == 3 and set(regs) == {"opposite", "none", "other"}
    back = regs["opposite"]  # F5: 20 × 20, 3 deep from the bottom
    assert back["directions"] == ["-z"]
    assert back["min"][2] == pytest.approx(-50.8, abs=1e-6) and back["max"][2] == pytest.approx(-47.8, abs=1e-6)
    cavity = regs["none"]  # F6: the 36 × 12 cavity under the neck
    assert cavity["directions"] == []
    assert np.subtract(cavity["max"], cavity["min"]) == pytest.approx([12, 36, 4], abs=1e-6)
    groove = regs["other"]  # F7: open only to its side face (work +X in the default setup)
    assert groove["directions"] == ["+x"]
    assert np.subtract(groove["max"], groove["min"]) == pytest.approx([3, 40, 3], abs=1e-6)
    for r in a["regions"]:
        assert all(a["faces"][i]["boundary"] is None and a["faces"][i]["access"] != "this" for i in r["faces"])
    # The neck itself is seen from +Z: not part of the cavity's region.
    assert all(f["access"] == "this" for f in a["faces"] if f["index"] not in
               {i for r in a["regions"] for i in r["faces"]} and f["boundary"] is None)


def test_turning_the_part_over_changes_the_findings(part, work):
    flip = np.diag([1.0, -1.0, -1.0, 1.0]) @ work  # feature face down
    flip[2, 3] -= 50.8                               # top back at Z = 0
    a = _run(part, flip, access=True)[0]["access"]
    back = _floor(a, 20.0)  # F5's 20 × 20 recess is now a floor seen from the top...
    assert back["wall_depth"] == pytest.approx(3, abs=0.05) and back["holder_depth"] == pytest.approx(4, abs=0.05)
    assert all(abs(f["width"] - 6.0) > 0.05 for f in a["floors"])  # ...and F2 is not
    assert any(r["access"] == "opposite" and len(r["faces"]) >= 4 for r in a["regions"])
    assert a["holes"][0]["access"] == "opposite"


def test_corner_radius_ignores_a_full_hole():
    """A 2 mm hole (R1) and a pocket with R1.5 corners: the hole isn't an inside corner."""
    from OCP.BRepFilletAPI import BRepFilletAPI_MakeFillet
    from OCP.BRepAdaptor import BRepAdaptor_Curve
    from OCP.TopAbs import TopAbs_EDGE
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopoDS import TopoDS

    body = BRepPrimAPI_MakeBox(gp_Pnt(0, 0, -8), 30, 20, 8).Shape()
    pocket = BRepPrimAPI_MakeBox(gp_Pnt(4, 5, -4), 10, 10, 5).Shape()
    f = BRepFilletAPI_MakeFillet(pocket)
    e = TopExp_Explorer(pocket, TopAbs_EDGE)
    while e.More():
        ed = TopoDS.Edge(e.Current())
        c = BRepAdaptor_Curve(ed)
        a, b = c.Value(c.FirstParameter()), c.Value(c.LastParameter())
        if abs(a.X() - b.X()) < 1e-6 and abs(a.Y() - b.Y()) < 1e-6:
            f.Add(1.5, ed)
        e.Next()
    body = BRepAlgoAPI_Cut(body, f.Shape()).Shape()
    hole = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(22, 10, -9), gp_Dir(0, 0, 1)), 1.0, 10).Shape()
    body = BRepAlgoAPI_Cut(body, hole).Shape()
    mesh, _ = tessellate(body, 0.01)
    r = analyse(body, g.PartGeometry(mesh.vertices, mesh.indices, np.eye(4)))
    assert r["min_corner_radius"] == pytest.approx(1.5, abs=1e-6)
    assert r["thinnest_wall"] is None, "sharp outside corners are not thin walls"


def test_concave_radius_ignores_a_holes_countersink_but_not_a_lone_cone():
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeCone

    def run(with_hole):
        body = BRepPrimAPI_MakeBox(gp_Pnt(0, 0, -10), 20, 20, 10).Shape()
        cone = BRepPrimAPI_MakeCone(gp_Ax2(gp_Pnt(10, 10, -3), gp_Dir(0, 0, 1)), 0.0, 4.0, 4.0).Shape()
        body = BRepAlgoAPI_Cut(body, cone).Shape()  # a conical dimple, 3 deep at the axis
        if with_hole:
            hole = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(10, 10, -11), gp_Dir(0, 0, 1)), 1.5, 12).Shape()
            body = BRepAlgoAPI_Cut(body, hole).Shape()  # now a countersunk through hole
        mesh, _ = tessellate(body, 0.01)
        return analyse(body, g.PartGeometry(mesh.vertices, mesh.indices, np.eye(4)))["min_concave_radius"]

    assert run(with_hole=False) is not None
    assert run(with_hole=True) is None


def test_holder_depth_sees_a_tall_neighbour_within_the_nut_radius():
    """A pocket in a low step, 15 mm from a tower: the wall is the step, but a big nut must
    also clear the tower."""
    body = BRepPrimAPI_MakeBox(gp_Pnt(-30, -20, -20), 60, 40, 10).Shape()           # low step, top -10
    tower = BRepPrimAPI_MakeBox(gp_Pnt(10, -20, -20), 20, 40, 20).Shape()           # top 0, x 10..30
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Fuse
    from OCP.ShapeUpgrade import ShapeUpgrade_UnifySameDomain
    body = BRepAlgoAPI_Fuse(body, tower).Shape()
    body = BRepAlgoAPI_Cut(body, BRepPrimAPI_MakeBox(gp_Pnt(-15, -5, -15), 10, 10, 6).Shape()).Shape()  # x -15..-5
    u = ShapeUpgrade_UnifySameDomain(body, True, True, True)
    u.Build()
    body = u.Shape()
    mesh, _ = tessellate(body, 0.01)
    part = ImportedPart("tower.step", "step", mesh, body, 0, True)
    for nut, holder in ((8.0, 6.0), (20.0, 16.0)):
        a = _run(part, np.eye(4), access=True, nut_radius=nut)[0]["access"]
        pocket = next(f for f in a["floors"] if f["z"] == pytest.approx(-15, abs=1e-6))
        assert pocket["wall_depth"] == pytest.approx(5, abs=0.05)
        assert pocket["holder_depth"] == pytest.approx(holder, abs=0.05), nut
        assert pocket["width"] == pytest.approx(10, abs=0.01)
        assert pocket["enclosed"] >= 0.95, "walls all round: a closed pocket"
    assert all(f["z"] < -1e-3 for f in a["floors"]), "the part top is not a floor"
    step = next(f for f in a["floors"] if f["z"] == pytest.approx(-10, abs=1e-6))
    assert step["enclosed"] < 0.5, "the low step has the tower on one side only"


def _grooved_bore():
    """A 40 mm block with a ⌀8 bore along Y through it and a ⌀12 groove, 2 wide, in its middle:
    the groove is hidden from every side; the bore's halves are seen from their ends."""
    body = BRepPrimAPI_MakeBox(gp_Pnt(-20, -20, -20), 40, 40, 20).Shape()
    bore = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0, -25, -10), gp_Dir(0, 1, 0)), 4, 50).Shape()
    groove = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0, -1, -10), gp_Dir(0, 1, 0)), 6, 2).Shape()
    body = BRepAlgoAPI_Cut(BRepAlgoAPI_Cut(body, bore).Shape(), groove).Shape()
    mesh, _ = tessellate(body, 0.01)
    return ImportedPart("grooved.step", "step", mesh, body, 0, True)


def test_a_hidden_groove_does_not_make_the_bore_round_it_hidden():
    a = _run(_grooved_bore(), np.eye(4), access=True)[0]["access"]
    kinds = {r["access"]: [] for r in a["regions"]}
    for r in a["regions"]:
        kinds[r["access"]].append(r)
    # The groove alone has no straight path: one region, 2 mm along Y.
    assert len(kinds["none"]) == 1
    groove = kinds["none"][0]
    assert groove["max"][1] - groove["min"][1] == pytest.approx(2, abs=1e-6)
    assert "thread" not in groove  # one radius of plain cylinder: not a thread
    # Each half of the bore is its own region, reached from its own end, about 19 mm deep.
    halves = sorted(kinds["other"], key=lambda r: r["min"][1])
    assert len(halves) == 2
    for r, side in zip(halves, ("-y", "+y")):
        assert side in r["directions"]
        assert r["sides"][0]["side"] == side and r["sides"][0]["share"] == 1
        assert 17 <= r["sides"][0]["depth"] <= 19 + 1e-6
        assert r["sides_two"] == r["sides"]  # the back sees none of it


def test_a_thread_is_found_by_its_shape():
    """Crest and root cylinders round one line along Y, a helical face between: a thread,
    entered from the end it opens on, 18 mm deep."""
    from OCP.BRepAdaptor import BRepAdaptor_Surface
    from OCP.TopAbs import TopAbs_FACE
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopoDS import TopoDS
    from coastline_engine.cam.analysis import _thread
    from coastline_engine.cam.features import _bounds

    def side_face(r, x=0.0):
        solid = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(x, 67, -25), gp_Dir(0, 1, 0)), r, 18).Shape()
        ex = TopExp_Explorer(solid, TopAbs_FACE)
        while ex.More():
            f = TopoDS.Face(ex.Current())
            s = BRepAdaptor_Surface(f)
            if s.GetType().name == "GeomAbs_Cylinder":
                lo, hi = _bounds(f)
                return {"kind": "cylinder", "surf": s, "min": lo, "max": hi}
            ex.Next()

    pmin, pmax = np.array([-25.4, -85, -50.8]), np.array([25.4, 85, 0])
    helix = {"kind": "other", "min": (-6.4, 67, -31.4), "max": (6.4, 85, -18.6)}
    t = _thread([side_face(5.7), side_face(6.4), helix], pmin, pmax)
    assert t is not None
    assert t["sides"][0] == {"side": "+y", "depth": 18.0, "open": True}
    assert t["major"] == pytest.approx(12.8) and t["minor"] == pytest.approx(11.4) and t["length"] == pytest.approx(18)
    # Off the axis, or a plain bore of one radius with no helix: not a thread.
    assert _thread([side_face(5.7), side_face(6.4, x=1.0), helix], pmin, pmax) is None
    assert _thread([side_face(5.7), side_face(5.7)], pmin, pmax) is None
