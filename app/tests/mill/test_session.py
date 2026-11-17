"""Port of MillCoreSelfTest/SessionTests.swift and SessionCoreTests.swift."""

import time
from pathlib import Path

import pytest

from coastline_app.mill.geometry import Point3, Range
from coastline_app.mill.mock import STANDARD_SETTINGS, MockGRBL, MockOptions
from coastline_app.mill.programs import M100, M101, M102, M106, TestProgram, check_job_program, check_test_program
from coastline_app.mill.session import MillSession
from coastline_app.mill.session_types import JogRequest, MillEnvelope, MillLink, MillPort, MillRefusal, ProgramOutcome
from coastline_app.mill.status import MillSettings
from coastline_app.mill.geometry import Axis

from .helpers import connected, homed, mill_mock, real_settings, wait_for

REPO = Path(__file__).resolve().parents[3]
NOT_HOMED = MillRefusal("notHomed")


def envelope_settings(travel: Point3, pull_off: float | None = None) -> MillSettings:
    s = MillSettings()
    s.update(130, travel.x)
    s.update(131, travel.y)
    s.update(132, travel.z)
    if pull_off is not None:
        s.update(27, pull_off)
    return s


def failed(s):
    return s.program is not None and s.program.outcome is ProgramOutcome.FAILED


# ---------------------------------------------------------------- SessionCoreTests

def test_digital_machine_homes_through_production_connection():
    session = MillSession()
    session.connect(MillPort.simulated())
    try:
        wait_for(session, "digital ready", lambda s: s.gates.home is None)
        assert session.home() is None
        wait_for(session, "digital homed", lambda s: s.homed and s.homing_since is None and s.gates.jog is None, timeout=8)
    finally:
        session.disconnect()


def test_envelope_uses_controller_pull_off_or_default_margin():
    travel = Point3(100, 200, 80)
    e = MillEnvelope.from_settings(envelope_settings(travel))
    assert (e.x, e.y, e.z) == (Range(-99.5, -0.5), Range(-199.5, -0.5), Range(-79.5, -0.5))
    e = MillEnvelope.from_settings(envelope_settings(travel, 2))
    assert (e.x, e.y, e.z) == (Range(-98.0, -2.0), Range(-198.0, -2.0), Range(-78.0, -2.0))


def test_envelope_rejects_pull_off_that_inverts_any_axis():
    for travel in (Point3(3, 100, 100), Point3(100, 3, 100), Point3(100, 100, 3)):
        assert MillEnvelope.from_settings(envelope_settings(travel, 2)) is None
    touching = MillEnvelope.from_settings(envelope_settings(Point3(4, 100, 100), 2))
    assert touching.x == Range(-2.0, -2.0)


def test_envelope_rejects_nonfinite_travel_and_pull_off():
    for invalid in (float("nan"), float("inf"), float("-inf")):
        for travel in (Point3(invalid, 100, 100), Point3(100, invalid, 100), Point3(100, 100, invalid)):
            assert MillEnvelope.from_settings(envelope_settings(travel)) is None
        assert MillEnvelope.from_settings(envelope_settings(Point3(100, 100, 100), invalid)) is None


def test_invalid_envelope_refuses_motion_and_work_offset_changes():
    def reply(line):
        if line != "$$":
            return None
        # 50 mm at each end exceeds the controller's X and Z travel.
        return "\r\n".join([f"${n}={50 if n == 27 else v}" for n, v, _ in STANDARD_SETTINGS] + ["ok"])

    mock = MockGRBL(MockOptions(reply_override=reply))
    session = MillSession()
    session.connect(MillPort.simulated(), transport=mock)
    try:
        wait_for(session, "invalid settings refusal", lambda s: s.link is MillLink.CONNECTED and s.parser_state is not None
                 and s.status is not None and s.gates.home is not None)
        snapshot = session.snapshot
        assert snapshot.envelope is None
        problem = MillSession.settings_problem(snapshot.settings)
        assert "$130–$132" in problem and "$27" in problem
        refusal = MillRefusal("settings", problem)
        assert snapshot.gates.home == refusal == snapshot.gates.jog == snapshot.gates.run == snapshot.gates.setup
        assert session.home() == refusal
        assert session.jog(JogRequest(axis=Axis.X, distance=1, feed=100)) == refusal
        assert session.set_work_position({Axis.X: 0}, 54) == refusal
        assert not any(l == "$H" or l.startswith("$J=") or l.startswith("G10") for l in mock.received_lines)
    finally:
        session.disconnect()


