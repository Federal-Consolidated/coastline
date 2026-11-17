"""Port of CoastlineSelfTest/LibraryWorkholdingTests.swift."""

import copy
import json
import math

import numpy as np
import pytest

from coastline_app.core import codable
from coastline_app.core.export import guided_job as G
from coastline_app.core.feeds import OperationKind
from coastline_app.core.geometry import Vec3
from coastline_app.core.inventory.inventory import Inventory
from coastline_app.core.inventory.items import Accessory, AccessoryKind, Fixture, FixtureKind, StockItem, Tool, ToolKind
from coastline_app.core.machine.profile import MachineProfile
from coastline_app.core.materials import MaterialLibrary
from coastline_app.core.plan import job_library_guide
from coastline_app.core.plan import library_workholding as L
from coastline_app.core.plan.fixture_assembly import FixtureAssemblyState
from coastline_app.core.plan.operation import Operation
from coastline_app.core.plan.setup import CustomFixture, Facing, Setup
from coastline_app.core.plan.workholding_profile import Contact, ContactNormal, FixturePlanningProfile, LibraryWorkholdingPlan
from coastline_app.core.post.toolpath import Motion, Move, Role
from coastline_app.core.safety.fixture_clearance import FixtureField, box_triangles
from coastline_app.core.sim.dexel import DexelGrid

STOCK = (20.0, 20.0, 10.0)
TOOL = Tool.make("Test cutter", ToolKind.FLAT_END_MILL, 1, 1, 2, 10, 20, 40)


def jig(number: int, obstruction_x: float | None = None) -> L.Candidate:
    fixture = Fixture.make(f"Jig {number}", FixtureKind.OTHER, id=f"00000000-0000-0000-0000-{number:012d}", model_path="synthetic.step")
    p = FixturePlanningProfile()
    p.enabled, p.stock_size, p.allows_roughing, p.grip_definition_reviewed = True, Vec3(20, 20, 10), True, True
    p.contacts = [Contact(point=Vec3(-8, -8, -8), radius=0.4), Contact(point=Vec3(8, 8, -8), radius=0.4)]
    fixture.planning = p
    tris = [box_triangles((-30, -30, -20), (-28, -28, -18))]
    if obstruction_x is not None:
        tris.append(box_triangles((obstruction_x - 1, -1, -10), (obstruction_x + 1, 1, 0)))
    field = FixtureField(np.concatenate(tris), (-40, -40), (40, 40), cell=1)
    return L.Candidate(fixture, field, DexelGrid((-10, -10), (10, 10), 0.2), model_signature="synthetic")


def cut(key, x, y=0.0, depth=-2.0, side=0, kind=OperationKind.CONTOUR) -> L.Cut:
    return L.Cut(key, side, Operation(kind, tool_id=TOOL.id), TOOL,
                 [Move(Role.RAPID, x=x, y=y, z=3), Move(Role.PLUNGE, x=x, y=y, z=depth, feed=100),
                  Move(Role.CUT, x=x + 0.5, y=y, z=depth, feed=200), Move(Role.RAPID, x=x + 0.5, y=y, z=3)])


def issues(plan):
    return "".join(plan.issues)


def test_chosen_fixture_ids_and_mechanical_snapshots_round_trip_with_legacy_fallback():
    fixture = jig(1).fixture
    fixture.planning.assembly_state = FixtureAssemblyState({"fixed-slide": 12, "pressure-extension": 3.5}, True, {"fixed-end", "clamp-end"})
    setup = Setup()
    setup.fixture_assemblies = [fixture]
    setup.selected_fixture_ids = [fixture.id, jig(2).fixture.id]
    data = codable.encode(setup)
    reopened = codable.decode(Setup, data)
    assert reopened == setup
    assert reopened.fixture_assemblies[0].planning.assembly_state == fixture.planning.assembly_state
    raw = json.loads(data)
    raw.pop("selectedFixtureIDs")
    legacy = codable.decode(Setup, json.dumps(raw))
    assert legacy.selected_fixture_ids is None and legacy.fixture_assemblies == setup.fixture_assemblies
    setup.selected_fixture_ids = []
    assert codable.decode(Setup, codable.encode(setup)).selected_fixture_ids == []


