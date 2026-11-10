"""Machine packages must describe the actual motion hierarchy and asset identity.

These tests establish digital representation only, not physical calibration.
"""

import copy
import hashlib
import json
import shutil
from pathlib import Path

import numpy as np
import pytest

from coastline_engine.machine_profile import load_definition
from coastline_engine.machine_model import load_profile_machine
from coastline_engine.server import HANDLERS


RESOURCES = Path(__file__).resolve().parents[2] / "resources"
DESKTOP = RESOURCES / "machines/desktop-cnc"


def vec(x=0, y=0, z=0):
    return {"x": x, "y": y, "z": z}


def axis(coordinate, direction, offset=0):
    return {"coordinate": coordinate, "direction": direction, "modelMinimum": -100,
            "modelMaximum": 100, "modelHome": 0, "controllerScale": 1, "controllerOffset": offset}


@pytest.fixture
def vertical_package(tmp_path):
    """A contrasting machine: X/Y table, independent vertical spindle Z."""
    geometry = b"test geometry identity; no tessellation in these unit tests"
    (tmp_path / "machine.step").write_bytes(geometry)
    data = {
        "schemaVersion": 1, "id": "vertical-test", "revision": 1, "name": "Vertical test mill",
        "units": "mm", "process": "milling", "controller": "grbl", "verification": "draft",
        "assets": [{"path": "machine.step", "role": "geometry", "sha256": hashlib.sha256(geometry).hexdigest()}],
        "components": [
            {"id": "base", "role": "static", "modelEntities": ["0"]},
            {"id": "x", "role": "linearAxis", "axis": axis("x", vec(y=1)), "modelEntities": ["0/1"]},
            {"id": "y", "role": "linearAxis", "parentID": "x", "axis": axis("y", vec(x=1)), "modelEntities": ["0/1/1"]},
            {"id": "bed", "role": "table", "parentID": "y", "modelEntities": ["0/1/1/0"]},
            {"id": "z", "role": "linearAxis", "axis": axis("z", vec(z=1)), "modelEntities": ["0/2"]},
            {"id": "spindle", "role": "head", "parentID": "z", "modelEntities": ["0/2/0"]},
        ],
        "frames": [
            {"id": "table", "componentID": "bed", "origin": vec(10, 20, 30), "xDirection": vec(x=1), "zDirection": vec(z=1)},
            {"id": "tool", "componentID": "spindle", "origin": vec(0, 0, 80), "xDirection": vec(x=1), "zDirection": vec(z=1)},
        ],
    }
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(data))
    return path, data


def write_variant(package, mutate):
    path, original = package
    data = copy.deepcopy(original)
    mutate(data)
    path.write_text(json.dumps(data))
    return path


def test_vertical_mill_uses_its_own_hierarchy_and_world_directions(vertical_package):
    definition = load_definition(vertical_package[0])
    offsets = definition.translations([1, 2, 3])
    assert offsets["base"] == [0, 0, 0]
    assert offsets["bed"] == [2, 1, 0]
    assert offsets["spindle"] == [0, 0, 3]
    assert definition.frame_origin("table", [1, 2, 3]) == [12, 21, 30]
    assert definition.frame_origin("tool", [1, 2, 3]) == [0, 0, 83]
    assert all(offset == [0, 0, 0] for offset in definition.translations().values())
    # Geometry follows exact hierarchical paths, not English part names or substring matching.
    assert definition.component_for_path("0/1/1/0/6") == "bed"
    assert definition.component_for_path("0/10") == "base"
    assert definition.component_for_path("0/2/0/1") == "spindle"


def test_controller_mapping_is_applied_once_and_reference_pose_stays_q_zero(vertical_package):
    def mutate(data):
        data["components"][1]["axis"].update(controllerScale=-1, controllerOffset=12)
    definition = load_definition(write_variant(vertical_package, mutate))
    assert definition.translations([2, 0, 0])["x"] == [0, 10, 0]
    assert definition.translations()["x"] == [0, 0, 0]


