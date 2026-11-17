"""Port of CoastlineSelfTest/MachinePlanningGeometryTests.swift."""

import copy
import json
from dataclasses import replace

import numpy as np
import pytest

from coastline_app.core import codable
from coastline_app.core.engine.client import MachinePart
from coastline_app.core.geometry import Vec3
from coastline_app.core.inventory.items import Fixture, FixtureKind
from coastline_app.core.machine.definition import MachineDefinitionError, MachineValidationStatus
from coastline_app.core.machine.package import MachineDefinitionPackage
from coastline_app.core.machine.planning_geometry import MachinePlanningGeometry
from coastline_app.core.mesh import MeshData
from coastline_app.core.plan.fixture_assembly import FixtureAssemblyDefinition
from coastline_app.core.plan import fixture_mechanism
from coastline_app.paths import REPO_ROOT

_DEF = None


def planning_definition():
    global _DEF
    if _DEF is None:
        _DEF = MachineDefinitionPackage.load(REPO_ROOT / "resources/machines/desktop-cnc").definition
    return copy.deepcopy(_DEF)


POINTS = [15.865, -389.423, 54.914, 15.865, -84.423, 54.914, 15.865, -84.423, 129.844, 15.865, -389.423, 129.844,
          1.260, -429.423, 54.914, 1.260, -44.423, 54.914, 1.260, -44.423, 129.844, 1.260, -429.423, 129.844]


def table_parts(points=None, extra=None):
    v = np.array(points or POINTS, np.float32).reshape(-1, 3)
    idx = [0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6]
    if extra is not None:
        base = len(v)
        v = np.concatenate([v, np.array(extra, np.float32).reshape(-1, 3)])
        idx += [base, base + 1, base + 2, base, base + 2, base + 3]
    n = np.tile(np.array([1, 0, 0], np.float32), (len(v), 1))
    mesh = MeshData(v, n, np.array(idx, np.uint32), Vec3.ZERO, Vec3.ZERO, False, 2)
    return [MachinePart("table", "aluminium", (0.5, 0.5, 0.5), mesh)]


def near(a: Vec3, b: Vec3, tol=0.00001):
    assert abs(a.x - b.x) < tol and abs(a.y - b.y) < tol and abs(a.z - b.z) < tol, f"expected {b}, got {a}"


def test_profile_coordinates_and_table_geometry_replace_legacy_constants():
    d = planning_definition()
    g = MachinePlanningGeometry(d, table_parts())
    near(g.model.model_pose, Vec3(0, -69, -79.9))
    near(g.model.spindle_nose, Vec3(105.43, -176.8, 112.26))
    assert abs(g.model.table_top_x - 15.865) < 0.000001
    assert len(g.model.t_slot_z) == 2
    assert abs(g.model.t_slot_z[0] - 78.759) < 0.000001
    assert abs(g.model.t_slot_z[1] - 118.764) < 0.000001
    assert abs(g.support_bounds.size.y - 305) < 0.0001
    assert abs(g.table_bounds.size.y - 385) < 0.0001
    table = g.bookend_mount_table(-251.75)
    assert table is not None
    assert table.top_x == g.model.table_top_x and table.slot_z == g.model.t_slot_z
    assert abs(table.slot_y.lower - -389.42) < 0.000001 and abs(table.slot_y.upper - -84.42) < 0.000001
    assert table.front_z == g.support_bounds.maximum.z and table.centre_y == -251.75
    assert g.bookend_mount_table(float("nan")) is None
    # The real table takes the C-clamps on the 2 × 2 × 8" bar and the vise on a small block.
    for file, stock in [("c-clamps/definition.json", (50.8, 203.2, 50.8)), ("vise/definition.json", (30, 40, 20))]:
        f = Fixture.make(file, FixtureKind.OTHER, quantity=2)
        f.assembly = codable.decode(FixtureAssemblyDefinition, (REPO_ROOT / "resources/fixtures" / file).read_bytes())
        assert fixture_mechanism.FixtureMechanism.automatic(f, table, stock) is not None, file
    home = g.component_translations(d.controller_home_position)
    near(home[g.table_component_id], Vec3(86, 0, 0))
    near(home[g.head_component_id], Vec3(0, 68.5, 79.4))
    near(home["cover"], Vec3.ZERO)
    assert g.is_moving("head")
    assert g.moves_with_table("table") and not g.moves_with_table("head")
    assert g.is_enclosure("cover") and not g.is_enclosure("table")


def test_rotated_cad_basis_and_renamed_components_produce_same_workspace():
    d = planning_definition()
    original = MachinePlanningGeometry(d, table_parts())

    def rotate(p):
        return Vec3(p.z, p.x, p.y)

    renamed = {c.id: f"assembly-{k}" for k, c in enumerate(d.components)}
    for c in d.components:
        c.id = renamed[c.id]
        c.parent_id = renamed[c.parent_id] if c.parent_id is not None else None
        if c.axis is not None:
            c.axis.direction = rotate(c.axis.direction)
    for f in d.frames:
        f.component_id = renamed[f.component_id]
        f.origin, f.x_direction, f.z_direction = rotate(f.origin), rotate(f.x_direction), rotate(f.z_direction)
    parts = table_parts()
    for p in parts:
        p.group = renamed[p.group]
        p.mesh.vertices = p.mesh.vertices[:, [2, 0, 1]].copy()
        p.mesh.normals = p.mesh.normals[:, [2, 0, 1]].copy()
    t = MachinePlanningGeometry(d, parts)
    near(t.model.spindle_nose, original.model.spindle_nose)
    assert t.support_bounds == original.support_bounds
    assert np.array_equal(t.model.parts[0].mesh.vertices, original.model.parts[0].mesh.vertices)
    assert np.array_equal(t.model.parts[0].mesh.normals, original.model.parts[0].mesh.normals)
    a, b = original.bookend_mount_table(-200), t.bookend_mount_table(-200)
    assert (b.slot_y, b.slot_z, b.top_x, b.front_z, b.centre_y) == (a.slot_y, a.slot_z, a.top_x, a.front_z, a.centre_y)
    near(t.component_translations(d.controller_home_position)[renamed["table"]], Vec3(86, 0, 0))
    near(t.planning_to_world(t.world_to_planning(Vec3(7, 8, 9))), Vec3(7, 8, 9))