def test_job_fixture_selection_allows_only_chosen_candidates_and_preserves_other_resources():
    a, b, c = jig(1).fixture, jig(2).fixture, jig(3).fixture
    inventory = Inventory()
    inventory.fixtures = [a, b, c]
    inventory.stock = [StockItem.make("al-6061", 20, 20, 10)]
    inventory.tools = [TOOL]
    inventory.accessories = [Accessory.make("Shop collet", AccessoryKind.COLLET, size=3.175)]
    setup = Setup()
    assert inventory.for_fixture_setup(setup) == inventory
    setup.selected_fixture_ids = [c.id, b.id, b.id]
    expected = copy.deepcopy(inventory)
    expected.fixtures = [b, c]
    assert inventory.for_fixture_setup(setup) == expected
    assert inventory.fixtures == [a, b, c]
    setup.selected_fixture_ids = []
    expected.fixtures = []
    assert inventory.for_fixture_setup(setup) == expected


def test_job_fixture_snapshot_keeps_its_state_but_uses_live_availability():
    owned = jig(1).fixture
    owned.quantity, owned.name = 3, "Updated library default"
    owned.planning.datum = Vec3(50, 60, 70)
    saved = copy.deepcopy(owned)
    saved.quantity, saved.name = 99, "Job placement"
    saved.planning.datum = Vec3(1, 2, 3)
    saved.planning.assembly_state = FixtureAssemblyState({"pressure-extension": 4}, True, {"fixed-end", "clamp-end"})
    setup = Setup()
    setup.fixture_assemblies, setup.selected_fixture_ids = [saved], [saved.id]
    inventory = Inventory()
    inventory.fixtures = [owned]
    expected = copy.deepcopy(saved)
    expected.quantity = 3
    assert inventory.for_fixture_setup(setup).fixtures == [expected]
    assert inventory.fixtures == [owned]
    inventory.fixtures[0].quantity = 0
    expected.quantity = 0
    unavailable = inventory.for_fixture_setup(setup)
    assert unavailable.fixtures == [expected]
    assert L.eligibility(unavailable.fixtures[0], STOCK)
    inventory.fixtures = []
    assert inventory.for_fixture_setup(setup).fixtures == []
    assert setup.fixture_assemblies == [saved]


def test_planner_cannot_substitute_an_unselected_fixture():
    blocked, clear = jig(1, 0), jig(2)
    candidates = [blocked, clear]
    inventory = Inventory()
    inventory.fixtures = [c.fixture for c in candidates]
    setup = Setup()
    setup.selected_fixture_ids = [blocked.fixture.id]

    def plan(s):
        ids = {f.id for f in inventory.for_fixture_setup(s).fixtures}
        return L.plan([cut("centre", 0)], [c for c in candidates if c.fixture.id in ids], STOCK)

    assert not plan(setup).complete
    setup.selected_fixture_ids = [clear.fixture.id]
    selected = plan(setup)
    assert selected.complete and [s.fixture.id for s in selected.steps] == [clear.fixture.id]
    setup.selected_fixture_ids = None
    assert plan(setup).complete


def test_visual_fixture_rotations_use_work_axes_and_keep_the_stock_datum_fixed():
    for facing in Facing:
        for spin in range(4):
            p = FixturePlanningProfile()
            p.facing, p.spin, p.datum, p.grip_definition_reviewed = facing, spin, Vec3(12, -3, 7), True
            datum, point = np.array([12, -3, 7, 1.0]), np.array([22, 4, 11, 1.0])
            for axis in range(3):
                for q in (-1, 1):
                    nxt = p.turned(axis, q)
                    actual = nxt.model_to_work @ point
                    before = p.model_to_work @ point
                    rotation = Setup().turned(axis, q).part_rotation
                    assert np.linalg.norm(actual[:3] - rotation @ before[:3]) < 1e-7
                    assert np.linalg.norm((nxt.model_to_work @ datum)[:3]) < 1e-7
                    assert not nxt.grip_definition_reviewed