# ---------------------------------------------------------------- SessionTests

def test_home_target_and_envelope_from_real_settings():
    settings = real_settings()
    assert MillSession.home_target(settings) == Point3(-86, -0.5, -0.5)
    e = MillEnvelope.from_settings(settings)
    assert (e.x, e.y, e.z) == (Range(-86.0, -0.5), Range(-241.0, -0.5), Range(-78.0, -0.5))
    assert MillSession.settings_problem(settings) is None


def test_console_rules():
    for line in ["$RST=*", "$RST=#", "$130=1", "$N0=G0X0", "$I=x", "$L", "$HX"]:
        assert MillSession.blocked_console_reason(line) is not None, line
    for line in ["$$", "$#", "$G", "$I", "$X", "$N", "G21", "M5", "G54"]:
        assert MillSession.blocked_console_reason(line) is None, line
    for line in ["G0X-10", "G1Y-5F100", "$J=G91G21X1F100", "X-3", "G28", "G38.2Z-5F50", "G91G0Z1"]:
        assert MillSession.is_motion(line), line
    for line in ["G21", "G90", "M5", "G54", "G10L20P1X0", "$$", "(MOVE X10)", "G4P1", "M3S8000"]:
        assert not MillSession.is_motion(line) or line.startswith("G10"), line


def test_connect_sends_only_read_only_commands():
    mock = mill_mock()
    session = connected(mock)
    try:
        wait_for(session, "offsets", lambda s: s.offsets and s.firmware is not None)
        assert mock.received_lines == ["$$", "$I", "$#", "$G"]
        assert all(b == ord("?") for b in mock.realtime_bytes)
        s = session.snapshot
        assert s.locked and s.banner == "Grbl 1.1g [help:'$']"
        assert s.firmware == "[grbl:1.1g XY:3A PCB:3B YMD:20240318]"
        assert s.state == "Alarm" and not s.homed and s.gates.jog == NOT_HOMED
    finally:
        session.disconnect()


def test_home_then_jog_is_clamped_to_the_envelope():
    mock = mill_mock()
    session = homed(mock)
    try:
        assert mock.position == Point3(-86, -0.5, -0.5)
        assert not session.snapshot.locked
        # From home, Y can only go negative and X only positive.
        assert session.jog(JogRequest(axis=Axis.Y, distance=10, feed=300)) is None
        assert session.jog(JogRequest(axis=Axis.X, distance=-10, feed=300)) is None
        assert session.jog(JogRequest(axis=Axis.Y, distance=-10, feed=5000)) is None
        wait_for(session, "jog", lambda s: abs((s.status.machine_position.y if s.status else 0) + 10.5) < 0.001 and s.gates.jog is None)
        assert [l for l in mock.received_lines if l.startswith("$J=")] == ["$J=G21 G91 Y-10.000 F3100"]  # capped by $111
        assert session.jog(JogRequest(axis=Axis.X, distance=100, feed=1000)) is None
        wait_for(session, "x to the far end", lambda s: abs((s.status.machine_position.x if s.status else 0) + 0.5) < 0.001)
        assert mock.position.x == -0.5
    finally:
        session.disconnect()


def test_jog_and_console_moves_need_homing():
    mock = mill_mock()
    session = connected(mock)
    try:
        wait_for(session, "status", lambda s: s.status is not None)
        assert session.jog(JogRequest(axis=Axis.Y, distance=-1, feed=300)) == NOT_HOMED
        assert session.send_console("G0 Y-10") == NOT_HOMED
        assert session.send_console("$RST=*") is not None
        assert session.send_console("$#") is None
        time.sleep(0.3)
        assert not any(l.startswith(("$J", "G0", "$RST")) for l in mock.received_lines)
    finally:
        session.disconnect()


