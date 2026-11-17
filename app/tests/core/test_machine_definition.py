"""Port of CoastlineSelfTest/MachineDefinitionTests.swift."""

import copy
import json
import math
import os
import shutil
from dataclasses import replace

import pytest

from coastline_app.core import codable
from coastline_app.core.codable import Range
from coastline_app.core.geometry import Vec3
from coastline_app.core.machine import definition as md
from coastline_app.core.machine.definition import (MachineComponentRole, MachineCoordinate, MachineDefinition,
                                                   MachineDefinitionError, MachineEvidenceStatus, MachineValidationCheck,
                                                   MachineValidationScope, MachineValidationStatus, MachineVerification)
from coastline_app.core.machine.package import MAXIMUM_ASSET_BYTES, MachineDefinitionPackage
from coastline_app.core.machine.profile import MachineProfile
from coastline_app.core.post.grbl_post import ADAPTER_ID
from coastline_app.paths import REPO_ROOT

PACKAGE = REPO_ROOT / "resources/machines/desktop-cnc"


def load():
    return MachineDefinitionPackage.load(PACKAGE).definition


def copied(tmp_path):
    dst = tmp_path / "source"
    shutil.copytree(PACKAGE, dst)
    return dst


def write_definition(d, folder):
    (folder / "manifest.json").write_bytes(codable.encode(d, pretty=True))


def comp(d, pred):
    return next(c for c in d.components if pred(c))


def test_desktop_package_proves_digital_setup_and_preserves_physical_calibration_task():
    package = MachineDefinitionPackage.load(PACKAGE)
    d = package.definition
    assert (d.id, d.revision, d.verification) == ("desktop-cnc", 2, MachineVerification.DIGITAL)
    assert d.supports_digital_setup
    assert d.validation_status(MachineValidationScope.HARDWARE) is MachineValidationStatus.PENDING
    assert [c.id for c in d.validation_checks if c.status is MachineValidationStatus.PENDING] == ["physical-calibration"]
    assert [f.id for f in d.blocking_findings] == ["physical-calibration"]
    assert d.post_processor_id == ADAPTER_ID
    assert d.profile.max_tool_length == 75
    assert d.profile.spindle_rpm == Range(1500, 8000)
    assert d.controller_home_position == Vec3(-86, -0.5, -0.5)
    assert d.controller_envelope.y == Range(-241.5, 0)
    assert package.fusion_definition_path is not None
    assert any(e.status is MachineEvidenceStatus.INFERRED for e in d.evidence)
    assert [c.id for c in d.components if c.is_enclosure is True] == ["cover"]
    assert d.world_translation("cover", d.controller_home_position) == Vec3.ZERO
    assert MachineDefinitionPackage.load(package.manifest_path).definition == d


def test_table_and_nested_head_move_in_their_defined_directions():
    d = load()
    home = d.controller_home_position
    table_id = comp(d, lambda c: c.role is MachineComponentRole.TABLE).id
    head_id = comp(d, lambda c: c.role is MachineComponentRole.HEAD).id
    table, head = d.world_translation(table_id, home), d.world_translation(head_id, home)
    assert table == Vec3(86, 0, 0) and head == Vec3(0, 68.5, 79.4)
    moved = home.replacing(0, home.x + 1)
    assert d.world_translation(table_id, moved) == Vec3(85, 0, 0)
    assert d.world_translation(head_id, moved) == head
    moved = Vec3(home.x, home.y + 1, home.z - 2)
    assert d.world_translation(head_id, moved) == Vec3(0, 69.5, 77.4)
    assert d.world_translation(table_id, moved) == table
    frame = next(f for f in d.frames if f.component_id == table_id)
    assert d.world_origin(frame.id, home).x == frame.origin.x + 86