def test_fixture_nudges_stay_in_machine_directions_after_turning_sideways():
    p = FixturePlanningProfile()
    p.datum = Vec3(3, 4, 5)
    p = p.turned(2, 1).turned(1, -1)
    p.grip_definition_reviewed = True
    point = np.array([10, 20, 30, 1.0])
    for delta in (Vec3(5, 0, 0), Vec3(0, -5, 0), Vec3(0, 0, 10)):
        nxt = p.moved(delta)
        d = (nxt.model_to_work @ point - p.model_to_work @ point)[:3]
        assert np.linalg.norm(d - delta.array) < 1e-7
        assert not nxt.grip_definition_reviewed


def test_stock_guide_uses_owned_blanks_and_does_not_require_a_clamp_frame():
    exact = StockItem.make("al-6061", 20, 20, 10)
    unavailable = StockItem.make("al-6061", 20, 20, 10, quantity=0)
    unknown = StockItem.make("no-material", 20, 20, 10)
    inventory = Inventory()
    inventory.stock = [unavailable, unknown, exact]
    choices = job_library_guide.stock_choices(STOCK, inventory)
    assert [c.stock.id for c in choices] == [exact.id] and choices[0].matching_fixtures == 0


def test_stock_guide_prefers_an_owned_defined_jig_without_discarding_other_stock():
    small, matched = StockItem.make("al-6061", 18, 18, 8), StockItem.make("al-6061", 20, 20, 10)
    inventory = Inventory()
    inventory.stock, inventory.fixtures = [small, matched], [jig(1).fixture]
    assert [c.stock.id for c in job_library_guide.stock_choices((18, 18, 8), inventory)] == [matched.id, small.id]
    inventory.fixtures[0].quantity = 0
    without = job_library_guide.stock_choices((18, 18, 8), inventory)
    assert without[0].stock.id == small.id and all(c.matching_fixtures == 0 for c in without)


def test_stock_guide_proposes_the_orientation_that_matches_the_jig():
    stock = StockItem.make("al-6061", 10, 30, 20)
    fixture = jig(1).fixture
    fixture.planning.stock_size = Vec3(20, 30, 10)
    inventory = Inventory()
    inventory.stock, inventory.fixtures = [stock], [fixture]
    choices = job_library_guide.stock_choices((18, 28, 8), inventory)
    assert choices[0].axes == [2, 1, 0] and choices[0].matching_fixtures == 1


def test_a_cut_from_the_upper_side_counts_against_the_next_setups_grip():
    turned = jig(2)
    turned.fixture.planning.stock_size = Vec3(10, 20, 20)
    turned.fixture.planning.contacts = [Contact(point=Vec3(4, 9, -19), radius=0.3), Contact(point=Vec3(-4, 9, -19), radius=0.3)]
    bad = L.plan([cut("side hole", 3, -8, -18, 2), cut("front", 0)], [jig(1), turned], STOCK)
    assert not bad.complete and "grip/support material" in issues(bad), bad.issues
    good = L.plan([cut("side hole", 0, 2, -6, 2), cut("front", 0)], [jig(1), turned], STOCK)
    assert good.complete and [s.side for s in good.steps] == [2, 0], good.issues
    assert good.steps[0].instructions.startswith("Turn the stock so its upper side faces the spindle."), good.steps[0].instructions
    assert [s.fixture.id for s in good.steps] == [turned.fixture.id, jig(1).fixture.id]


def test_side_clamping_patches_are_checked_in_their_own_face_plane():
    c = jig(1)
    c.fixture.planning.contacts = [Contact(point=Vec3(-10, 0, -5), radius=0.5, normal=ContactNormal.X),
                                   Contact(point=Vec3(10, 0, -5), radius=0.5, normal=ContactNormal.X)]
    good = L.plan([cut("front", 0)], [c], STOCK)
    assert good.complete, good.issues
    bad = L.plan([cut("grip", -9.7, depth=-8)], [c], STOCK)
    assert not bad.complete and "grip/support material" in issues(bad), bad.issues


