"""Port of MillCoreSelfTest/ManualControlTests.swift: jogging, hold-to-jog, work offsets,
spindle, overrides and go-to on the session."""

import math
import threading
import time

import pytest

from coastline_app.mill.geometry import Axis, Point3
from coastline_app.mill.programs import GoToFrame, go_to_lines
from coastline_app.mill.session import HOLD_SEGMENT, MillSession
from coastline_app.mill.session_types import JogRequest, MillEnvelope, MillOverride, MillPort, MillRefusal, ProgramOutcome
from coastline_app.mill.status import MillOverrides

from .helpers import (command_bytes, connected, hold, homed, jog_lines, jog_word, mill_mock, position, real_settings,
                      wait_for)

NOT_HOMED = MillRefusal("notHomed")


class JogPauseTransport:
    """Pauses the I/O thread at deterministic boundaries without blocking real-time writes."""

    def __init__(self) -> None:
        self.mock = mill_mock(timed_jogs=True)
        self.read_paused = threading.Semaphore(0)
        self.resume_read = threading.Semaphore(0)
        self.jog_paused = threading.Semaphore(0)
        self.resume_jog = threading.Semaphore(0)
        self._lock = threading.Lock()
        self.pause_read = False
        self.pause_jog = False
        self.events: list[str] = []

    @property
    def is_open(self) -> bool:
        return self.mock.is_open

    def open(self) -> None:
        self.mock.open()

    def close(self) -> None:
        self.mock.close()

    def _take(self, name: str) -> bool:
        with self._lock:
            flag = getattr(self, name)
            setattr(self, name, False)
            return flag

    def write(self, data: bytes) -> None:
        line = data.decode("utf-8", "replace")
        if line.startswith("$J=") and self._take("pause_jog"):
            self.jog_paused.release()
            self.resume_jog.acquire(timeout=3)
        with self._lock:
            if line.startswith("$J="):
                self.events.append("jog")
            if data == bytes([0x85]):
                self.events.append("cancel")
            if data == b"!":
                self.events.append("hold")
        self.mock.write(data)

    def read_available(self) -> bytes:
        if self._take("pause_read"):
            self.read_paused.release()
            self.resume_read.acquire(timeout=3)
        return self.mock.read_available()


def homed_transport(transport: JogPauseTransport) -> MillSession:
    session = MillSession()
    session.connect(MillPort.simulated(), transport=transport)
    wait_for(session, "transport ready", lambda s: s.link.value == "connected" and s.gates.home is None)
    assert session.home() is None
    wait_for(session, "transport homed", lambda s: s.homed and s.gates.jog is None)
    position(transport.mock, session, Point3(-40, -100, -20))
    return session


def idle(s):
    return s.state == "Idle"


@pytest.mark.parametrize("feed_hold", [False, True])
def test_cancelling_queued_jog(feed_hold):
    transport = JogPauseTransport()
    session = homed_transport(transport)
    try:
        before = transport.mock.position
        transport.pause_read = True
        assert transport.read_paused.acquire(timeout=1)
        assert session.jog(JogRequest(x=5, y=-5, feed=600)) is None
        session.feed_hold() if feed_hold else session.jog_cancel()
        transport.resume_read.release()
        if feed_hold:
            wait_for(session, "hold before resume", lambda s: s.gates.resume is None)
            assert session.resume() is None
        wait_for(session, "cancelled queued jog idle", idle)
        time.sleep(0.35)
        assert jog_lines(transport.mock) == [], "an old step escaped cancellation"
        assert transport.mock.position == before
    finally:
        transport.resume_read.release()
        session.disconnect()


@pytest.mark.parametrize("feed_hold", [False, True])
def test_cancelling_jog_during_write(feed_hold):
    transport = JogPauseTransport()
    session = homed_transport(transport)
    try:
        before = transport.mock.position
        transport.pause_jog = True
        assert session.jog(JogRequest(x=5, y=-5, feed=600)) is None
        assert transport.jog_paused.acquire(timeout=1)
        session.feed_hold() if feed_hold else session.jog_cancel()
        expected = "hold" if feed_hold else "cancel"
        wait_for(session, "immediate real-time cancellation", lambda _: expected in transport.events)
        transport.resume_jog.release()

        def cancelled_after_sent(_):
            events = list(transport.events)
            if "jog" not in events or "cancel" not in events:
                return False
            return len(events) - 1 - events[::-1].index("cancel") > len(events) - 1 - events[::-1].index("jog")
        wait_for(session, "I/O cancellation after the old write", cancelled_after_sent)
        if feed_hold:
            wait_for(session, "held after pending jog", lambda s: s.gates.resume is None)
            assert session.resume() is None
        wait_for(session, "cancelled old jog idle", idle)
        stopped = transport.mock.position
        assert math.hypot(stopped.x - before.x, stopped.y - before.y) < 0.5
        time.sleep(0.35)
        assert transport.mock.position == stopped
        assert len(jog_lines(transport.mock)) == 1
    finally:
        transport.resume_jog.release()
        session.disconnect()