@pytest.mark.parametrize("mutate, message", [
    (lambda d: d.update(schemaVersion=2), "schema"),
    (lambda d: d.update(revision="1"), "revision"),
    (lambda d: d.update(units="cm"), "millimetre"),
    (lambda d: d.update(controller="unimplemented"), "controller"),
    (lambda d: d.update(id="../outside"), "identifier"),
    (lambda d: d["components"][1].update(role="rotaryAxis"), "Unsupported"),
    (lambda d: d["components"][1].update(parentID="bed"), "cycle"),
    (lambda d: d["components"][1].update(parentID="missing"), "unknown parent"),
    (lambda d: d["components"][4].update(parentID="y"), "shared or disconnected"),
    (lambda d: d["components"][3].update(parentID="x"), "shared or disconnected"),
    (lambda d: d["components"][1].update(id="base"), "Duplicate"),
    (lambda d: d["components"][1]["axis"].update(controllerOffset=float("nan")), "finite"),
    (lambda d: d.update(evidence=[{"detail": float("inf")}]), "finite"),
    (lambda d: d["components"][1]["axis"].update(controllerOffset=1e308), "numeric range"),
    (lambda d: d["frames"][0].update(origin=vec(1e308, 0, 0)), "numeric range"),
    (lambda d: d["components"][1]["axis"].update(direction=vec(y=2)), "unit direction"),
    (lambda d: d["components"][1]["axis"].update(direction=vec(x=1)), "perpendicular"),
    (lambda d: d["components"][1]["axis"].update(modelHome=101), "invalid limits"),
    (lambda d: d["components"][1]["axis"].update(coordinate="z"), "unique"),
    (lambda d: d["components"][1].update(modelEntities=["0"]), "Duplicate"),
    (lambda d: d["components"][1].update(modelEntities=["../../0"]), "occurrence path"),
    (lambda d: d["frames"][0].update(componentID="missing"), "existing components"),
    (lambda d: d["frames"][0].update(zDirection=vec(x=1)), "perpendicular"),
    (lambda d: d["assets"][0].update(path="../machine.step"), "inside"),
    (lambda d: d["assets"][0].update(sha256="0" * 64), "SHA-256"),
])
def test_invalid_profiles_are_rejected_with_a_specific_reason(vertical_package, mutate, message):
    with pytest.raises(ValueError, match=message):
        load_definition(write_variant(vertical_package, mutate))


def test_external_asset_symlinks_are_rejected(vertical_package, tmp_path):
    outside = tmp_path.parent / f"outside-{tmp_path.name}.step"
    outside.write_bytes(b"other machine")
    linked = tmp_path / "linked.step"
    linked.symlink_to(outside)
    path = write_variant(vertical_package, lambda d: d["assets"][0].update(path="linked.step"))
    with pytest.raises(ValueError, match="symbolic link"):
        load_definition(path)


def test_internal_asset_symlinks_are_also_rejected(vertical_package, tmp_path):
    (tmp_path / "linked.step").symlink_to(tmp_path / "machine.step")
    path = write_variant(vertical_package, lambda d: d["assets"][0].update(path="linked.step"))
    with pytest.raises(ValueError, match="symbolic link"):
        load_definition(path)


def test_manifest_size_limit_is_checked_before_decoding(vertical_package):
    path, _ = vertical_package
    with path.open("ab") as stream:
        stream.write(b" " * 1_048_576)
    with pytest.raises(ValueError, match="size limit"):
        load_definition(path)


def test_asset_size_limit_is_checked_before_hashing(vertical_package):
    path, _ = vertical_package
    with (path.parent / "machine.step").open("r+b") as stream:
        stream.truncate(209_715_201)
    with pytest.raises(ValueError, match="size limit"):
        load_definition(path)


def test_extreme_finite_position_cannot_overflow_into_a_render_transform(vertical_package):
    definition = load_definition(vertical_package[0])
    with pytest.raises(ValueError, match="numeric range"):
        definition.translations([1e308, 0, 0])


