"""Fixture assemblies retain individual solid occupancy, including overlapping hardware."""
import numpy as np
import pytest
from OCP.BRep import BRep_Builder
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakePolygon
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCP.TopoDS import TopoDS_Compound
from OCP.gp import gp_Pnt
from coastline_engine.cad_import import ImportedPart, tessellate
from coastline_engine.server import PARTS, _fixture_solids


@pytest.fixture
def assembly():
    comp = TopoDS_Compound()
    builder = BRep_Builder()
    builder.MakeCompound(comp)
    builder.Add(comp, BRepPrimAPI_MakeBox(10, 10, 10).Shape())
    builder.Add(comp, BRepPrimAPI_MakeBox(gp_Pnt(5, 0, 0), 10, 10, 10).Shape())
    yield comp, builder
    PARTS.pop("fixture-test", None)


def register(shape):
    mesh, faces = tessellate(shape, 0.01)
    PARTS["fixture-test"] = ImportedPart("test.step", "step", mesh, shape, faces, True)


def test_overlapping_hardware_is_returned_as_separate_closed_solids(assembly):
    register(assembly[0])
    result, blobs = _fixture_solids({"part_id": "fixture-test"}, [])
    assert len(result["solids"]) == 2
    assert len(blobs) == 6
    assert all(s["face_count"] == 6 for s in result["solids"])
    for i, meta in enumerate(result["solids"]):
        vertices = np.frombuffer(blobs[3 * i], "<f4").reshape(-1, 3)
        assert vertices.min(0) == pytest.approx(meta["bounds_min"])
        assert vertices.max(0) == pytest.approx(meta["bounds_max"])


def test_open_surfaces_are_not_silently_omitted_from_a_fixture(assembly):
    comp, builder = assembly
    wire = BRepBuilderAPI_MakePolygon()
    for point in [(0, 0, 20), (5, 0, 20), (5, 5, 20), (0, 5, 20)]:
        wire.Add(gp_Pnt(*point))
    wire.Close()
    builder.Add(comp, BRepBuilderAPI_MakeFace(wire.Wire()).Face())
    register(comp)
    with pytest.raises(ValueError, match="closed solid"):
        _fixture_solids({"part_id": "fixture-test"}, [])


def test_mesh_only_previews_are_not_assumed_to_be_solid_fixtures(assembly):
    register(assembly[0])
    PARTS["fixture-test"].shape = None
    with pytest.raises(ValueError, match="closed-solid"):
        _fixture_solids({"part_id": "fixture-test"}, [])
