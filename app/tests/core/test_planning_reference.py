"""Port of CoastlineSelfTest/PlanningMachineReferenceTests.swift."""

import copy
import hashlib
import json
import shutil
from dataclasses import replace

import pytest

from coastline_app.core import codable
from coastline_app.core.machine.definition import MachineAssetRole, MachineDefinitionError
from coastline_app.core.machine.package import MachineDefinitionPackage
from coastline_app.core.machine.planning_reference import PlanningMachineReference
from coastline_app.paths import REPO_ROOT

PACKAGE = REPO_ROOT / "resources/machines/desktop-cnc"


def write(d, folder):
    (folder / "manifest.json").write_bytes(codable.encode(d))


def test_profile_snapshot_round_trips_with_all_asset_fingerprints():
    package = MachineDefinitionPackage.load(PACKAGE)
    reference = PlanningMachineReference.of(package.definition)
    restored = codable.decode(PlanningMachineReference, codable.encode(reference))
    assert restored == reference
    assert restored.reference == package.definition.reference
    assert restored.definition.assets == package.definition.assets
    assert restored.profile == package.definition.profile
    assert restored.fingerprint() == reference.fingerprint()
    assert restored.resolve([package]).root == package.root
    assert not restored.is_legacy


def test_missing_profile_never_falls_back_to_legacy():
    reference = PlanningMachineReference.of(MachineDefinitionPackage.load(PACKAGE).definition)
    with pytest.raises(MachineDefinitionError):
        reference.resolve([])
    assert PlanningMachineReference.legacy().resolve([]) is None
    assert reference != PlanningMachineReference.legacy()


def test_same_revision_changed_limits_cannot_replace_saved_machine(tmp_path):
    package = MachineDefinitionPackage.load(PACKAGE)
    reference = PlanningMachineReference.of(package.definition)
    destination = tmp_path / "profile"
    shutil.copytree(PACKAGE, destination)
    changed = copy.deepcopy(package.definition)
    changed.profile = replace(changed.profile, max_rate=changed.profile.max_rate.replacing(0, changed.profile.max_rate.x / 2))
    write(changed, destination)
    replacement = MachineDefinitionPackage.load(destination)
    assert replacement.definition.reference == reference.reference
    with pytest.raises(MachineDefinitionError):
        reference.resolve([replacement])
    with pytest.raises(MachineDefinitionError):
        reference.resolve([package, replacement])
    assert reference.fingerprint() != PlanningMachineReference.of(changed).fingerprint()


def test_same_revision_changed_assets_cannot_replace_saved_machine(tmp_path):
    package = MachineDefinitionPackage.load(PACKAGE)
    reference = PlanningMachineReference.of(package.definition)
    destination = tmp_path / "profile"
    shutil.copytree(PACKAGE, destination)
    changed = copy.deepcopy(package.definition)
    asset = next(a for a in changed.assets if a.role is MachineAssetRole.GEOMETRY)
    geometry = destination / asset.path
    data = geometry.read_bytes() + b"\n"
    geometry.write_bytes(data)
    asset.sha256 = hashlib.sha256(data).hexdigest()
    write(changed, destination)
    with pytest.raises(MachineDefinitionError):
        reference.resolve([MachineDefinitionPackage.load(destination)])


def test_newer_revision_does_not_upgrade_existing_job(tmp_path):
    original = MachineDefinitionPackage.load(PACKAGE)
    reference = PlanningMachineReference.of(original.definition)
    destination = tmp_path / "newer"
    shutil.copytree(PACKAGE, destination)
    changed = copy.deepcopy(original.definition)
    changed.revision += 1
    write(changed, destination)
    newer = MachineDefinitionPackage.load(destination)
    with pytest.raises(MachineDefinitionError):
        reference.resolve([newer])
    assert reference.resolve([newer, original]).definition == original.definition


def test_legacy_assignment_retains_its_saved_limits():
    original = PlanningMachineReference.legacy()
    obj = json.loads(codable.encode(original))
    obj["legacyProfile"]["maxRate"]["x"] = 1200.0
    saved = codable.decode(PlanningMachineReference, json.dumps(obj))
    assert saved.is_legacy and saved.profile.max_rate.x == 1200
    assert saved.reference.id == "coastline.legacy-desktop"
    assert saved != original
    assert codable.decode(PlanningMachineReference, codable.encode(saved)) == saved


def test_incomplete_or_ambiguous_machine_assignments_are_rejected():
    reference = PlanningMachineReference.of(MachineDefinitionPackage.load(PACKAGE).definition)
    obj = json.loads(codable.encode(reference))
    obj["kind"] = "legacy"
    with pytest.raises(MachineDefinitionError):
        codable.decode(PlanningMachineReference, json.dumps(obj))
    obj["kind"] = "profile"
    del obj["definition"]
    with pytest.raises(MachineDefinitionError):
        codable.decode(PlanningMachineReference, json.dumps(obj))
    bad = json.loads(codable.encode(PlanningMachineReference.legacy()))
    bad["legacyProfile"]["maxShankDiameter"] = 0
    with pytest.raises(MachineDefinitionError):
        codable.decode(PlanningMachineReference, json.dumps(bad))
