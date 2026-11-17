"""Port of CoastlineSelfTest/GuidedTests.swift."""

import math
import re

import pytest

from coastline_app.core import feeds
from coastline_app.core.export import guided_job as G
from coastline_app.core.export import surface_probe as SurfaceProbe
from coastline_app.core.inventory.catalogs import ToolCatalog
from coastline_app.core.inventory.items import MeasuringKind, MeasuringTool, StockItem, Tool, ToolKind
from coastline_app.core.machine.profile import MachineProfile
from coastline_app.core.materials import MaterialLibrary
from coastline_app.core.plan import reference_bores as ReferenceBores
from coastline_app.core.plan.engraving import Engraving
from coastline_app.core.plan.operation import Operation, OperationKind
from coastline_app.core.plan.setup import CustomFixture
from coastline_app.core.plan.texture import Pattern, Region, Texture
from coastline_app.core.plan.threads import ThreadSpec
from coastline_app.core.safety.gcode_validator import Context, GCodeValidator
from coastline_app.mill.connection import MillConnection
from coastline_app.mill.geometry import Point3
from coastline_app.mill.gcode import program_from_source
from coastline_app.mill.mock import MockGRBL
from coastline_app.mill.serial_connection import MachineLog
from coastline_app.mill.transport import MillDevice


def connect(mock):
    return MillConnection.connect(MillDevice("/dev/mock", "MOCK"), mock, MachineLog(), is_manual_operation=lambda: False)


def test_markdown_is_made_safe_for_the_cutcode_format():
    lines = G.safe_markdown("Tip: keep it clean\nOK!\n**Bold:** fine\nnormal line").split("\n")
    assert lines[:3] == ["› Tip: keep it clean", "OK! ", "**Bold:** fine"]


def test_air_cut_lifts_z_and_never_starts_the_spindle():
    g = "G90 G17 G21\nG53 G0 G90 Z-1.\nS0 M3\nG4 P1.\nS5000\nS8000 M3\nG0 X1 Y2 Z3\nG1 Z-1 F100\nG2 X3 Y2 Z-1 I1 J0\nG53 G0 G90 Z-1.\nM5\n"
    a = G.air_cut(g, 10)
    assert not any(not l.startswith("(") and ("M3" in l or l.startswith("S")) for l in a.split("\n"))
    assert "G1 Z9 F100" in a and "Z13" in a and "G53 G0 G90 Z-1." in a, a


def test_guided_project_reads_back_in_the_package_parser():
    al = MaterialLibrary.material("al-6061")
    tool = Tool.make('1/4" flat end mill', ToolKind.FLAT_END_MILL, 6.35, 6.35, 3, 12.7, 28.575, 50.8)
    stock = StockItem.make("al-6061", 150, 80, 20)
    data = feeds.compute(tool, al, feeds.OperationKind.FACING)
    program = G.facing_program(80, 150, 0.25, tool, data, MachineProfile.standard(), "Test #1")
    inp = G.Input("Pendant", al, stock, (80, 150, 20), "OP1", [G.Program(tool, program, ["Facing"], 7)],
                  [G.Checkpoint(0, "Stock face flatness", 0, 0.02)], [MeasuringTool.make("Digital caliper", MeasuringKind.CALIPER)],
                  bytes([0x89, 0x50, 0x4E, 0x47]))
    jobs, files = G.build(inp)
    assert [j.title for j in jobs] == ["OP1 · Pendant"]
    job = jobs[0]
    assert len(job.steps) > 20
    assert any(s.gcode_path == "Code/set_x_centre.nc" for s in job.steps)
    air = next(k for k, s in enumerate(job.steps) if s.title == "Air Cut First?")
    assert job.steps[air].popup_no_step == "+2"
    assert job.steps[air + 2].title == "Cut · Program 1"
    measure = next(k for k, s in enumerate(job.steps) if s.title.startswith("Measure"))
    assert job.steps[measure].popup_yes_step == "+2" and job.steps[measure + 1].go_to == "-1"
    v = GCodeValidator()
    lo, hi = (-40, -75, -20), (40, 75, 0)
    cut = files[job.steps[air + 2].gcode_path].decode()
    assert v.validate(cut, Context(lo, hi, tool)).passed
    r = v.validate(files[job.steps[air + 1].gcode_path].decode(), Context(lo, hi, tool, air_cut=True))
    assert r.passed and r.min_z > 9, ([i.message for i in r.issues], r.min_z)


