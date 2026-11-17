"""Parses responses from GRBL and updates the connection state. Port of GRBLProtocol.swift
(`Protocol`, `FeedRate`, `POSITION_ACCUMULATOR` in the original)."""

from __future__ import annotations

import threading
from typing import Callable

from .errors import MillError, MillErrorKind as K
from .gcode import GCodeLine, LineGroup, LineKind, chunk_gcode_line
from .geometry import Axis, Point3
from .state import ConnectionState
from .status import RealTimeStatus, StatusParseError
from .support import leading_integer, parse_double, parse_int, sleep_ms


class GRBLProtocol:
    V1_0 = "1.0"
    V1_1 = "1.1"

    def __init__(self, serial, state: ConnectionState) -> None:
        self.serial = serial
        self.state = state
        self.on_probe_result: Callable[[str], None] | None = None  # `[PRB:…]` lines
        self._version = self.V1_1
        self._lock = threading.Lock()

    @property
    def version(self) -> str:
        with self._lock:
            return self._version

    def set_version(self, version: str) -> None:
        with self._lock:
            self._version = self.V1_1 if version.startswith("1.1") else self.V1_0

    def process_response(self, line: str) -> None:
        """Raises when the machine is no longer usable (error, alarm, lock)."""
        if not line.strip(" \t"):
            return
        if line in ("ok", "0k", "1k", "2k", "3k") or self.is_hex_ok(line):
            # GRBL acknowledges $H/$L only when the cycle has finished: homing timeout ends here.
            popped = self.state.buffer_pop()
            if popped is not None and (popped.is_home or popped.is_level):
                self.state.set_homing(False)
            return
        if line.startswith("[PRB:") and self.on_probe_result is not None:
            self.on_probe_result(line)
        if line.startswith("error:"):
            source = self.state.buffer_pop()
            rest = line[6:]
            code, message = -1, ""
            if self.version == self.V1_1:
                parsed = leading_integer(rest)
                if parsed is None:
                    raise MillError(K.GRBL_ERROR, rest)
                code = parsed
            else:
                message = rest
            self.state.set_error(code, message, source)
            raise MillError(K.GRBL_ERROR, message)
        if line in ("[Enabled]", "[Disabled]"):
            self.state.set_check_mode(False)
            return
        if self.is_lock_message(line) or "[MSG:Reset" in line:
            self.state.set_locked(True)
            raise MillError(K.MACHINE_LOCKED, "Machine locked. Reset to continue.")
        setting = self.parse_setting(line)
        if setting is not None:
            self.state.update_setting(*setting)
            return
        if line.startswith("<"):
            settings, wcs, units, distance = self.state.settings, self.state.wcs, self.state.units, self.state.distance_mode
            try:
                parse = RealTimeStatus.parse_v0 if self.version == self.V1_0 else RealTimeStatus.parse
                status = parse(line, wcs, settings.report_unit, units, distance)
                # GRBL only reports the work offset every few reports; keep the last known one.
                previous = self.state.status
                if status.work_offset is None and previous is not None:
                    status.work_offset = previous.work_offset
                    status.wcs = wcs
                self.state.set_status(status)
            except StatusParseError:
                pass  # the original logs and ignores unparsable status reports
            return
        if line.startswith("ALARM:"):
            rest = line[6:]
            code, description = -1, ""
            if self.version == self.V1_1:
                code = leading_integer(rest)
                code = -1 if code is None else code
            else:
                description = rest
            self.state.set_alarm(code)
            if code in (4, 5) or description == "Probe fail":
                raise MillError(K.ALARM_PROBE)
            if code == 2 or description == "Hard/soft limit":
                raise MillError(K.ALARM_LIMIT)
            raise MillError(K.ALARM, description)

    def requires_empty_buffer(self, line: GCodeLine) -> bool:
        """Whether all outstanding lines must be acknowledged before sending."""
        if not line.cleaned:
            return False
        if line.kind in (LineKind.GRBL, LineKind.MCODE, LineKind.UNKNOWN):
            return True
        if line.kind is LineKind.GCODE:
            return self.state.last_gcode_group is not LineGroup.MOTION or line.group is not LineGroup.MOTION
        return self.state.last_gcode_group is not LineGroup.MOTION  # axisFeedSpindle

    def query_status(self) -> RealTimeStatus | None:
        """The cached status if under 200 ms old, otherwise sends `?` and reads up to 5 lines."""
        if self.state.is_status_recent():
            return self.state.status
        if not self.state.is_locked and not self.state.is_timed_out:
            try:
                self.serial.write_char(ord("?"))
                for _ in range(5):
                    line = self.serial.read_line()
                    if line is not None:
                        self.process_response(line)
                        if self.state.is_status_recent():
                            return self.state.status
                    else:
                        sleep_ms(5)
            except MillError:
                pass  # swallowed, as in the original
        return self.state.status

    @staticmethod
    def is_hex_ok(line: str) -> bool:
        """`^K([0-9A-F])$`: corrupted "ok" variants seen from the firmware."""
        return len(line) == 2 and line[0] == "K" and line[1] in "0123456789ABCDEF"

    @staticmethod
    def is_lock_message(line: str) -> bool:
        """Stock grbl: `[MSG:'$H'|'$X' to unlock]`; the machine firmware: `[MSG:$H/$X]`."""
        return line == "[MSG:$H/$X]" or (line.startswith("[") and line.endswith("to unlock]"))

    @staticmethod
    def parse_setting(line: str) -> tuple[int, float] | None:
        """`^\\$(.?\\d+)=(-?\\d*\\.?\\d+).*`"""
        if not line.startswith("$") or "=" not in line:
            return None
        eq = line.index("=")
        setting = parse_int(line[1:eq])
        if setting is None:
            return None
        value_text = ""
        for c in line[eq + 1:]:
            if c.isdigit() or c in ".-":
                value_text += c
            else:
                break
        value = parse_double(value_text)
        return None if value is None else (setting, value)


