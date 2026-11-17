"""Model of the GRBL controller and connection: flags, alarm/error, buffer, cached status.
Port of ConnectionState.swift. All access is locked."""

from __future__ import annotations

import threading
from dataclasses import dataclass, field

from .gcode import GCodeLine, LineGroup
from .status import MillSettings, RealTimeStatus
from .support import monotonic_now

GRBL_BUFFER_SIZE = 127  # GRBL's receive buffer is 128 bytes; the original reserved one


class LineBuffer:
    """Lines sent to GRBL that have not been acknowledged yet (character-counting flow control)."""

    def __init__(self) -> None:
        self.lines: list[GCodeLine] = []
        self.used = 0

    @staticmethod
    def cost(line: GCodeLine) -> int:
        return len(line.cleaned.encode()) + 1

    def pop(self) -> GCodeLine | None:
        if not self.lines:
            return None
        line = self.lines.pop(0)
        self.used -= self.cost(line)
        return line

    def push(self, line: GCodeLine) -> None:
        self.used += self.cost(line)
        self.lines.append(line)

    def clear(self) -> None:
        self.lines.clear()
        self.used = 0

    @property
    def remaining(self) -> int:
        return max(0, GRBL_BUFFER_SIZE - self.used)

    def fits(self, line: GCodeLine) -> bool:
        return self.remaining >= self.cost(line)


@dataclass
class _Values:
    connected: bool = False
    startup: bool = False
    locked: bool = False
    homing: bool = False
    check_mode: bool = False
    timed_out: bool = False
    error_flag: bool = False
    alarm: int = 0
    error: int = 0
    error_message: str = ""
    error_source: GCodeLine | None = None
    last_read_time: float = field(default_factory=monotonic_now)
    buffer: LineBuffer = field(default_factory=LineBuffer)
    last_gcode_group: LineGroup = LineGroup.UNKNOWN
    status_requested: bool = False
    retry_probe: bool = False
    wcs: int = 54
    units: int = 21
    distance_mode: int = 90
    status: RealTimeStatus | None = None
    status_time: float = 0.0
    settings: MillSettings = field(default_factory=MillSettings)