def test_legacy_zero_distance_jog_retains_its_axis_when_edited():
    request = JogRequest(axis=Axis.Y, distance=0, feed=100)
    assert request.axis is Axis.Y
    request.distance = -2
    assert request == JogRequest(y=-2, feed=100)
    request.axis = Axis.Z
    assert request == JogRequest(z=-2, feed=100)
    request.distance = 0
    assert request.axis is Axis.Z
    request.distance = 3
    assert request == JogRequest(z=3, feed=100)


def test_new_step_after_cancellation_can_still_run():
    transport = JogPauseTransport()
    session = homed_transport(transport)
    try:
        transport.pause_read = True
        assert transport.read_paused.acquire(timeout=1)
        assert session.jog(JogRequest(x=5, y=-5, feed=600)) is None
        session.jog_cancel()
        assert session.jog(JogRequest(x=-2, y=3, feed=600)) is None
        transport.resume_read.release()
        wait_for(session, "new step after unlocking", lambda s: s.status is not None and s.status.machine_position == Point3(-42, -97, -20))
        assert jog_lines(transport.mock) == ["$J=G21 G91 X-2.000 Y3.000 F600"]
    finally:
        transport.resume_read.release()
        session.disconnect()


def test_diagonal_step_is_one_coordinated_jog():
    mock = mill_mock()
    session = homed(mock)
    try:
        position(mock, session, Point3(-40, -100, -20))
        assert session.jog(JogRequest(x=-5, y=5, feed=600)) is None
        wait_for(session, "diagonal arrived", lambda s: s.status.machine_position == Point3(-45, -95, -20))
        assert jog_lines(mock) == ["$J=G21 G91 X-5.000 Y5.000 F600"]
    finally:
        session.disconnect()


def test_diagonal_step_stops_both_axes_at_the_first_boundary():
    mock = mill_mock()
    session = homed(mock)
    try:
        position(mock, session, Point3(-1.5, -100, -20))
        assert session.jog(JogRequest(x=10, y=20, feed=600)) is None
        wait_for(session, "clipped diagonal", lambda s: s.status.machine_position == Point3(-0.5, -98, -20) and s.gates.jog is None)
        assert jog_lines(mock) == ["$J=G21 G91 X1.000 Y2.000 F600"]
        # An outward diagonal at X's boundary must not turn into a pure Y move.
        assert session.jog(JogRequest(x=1, y=1, feed=600)) is None
        time.sleep(0.35)
        assert len(jog_lines(mock)) == 1
        assert mock.position == Point3(-0.5, -98, -20)
    finally:
        session.disconnect()


def test_diagonal_feed_respects_each_axis_component_limit():
    mock = mill_mock()
    session = homed(mock)
    try:
        position(mock, session, Point3(-40, -100, -20))
        assert session.jog(JogRequest(x=10, y=10, feed=5000)) is None
        wait_for(session, "feed capped diagonal", lambda s: s.status.machine_position == Point3(-30, -90, -20))
        feed = jog_word(jog_lines(mock)[0], "F")
        assert feed == 3592  # floor(2540 * sqrt(2)); X's component stays <= $110
        assert feed / math.sqrt(2) <= 2540
    finally:
        session.disconnect()