def test_a_locating_fixture_can_use_a_pocket_only_after_it_is_machined():
    a, b = jig(1, 5), jig(2)
    for row in (49, 50):
        for col in (49, 50):
            b.occupied.add(row * b.occupied.cols + col, -2, -1)
    too_soon = L.plan([cut("finish", 5)], [b], STOCK)
    assert not too_soon.complete and "intersects material" in issues(too_soon)
    rough = cut("pocket", -2, depth=-3, kind=OperationKind.ADAPTIVE)
    rough.moves = [Move(Role.RAPID, x=-2, y=-0.5, z=3), Move(Role.PLUNGE, x=-2, y=-0.5, z=-3, feed=100)]
    for y in (-0.5, 0, 0.5):
        rough.moves += [Move(Role.CUT, x=-2, y=y, z=-3, feed=200), Move(Role.CUT, x=2, y=y, z=-3, feed=200)]
    plan = L.plan([rough, cut("finish", 5)], [a, b], STOCK)
    assert plan.complete and len(plan.steps) == 2, plan.issues
    assert [s.fixture.id for s in plan.steps] == [a.fixture.id, b.fixture.id]


def test_a_side_b_locating_pin_uses_the_cavity_actually_cut_on_side_a():
    a, b = jig(1, 5), jig(2)
    row = int(math.floor((3 - b.occupied.origin[1]) / b.occupied.cell + 0.5))
    for col in (49, 50):
        b.occupied.add(row * b.occupied.cols + col, -9.5, -8)
    rough = cut("pocket", -2, -3, -3, kind=OperationKind.ADAPTIVE)
    rough.moves = [Move(Role.RAPID, x=-2, y=-3.5, z=3), Move(Role.PLUNGE, x=-2, y=-3.5, z=-3, feed=100)]
    for y in (-3.5, -3, -2.5):
        rough.moves += [Move(Role.CUT, x=-2, y=y, z=-3, feed=200), Move(Role.CUT, x=2, y=y, z=-3, feed=200)]
    plan = L.plan([rough, cut("B", 5, side=1)], [a, b], STOCK)
    assert plan.complete and len(plan.steps) == 2 and plan.steps[1].side == 1, plan.issues


def test_assigns_different_owned_jigs_to_cuts_they_actually_clear():
    a, b = jig(1, -5), jig(2, 5)
    plan = L.plan([cut("left", -5), cut("right", 5)], [a, b], STOCK)
    assert plan.complete and len(plan.steps) == 2, plan.issues
    assert [s.fixture.id for s in plan.steps] == [b.fixture.id, a.fixture.id]
    assert [k for s in plan.steps for k in s.cut_keys] == ["left", "right"]
    assert not plan.reviewed


def test_minimizes_reclampings_without_reordering_cuts():
    plan = L.plan([cut("left", -5), cut("right", 5)], [jig(1, -5), jig(2, 5), jig(3)], STOCK)
    assert plan.complete and len(plan.steps) == 1, plan.issues
    assert plan.steps[0].fixture.name == "Jig 3" and plan.steps[0].cut_keys == ["left", "right"]


def test_rejects_a_regrip_on_material_removed_by_earlier_cuts():
    a, b = jig(1, 5), jig(2)
    a.fixture.planning.contacts = [Contact(point=Vec3(8, -8, -8), radius=0.4), Contact(point=Vec3(8, 8, -8), radius=0.4)]
    b.fixture.planning.contacts = [Contact(point=Vec3(-8, -8, -8), radius=0.4), Contact(point=Vec3(-8, 8, -8), radius=0.4)]
    plan = L.plan([cut("rough", -8, -8, -9, kind=OperationKind.ADAPTIVE), cut("finish", 5)], [a, b], STOCK)
    assert not plan.complete and not plan.steps and "grip/support material" in issues(plan), plan.issues


def test_side_b_does_not_restore_material_removed_on_side_a():
    a, b = jig(1, 5), jig(2)
    a.fixture.planning.contacts = [Contact(point=Vec3(8, -8, -8), radius=0.4), Contact(point=Vec3(8, 8, -8), radius=0.4)]
    b.fixture.planning.contacts = [Contact(point=Vec3(-8, 8, -2), radius=0.4), Contact(point=Vec3(-8, -8, -2), radius=0.4)]
    plan = L.plan([cut("A", -8, -8, -9), cut("B", 5, side=1)], [a, b], STOCK)
    assert not plan.complete and "grip/support material" in issues(plan), plan.issues