def frame(d, fid):
    return next(f for f in d.frames if f.id == fid)


def test_unsupported_vertical_planner_cannot_silently_become_horizontal():
    d = planning_definition()
    f = frame(d, "table-surface")
    f.x_direction, f.z_direction = Vec3(1, 0, 0), Vec3(0, 0, 1)
    d.validate()  # still a valid generic digital machine definition
    with pytest.raises(MachineDefinitionError):
        MachinePlanningGeometry(d, table_parts())


def test_model_and_mounting_mismatch_must_be_corrected_before_planning():
    original = planning_definition()
    d = copy.deepcopy(original)
    f = frame(d, "table-surface")
    f.origin = f.origin.replacing(0, f.origin.x + 2)
    with pytest.raises(MachineDefinitionError):
        MachinePlanningGeometry(d, table_parts())
    d = copy.deepcopy(original)
    s = d.mounting_interfaces[0].slots[0]
    s.origin = s.origin.replacing(2, s.origin.z + 300)
    with pytest.raises(MachineDefinitionError):
        MachinePlanningGeometry(d, table_parts())
    d = copy.deepcopy(original)
    d.mounting_interfaces[0].slots[0].direction = Vec3(0, 0, 1)
    with pytest.raises(MachineDefinitionError):
        MachinePlanningGeometry(d, table_parts())
    with pytest.raises(MachineDefinitionError):
        MachinePlanningGeometry(original, [])


def test_physical_calibration_does_not_hide_unresolved_planning_requirements():
    d = planning_definition()
    MachinePlanningGeometry(d, table_parts())
    c = next(c for c in d.checks if c.id == "native-post")
    c.status, c.action = MachineValidationStatus.PENDING, "Review the changed post."
    with pytest.raises(MachineDefinitionError):
        MachinePlanningGeometry(d, table_parts())


def test_different_slot_families_stay_digital_without_claiming_vetted_fixture_compatibility():
    d = planning_definition()
    assert MachinePlanningGeometry(d, table_parts()).supports_vetted_fixture_mounting
    s0, s1 = d.mounting_interfaces[0].slots
    s1.origin = s1.origin.replacing(2, s0.origin.z + 80)
    pts = list(POINTS)
    for i in range(2, len(pts), 3):
        if pts[i] > 129:
            pts[i] = 190
    wider = MachinePlanningGeometry(d, table_parts(pts))
    assert not wider.supports_vetted_fixture_mounting and wider.bookend_mount_table(0) is None
    d = planning_definition()
    d.mounting_interfaces[0].slots[0].cavity_depth = 4
    assert not MachinePlanningGeometry(d, table_parts()).supports_vetted_fixture_mounting
    d = planning_definition()
    d.mounting_interfaces[0].slots[0].length = 10.99
    assert not MachinePlanningGeometry(d, table_parts()).supports_vetted_fixture_mounting
    d.mounting_interfaces[0].slots[0].length = 11
    assert MachinePlanningGeometry(d, table_parts()).supports_vetted_fixture_mounting


def test_bookend_mount_uses_only_table_slots_and_their_shared_length():
    d = planning_definition()
    expected = MachinePlanningGeometry(d, table_parts()).bookend_mount_table(-210)
    other = copy.deepcopy(d.mounting_interfaces[0])
    other.id, other.frame_id = "head-accessory-slots", "tool"
    other.slots[0].length = other.slots[1].length = 5
    d.mounting_interfaces.append(other)
    g = MachinePlanningGeometry(d, table_parts())
    assert g.supports_vetted_fixture_mounting
    a = g.bookend_mount_table(-210)
    assert (a.slot_y, a.slot_z, a.top_x, a.front_z, a.centre_y) == (expected.slot_y, expected.slot_z, expected.top_x, expected.front_z, expected.centre_y)
    s0, s1 = d.mounting_interfaces[0].slots
    s0.length = 250
    s1.origin = s1.origin.replacing(1, s1.origin.y + 280)
    s1.direction = s1.direction.replacing(1, -1)
    s1.length = 260
    overlap = MachinePlanningGeometry(d, table_parts()).bookend_mount_table(-210)
    assert abs(overlap.slot_y.lower - (expected.slot_y.lower + 20)) < 0.000001
    assert abs(overlap.slot_y.upper - (expected.slot_y.lower + 250)) < 0.000001
    s0.length = s1.length = 11
    disjoint = MachinePlanningGeometry(d, table_parts())
    assert disjoint.supports_vetted_fixture_mounting and disjoint.bookend_mount_table(-210) is None


def test_coplanar_fastener_pads_do_not_enlarge_the_stock_support_footprint():
    d = planning_definition()
    original = MachinePlanningGeometry(d, table_parts())
    actual = MachinePlanningGeometry(d, table_parts(extra=[15.865, -412, 126, 15.865, -403, 126, 15.865, -403, 129, 15.865, -412, 129]))
    assert actual.support_bounds == original.support_bounds
    assert abs(actual.support_bounds.size.y - 305) < 0.001
