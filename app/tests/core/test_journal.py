"""Port of CoastlineSelfTest/JournalTests.swift and MachineTests.swift."""

import json
import math

import numpy as np

from coastline_app.core import codable
from coastline_app.core.geometry import Vec3
from coastline_app.core.inventory.inventory import Inventory
from coastline_app.core.inventory.items import StockItem, Tool, ToolKind
from coastline_app.core.journal import FeedLearning, JournalEntry, Measurement, ProgramRun, ToolLife, record
from coastline_app.core.machine.profile import MachineProfile
from coastline_app.core.materials import MaterialLibrary
from coastline_app.core.plan.engraving import Engraving
from coastline_app.core.plan.operation import Operation, OperationKind
from coastline_app.mill.gcode import program_from_source


def test_recording_a_job_wears_tools_uses_stock_and_puts_the_offcut_back():
    tool = Tool.make('1/4" flat end mill', ToolKind.FLAT_END_MILL, 6.35, 6.35, 3, 19, 28, 63.5)
    bar = StockItem.make("al-6061", 150, 80, 20)
    bar.extrusion_axis = 0
    inv = Inventory()
    inv.tools, inv.stock = [tool], [bar]
    e = JournalEntry("Pendant", "al-6061", bar.size_description,
                     [ProgramRun("Roughing", tool.id, tool.name, 30, 12_000), ProgramRun("Facing", tool.id, tool.name, 5, 2_000)],
                     [Measurement("Thickness", 5, 0.05, 5.03)])
    e.stock_id, e.remnant_length = bar.id, 62
    notes = record(e, inv)
    assert abs(inv.tools[0].cutting_minutes - 35) < 1e-9 and abs(inv.tools[0].cutting_distance - 14_000) < 1e-9
    assert len(inv.stock) == 1
    r = inv.stock[0]
    assert r.is_remnant and r.id != bar.id and (r.size_x, r.size_y, r.size_z) == (62, 80, 20), r.size_description
    assert len(notes) == 2, notes
    assert e.measurements[0].in_tolerance is True
    al = MaterialLibrary.material("al-6061")
    assert ToolLife.status(inv.tools[0], al).used < 0.1
    assert ToolLife.shopping_list(inv, al) == []
    inv.tools[0].cutting_minutes = 850
    assert len(ToolLife.shopping_list(inv, al)) == 1, "nearly worn out, no spare"
    inv.tools[0].quantity = 3
    assert ToolLife.shopping_list(inv, al) == [], "spares on hand"


def test_chatter_teaches_slower_feeds_clean_jobs_give_some_back():
    ball = Tool.make('1/8" ball', ToolKind.BALL_END_MILL, 3.175, 3.175, 2, 9.5, 15, 38)
    learn = FeedLearning()
    e = JournalEntry("P", "al-6061", "", [ProgramRun("Finish", ball.id, ball.name, 10, 1)], [])
    e.chatter = True
    learn.learn(e, [ball])
    assert abs(learn.factor("al-6061", ToolKind.BALL_END_MILL) - 0.9) < 1e-9
    assert learn.factor("brass-360", ToolKind.BALL_END_MILL) == 1, "other materials untouched"
    e.chatter = False
    for _ in range(3):
        learn.learn(e, [ball])
    assert abs(learn.factor("al-6061", ToolKind.BALL_END_MILL) - 0.9 * 1.03) < 1e-9
    e.chatter = True
    for _ in range(20):
        learn.learn(e, [ball])
    assert learn.factor("al-6061", ToolKind.BALL_END_MILL) == 0.6, "never below 60 %"
    assert codable.decode(FeedLearning, codable.encode(learn)) == learn


def test_engraving_text_becomes_closed_outlines_of_the_right_size():
    e = Engraving(text="HI", height=4, x=1, y=-2, depth=0.15, font="Helvetica-Bold")
    loops = e.polylines()
    assert len(loops) >= 2
    assert all(math.dist(l[0], l[-1]) < 1e-6 for l in loops), "closed"
    pts = np.array([p for l in loops for p in l])
    lo, hi = pts.min(axis=0), pts.max(axis=0)
    assert abs((hi[0] - lo[0]) - 4) < 0.2, f"height {hi[0] - lo[0]}"
    assert abs((lo[0] + hi[0]) / 2 - 1) < 0.2 and abs((lo[1] + hi[1]) / 2 + 2) < 0.6
    assert hi[1] - lo[1] > 3, "the word runs along Y"
    turned = Engraving(text="HI", height=4, x=1, y=-2, depth=0.15, font="Helvetica-Bold", angle=90)
    s, flat = turned.size, e.size
    assert abs(s[1] - flat[0]) < 0.1 and abs(s[0] - flat[1]) < 0.1
    old = '{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"contour","enabled":true,"leaveRadial":0,"leaveAxial":0,"faceDepth":0.25,"springPass":false,"scallop":0.008,"angle":0,"steepAngle":45,"feedScale":1}'
    op = codable.decode(Operation, old)
    assert op.engraving is None and op.kind is OperationKind.CONTOUR


def test_envelope_matches_the_soft_limit_window():
    m = MachineProfile.standard()
    assert (m.machine_envelope.x.lower, m.machine_envelope.x.upper) == (-(m.travel.x - 0.5), -0.5)
    assert (m.machine_envelope.y.lower, m.machine_envelope.y.upper) == (-m.travel.y, -0.5)
    assert (m.machine_envelope.z.lower, m.machine_envelope.z.upper) == (-m.travel.z, -0.5)
    assert m.machine_envelope.contains(Vec3(-78, -165, -12.8))
    assert not m.machine_envelope.contains(Vec3(0, -100, -10))


def test_spindle_range_is_the_usable_one():
    m = MachineProfile.standard()
    assert m.is_usable_rpm(1500) and m.is_usable_rpm(8000)
    assert not m.is_usable_rpm(1400) and not m.is_usable_rpm(8500)


def test_tool_change_moves_are_valid_gcode():
    m = MachineProfile.standard()
    assert program_from_source(m.tool_change_moves)[0].is_home
    assert all(len(line) <= m.max_line_length for line in m.tool_change_moves)


def test_profile_round_trips_through_json():
    assert codable.decode(MachineProfile, codable.encode(MachineProfile.standard())) == MachineProfile.standard()


def test_tool_change_pose_follows_the_makers_moves():
    w = MachineProfile.standard().tool_change_waypoints
    assert len(w) == 4
    assert w[0][2] == -1 and w[1][1] == -58 and w[2][0] == -1 and tuple(w[3]) == (-1, -58, -60)
    assert tuple(MachineProfile.standard().tool_change_pose) == (-1, -58, -60)