def test_does_not_pretend_an_undefined_or_unowned_fixture_can_hold_stock():
    c = jig(1)
    c.fixture.quantity = 0
    assert L.eligibility(c.fixture, STOCK)
    c.fixture.quantity, c.fixture.planning = 1, None
    assert L.eligibility(c.fixture, STOCK)
    c = jig(1)
    c.fixture.planning.stock_size = Vec3(30, 20, 10)
    assert L.eligibility(c.fixture, STOCK)
    c = jig(1)
    c.fixture.planning.allows_roughing = False
    plan = L.plan([cut("rough", 0, kind=OperationKind.ADAPTIVE)], [c], STOCK)
    assert not plan.complete and "not defined for roughing" in issues(plan)


def test_checks_arc_extrema_against_machine_travel():
    candidate = jig(1)
    env = MachineProfile.standard().machine_envelope
    candidate.machine_origin = np.array([env.x.upper - 1, (env.y.lower + env.y.upper) / 2, (env.z.lower + env.z.upper) / 2 - TOOL.stickout])
    op = cut("arc", 0)
    op.moves = [Move(Role.RAPID, x=0, y=-5, z=3), Move(Role.PLUNGE, x=0, y=-5, z=-2, feed=100),
                Move(Role.CUT, Motion.ARC_CCW, x=0, y=5, z=-2, i=0, j=5, feed=200)]
    plan = L.plan([op], [candidate], STOCK)
    assert not plan.complete and "past the machine's" in issues(plan), plan.issues


def test_a_longer_tool_raises_the_spindle_in_the_travel_check():
    candidate = jig(1)
    env = MachineProfile.standard().machine_envelope
    candidate.machine_origin = np.array([(env.x.lower + env.x.upper) / 2, (env.y.lower + env.y.upper) / 2, env.z.lower + 5])
    plan = L.plan([cut("deep", 0)], [candidate], STOCK)
    assert "past the machine's" not in issues(plan), plan.issues


def test_invalid_input_produces_an_issue_instead_of_crashing():
    plan = L.plan([cut("bad", math.nan)], [jig(1)], STOCK)
    assert not plan.complete and "Invalid" in issues(plan)
    fixture = jig(1).fixture
    fixture.planning.datum = Vec3(fixture.planning.datum.x, fixture.planning.datum.y, math.inf)
    assert L.eligibility(fixture, STOCK)


def test_fixture_definitions_and_plans_round_trip_without_breaking_old_inventory():
    fixture = jig(1).fixture
    assert codable.decode(Fixture, codable.encode(fixture)) == fixture
    raw = json.loads(codable.encode(fixture))
    raw.pop("planning")
    assert codable.decode(Fixture, json.dumps(raw)).planning is None
    plan = L.plan([cut("first", -5)], [jig(1)], STOCK)
    assert codable.decode(LibraryWorkholdingPlan, codable.encode(plan)) == plan


def test_guided_jobs_stop_for_fixture_changes_and_require_reviewed_setups():
    plan = L.plan([cut("left", -5), cut("right", 5)], [jig(1, -5), jig(2, 5)], STOCK)
    programs = []
    for step in plan.steps:
        p = G.Program(TOOL, "G21 G90\nM5\n", step.operations, 1)
        p.workholding = step
        programs.append(p)
    inp = G.Input("Test", MaterialLibrary.material("al-6061"), StockItem.make("al-6061", 20, 20, 10), STOCK, "Library",
                  programs, [], [], None)
    with pytest.raises(G.WorkholdingNotReviewed):
        G.validate_workholding(inp)
    for i, s in enumerate(plan.steps):
        s.reviewed = True
        programs[i].workholding = s
    inp.programs = programs
    inp.custom_holding = CustomFixture(plan.steps[0].fixture.name)
    G.validate_workholding(inp)
    jobs, _ = G.build(inp)
    steps = jobs[-1].steps
    assert sum(s.title.startswith("Change Workholding") for s in steps) == 1
    assert sum(s.title.startswith("Establish Work Zero") for s in steps) == 2
    assert any("Do not substitute a fresh blank" in s.markdown for s in steps)
    assert not any("edge_" in s.gcode_path for s in steps)