def test_custom_holding_export_does_not_invent_a_clamp_kit_or_assume_the_flip_position():
    tool = Tool.make("Flat", ToolKind.FLAT_END_MILL, 3.175, 3.175, 2, 12, 25, 50)
    inp = G.Input("Pocket block", MaterialLibrary.material("al-6061"), StockItem.make("al-6061", 60, 30, 10), (30, 60, 10), "Custom",
                  [G.Program(tool, "G21 G90\nM5\n", ["Pocket"], 1), G.Program(tool, "G21 G90\nM5\n", ["Back pocket"], 1, side=1)],
                  [], [], None)
    inp.custom_holding = CustomFixture("Test vise", 12, 2.0, "Grip on the uncut lower band.")
    jobs, _ = G.build(inp)
    job = jobs[-1]
    mount = next(s for s in job.steps if s.title == "Mount the Stock").markdown
    assert "Test vise" in mount and "Grip on the uncut lower band." in mount and "not included in collision checks" in mount
    assert "universal clamp" not in mount and "lower jaw" not in mount and "T-slot" not in mount
    flip = next(s for s in job.steps if s.title == "Flip the Stock").markdown
    assert "Test vise" in flip and "not assumed" in flip and "lower jaw" not in flip
    assert "thin web" not in next(s for s in job.steps if s.title == "Done").markdown


def test_reference_bores_sit_in_the_frame_off_the_centre_line():
    from coastline_app.core.codable import Range
    strips = [((-70, -114.75), (-30, -62.725)), ((-70, 62.725), (-30, 114.75)), ((10, -114.75), (70, -62.725)), ((10, 62.725), (70, 114.75))]
    plan = ReferenceBores.place((80, 169.5, 20), (-35, -50.8), (35, 50.8), 15, strips, Range(-43, 43), 6.35, 26)
    a = plan.centres_a
    assert len(a) == 2
    assert abs(a[0][0] - a[1][0]) < 1e-9 and abs(a[0][0]) >= 4
    assert abs(a[0][1] + a[1][1]) < 1e-9
    assert abs(a[0][1]) - 5 >= 50.8 + 15 and abs(a[0][1]) + 5 <= 169.5 / 2 - 2
    assert plan.depth_a == 19
    assert plan.window_depth > 1 and plan.probe_z < -plan.window_depth
    assert plan.centres_b[0] == (a[0][0], -a[0][1])
    assert ReferenceBores.place((80, 110, 20), (-35, -50.8), (35, 50.8), 15, tool_diameter=6.35, max_depth=26) is None
    for g in [ReferenceBores.bore_program(plan, 0, 6.35, True), ReferenceBores.zero_program(plan),
              ReferenceBores.top_program(-0.25), ReferenceBores.edge_program("X", 1, 2)]:
        for line in g.split("\n"):
            assert len(line) <= 79, line
        program_from_source(g.split("\n"))


def test_reference_bores_set_side_b_zero():
    plan = ReferenceBores.Plan([(-7, -74), (-7, 74)], 19, 20)
    b = plan.centres_b
    origin = Point3(-40, -120, -30)
    sx, sy = 0.4, -0.7
    mock = MockGRBL()
    mock.set_offset(54, origin)
    mock.set_offset(55, Point3(origin.x + b[0][0] + sx, origin.y + b[0][1] + sy, 0))
    mock.set_offset(56, Point3(origin.x + b[1][0] + sx, origin.y + b[1][1] + sy, 0))
    c = connect(mock)
    try:
        zero = [l for l in ReferenceBores.zero_program(plan).split("\n") if "G0 X" not in l]
        c.execute_program(program_from_source(zero))
        g54 = mock.offset(54)
        assert abs(g54.x - (origin.x + sx)) < 1e-3 and abs(g54.y - (origin.y + sy)) < 1e-3, g54
        mock.set_offset(56, Point3(origin.x + b[1][0] + sx + 0.3, origin.y + b[1][1] + sy, 0))
        with pytest.raises(Exception):
            c.execute_program(program_from_source(zero))
    finally:
        c.disconnect()


def test_threads_pick_their_holes_and_cutters():
    m3 = ThreadSpec.named("M3")
    assert m3.tap_drill == 2.5
    assert m3.fits(2.5) and m3.fits(2.45) and not m3.fits(3.0) and not m3.fits(2.2)
    assert ThreadSpec.likely(3.3).name == "M4" and ThreadSpec.likely(4.2).name == "M5"
    assert ThreadSpec.likely(3.4) is None
    mills = [t for t in ToolCatalog.suggestions() if t.kind is ToolKind.THREAD_MILL]
    assert [t.part_number for t in mills] == ["890322", "737624", "890326", "890328"]
    m3mill = next(t for t in mills if t.part_number == "737624")
    assert m3.can_be_cut(m3mill)
    assert not ThreadSpec.named("M4").can_be_cut(m3mill)
    assert not ThreadSpec.named("M2.5").can_be_cut(m3mill)