def test_seating_frame_places_asymmetric_stock_without_permuting_its_dimensions():
    d = load()
    seating = next(f for f in d.frames if f.id == "table-surface")
    assert d.reference_stock.frame_id == seating.id
    assert d.reference_stock.size == Vec3(203.2, 37, 50.8)
    d.validate()
    corners = d.reference_stock_corners()
    assert len(corners) == 8
    span = lambda k: max(c[k] for c in corners) - min(c[k] for c in corners)  # noqa: E731
    assert abs(span(0) - 50.8) < 0.000001 and abs(span(1) - 203.2) < 0.000001 and abs(span(2) - 37) < 0.000001
    assert corners[0] == seating.origin
    assert d.world_direction(Vec3(0, 0, 1), seating.id) == Vec3(1, 0, 0)
    assert d.world_direction(Vec3(0, 0, 1), "tool") == Vec3(0, 0, 1)
    home = d.reference_stock_corners(d.controller_home_position)
    for h, c in zip(home, corners):
        assert abs(h.x - c.x - 86) < 0.000001 and h.y == c.y and h.z == c.z
    moved = d.controller_home_position
    moved = moved.replacing(1, moved.y - 10)
    assert d.reference_stock_corners(moved) == home, "Head motion must not move table-mounted stock"
    d.reference_stock.frame_id = "tool"
    with pytest.raises(MachineDefinitionError):
        d.validate()


def test_revision_one_without_capability_metadata_still_loads_without_claiming_digital_setup():
    obj = json.loads((PACKAGE / "manifest.json").read_text())
    for k in ("postProcessorID", "checks", "referenceStock"):
        obj.pop(k, None)
    for c in obj["components"]:
        c.pop("isEnclosure", None)
    obj["verification"], obj["revision"] = "draft", 1
    d = codable.decode(MachineDefinition, json.dumps(obj))
    d.validate()
    assert not d.supports_digital_setup
    assert d.reference_stock is None and d.post_processor_id is None
    assert all(c.is_enclosure is None for c in d.components)


def test_digital_readiness_does_not_clear_physical_calibration():
    d = load()
    source = d.sources[0].id
    d.checks = [MachineValidationCheck(s.value, s.value, s, MachineValidationStatus.PASSED, "Checked against the referenced source.", [source])
                for s in (MachineValidationScope.GEOMETRY, MachineValidationScope.KINEMATICS, MachineValidationScope.SETUP_PLACEMENT)]
    d.checks.append(MachineValidationCheck("calibration", "Measure the installed machine", MachineValidationScope.HARDWARE,
                                           MachineValidationStatus.PENDING, "No physical measurements have been recorded.", [source],
                                           "Record table and spindle references after homing."))
    d.validate()
    assert d.supports_digital_setup
    assert d.validation_status(MachineValidationScope.HARDWARE) is MachineValidationStatus.PENDING
    d.checks[1].status, d.checks[1].action = MachineValidationStatus.FAILED, "Correct the axis direction."
    assert not d.supports_digital_setup
    assert d.validation_status(MachineValidationScope.KINEMATICS) is MachineValidationStatus.FAILED
    d.checks[3].action = None
    with pytest.raises(MachineDefinitionError):
        d.validate()


def test_contrasting_vertical_machine_needs_no_desktop_motion_assumptions():
    d = load()
    d.id, d.name = "vertical-test", "Vertical test machine"
    x = comp(d, lambda c: c.axis is not None and c.axis.coordinate is MachineCoordinate.X)
    y = comp(d, lambda c: c.axis is not None and c.axis.coordinate is MachineCoordinate.Y)
    z = comp(d, lambda c: c.axis is not None and c.axis.coordinate is MachineCoordinate.Z)
    table = comp(d, lambda c: c.role is MachineComponentRole.TABLE)
    head = comp(d, lambda c: c.role is MachineComponentRole.HEAD)
    x.parent_id, x.axis.direction = None, Vec3(1, 0, 0)
    y.parent_id, z.parent_id = x.id, y.id
    table.parent_id, head.parent_id = None, z.id
    d.validate()
    p = Vec3(-10, -50, -30)
    assert d.world_translation(table.id, p) == Vec3.ZERO
    t = d.world_translation(head.id, p)
    assert t.x == -10 and t.y == 19 and abs(t.z - 49.9) < 0.00001


def test_invalid_kinematics_cannot_become_a_valid_package():
    valid = load()

    def fails(mutate):
        d = copy.deepcopy(valid)
        mutate(d)
        with pytest.raises(MachineDefinitionError):
            d.validate()

    def xaxis(d):
        return comp(d, lambda c: c.axis is not None and c.axis.coordinate is MachineCoordinate.X).axis

    fails(lambda d: setattr(d, "schema_version", 2))
    fails(lambda d: setattr(d, "controller", "unsupported"))
    fails(lambda d: setattr(d.components[0], "parent_id", d.components[0].id))
    fails(lambda d: setattr(xaxis(d), "controller_scale", 0))
    fails(lambda d: setattr(xaxis(d), "model_home", 10000))
    fails(lambda d: setattr(xaxis(d), "direction", Vec3(math.nan, 0, 0)))
    fails(lambda d: setattr(d, "profile", replace(d.profile, home_position=Vec3(-0.5, -0.5, -0.5))))
    fails(lambda d: setattr(d.frames[0], "z_direction", d.frames[0].x_direction))


