"""Floor finishing: a floor's edges that drop away aren't walls, so strips narrower than the
tool (between a hole and the part's edge) are finished too; real walls still keep a radius off."""
import math

import numpy as np
import pyclipper
import pytest

from coastline_engine.cad_import import import_part
from coastline_engine.cam import geometry as g
from coastline_engine.cam import ops as O
from coastline_engine.cam.features import find_features
from coastline_engine.cam.toolpath import Toolpath


@pytest.fixture(scope="module")
def plate(tmp_path_factory):
    """40 × 20 plate, top face at Z−1, a ⌀8 hole 3 mm from one long edge and a 10 × 10 boss up to Z0."""
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder
    from OCP.gp import gp_Ax2, gp_Dir, gp_Pnt
    from OCP.STEPControl import STEPControl_AsIs, STEPControl_Writer

    body = BRepPrimAPI_MakeBox(gp_Pnt(-20, -10, -6), 40, 20, 5).Shape()
    body = BRepAlgoAPI_Cut(body, BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(-8, 3, -7), gp_Dir(0, 0, 1)), 4, 8).Shape()).Shape()
    body = BRepAlgoAPI_Fuse(body, BRepPrimAPI_MakeBox(gp_Pnt(5, -5, -1), 10, 10, 1).Shape()).Shape()
    path = tmp_path_factory.mktemp("floors") / "plate.step"
    w = STEPControl_Writer()
    w.Transfer(body, STEPControl_AsIs)
    w.Write(str(path))
    part = import_part(path, 0.01)
    geo = g.PartGeometry(part.mesh.vertices, part.mesh.indices, np.eye(4))
    floors = [f for f in find_features(part.shape, geo.zmin)["floors"] if abs(f["z"] + 1) < 1e-3]
    return geo, floors


def _swept(rows, z, r):
    """The area the tool sweeps at height z (arcs sampled), as pyclipper paths."""
    runs, cur, prev = [], [], None
    for _, mo, x, y, zz, i, j, _ in rows:
        on = abs(zz - z) < 1e-6 and prev is not None and abs(prev[2] - z) < 1e-6
        if on and mo != 0:
            cx, cy = prev[0] + i, prev[1] + j
            a0, a1 = math.atan2(prev[1] - cy, prev[0] - cx), math.atan2(y - cy, x - cx)
            sweep = a1 - a0
            while mo == 1 and sweep >= 0:
                sweep -= 2 * math.pi
            while mo == 2 and sweep <= 0:
                sweep += 2 * math.pi
            R = math.hypot(prev[0] - cx, prev[1] - cy)
            cur += [(cx + R * math.cos(a0 + sweep * t), cy + R * math.sin(a0 + sweep * t)) for t in np.linspace(0, 1, 64)[1:]]
        elif on:
            cur.append((x, y))
        else:
            if len(cur) > 1:
                runs.append(cur)
            cur = [(x, y)]
        prev = (x, y, zz)
    if len(cur) > 1:
        runs.append(cur)
    pc = pyclipper.PyclipperOffset()
    for run in runs:
        pc.AddPath(g.to_int(np.array(run)), pyclipper.JT_ROUND, pyclipper.ET_OPENROUND)
    return pc.Execute(r * g.SCALE), runs


def _op(d):
    return O.Op({"id": "t", "kind": "floor", "tool": {"diameter": d, "flute_length": 3 * d, "kind": "flatEndMill"}, "z_top": 0,
                 "data": {"feed": 600, "plunge_feed": 200, "ramp_feed": 500, "stepdown": 0, "stepover": 0.4 * d, "ramp_angle": 2}})


def test_floor_finishing_reaches_strips_narrower_than_the_tool(plate):
    geo, floors = plate
    assert floors, "the plate's top face is a floor"
    op = _op(6.0)
    tp = Toolpath(safe_z=3, approach_z=1)
    O.floors(op, floors, tp, part=geo)
    swept, runs = _swept(tp.array(), -1.0, op.r)
    c = pyclipper.Pyclipper()
    c.AddPaths(floors[0]["paths"], pyclipper.PT_SUBJECT, True)
    c.AddPaths(swept, pyclipper.PT_CLIP, True)
    left = c.Execute(pyclipper.CT_DIFFERENCE, pyclipper.PFT_EVENODD, pyclipper.PFT_NONZERO)
    missed = sum(abs(pyclipper.Area(p)) for p in left) / g.SCALE**2
    assert missed < 0.05  # mm²: the 3 mm strip beside the hole is finished too
    # The boss is a wall: the tool's centre stays a radius (less a hair) off it.
    pts = np.array([p for run in runs for p in run])
    dx = np.maximum(np.maximum(5 - pts[:, 0], pts[:, 0] - 15), 0)
    dy = np.maximum(np.maximum(-5 - pts[:, 1], pts[:, 1] - 5), 0)
    assert np.hypot(dx, dy).min() >= op.r - 0.01


def test_without_the_part_floors_keep_off_every_edge(plate):
    geo, floors = plate
    tp = Toolpath(safe_z=3, approach_z=1)
    O.floors(_op(6.0), floors, tp)
    swept, _ = _swept(tp.array(), -1.0, 3.0)
    c = pyclipper.Pyclipper()
    c.AddPaths(swept, pyclipper.PT_SUBJECT, True)
    c.AddPaths(floors[0]["paths"], pyclipper.PT_CLIP, True)
    outside = c.Execute(pyclipper.CT_DIFFERENCE, pyclipper.PFT_NONZERO, pyclipper.PFT_EVENODD)
    assert sum(abs(pyclipper.Area(p)) for p in outside) / g.SCALE**2 < 0.2  # mm²: arc sampling only