class ConnectionState:
    STARTUP_DELAY = 10.0  # startup banner must arrive within this window

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._v = _Values()

    def reset(self, keep_connected: bool = False) -> None:
        """`keep_connected` sets `connected` in the same critical section, so a concurrent
        observer never sees a momentary "disconnected" during a reset."""
        with self._lock:
            settings = self._v.settings  # settings survive a reset
            self._v = _Values()
            self._v.settings = settings
            self._v.connected = keep_connected

    def _get(self, name: str):
        with self._lock:
            return getattr(self._v, name)

    def _set(self, name: str, value) -> None:
        with self._lock:
            setattr(self._v, name, value)

    # ---- flags
    is_connected = property(lambda s: s._get("connected"))
    is_startup = property(lambda s: s._get("startup"))
    is_locked = property(lambda s: s._get("locked"))
    is_homing = property(lambda s: s._get("homing"))
    is_check_mode = property(lambda s: s._get("check_mode"))
    is_timed_out = property(lambda s: s._get("timed_out"))
    is_error = property(lambda s: s._get("error_flag"))
    alarm = property(lambda s: s._get("alarm"))
    error = property(lambda s: s._get("error"))
    error_source = property(lambda s: s._get("error_source"))
    error_message = property(lambda s: s._get("error_message"))

    @property
    def is_alarm(self) -> bool:
        return self.alarm != 0

    def set_connected(self, v: bool) -> None:
        self._set("connected", v)

    def set_startup(self, v: bool) -> None:
        self._set("startup", v)

    def set_locked(self, v: bool) -> None:
        self._set("locked", v)

    def set_homing(self, v: bool) -> None:
        self._set("homing", v)

    def set_check_mode(self, v: bool) -> None:
        self._set("check_mode", v)

    def set_timed_out(self, v: bool) -> None:
        self._set("timed_out", v)

    retry_probe = property(lambda s: s._get("retry_probe"), lambda s, v: s._set("retry_probe", v))
    wcs = property(lambda s: s._get("wcs"), lambda s, v: s._set("wcs", v))
    units = property(lambda s: s._get("units"), lambda s, v: s._set("units", v))
    distance_mode = property(lambda s: s._get("distance_mode"), lambda s, v: s._set("distance_mode", v))
    last_gcode_group = property(lambda s: s._get("last_gcode_group"), lambda s, v: s._set("last_gcode_group", v))

    @property
    def settings(self) -> MillSettings:
        with self._lock:
            return self._v.settings.copy()

    def update_setting(self, setting: int, value: float) -> None:
        with self._lock:
            self._v.settings.update(setting, value)

    # ---- buffer
    def buffer_push(self, line: GCodeLine) -> None:
        with self._lock:
            self._v.buffer.push(line)

    def buffer_pop(self) -> GCodeLine | None:
        with self._lock:
            return self._v.buffer.pop()

    @property
    def buffer_is_empty(self) -> bool:
        with self._lock:
            return not self._v.buffer.lines

    def buffer_fits(self, line: GCodeLine) -> bool:
        with self._lock:
            return self._v.buffer.fits(line)

    @property
    def buffer_front(self) -> GCodeLine | None:
        with self._lock:
            return self._v.buffer.lines[0] if self._v.buffer.lines else None

    @property
    def buffer_back(self) -> GCodeLine | None:
        with self._lock:
            return self._v.buffer.lines[-1] if self._v.buffer.lines else None

    @property
    def buffer_used(self) -> int:
        with self._lock:
            return self._v.buffer.used

    # ---- idle / timeout (the e-stop heuristic)
    def update_state(self, now: float | None = None) -> None:
        """Ends the startup window and flags a timeout after 2 s of silence (25 s while homing
        or levelling). The original treats such a timeout as the hardware e-stop."""
        now = monotonic_now() if now is None else now
        with self._lock:
            v = self._v
            delta = now - v.last_read_time
            if v.startup and delta > self.STARTUP_DELAY:
                v.startup = False
            if delta > (25.0 if v.homing else 2.0):
                v.timed_out = True

    def should_request_status(self, now: float | None = None) -> bool:
        """One `?` probe, sent 1 s before the timeout would trigger."""
        now = monotonic_now() if now is None else now
        with self._lock:
            v = self._v
            if v.status_requested:
                return False
            timeout = 25.0 if v.homing else 2.0
            if v.last_read_time + timeout < now + 1:
                v.status_requested = True
                return True
            return False

    def reset_idle_time(self, now: float | None = None) -> None:
        now = monotonic_now() if now is None else now
        with self._lock:
            self._v.last_read_time = now
            self._v.timed_out = False
            self._v.status_requested = False

    # ---- alarm / error
    def clear_alarm(self) -> None:
        with self._lock:
            self._v.alarm, self._v.locked, self._v.error_flag = 0, False, False

    def set_alarm(self, alarm: int) -> None:
        with self._lock:
            v = self._v
            v.alarm, v.locked, v.error_flag = alarm, True, True
            if v.status is not None:
                v.status = v.status.copy(state="Alarm")

    def clear_error(self) -> None:
        with self._lock:
            v = self._v
            v.error, v.error_flag, v.error_message, v.error_source = 0, False, "", None

    def set_error(self, error: int, message: str = "", source: GCodeLine | None = None) -> None:
        with self._lock:
            v = self._v
            v.error, v.error_flag, v.error_message, v.error_source = error, True, message, source

    # ---- status
    def is_status_recent(self, now: float | None = None) -> bool:
        now = monotonic_now() if now is None else now
        with self._lock:
            return self._v.status is not None and self._v.status_time >= now - 0.2

    @property
    def status(self) -> RealTimeStatus | None:
        with self._lock:
            return self._v.status

    def set_status(self, status: RealTimeStatus, now: float | None = None) -> None:
        now = monotonic_now() if now is None else now
        with self._lock:
            self._v.status = status
            self._v.status_time = now
