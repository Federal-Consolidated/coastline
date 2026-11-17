"""Shared helpers for the session tests (Swift: SessionTests.swift top)."""

import time

from coastline_app.mill.geometry import Point3
from coastline_app.mill.mock import STANDARD_SETTINGS, MockGRBL, MockOptions
from coastline_app.mill.session import MillSession
from coastline_app.mill.session_types import MillLink, MillPort
from coastline_app.mill.status import MillSettings


def real_settings() -> MillSettings:
    """`$$` of the user's real machine."""
    s = MillSettings()
    for n, v, _ in STANDARD_SETTINGS:
        s.update(n, v)
    return s


def mill_mock(timed_jogs: bool = False, **options) -> MockGRBL:
    return MockGRBL(MockOptions(start_locked=True, soft_limit_travel=Point3(86.5, 241.5, 78.5), timed_jogs=timed_jogs, **options))


class Timeout(AssertionError):
    pass


def wait_for(session: MillSession, what: str, condition, timeout: float = 5.0) -> None:
    end = time.time() + timeout
    while time.time() < end:
        if condition(session.snapshot):
            return
        time.sleep(0.01)
    console = " | ".join(l.text for l in session.console(0)[-12:])
    raise Timeout(f"timed out waiting for {what}; state {session.snapshot.state}; console: {console}")


def connected(mock, session: MillSession | None = None) -> MillSession:
    session = session or MillSession()
    session.connect(MillPort.simulated(), transport=mock)
    wait_for(session, "settings", lambda s: s.link is MillLink.CONNECTED and s.envelope is not None and s.parser_state is not None)
    return session


def homed(mock) -> MillSession:
    session = connected(mock)
    wait_for(session, "home gate", lambda s: s.gates.home is None)
    assert session.home() is None
    wait_for(session, "homed", lambda s: s.homed and s.gates.jog is None)
    return session


def jog_lines(mock) -> list[str]:
    return [l for l in mock.received_lines if l.startswith("$J=")]


def command_bytes(mock) -> list[int]:
    """Real-time bytes other than status polls."""
    return [b for b in mock.realtime_bytes if b != ord("?")]


def hold(session: MillSession, seconds: float) -> None:
    """Renews a hold for `seconds`, as the app does while the operator holds."""
    end = time.time() + seconds
    while time.time() < end:
        session.renew_hold()
        time.sleep(0.05)


def position(mock, session: MillSession, point: Point3) -> None:
    mock.set_position(point)
    wait_for(session, "position", lambda s: s.status is not None and s.status.machine_position == point and s.gates.jog is None)


def jog_word(line: str, letter: str) -> float | None:
    for w in line.split(" "):
        if w.startswith(letter):
            try:
                return float(w[1:])
            except ValueError:
                return None
    return None