def test_stop_and_hold_are_never_refused():
    mock = mill_mock()
    session = homed(mock)
    try:
        mock.silent = True
        wait_for(session, "silence", lambda s: s.silent_since is not None, timeout=4)
        assert session.snapshot.gates.jog == MillRefusal("silent")
        assert not session.snapshot.homed
        session.feed_hold()
        session.jog_cancel()
        session.stop()
        time.sleep(0.2)
        b = mock.realtime_bytes
        assert ord("!") in b and 0x85 in b and 0x18 in b
    finally:
        session.disconnect()


def test_soft_reset_clears_homed_and_restart_is_detected():
    mock = mill_mock()
    session = homed(mock)
    try:
        session.stop()  # Idle: a soft reset
        wait_for(session, "restart", lambda s: s.restarts == 1 and s.locked)
        assert not session.snapshot.homed
        assert session.snapshot.gates.jog == NOT_HOMED
    finally:
        session.disconnect()


def test_song_matches_the_file_played_on_the_real_mill():
    file = REPO / "scripts" / "korobeiniki.nc"
    if not file.exists():
        pytest.skip("scripts/korobeiniki.nc not present")
    envelope = MillEnvelope.from_settings(real_settings())
    home = Point3(-86, -0.5, -0.5)
    from_file = check_test_program(file.read_text().split("\n"), home, envelope)
    from_code = check_test_program(TestProgram.KOROBEINIKI.lines, home, envelope)
    assert len(from_code) == 68
    assert from_code == from_file


def test_program_check_refuses_unsafe_lines():
    envelope = MillEnvelope.from_settings(real_settings())
    home = Point3(-86, -0.5, -0.5)
    for bad in (["M3 S8000"], ["G91", "G1 Y-300 F100"], ["G90", "G1 Y-10 F100"], ["G91", "G1 X-5 F100"],
                ["G2 X-10 Y-10 I1 F100"], ["G91", "G53 G1 Y-1 F100"], ["$H"], ["G20"]):
        with pytest.raises(MillRefusal):
            check_test_program(bad, home, envelope)
    assert check_test_program(["G21 (mm)", "G91", "g1 y-1 f100 ; down"], home, envelope) == ["G21", "G91", "G1Y-1F100"]


def test_song_runs_on_the_simulated_mill():
    mock = mill_mock()
    session = homed(mock)
    try:
        assert session.run(TestProgram.KOROBEINIKI.title, TestProgram.KOROBEINIKI.lines) is None
        wait_for(session, "song done", lambda s: s.program is not None and s.program.outcome is ProgramOutcome.COMPLETED, timeout=10)
        assert session.snapshot.program.done == 68
        assert mock.position == Point3(-86, -0.5, -0.5)
        assert "G53G1Y-30.000F1000" in mock.received_lines
        assert session.snapshot.gates.run is None
    finally:
        session.disconnect()


def test_program_needs_homing_and_an_error_holds():
    mock = mill_mock(reply_override=lambda l: "error:20" if l == "G4P0.5" else None)
    session = connected(mock)
    try:
        wait_for(session, "status", lambda s: s.status is not None)
        assert session.run("song", TestProgram.KOROBEINIKI.lines) == NOT_HOMED
        assert session.home() is None
        wait_for(session, "homed", lambda s: s.homed and s.gates.run is None)
        assert session.run("song", TestProgram.KOROBEINIKI.lines) is None
        wait_for(session, "failure", failed)
        assert ord("!") in mock.realtime_bytes
        assert "G91" not in mock.received_lines  # nothing after the failed line
    finally:
        session.disconnect()


