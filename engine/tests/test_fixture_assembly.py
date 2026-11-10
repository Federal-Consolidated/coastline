"""Vetted fixture paths must identify real CAD hardware without spatial grouping."""
import copy
import json
from pathlib import Path

import pytest

from coastline_engine.fixture_assembly import _validate_definition, load_fixture_assembly

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "resources/fixtures/bookends"


@pytest.fixture(scope="module")
def definition():
    return json.loads((BUNDLE / "definition.json").read_text())


def test_real_bookend_hardware_has_exact_occurrence_identity(definition):
    parts = load_fixture_assembly(BUNDLE / "assembly.step", definition)
    assert len(parts) == 15
    keys = {(m["entity_path"], m["solid_index"]) for m, _ in parts}
    assert len(keys) == 15
    by_component = {}
    for metadata, mesh in parts:
        by_component.setdefault(metadata["component_id"], []).append(metadata["entity_path"])
        assert len(mesh.indices) > 0
    assert len(by_component["fixed-end"]) == 7
    assert len(by_component["clamp-end"]) == 7
    assert by_component["pressure-screw"] == ["10/0"]


def test_fixture_asset_hash_is_required(definition):
    changed = copy.deepcopy(definition)
    changed["modelSHA256"] = "0" * 64
    with pytest.raises(ValueError, match="SHA-256"):
        load_fixture_assembly(BUNDLE / "assembly.step", changed)


def test_unassigned_or_nonleaf_occurrences_cannot_fall_back_to_proximity(definition):
    missing = copy.deepcopy(definition)
    missing["components"][0]["modelEntities"].pop()
    with pytest.raises(ValueError, match="no explicit component assignment"):
        load_fixture_assembly(BUNDLE / "assembly.step", missing)
    nonleaf = copy.deepcopy(definition)
    nonleaf["components"][0]["modelEntities"].append("0/3")
    with pytest.raises(ValueError, match="not exact leaf"):
        load_fixture_assembly(BUNDLE / "assembly.step", nonleaf)


def test_component_cycles_duplicate_bindings_and_bad_joints_are_rejected(definition):
    cycle = copy.deepcopy(definition)
    cycle["components"][1]["parentID"] = "pressure-screw"
    with pytest.raises(ValueError, match="cycle"):
        _validate_definition(cycle)
    duplicate = copy.deepcopy(definition)
    duplicate["components"][1]["modelEntities"].append(duplicate["components"][0]["modelEntities"][0])
    with pytest.raises(ValueError, match="unique"):
        _validate_definition(duplicate)
    bad_axis = copy.deepcopy(definition)
    bad_axis["components"][0]["joint"]["axis"] = {"x": 0, "y": 0, "z": 0}
    with pytest.raises(ValueError, match="axis"):
        _validate_definition(bad_axis)
    bad_pitch = copy.deepcopy(definition)
    bad_pitch["components"][2]["joint"]["pitch"] = 1e-300
    with pytest.raises(ValueError, match="pitch"):
        _validate_definition(bad_pitch)


def test_clean_quick_release_package_contains_only_fixture_hardware():
    bundle = ROOT / "resources/fixtures/quick-release"
    definition = json.loads((bundle / "definition.json").read_text())
    assert definition["isAssembled"] is False
    parts = load_fixture_assembly(bundle / "fixture.step", definition)
    roles = {component["id"]: component["role"] for component in definition["components"]}
    assert len(parts) == 34
    assert len({meta["entity_path"] for meta, _ in parts}) == 33
    assert all(roles[meta["component_id"]] == "physical" for meta, _ in parts)
    # The source assembly's X table (385 mm along Y) was explicitly removed at
    # package authoring; the new path 0/0 is hardware, not that old reference body.
    assert all(meta["bounds_max"][1] - meta["bounds_min"][1] < 385 for meta, _ in parts)