@pytest.mark.parametrize("position", [[1, 2], [1, 2, float("inf")], {"x": 1, "y": 2, "z": 3}])
def test_invalid_controller_positions_are_not_rendered(vertical_package, position):
    definition = load_definition(vertical_package[0])
    with pytest.raises(ValueError, match="position"):
        definition.translations(position)


@pytest.fixture(scope="module")
def desktop_geometry(tmp_path_factory):
    cache = tmp_path_factory.mktemp("desktop-machine-cache")
    parts, definition = load_profile_machine(DESKTOP / "manifest.json", cache)
    return parts, definition, cache


def test_supplied_desktop_geometry_uses_explicit_groups_and_converts_cm_once(desktop_geometry):
    parts, definition, _ = desktop_geometry
    assert definition.data["revision"] == 2
    assert definition.data["verification"] == "digital"
    # X is a motion-only parent; its table owns the geometry. Cover is a separate
    # static component, so visibility can change without reassigning moving parts.
    assert set(definition.components) == {"base", "x", "table", "y", "z", "head", "cover"}
    assert {p.group for p in parts} == {"base", "table", "y", "z", "head", "cover"}
    assert definition.components["table"]["parentID"] == "x"
    assert definition.components["z"]["parentID"] == "y"
    assert definition.components["head"]["parentID"] == "z"
    assert definition.components["cover"]["isEnclosure"]
    audit = json.loads((DESKTOP / "geometry-index.json").read_text())
    assert audit["shapeCount"] == 50
    assert audit["assembledSolidCount"] == 52
    cover_shapes = [entry for entry in audit["entities"]
                    if entry["componentID"] == "cover" and entry["kind"] == "shape"]
    assert len(cover_shapes) == 9
    assert all(definition.component_for_path(entry["path"]) == "cover" for entry in cover_shapes)
    table = next(p for p in parts if p.group == "table" and p.role == "aluminium")
    lo, hi = table.mesh.bounds
    assert hi == pytest.approx([15.865, -44.423, 129.844], abs=.01)
    assert lo == pytest.approx([1.260, -429.423, 54.914], abs=.01)
    assert definition.translations([-86, -.5, -.5])["table"] == pytest.approx([86, 0, 0])
    assert definition.translations([-86, -.5, -.5])["head"] == pytest.approx([0, 68.5, 79.4])
    assert definition.translations([-86, -.5, -.5])["cover"] == [0, 0, 0]


def test_profile_rpc_preserves_metadata_blobs_and_digital_status(desktop_geometry):
    parts, _, cache = desktop_geometry
    result, blobs = HANDLERS["machine_model"]({"manifestPath": str(DESKTOP / "manifest.json"),
                                              "machinePosition": [-86, -.5, -.5], "cache_dir": str(cache)}, [])
    assert result["profile"]["id"] == "desktop-cnc"
    assert result["profile"]["revision"] == 2
    assert result["profile"]["verification"] == "digital"
    assert not result["reference_pose"]
    assert "model_pose" not in result  # Do not inject the other model's legacy calibration.
    assert result["group_translations"]["head"] == pytest.approx([0, 68.5, 79.4])
    assert len(blobs) == 3 * len(parts)
    assert np.array_equal(np.frombuffer(blobs[0], "<f4").reshape(-1, 3), parts[0].mesh.vertices)


def test_unbound_geometry_and_changed_asset_are_not_hidden_by_cache(desktop_geometry, tmp_path):
    _, _, cache = desktop_geometry
    package = tmp_path / "machine"
    shutil.copytree(DESKTOP, package)
    manifest = package / "manifest.json"
    data = json.loads(manifest.read_text())
    next(c for c in data["components"] if c["id"] == "base")["modelEntities"] = []
    manifest.write_text(json.dumps(data))
    with pytest.raises(ValueError, match="no component assignment"):
        load_profile_machine(manifest, cache)
    shutil.copyfile(DESKTOP / "manifest.json", manifest)
    (package / "machine.step").write_bytes(b"different geometry with unchanged manifest")
    with pytest.raises(ValueError, match="SHA-256"):
        load_profile_machine(manifest, cache)