def test_job_program_check():
    settings, envelope = real_settings(), MillEnvelope.from_settings(real_settings())
    typical = check_job_program(["G90 G94 G17", "G21", "G40 G91.1", "M3 S8000", "G0 X1.5 Y-2. (comment)", "G1 Z-1. F600",
                                 "G2 X2 Y-2 I0.25 J0", "G38.3 Z-5 F30", "G10 L20 P2 Z0", "G0 X+0.25",
                                 "G53 G0 Z-1.", "M5"], settings, envelope)
    assert len(typical.lines) == 12
    # A file from other CAM: tape markers, a program number and line numbers carry no motion.
    file = check_job_program(["%", "O1001 (part)", "N10 G90 G21", "N20 M3 S8000", "N30", "N40 G0 X1 Y-2", "N50 M30", "%"], settings, envelope)
    assert file.lines == ["G90G21", "M3S8000", "G0X1Y-2", "M30"]
    home = check_job_program(["$H (home)", "G92.1", "$#", "G10 L20 P2 X0 Y0 Z0"], settings, envelope)
    assert home.starts_with_home and home.lines == ["$H", "G92.1", "G4P0", "$#", "G10L20P2X0Y0Z0"]
    for bad in (["G20"], ["G28"], ["$X"], ["M6 T1"], ["M3 S9000"], ["G10 L1 P1 R2"], ["G53 G0 X10"], ["M100 G56X G57X"],
                ["M101 G57 G58 X 0.1"], ["$L"], ["G38.4 Z-5 F20"], ["G49 G0 Z-1"], ["G93"], ["N10 G28"], ["O1001 G0 X1"]):
        with pytest.raises(MillRefusal):
            check_job_program(bad, settings, envelope)
    call = M100.parse("M100G56XG57XG55X")
    assert call.a[0] == 56 and call.b[0] == 57 and call.destination == (55, Axis.X)


def test_job_program_homes_first_and_runs_m100():
    mock = mill_mock()
    mock.set_offset(56, Point3(-10.001, 0, 0))
    mock.set_offset(57, Point3(-20.000, 0, 0))
    session = connected(mock)
    try:
        wait_for(session, "home gate", lambda s: s.gates.home is None)
        assert session.run_job("home", ["$H", "G92.1", "G90 G21", "G53 G0 X-1 Y-110"]) is None
        wait_for(session, "home program", lambda s: s.program is not None and s.program.name == "home" and s.program.outcome is ProgramOutcome.COMPLETED)
        assert session.snapshot.homed
        assert session.run_job("probe", ["G21 G90", "M100 G56XG57XG55X", "G0 X-1"]) is None
        wait_for(session, "M100 program", lambda s: s.program is not None and s.program.name == "probe" and s.program.outcome is ProgramOutcome.COMPLETED)
        assert abs(mock.offset(55).x + 15.0005) < 0.0011
        assert "G4P0" in mock.received_lines and any(l.startswith("G10L2P2X-15.00") for l in mock.received_lines)
        assert session.snapshot.program.done == 3
    finally:
        session.disconnect()


def test_job_program_runs_m101_tolerance_check():
    call = M101.parse("M101G57G58G59X0.152")
    assert call.offsets == (57, 58, 59) and call.axis is Axis.X and call.tolerance == 0.152
    assert M101.parse("M101G57G58X0.1") is None and M101.parse("M101G57G58G59X") is None
    mock = mill_mock()
    mock.set_offset(57, Point3(-10.00, 0, 1.00))
    mock.set_offset(58, Point3(-10.10, 0, 1.05))
    mock.set_offset(59, Point3(-10.05, 0, 1.20))
    session = homed(mock)
    try:
        assert session.run_job("check", ["G21", "M101 G57 G58 G59 X 0.152", "G0 Z-1"]) is None
        wait_for(session, "M101 pass", lambda s: s.program is not None and s.program.name == "check" and s.program.outcome is ProgramOutcome.COMPLETED)
        assert "G0Z-1" in mock.received_lines
        assert session.run_job("check2", ["G21", "M101 G57 G58 G59 Z 0.076", "G0 Z-2"]) is None
        wait_for(session, "M101 failure", failed)
        time.sleep(0.2)
        assert "G0Z-2" not in mock.received_lines, "the program stopped at the check"
        assert "out of tolerance" in (session.snapshot.last_error or "")
    finally:
        session.disconnect()