def test_surface_probing_follows_the_face():
    cuts = [(0, -3, -0.575), (0, 3, -0.575), (0, -3, -0.65), (1.5, 3, -0.65), (-1.5, 0, -0.65), (1.5, -3, -0.65), (0, 3, -0.65)]
    face, _ = SurfaceProbe.flat_face(cuts, 0.15)
    assert abs((face if face is not None else 99) + 0.5) < 1e-9
    assert SurfaceProbe.flat_face([(0, 0, -0.65), (3, 0, -0.95)], 0.15)[0] is None
    points = SurfaceProbe.points([(c[0], c[1]) for c in cuts])
    assert 3 <= len(points) <= SurfaceProbe.MAX_POINTS
    probe = SurfaceProbe.program(points, -0.5)
    engrave = "G90 G17 G21\nG54\nG53 G0 G90 Z-1.\nS8000 M3\nG0 X0 Y-3\nG0 Z3\nG1 Z-0.65 F100\nG1 Y3\nG0 Z3\nG53 G0 G90 Z-1.\nM5"
    text, moved = SurfaceProbe.follow(engrave, -0.5)
    for line in (probe + text).split("\n"):
        assert len(line) <= 79
    assert len(moved) == len(engrave.split("\n"))
    assert "M112" in text and "M113" in text and "Z-0.15" in text
    mock = MockGRBL()
    mock.set_offset(54, Point3(-40, -120, -20))
    mock.options.probe_contact_z = -20.8
    c = connect(mock)
    try:
        c.execute_program(program_from_source(probe.split("\n")))
        before = len(mock.received_lines)
        c.execute_program(program_from_source(text.split("\n")))
        sent = [l for l in mock.received_lines[before:] if "G1" in l and "Z" in l]
        z = float(re.search(r"Z(-?[0-9.]+)", sent[0]).group(1))
        assert abs(z - (-0.8 - 0.15)) < 0.002, sent[0]
    finally:
        c.disconnect()


def test_textures_stay_in_their_area_with_their_spacing():
    for p in Pattern:
        t = Texture.preset(p)
        lines = t.lines()
        assert lines, p
        hx, hy = t.size[0] / 2, t.size[1] / 2
        for l in lines:
            for q in l:
                inside = math.hypot(*q) <= hx + 1e-6 if t.region is Region.CIRCLE else abs(q[0]) <= hx + 1e-6 and abs(q[1]) <= hy + 1e-6
                assert inside, (p, q)
    b = Texture.preset(Pattern.BARLEYCORN)
    rings = [l for l in b.lines() if math.dist(l[0], l[-1]) < 0.01]
    assert abs(len(rings) - (b.width / 2 - 2.5 * b.amplitude) / b.pitch) <= 2
    c = Texture.preset(Pattern.CLOUS_DE_PARIS).lines()
    dirs = {int(round(math.degrees(math.atan2(l[-1][1] - l[0][1], l[-1][0] - l[0][0])))) for l in c}
    assert dirs <= {45, -45, 135, -135} and len(dirs) >= 2
    assert len(Texture.preset(Pattern.SPIRAL).lines()) == 1
    e = Engraving(text="", depth=0.08)
    e.texture = Texture(Pattern.SUNBURST, width=10)
    e.x, e.y = 3, -2
    pts = [p for l in e.polylines() for p in l]
    mid = (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))
    assert math.dist(mid, (3, -2)) < 0.3, mid
    assert Operation(OperationKind.ENGRAVE).title == "Engraving"
    op = Operation(OperationKind.ENGRAVE)
    op.engraving = e
    assert op.title == "Texture · Sunburst (soleil)"


def test_tool_change_stops_short_where_the_jobs_clamps_are():
    m = MachineProfile.standard()
    plain = G.helper_files(m)["Code/tool_change_position.nc"]
    assert "G53 G0 Z-60" in plain
    short = G.helper_files(m, -28)["Code/tool_change_position.nc"]
    assert "G53 G0 Z-28" in short and "Z-60" not in short and "G53 G0 Z-1" in short
    moved = G.helper_files(m, None, -110)["Code/tool_change_position.nc"]
    assert "G53 G0 Y-110" in moved and "Y-58" not in moved and "G53 G0 Z-60" in moved
