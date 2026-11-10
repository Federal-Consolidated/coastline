"""A setup from a side cuts only the features inside its window (SideCuts in the app)."""
import numpy as np
import pytest

from coastline_engine.cad_import import import_part
from coastline_engine.server import PARTS, _generate


@pytest.fixture(scope="module")
def pid(tmp_path_factory):
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut
    from OCP.gp import gp_Ax2, gp_Dir, gp_Pnt
    from OCP.STEPControl import STEPControl_AsIs, STEPControl_Writer
    # A 20 × 40 × 10 block (X × Y × Z) with two blind ⌀5 holes into its +X side, and a
    # ⌀4 hole down from its top.
    body = BRepPrimAPI_MakeBox(gp_Pnt(-10, -20, 0), 20, 40, 10).Shape()
    for y in (-10, 10):
        h = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(10.5, y, 5), gp_Dir(-1, 0, 0)), 2.5, 8.5).Shape()
        body = BRepAlgoAPI_Cut(body, h).Shape()
    top = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0, 0, -1), gp_Dir(0, 0, 1)), 2.0, 12).Shape()
    body = BRepAlgoAPI_Cut(body, top).Shape()
    path = tmp_path_factory.mktemp("side") / "block.step"
    w = STEPControl_Writer(); w.Transfer(body, STEPControl_AsIs); w.Write(str(path))
    PARTS["side-block"] = import_part(path)
    return "side-block"


# Turned so the part's +X side faces the spindle: part X → work Z, part Z → work −X, its
# +X face at Z0.
M = np.array([[0, 0, -1, 5], [0, 1, 0, 0], [1, 0, 0, -10], [0, 0, 0, 1]], float)
STOCK_MIN, STOCK_MAX = [-5, -20, -20], [5, 20, 0]


def _op(kind, d, **extra):
    op = {"id": kind, "kind": kind, "tool": {"diameter": d, "flute_length": 15, "kind": "flatEndMill"},
          "data": {"feed": 500, "plunge_feed": 150, "ramp_feed": 400, "stepdown": 1.0, "stepover": 0.4, "ramp_angle": 2},
          "leave_radial": 0, "leave_axial": 0}
    op.update(extra)
    return op


def _run(ops):
    r, blobs = _generate({"part_id": "side-block", "transform": M.flatten().tolist(), "stock_min": STOCK_MIN,
                          "stock_max": STOCK_MAX, "safe_z": 3, "ops": ops}, [])
    return r, [np.frombuffer(b, "<f4").reshape(-1, 8) for b in blobs]


def test_only_the_holes_in_the_window_are_drilled(pid):
    r, _ = _run([_op("drill", 5.0)])
    assert r["holes"] == 2                                  # both side holes, seen from this side
    _, rows = _run([_op("drill", 5.0, window=[-5, 5, 5, 15])])
    cuts = rows[0][rows[0][:, 0] != 0]
    assert len(cuts) and np.allclose(cuts[:, 3], 10, atol=1e-3)   # only the hole at Y 10
    assert cuts[:, 4].min() == pytest.approx(-8, abs=0.6)          # to its bottom, 8 mm in


def test_roughing_stays_inside_its_window(pid):
    keep = [[-60, -60, -6, 60], [6, -60, 60, 60], [-6, -60, 6, 4], [-6, 16, 6, 60]]
    _, rows = _run([_op("adaptive", 3.0, window=[-6, 4, 6, 16], z_min=-8.2, side_cavity=True,
                         keep_out={"below": 1, "rects": keep})])
    cut = rows[0][(rows[0][:, 0] != 0) & (rows[0][:, 4] < -0.05)]
    assert len(cut)
    assert cut[:, 3].min() >= 4 - 1e-3 and cut[:, 3].max() <= 16 + 1e-3     # Y inside the window
    assert cut[:, 2].min() >= -6 - 1e-3 and cut[:, 2].max() <= 6 + 1e-3


def test_roughing_from_a_side_clears_its_step_and_leaves_the_rest(tmp_path):
    """A step open to the part's edge, seen from the side, is cleared; the stock around the part's
    outline (the other setups' faces) is not, and it's quick (the old way took minutes)."""
    import time
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut
    from OCP.gp import gp_Pnt
    from OCP.STEPControl import STEPControl_AsIs, STEPControl_Writer
    # 60 × 100 × 20, a 5 deep, 10 tall step into its +X side along Y −20…20, open to the top.
    body = BRepPrimAPI_MakeBox(gp_Pnt(-30, -50, 0), 60, 100, 20).Shape()
    body = BRepAlgoAPI_Cut(body, BRepPrimAPI_MakeBox(gp_Pnt(25, -20, 10), 6, 40, 11).Shape()).Shape()
    path = tmp_path / "step.step"
    w = STEPControl_Writer(); w.Transfer(body, STEPControl_AsIs); w.Write(str(path))
    PARTS["side-step"] = import_part(path)
    # Turned +X to the spindle in 63 × 103 × 22 stock: part Z → work −X, its +X face at Z −1.5.
    m = np.array([[0, 0, -1, 10], [0, 1, 0, 0], [1, 0, 0, -31.5], [0, 0, 0, 1]], float)
    op = _op("adaptive", 6.0, z_min=-63, side_cavity=True)
    op["data"]["stepdown"] = 2.0
    t = time.time()
    _, blobs = _generate({"part_id": "side-step", "transform": m.flatten().tolist(), "stock_min": [-11, -51.5, -63],
                          "stock_max": [11, 51.5, 0], "safe_z": 3, "ops": [op]}, [])
    assert time.time() - t < 30
    rows = np.frombuffer(blobs[0], "<f4").reshape(-1, 8)
    cut = rows[(rows[:, 0] != 0) & (rows[:, 4] < -1.6)]
    assert len(cut)
    assert cut[:, 2].min() >= -10 + 3 - 0.05 and cut[:, 2].max() <= 0 - 3 + 0.05     # inside the step's X (part Z 10…20)
    assert cut[:, 3].min() >= -20 + 3 - 0.05 and cut[:, 3].max() <= 20 - 3 + 0.05    # and its Y
    assert cut[:, 4].min() == pytest.approx(-6.5, abs=0.05)                           # down to its floor