def test_diagonal_hold_uses_path_speed_and_cancels_on_release():
    mock = mill_mock(timed_jogs=True)
    session = homed(mock)
    try:
        start = Point3(-40, -100, -20)
        position(mock, session, start)
        assert session.start_hold(x=1, y=-1, feed=1200) is None
        hold(session, 0.8)
        assert session.snapshot.holding
        moved = mock.position
        assert moved.x > start.x + 5 and moved.y < start.y - 5
        assert abs((moved.x - start.x) + (moved.y - start.y)) < 0.01
        session.end_hold()
        wait_for(session, "diagonal released", lambda s: idle(s) and not s.holding)
        stopped, count = mock.position, len(jog_lines(mock))
        time.sleep(0.3)
        assert mock.position == stopped and len(jog_lines(mock)) == count
        assert command_bytes(mock)[-1] == 0x85
        for line in jog_lines(mock):
            x, y = jog_word(line, "X"), jog_word(line, "Y")
            assert abs(x + y) < 0.001, line
            assert math.hypot(x, y) <= 1200 / 60 * HOLD_SEGMENT + 0.001, line
    finally:
        session.disconnect()


def test_diagonal_hold_does_not_slide_along_the_boundary():
    mock = mill_mock(timed_jogs=True)
    session = homed(mock)
    try:
        position(mock, session, Point3(-85, -239, -20))
        assert session.start_hold(x=-1, y=-1, feed=1200) is None
        hold(session, 0.7)
        wait_for(session, "first diagonal boundary", idle)
        assert mock.position == Point3(-86, -240, -20)
        assert session.snapshot.last_alarm is None and session.snapshot.last_error is None
        session.end_hold()
    finally:
        session.disconnect()


def test_diagonal_hold_watchdog_cancels_both_axes():
    mock = mill_mock(timed_jogs=True)
    session = homed(mock)
    try:
        start = Point3(-40, -100, -20)
        position(mock, session, start)
        assert session.start_hold(x=1, y=-1, feed=600) is None
        wait_for(session, "diagonal dead man", lambda s: not s.holding and "stopped confirming" in (s.last_error or ""), timeout=2)
        wait_for(session, "diagonal idle", idle)
        stopped = mock.position
        assert math.hypot(stopped.x - start.x, stopped.y - start.y) < 7
        assert command_bytes(mock)[-1] == 0x85
        time.sleep(0.3)
        assert mock.position == stopped
    finally:
        session.disconnect()


def test_invalid_jog_vectors_never_reach_the_controller():
    mock = mill_mock()
    session = homed(mock)
    try:
        nan, inf = float("nan"), float("inf")
        for r in (JogRequest(feed=100), JogRequest(x=nan, y=1, feed=100), JogRequest(x=1, z=inf, feed=100),
                  JogRequest(y=1, feed=inf), JogRequest(y=1, feed=0), JogRequest(y=1, feed=-100)):
            assert session.jog(r) is not None
            assert session.start_hold(x=r.x, y=r.y, z=r.z, feed=r.feed) is not None
        assert session.start_hold(axis=Axis.X, direction=0, feed=100) is not None
        assert session.start_hold(axis=Axis.X, direction=nan, feed=100) is not None
        time.sleep(0.3)
        assert jog_lines(mock) == []
    finally:
        session.disconnect()


def test_hold_jog_moves_while_held_and_stops_when_let_go():
    mock = mill_mock(timed_jogs=True)
    session = homed(mock)
    try:
        assert session.start_hold(axis=Axis.Y, direction=-1, feed=1200) is None  # 20 mm/s
        hold(session, 0.8)
        assert session.snapshot.holding
        moved = mock.position.y
        assert -20 < moved < -8, f"moved to {moved} in 0.8 s"
        session.end_hold()
        let_go = mock.position.y
        wait_for(session, "idle", lambda s: idle(s) and not s.holding)
        assert abs(mock.position.y - let_go) < 0.5
        sent = len(jog_lines(mock))
        time.sleep(0.3)
        assert len(jog_lines(mock)) == sent, "no jog after letting go"
        assert command_bytes(mock)[-1] == 0x85
        for line in jog_lines(mock):  # every jog is short: 0.25 s of motion at most
            assert abs(jog_word(line, "Y")) <= 1200.0 / 60 * HOLD_SEGMENT + 0.001, line
        assert session.snapshot.last_error is None
    finally:
        session.disconnect()


def test_hold_jog_stops_when_the_app_stops_renewing():
    mock = mill_mock(timed_jogs=True)
    session = homed(mock)
    try:
        assert session.start_hold(axis=Axis.Y, direction=-1, feed=600) is None  # never renewed
        wait_for(session, "dead man", lambda s: not s.holding and "stopped confirming" in (s.last_error or ""), timeout=2)
        wait_for(session, "idle", idle)
        assert mock.position.y > -0.5 - 7
        assert command_bytes(mock)[-1] == 0x85
    finally:
        session.disconnect()


