"""Exact-size blanks: existing stock faces are not extra material to machine."""

import numpy as np
import pytest
from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder
from OCP.gp import gp_Ax2, gp_Dir, gp_Pnt

from coastline_engine.cad_import import ImportedPart, tessellate
from coastline_engine.server import PARTS, _generate


def _operation(kind, **extra):
    return dict(id=kind, kind=kind,
                tool=dict(diameter=2, flute_length=12, kind="flatEndMill"),
                data=dict(feed=600, plunge_feed=150, ramp_feed=300, stepdown=1, stepover=0.5),
                **extra)


@pytest.fixture
def generate():
    pid = "stock-face-regression"

    def run(shape, ops, low=(-10, -15, -6), high=(10, 15, 0)):
        mesh, _ = tessellate(shape, 0.01)
        PARTS[pid] = ImportedPart("regression.step", "step", mesh, shape, 0, True)
        result, blobs = _generate(dict(part_id=pid, transform=np.eye(4).ravel().tolist(),
                                       stock_min=low, stock_max=high, ops=ops), [])
        return result, [np.frombuffer(b, "<f4").reshape(-1, 8) for b in blobs]

    yield run
    PARTS.pop(pid, None)


def test_exact_blank_does_not_face_profile_or_finish_existing_faces(generate):
    box = BRepPrimAPI_MakeBox(gp_Pnt(-10, -15, -6), 20, 30, 6).Shape()
    result, paths = generate(box, [_operation("facing", face_depth=0), _operation("contour"),
                                   _operation("floor"), _operation("adaptive")])
    assert all(len(p) == 0 for p in paths), result


def test_pocket_in_exact_blank_still_gets_cut_without_skim_on_outer_faces(generate):
    box = BRepPrimAPI_MakeBox(gp_Pnt(-10, -15, -6), 20, 30, 6).Shape()
    pocket = BRepPrimAPI_MakeBox(gp_Pnt(-4, -5, -3), 8, 10, 4).Shape()
    part = BRepAlgoAPI_Cut(box, pocket).Shape()
    _, paths = generate(part, [_operation("contour", spring_pass=True), _operation("floor"),
                              _operation("adaptive")])
    for rows in paths:
        assert len(rows) > 0
        cuts = rows[(rows[:, 0] == 1) & (rows[:, 4] < -0.01)]
        assert len(cuts) > 0
        assert np.max(np.abs(cuts[:, 2])) < 5.1
        assert np.max(np.abs(cuts[:, 3])) < 6.1
    floor = paths[1]
    assert np.all(floor[floor[:, 0] == 1, 4] < -0.01), "do not finish the supplied top face"


def test_open_edge_recess_is_cut_but_existing_walls_are_preserved(generate):
    box = BRepPrimAPI_MakeBox(gp_Pnt(-10, -15, -6), 20, 30, 6).Shape()
    notch = BRepPrimAPI_MakeBox(gp_Pnt(-4, 10, -3), 8, 6, 4).Shape()
    part = BRepAlgoAPI_Cut(box, notch).Shape()
    _, (rows,) = generate(part, [_operation("contour", spring_pass=True)])
    assert len(rows) > 0
    cuts = rows[(rows[:, 0] == 1) & (rows[:, 4] < -0.01)]
    assert len(cuts) > 0
    assert np.max(np.abs(cuts[:, 2])) < 5.1
    assert np.min(cuts[:, 3]) >= 10.9
    assert np.min(cuts[:, 4]) >= -3.001
    # An open contour's spring pass must not join its ends across the uncut part.
    prev = None
    for row in rows:
        role, x, y, z = int(row[0]), row[2], row[3], row[4]
        if prev is not None and role == 0 and np.linalg.norm(np.array([x, y]) - prev[:2]) > 1e-4:
            assert min(z, prev[2]) >= 3 - 1e-4
        prev = np.array([x, y, z])


def test_matching_bounds_do_not_hide_material_around_a_round_part(generate):
    part = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0, 0, -6), gp_Dir(0, 0, 1)), 10, 6).Shape()
    _, (rows,) = generate(part, [_operation("contour")], low=(-10, -10, -6), high=(10, 10, 0))
    cuts = rows[rows[:, 0] == 1]
    assert len(cuts) > 20, "the blank's corners still contain material"
    assert set((int(x > 0), int(y > 0)) for x, y in cuts[:, 2:4]) == {(0, 0), (0, 1), (1, 0), (1, 1)}