def test_install_copies_assets_and_rejects_changed_revision(tmp_path):
    source = copied(tmp_path)
    library = tmp_path / "library"
    installed = MachineDefinitionPackage.install(source, library)
    assert str(installed.root).startswith(str(library.resolve()) + os.sep)
    assert MachineDefinitionPackage.install(source, library).root == installed.root
    changed = copy.deepcopy(installed.definition)
    changed.name = "Different machine, same revision"
    write_definition(changed, source)
    with pytest.raises(MachineDefinitionError):
        MachineDefinitionPackage.install(source, library)
    shutil.rmtree(source)
    assert MachineDefinitionPackage.load(installed.root).definition == installed.definition


def test_numeric_headroom_rejects_finite_values_that_break_the_renderer():
    valid = load()
    excessive = md.MAXIMUM_COORDINATE_MAGNITUDE * 2

    def check(mutate, ok=False):
        d = copy.deepcopy(valid)
        mutate(d)
        if ok:
            d.validate()
        else:
            with pytest.raises(MachineDefinitionError):
                d.validate()

    check(lambda d: setattr(d.frames[0], "origin", d.frames[0].origin.replacing(0, excessive)))
    check(lambda d: setattr(comp(d, lambda c: c.axis is not None and c.axis.coordinate is MachineCoordinate.X).axis, "controller_offset", excessive))
    check(lambda d: setattr(d.mounting_interfaces[0].slots[0], "length", excessive))
    head = comp(valid, lambda c: c.role is MachineComponentRole.HEAD).id
    with pytest.raises(MachineDefinitionError):
        valid.world_translation(head, Vec3(0, 1e100, 0))
    check(lambda d: setattr(d.frames[0], "origin", d.frames[0].origin.replacing(0, 1e9)), ok=True)
    check(lambda d: setattr(d.components[0], "model_entities", ["00/1"]))


def test_hash_mismatch_and_path_escapes_are_rejected(tmp_path):
    source = copied(tmp_path)
    valid = MachineDefinitionPackage.load(source).definition
    d = copy.deepcopy(valid)
    d.assets[0].sha256 = "0" * 64
    write_definition(d, source)
    with pytest.raises(MachineDefinitionError):
        MachineDefinitionPackage.load(source)
    for path in ["../machine.step", "/tmp/machine.step", "models/../../machine.step", "models\\machine.step"]:
        d = copy.deepcopy(valid)
        next(a for a in d.assets if a.role is md.MachineAssetRole.GEOMETRY).path = path
        write_definition(d, source)
        with pytest.raises(MachineDefinitionError):
            MachineDefinitionPackage.load(source)


@pytest.mark.skipif(os.name == "nt", reason="symbolic links need extra rights on Windows")
def test_symlink_assets_and_oversized_files_are_rejected(tmp_path):
    source = copied(tmp_path)
    package = MachineDefinitionPackage.load(source)
    original = tmp_path / "outside.step"
    shutil.move(package.geometry_path, original)
    os.symlink(original, package.geometry_path)
    with pytest.raises(MachineDefinitionError):
        MachineDefinitionPackage.load(source)
    os.remove(package.geometry_path)
    package.geometry_path.write_bytes(b"STEP")
    with open(package.geometry_path, "r+b") as f:
        f.truncate(MAXIMUM_ASSET_BYTES + 1)
    with pytest.raises(MachineDefinitionError):
        MachineDefinitionPackage.load(source)


def test_home_is_explicit_and_legacy_profiles_still_decode():
    standard = MachineProfile.standard()
    assert tuple(standard.tool_change_waypoints[0]) == (-86, -0.5, -1)
    obj = codable.to_json(standard)
    obj.pop("homePosition")
    legacy = codable.from_json(MachineProfile, obj)
    assert legacy.home_position is None
    assert legacy.travel == standard.travel and legacy.spindle_rpm == standard.spindle_rpm