class FeedRate:
    """Feed-rate override slider (percentage, minimum 30)."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._update_required = False
        self._slider = 100
        self._feed_rate = 100

    @property
    def slider(self) -> int:
        with self._lock:
            return self._slider

    @slider.setter
    def slider(self, new: int) -> None:
        with self._lock:
            value = max(30, new)
            if self._slider != value:
                self._update_required = True
                self._slider = value

    def update(self, feed_rate: int) -> int:
        """Scales a programmed feed rate by the slider and remembers it."""
        with self._lock:
            self._feed_rate = feed_rate
            self._update_required = False
            return feed_rate * self._slider // 100

    @property
    def is_update_required(self) -> bool:
        with self._lock:
            return self._update_required

    def current_feed_rate(self) -> int:
        with self._lock:
            self._update_required = False
            return self._feed_rate * self._slider // 100


class PositionAccumulator:
    """Tracks the expected machine position as G-code is sent (for contour mapping)."""

    def __init__(self) -> None:
        self.clear()

    def clear(self) -> None:
        self.position = Point3()
        self.wcs = Point3()
        self.distance_mode = 90

    def copy(self) -> "PositionAccumulator":
        other = PositionAccumulator()
        other.position, other.wcs, other.distance_mode = self.position, self.wcs, self.distance_mode
        return other

    @property
    def work_position(self) -> Point3:
        return self.position - self.wcs

    def apply(self, line: GCodeLine) -> None:
        if line.group is LineGroup.USER_DEFINED or "$" in line.cleaned:
            return
        target: dict[Axis, float] = {}
        use_wcs = True
        for chunk in chunk_gcode_line(line.cleaned):
            if not chunk:
                continue
            letter, param = chunk[0], chunk[1:]
            axis = Axis.from_letter(letter)
            if axis is not None and letter.isupper():
                value = parse_double(param)
                if value is None:
                    continue
                target[axis] = value if self.distance_mode == 90 else self.position[axis] + value
            elif letter == "G":
                digits = param.replace(".", "", 1)  # remove the first '.', then stoi ("38.2" → 382)
                number = leading_integer(digits)
                if number is None:
                    continue
                if number == 53:
                    use_wcs = False
                elif number in (90, 91):
                    self.distance_mode = number
        for axis, value in target.items():
            self.position = self.position.replacing(
                axis, value + self.wcs[axis] if (use_wcs and self.distance_mode != 91) else value)
