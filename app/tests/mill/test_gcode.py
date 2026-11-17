"""Port of MillCoreSelfTest/GCodeTests.swift."""

from coastline_app.mill.gcode import GCodeLine, LineGroup, LineKind, chunk_gcode_line, program_from_source

L = GCodeLine.make


def test_cleaning():
    assert L("G0 X1.5 Y-2 ; rapid").cleaned == "G0X1.5Y-2"
    assert L("G1 (feed move) X3 F100").cleaned == "G1X3F100"
    assert L("(only a comment").cleaned == ""
    assert L("(only a comment").original == "(only a comment)"
    assert L("%").cleaned == ""
    assert L("\tM3 S10000").cleaned == "M3S10000"


def test_classification():
    empty = L("   ")
    assert empty.kind is LineKind.GRBL and empty.group is LineGroup.EMPTY
    axis = L("X10 Y5")
    assert axis.kind is LineKind.AXIS_FEED_SPINDLE and axis.group is LineGroup.MOTION
    dwell = L("G4 P0.1")
    assert dwell.kind is LineKind.GCODE and dwell.group is LineGroup.NON_MODAL and dwell.is_blocking and dwell.value == 4
    rapid = L("G00 X0")
    assert rapid.group is LineGroup.MOTION and not rapid.is_blocking and rapid.value == 0
    probe = L("G38.2 Z-10 F50")
    assert probe.is_probe and probe.group is LineGroup.MOTION
    wcs = L("G55")
    assert wcs.group is LineGroup.COORDINATE_SYSTEM and wcs.is_blocking and wcs.wcs == 55
    assert L("G20").units == 20
    assert L("g91").distance_mode == 91
    assert L("G091.1").distance_mode is None, "arc-centre mode must not change XYZ distance mode"
    assert L("G90.0").distance_mode == 90
    spindle = L("M3 S12000")
    assert spindle.kind is LineKind.MCODE and spindle.group is LineGroup.SPINDLE and spindle.mcode_options == "S12000"
    # Leading zeros keep the original's quirk: "M03" is an M-code but not grouped as spindle.
    assert L("M03").group is LineGroup.UNKNOWN
    custom = L("M102 G556X G54X + (2 * G55X)")
    assert custom.group is LineGroup.USER_DEFINED and custom.mcode_options == "G556XG54X+"
    assert L("$H").group is LineGroup.HOME
    assert L("$X").group is LineGroup.UNLOCK
    assert L("$#").group is LineGroup.WCS_INFO
    assert L("$J=G91 X1 F100").group is LineGroup.JOG
    assert L("$$").group is LineGroup.COMMAND and L("$$").is_blocking
    assert L("~").group is LineGroup.SPECIAL
    assert L("!").kind is LineKind.UNKNOWN, "'!' is not treated as GRBL by the original"


def test_program_inserts_helper_lines():
    program = program_from_source(["G21", "G38.2 Z-5 F20", "M101 G54X G55X 0.1"])
    assert [l.cleaned for l in program] == ["?", "G21", "?", "G38.2Z-5F20", "G4P0.1", "M101G54XG55X0.1"]
    assert program[0].is_injected and not program[2].is_injected


def test_probe_on_first_line_is_ignored_by_lookahead():
    assert [l.cleaned for l in program_from_source(["G38.2 Z-5", "G0 Z5"])] == ["G38.2Z-5", "G0Z5"]


def test_chunking():
    assert chunk_gcode_line("G10L2P1X0Y0") == ["G10L2P1", "X0", "Y0"]
    assert chunk_gcode_line("G0X1") == ["G0", "X1"]
