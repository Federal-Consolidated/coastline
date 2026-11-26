"""K12: clean CAD as a joined Rhino polysurface (.3dm through openNURBS), read back by rhino3dm."""
import os

import numpy as np
import pytest

from coastline_engine import clean_3dm, clean_cad

pytestmark = pytest.mark.skipif(not clean_3dm.available(), reason="openNURBS not built (native/build_opennurbs.sh)")


def test_a_box_with_a_round_pocket_is_one_closed_polysurface(tmp_path):
    import rhino3dm
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder
    from OCP.gp import gp_Ax2, gp_Dir, gp_Pnt

    box = BRepPrimAPI_MakeBox(gp_Pnt(-10, -10, -5), 20, 20, 5).Shape()
    hole = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0, 0, -3), gp_Dir(0, 0, 1)), 4, 10).Shape()
    r = clean_3dm.write(str(tmp_path / "b.3dm"), BRepAlgoAPI_Cut(box, hole).Shape(), "box with a pocket")
    assert r["valid3dm"] and r["dropped"] == 0, r["log"]
    f = rhino3dm.File3dm.Read(str(tmp_path / "b.3dm"))
    assert f.Settings.ModelUnitSystem == rhino3dm.UnitSystem.Millimeters
    o = f.Objects[0]
    assert o.Attributes.Name == "box with a pocket" and f.Layers[o.Attributes.LayerIndex].Name == "Coastline snapshot"
    g = o.Geometry
    assert isinstance(g, rhino3dm.Brep) and g.IsSolid and g.IsValid and len(g.Faces) == 8


def test_a_simulated_dish_comes_out_valid_and_closed(tmp_path):
    import rhino3dm
    from test_clean_cad import heights

    h, origin, cell = heights(dish=True)
    r = clean_cad.write_3dm(str(tmp_path / "d.3dm"), h, origin, cell, 0.0, -6.0, "dish")
    assert r["valid"], r["log"]
    g = rhino3dm.File3dm.Read(str(tmp_path / "d.3dm")).Objects[0].Geometry
    assert g.IsSolid and g.IsValid and r["kinds"].get("BSplineSurface", 0) == 1
