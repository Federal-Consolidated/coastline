"""Port of MillCoreSelfTest/GRBLTests.swift (tests of the legacy manager/jog/manual classes, which
the app does not use, are not ported)."""

import threading
import time

import pytest

from coastline_app.mill.connection import MillConnection, MillProgress
from coastline_app.mill.contour import M106Check, WCSExpression, WCSExpressionError
from coastline_app.mill.errors import MillError, MillErrorKind as K
from coastline_app.mill.gcode import GCodeLine, program_from_source
from coastline_app.mill.geometry import LengthUnit, Point3
from coastline_app.mill.mock import MockGRBL, MockOptions
from coastline_app.mill.protocol import GRBLProtocol
from coastline_app.mill.serial_connection import MachineLog
from coastline_app.mill.status import RealTimeStatus, SoftLimits, StatusParseError
from coastline_app.mill.transport import MillDevice

DEVICE = MillDevice("/dev/mock", "MOCK")
MM = LengthUnit.MILLIMETERS


def connect(mock: MockGRBL, manual: bool = False) -> MillConnection:
    return MillConnection.connect(DEVICE, mock, MachineLog(), is_manual_operation=lambda: manual)


def program(text: str):
    return program_from_source(text.split("\n"))


def test_status_parsing_cr_format():
    s = RealTimeStatus.parse("<Idle|M:-86.000,-0.500,-1.250|B:15,127|L:0|P0Y0|W:-10.000,-20.000,-30.000>", 55, MM, 21, 90)
    assert s.state == "Idle"
    assert s.machine_position == Point3(-86, -0.5, -1.25)
    assert s.work_offset == Point3(-10, -20, -30)
    assert s.work_position == Point3(-76, 19.5, 28.75)
    assert s.probe_tripped and s.limit_y and not s.limit_x
    assert s.wcs == 55
    hold = RealTimeStatus.parse("<Hold:0|M:0.000,0.000,0.000|B:15,128|L:|0000>", 54, MM, 21, 90)
    assert hold.state == "Hold" and hold.sub_state == 0 and hold.work_offset is None
    with pytest.raises(StatusParseError):
        RealTimeStatus.parse("<Idle|MPos:0,0,0|Bf:15,128|FS:0,0>", 54, MM, 21, 90)


def test_real_machine_replies():
    assert MillConnection.grbl_version("Grbl 1.1g [help:'$']") == "1.1"
    first = RealTimeStatus.parse("<Alarm|M:0.000,0.000,0.000|B:14,128|L:0|P000|W:0.000,0.000,0.000>", 54, MM, 21, 90)
    assert first.state == "Alarm" and first.free_planner_blocks == 14 and first.work_offset == Point3(0, 0, 0)
    assert first.probe_tripped and not (first.limit_x or first.limit_y or first.limit_z)
    later = RealTimeStatus.parse("<Alarm|M:0.000,0.000,0.000|B:14,128|L:0|P000>", 54, MM, 21, 90)
    assert later.work_offset is None
    assert GRBLProtocol.parse_setting("$0=10 (stepPulse)") == (0, 10)
    assert GRBLProtocol.parse_setting("$11=0.020 (jncDev)") == (11, 0.02)
    assert GRBLProtocol.parse_setting("$130=86.500 (x:mm)") == (130, 86.5)


def test_protocol_helpers():
    assert GRBLProtocol.is_hex_ok("KA") and not GRBLProtocol.is_hex_ok("KAB") and not GRBLProtocol.is_hex_ok("Ka")
    assert GRBLProtocol.parse_setting("$130=86.000") == (130, 86)
    assert GRBLProtocol.parse_setting("$N0=") is None
    assert MillConnection.grbl_version("Grbl 1.1g ['$' for help]") == "1.1"
    assert MillConnection.last_feed_rate("G1X10F200Y2F300") == 300
    assert MillConnection.replace_feed_rates("G1X10F200Y2f300", 150) == "G1X10F150Y2F150"