def test_job_program_runs_m102_and_m106():
    # M102 (arithmetic into a work offset) and M106 (a check that stops the program).
    call = M102.parse("M102 G57X ((G55X + G56X)/2)")
    assert call.destination == (57, Axis.X) and call.expression == "((G55X+G56X)/2)"
    assert M102.parse("M102 G55 X = abs(G56X - G57X)").destination == (55, Axis.X)
    assert M102.parse("M102 WCS G54 Y G55Y + 1").destination == (54, Axis.Y)
    assert M102.parse("M102 G57X") is None and M102.parse("M102 G57X ((G55X") is None and M102.parse("M102 G60X 1") is None
    assert M106.parse("M106 G58X > 3.2 error: bore 1 too small") is not None and M106.parse("M106 G58X ~ 3") is None
    envelope = MillEnvelope.from_settings(real_settings())
    checked = check_job_program(["G21", "M102 G57X ((G55X + G56X)/2) ; midpoint", "N20 M106 G57X < -14 error: Bore not found"],
                                real_settings(), envelope)
    assert checked.lines == ["G21", "M102 G57X ((G55X + G56X)/2)", "M106 G57X < -14 error: Bore not found"]
    mock = mill_mock()
    mock.set_offset(55, Point3(-10, 0, 0))
    mock.set_offset(56, Point3(-20.002, 0, 0))
    session = homed(mock)
    try:
        lines = ["G21", "M102 G57X ((G55X + G56X)/2)", "M106 G57X < -14 error: Bore not found", "G0 Z-1"]
        assert session.run_job("bores", lines) is None
        wait_for(session, "M102/M106 pass", lambda s: s.program is not None and s.program.name == "bores" and s.program.outcome is ProgramOutcome.COMPLETED)
        assert abs(mock.offset(57).x + 15.001) < 0.0011, mock.offset(57)
        assert any(l.startswith("G10L2P4X-15.00") for l in mock.received_lines) and "G0Z-1" in mock.received_lines
        assert not any(l.startswith(("M102", "M106")) for l in mock.received_lines), "the controller never sees them"
        assert session.run_job("bores2", ["G21", "M106 G57X > -14 error: Bore not found", "G0 Z-2"]) is None
        wait_for(session, "M106 failure", failed)
        time.sleep(0.2)
        assert "G0Z-2" not in mock.received_lines, "the program stopped at the check"
        assert session.snapshot.last_error == "M106: Bore not found", session.snapshot.last_error
    finally:
        session.disconnect()


def test_simulated_mill_follows_grbl():
    mock = mill_mock(probe_faces=True)
    session = homed(mock)
    try:
        assert session.run_job("moves", ["G21 G91", "G0 G53 Z-19", "G0 G53 X-40 Y-100", "G10 L20 P2 X1 Y2 Z3",
                                         "G38.3 Z-10 F30", "G0 Z1", "G38.3 Z-10 F30", "G90 G55 G0 X0"]) is None
        wait_for(session, "moves", lambda s: s.program is not None and s.program.name == "moves" and s.program.outcome is ProgramOutcome.COMPLETED)
        assert mock.offset(55) == Point3(-41, -102, -22)
        assert abs(mock.position.z + 24) < 1e-9, "both probes touch the face 5 mm down"
        assert abs(mock.position.x + 41) < 1e-9
        assert session.run_job("out", ["G21 G90 G55", "G0 Z-60"]) is None
        wait_for(session, "soft limit", failed)
        assert (session.snapshot.last_alarm or "").startswith("ALARM:2")
        assert abs(mock.position.z + 24) < 1e-9, "the machine did not move"
    finally:
        session.disconnect()


def test_probe_that_touches_nothing_stops_the_program():
    mock = mill_mock(probe_contact_z=None)
    session = homed(mock)
    try:
        assert session.run_job("probe", ["G21", "M4 S5000", "G38.3 Z-5 F30", "G10 L20 P2 Z0", "G0 Z1"]) is None
        wait_for(session, "probe failure", failed)
        time.sleep(0.2)
        assert "G10L20P2Z0" not in mock.received_lines, "the offset was not written"
        assert [l for l in mock.received_lines if not l.startswith("$")][-1] == "M5"
        assert "probe did not touch" in (session.snapshot.last_error or "")
    finally:
        session.disconnect()


def test_job_program_needs_homing_unless_it_homes():
    mock = mill_mock()
    session = connected(mock)
    try:
        wait_for(session, "status", lambda s: s.status is not None and s.gates.home is None)
        assert session.run_job("cut", ["G21", "G0 X1"]) == NOT_HOMED
        assert session.run_job("bad", ["G20", "G0 X1"]) is not None
    finally:
        session.disconnect()


def test_disconnect_closes_the_port():
    mock = mill_mock()
    session = connected(mock)
    session.disconnect()
    wait_for(session, "closed", lambda s: s.link is MillLink.DISCONNECTED)
    assert not mock.is_open
    assert session.snapshot.gates.home == MillRefusal("notConnected")