def test_hold_jog_stops_at_the_end_of_the_travel():
    mock = mill_mock(timed_jogs=True)
    session = homed(mock)
    try:
        # At home Y is at the top of its travel: nothing to do that way.
        assert session.start_hold(axis=Axis.Y, direction=1, feed=1000) is None
        wait_for(session, "refused", lambda s: not s.holding and "end of its travel" in (s.last_error or ""))
        assert jog_lines(mock) == []
        mock.set_position(Point3(-86, -236, -0.5))
        wait_for(session, "status", lambda s: abs(s.status.machine_position.y + 236) < 0.001)
        assert session.start_hold(axis=Axis.Y, direction=-1, feed=2000) is None
        hold(session, 0.9)
        wait_for(session, "at the end", idle)
        assert abs(mock.position.y + 241) < 0.002, f"stopped at {mock.position.y}"
        assert session.snapshot.last_alarm is None and session.snapshot.last_error is None
        session.end_hold()
    finally:
        session.disconnect()


def test_stop_ends_a_hold_even_if_the_app_keeps_renewing():
    mock = mill_mock(timed_jogs=True)
    session = homed(mock)
    try:
        assert session.start_hold(axis=Axis.Z, direction=-1, feed=600) is None
        hold(session, 0.4)
        session.stop()
        wait_for(session, "idle", lambda s: idle(s) and not s.holding)
        sent, stopped_at = len(jog_lines(mock)), mock.position
        hold(session, 0.4)  # renewing an ended hold does not start it again
        assert len(jog_lines(mock)) == sent and mock.position == stopped_at
        assert session.snapshot.restarts == 0, "a jog is cancelled, not reset"
        assert session.snapshot.homed
    finally:
        session.disconnect()


def test_hold_jog_needs_homing():
    mock = mill_mock(timed_jogs=True)
    session = connected(mock)
    try:
        wait_for(session, "status", lambda s: s.status is not None)
        assert session.start_hold(axis=Axis.Y, direction=-1, feed=1000) == NOT_HOMED
        time.sleep(0.2)
        assert jog_lines(mock) == []
    finally:
        session.disconnect()


def test_work_offsets_zero_set_undo_and_select():
    mock = mill_mock()
    session = homed(mock)
    try:
        mock.set_position(Point3(-40, -100, -20))
        wait_for(session, "status", lambda s: abs(s.status.machine_position.y + 100) < 0.001)
        assert session.set_work_position({Axis.X: 0, Axis.Y: 0}, 54) is None
        wait_for(session, "zeroed", lambda s: s.offset(54) == Point3(-40, -100, 0))
        assert mock.offset(54) == Point3(-40, -100, 0)
        work = session.snapshot.work_position
        assert abs(work.x) < 1e-9 and abs(work.y) < 1e-9 and abs(work.z + 20) < 1e-9
        assert session.set_work_position({Axis.Z: 5}, 54) is None  # this position is Z 5
        wait_for(session, "set", lambda s: s.offset(54) is not None and s.offset(54).z == -25)
        assert session.set_offset(Point3(-40, -100, 0), 54) is None  # undo
        wait_for(session, "undone", lambda s: s.offset(54) == Point3(-40, -100, 0))
        assert session.select_wcs(55) is None
        wait_for(session, "G55", lambda s: s.active_wcs == 55 and s.work_offset == Point3())
        assert session.select_wcs(53) is not None
        assert session.set_work_position({}, 54) is not None
        assert "G10L20P1X0.000Y0.000" in mock.received_lines
    finally:
        session.disconnect()


def test_work_offsets_need_a_homed_idle_machine():
    mock = mill_mock()
    session = connected(mock)
    try:
        wait_for(session, "status", lambda s: s.status is not None)
        assert session.set_work_position({Axis.X: 0}, 54) == NOT_HOMED
        assert session.select_wcs(55) == NOT_HOMED
        assert session.spindle_on(5000) == NOT_HOMED
        time.sleep(0.2)
        assert not any(l.startswith(("G10", "M3")) or l == "G55" for l in mock.received_lines)
    finally:
        session.disconnect()