def test_connect_loads_settings():
    mock = MockGRBL()
    c = connect(mock)
    try:
        assert c.is_connected and "$$" in mock.received_lines
        assert c.settings_snapshot.soft_limits == SoftLimits(True, 86, 241.5, 78.5)
    finally:
        c.disconnect()


def test_streaming_respects_receive_buffer():
    mock = MockGRBL(MockOptions(lines_per_poll=1))  # slow controller: the host must wait for space
    c = connect(mock)
    try:
        source = ["G21", "G90", "G0 X-10 Y-10"]
        source += [f"G1 X-{10 + i % 7}.123 Y-{20 + i % 5}.456 Z-1.789 F300" for i in range(60)]
        source.append("M5")
        c.execute_program(program_from_source(source))
        assert not mock.overflowed, f"receive buffer overflowed (max {mock.max_rx_used})"
        assert mock.max_rx_used > 60, f"streaming should keep the buffer busy, max was {mock.max_rx_used}"
        assert len([l for l in mock.received_lines if l.startswith("G1")]) == 60
        assert mock.received_lines[-1] == "G4P0"
        assert mock.pending_lines("M5") == 0  # M-codes need an empty buffer before they are sent
        assert c.progress == MillProgress(len(source), len(source))
    finally:
        c.disconnect()


def test_feed_rate_override():
    mock = MockGRBL()
    c = connect(mock)
    try:
        c.feed_rate_slider = 50
        c.execute_program(program("G1 X-5 F200"))
        assert "G1X-5F100" in mock.received_lines
        c.feed_rate_slider = 10  # clamped to 30
        assert c.feed_rate_slider == 30
    finally:
        c.disconnect()


def test_grbl_error_stops_program():
    mock = MockGRBL(MockOptions(reply_override=lambda l: "error:20" if "G99" in l else None))
    c = connect(mock)
    try:
        with pytest.raises(MillError) as e:
            c.execute_program(program("G0 X-1\nG99 X1\nG0 X-2"))
        assert e.value.kind is K.GRBL_ERROR
        assert c.current_error.title == "Unsupported command"
        assert 'Command "G99X1"' in c.current_error.description
    finally:
        c.disconnect()


def test_silence_is_treated_as_hardware_estop():
    mock = MockGRBL(MockOptions(lines_per_poll=1))
    c = connect(mock)
    try:
        mock.silent = True
        start = time.time()
        with pytest.raises(MillError) as e:
            c.execute_program(program("G4 P0.5\nG0 X-1"))
        assert e.value.kind is K.ESTOP_PUSHED
        elapsed = time.time() - start
        assert 1.9 < elapsed < 4, f"took {elapsed}s"
        assert c.is_estop_engaged
    finally:
        c.disconnect()


def test_software_estop_interrupts_program():
    mock = MockGRBL(MockOptions(lines_per_poll=1))
    c = connect(mock)
    try:
        lines = program_from_source([f"G1 X-{i % 50} F100" for i in range(400)])
        errors = []

        def run():
            try:
                c.execute_program(lines, stop_generation=c.stop_generation_snapshot)
            except MillError as e:
                errors.append(e)

        t = threading.Thread(target=run)
        t.start()
        time.sleep(0.3)
        assert t.is_alive()
        c.emergency_stop()
        t.join(5)
        assert not t.is_alive(), "program kept running after e-stop"
        assert len([b for b in mock.realtime_bytes if b == 0x18]) >= 2, "expected two soft resets"
        assert len([l for l in mock.received_lines if l.startswith("G1")]) < 400
    finally:
        c.disconnect()


def test_non_blocking_read_keeps_homing_timeout():
    mock = MockGRBL()
    c = connect(mock)
    try:
        c.state.set_homing(True)
        c.read_response(blocking=False)
        assert c.state.is_homing, "a status poll must not end the 25 s homing window"
    finally:
        c.disconnect()