def test_console_offset_changes_are_read_back():
    mock = mill_mock()
    session = homed(mock)
    try:
        assert session.send_console("G10 L20 P2 X0") is None
        wait_for(session, "G55 read back", lambda s: s.offset(55) is not None and s.offset(55).x == -86)
        assert session.send_console("G55") is None
        wait_for(session, "G55 active", lambda s: s.active_wcs == 55 and s.work_offset is not None and s.work_offset.x == -86)
    finally:
        session.disconnect()


def test_spindle_on_inside_its_range_and_off():
    mock = mill_mock()
    session = homed(mock)
    try:
        assert session.spindle_on(9000) is not None  # above $30
        assert session.spindle_on(500) is not None  # below $31
        assert session.spindle_on(5000) is None
        wait_for(session, "on", lambda s: s.spindle == ("M3", 5000))
        assert "M3S5000" in mock.received_lines
        assert session.spindle_off() is None
        wait_for(session, "off", lambda s: s.spindle is not None and s.spindle[0] == "M5")
        assert mock.spindle[0] == "M5"
    finally:
        session.disconnect()


def test_overrides_are_real_time_and_tracked():
    mock = mill_mock()
    session = connected(mock)
    try:
        for o in (MillOverride.FEED_PLUS_10, MillOverride.FEED_PLUS_10, MillOverride.FEED_MINUS_1, MillOverride.RAPID_25,
                  MillOverride.SPINDLE_MINUS_10):
            session.override(o)
        wait_for(session, "tracked", lambda s: (s.overrides.feed, s.overrides.rapid, s.overrides.spindle) == (119, 25, 90))
        assert not session.snapshot.overrides.reported
        time.sleep(0.1)
        assert mock.overrides.feed == 119
        assert command_bytes(mock) == [0x91, 0x91, 0x94, 0x97, 0x9B]
        for _ in range(12):
            session.override(MillOverride.FEED_PLUS_10)
        wait_for(session, "clamped", lambda s: s.overrides.feed == 200)
        session.soft_reset()
        wait_for(session, "restart", lambda s: s.restarts == 1 and s.overrides == MillOverrides())
    finally:
        session.disconnect()


def test_reported_overrides_win():
    mock = mill_mock(reports_overrides=True)
    session = connected(mock)
    try:
        session.override(MillOverride.SPINDLE_PLUS_10)
        wait_for(session, "reported", lambda s: s.overrides.reported and s.overrides.spindle == 110 and s.overrides.feed == 100)
    finally:
        session.disconnect()


def test_go_to_lines():
    e = MillEnvelope.from_settings(real_settings())
    work = Point3(-40, -100, -20)
    assert go_to_lines(0, 0, None, GoToFrame.WORK, work, e, True) == ["G21", "G90", "G53G0Z-0.500", "G53G0X-40.000Y-100.000"]
    assert go_to_lines(0, 0, 5, GoToFrame.WORK, work, e, True) == ["G21", "G90", "G53G0Z-0.500", "G53G0X-40.000Y-100.000", "G53G0Z-15.000"]
    assert go_to_lines(-10, -20, -30, GoToFrame.MACHINE, None, e, False) == ["G21", "G90", "G53G0X-10.000Y-20.000Z-30.000"]
    assert go_to_lines(None, None, -0.5, GoToFrame.MACHINE, None, e, True) == ["G21", "G90", "G53G0Z-0.500"]
    for args in ((None, -300, None, GoToFrame.MACHINE, None), (0, None, None, GoToFrame.WORK, None),
                 (None, None, None, GoToFrame.MACHINE, None), (50, None, None, GoToFrame.WORK, work)):
        with pytest.raises(MillRefusal):
            go_to_lines(*args, envelope=e, retract_first=True if args[3] is GoToFrame.MACHINE else False)


def test_go_to_runs_as_a_checked_program():
    mock = mill_mock()
    session = homed(mock)
    try:
        assert session.set_work_position({Axis.X: 0, Axis.Y: 0, Axis.Z: 0}, 54) is None  # work zero at home
        wait_for(session, "zeroed", lambda s: s.offset(54) == Point3(-86, -0.5, -0.5) and s.gates.run is None)
        lines = go_to_lines(30, -50, -10, GoToFrame.WORK, session.snapshot.work_offset, session.snapshot.envelope, True)
        assert session.run("Go to", lines) is None
        wait_for(session, "arrived", lambda s: s.program is not None and s.program.name == "Go to" and s.program.outcome is ProgramOutcome.COMPLETED)
        assert mock.position == Point3(-56, -50.5, -10.5)
    finally:
        session.disconnect()