def test_feed_override_accounts_for_longer_lines():
    mock = MockGRBL(MockOptions(lines_per_poll=1))
    c = connect(mock)
    try:
        c.feed_rate_slider = 150
        # F999 → F1498: one byte longer than counted; many such lines would overflow before.
        c.execute_program([GCodeLine.make(f"G1X-{i % 9}.5Y-1.25F999") for i in range(80)])
        assert not mock.overflowed, f"receive buffer overflowed (max {mock.max_rx_used})"
    finally:
        c.disconnect()


def test_estop_latched_while_program_waits_for_lock():
    mock = MockGRBL(MockOptions(lines_per_poll=1))
    c = connect(mock)
    try:
        lines = program_from_source([f"G1 X-{i % 9} F100" for i in range(200)])
        c.lock.acquire()  # the program thread is stuck waiting when stop is pressed
        generation = c.stop_generation_snapshot
        t = threading.Thread(target=lambda: _swallow(lambda: c.execute_program(lines, stop_generation=generation)))
        t.start()
        time.sleep(0.2)
        threading.Thread(target=c.emergency_stop).start()
        time.sleep(0.3)
        c.lock.release()
        t.join(8)
        assert not t.is_alive(), "program kept running after an e-stop it missed"
        assert len([l for l in mock.received_lines if l.startswith("G1")]) < 200
    finally:
        c.disconnect()


def _swallow(fn):
    try:
        fn()
    except MillError:
        pass


def test_probe_success_records_point():
    mock = MockGRBL()
    c = connect(mock)
    try:
        c.execute_program(program("G21\nG38.2 Z-20 F50\nG0 Z-1"))
        assert c.last_probed_point.z == -10
        assert "$G" in mock.received_lines  # queried before probing so the state can be restored
    finally:
        c.disconnect()


def test_probe_failure_recovers():
    mock = MockGRBL(MockOptions(probe_contact_z=None))
    c = connect(mock)
    try:
        with pytest.raises(MillError) as e:
            c.execute_program(program("G21\nG38.2 Z-20 F50"))
        assert e.value.kind is K.ALARM_PROBE
        error = c.current_error
        assert error.is_probe_failure and error.allows_retry
        c.probe_reset()  # what the guided runner does on retry
        assert "$X" in mock.received_lines
        assert any(l.startswith("G53 G0 X") for l in mock.received_lines)
    finally:
        c.disconnect()


def test_m100_midpoint():
    mock = MockGRBL()
    mock.set_offset(55, Point3(-10, -40, 0))
    mock.set_offset(56, Point3(-20, -50, 0))
    c = connect(mock)
    try:
        c.execute_program(program("M100 G55XG56XG54X"))
        assert "G10L2P1X-15.000" in mock.received_lines
        assert mock.offset(54).x == -15
    finally:
        c.disconnect()


def test_m102_expression():
    mock = MockGRBL()
    mock.set_offset(54, Point3(0, -2, 0))
    mock.set_offset(55, Point3(0, -4, 0))
    c = connect(mock)
    try:
        c.execute_program(program("M102 G54Y ((G54Y + G55Y)/2)"))  # the real Universal Clamp form
        assert "G10L2P1Y-3.000000" in mock.received_lines
    finally:
        c.disconnect()
    assert WCSExpression.evaluate("max(1,2)*-3+abs(-1)^2", lambda _: None) == -5
    with pytest.raises(WCSExpressionError):
        WCSExpression.evaluate("G54X +", lambda _: 1)


def test_m106_check():
    offsets = [("G54", Point3(1, 2, 3)), ("G55", Point3(1, 5, 0))]
    assert M106Check.parse("G54X == G55X error: X differs").evaluate(offsets)
    assert not M106Check.parse("G54Y > G55Y error: too short").evaluate(offsets)
    assert M106Check.parse("G54Y > G55Y error: too short").error_message == " too short"
    assert M106Check.parse("G54XYZ > -1 error: neg").evaluate(offsets)
    with pytest.raises(MillError):
        M106Check.parse("1 > G54X error: x")
