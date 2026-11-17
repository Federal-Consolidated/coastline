"""A simulated controller (the machine's grbl fork 1.1g) behind the transport interface. Used by
the tests and by the app's "simulated mill" mode. Port of Mock/MockGRBL.swift.

Lines are queued in a 128-byte receive buffer, as on the real controller, and acknowledged when
the host polls (`read_available`), `lines_per_poll` at a time. `max_rx_used`/`overflowed` let tests
verify the host's character-counting flow control.
"""

from __future__ import annotations

import math
import sys
import threading
from dataclasses import dataclass, field
from typing import Callable

from .errors import MillError, MillErrorKind as K
from .geometry import AXES, Axis, Point3
from .session_types import MillOverride
from .status import MillOverrides
from .support import monotonic_now


@dataclass
class MockOptions:
    start_locked: bool = False
    lines_per_poll: int = sys.maxsize  # 1 = slow controller, large = instant
    reply_override: Callable[[str], str | None] | None = None  # e.g. "error:N" instead of ok
    probe_contact_z: float | None = -10.0  # None → ALARM:5 (no contact)
    # A simulated part: the first probe along an axis and direction finds a face half way along
    # its move; later probes that way touch the same face when they reach it.
    probe_faces: bool = False
    soft_limit_travel: Point3 = field(default_factory=lambda: Point3(86, 241.5, 78.5))
    firmware_info: str = "[grbl:1.1g XY:3A PCB:3B YMD:20240318]"
    # Jogs take time (at their feed) and report Jog; 0x85 and `!` cancel them where they are.
    timed_jogs: bool = False
    reports_overrides: bool = False  # add `Ov:` to the status (stock grbl does; the machine does not)


RX_BUFFER_SIZE = 128

# `$$` of a real machine (grbl 1.1g XY:3A, YMD 20240318).
STANDARD_SETTINGS = [
    (0, 10, "stepPulse"), (1, 100, "idleDelay"), (2, 0, "stepMask"), (3, 0, "dirMask"), (4, 0, "stepEn"),
    (5, 1, "limLVL"), (6, 0, "prbLVL"), (10, 127, "statMask"), (11, 0.02, "jncDev"), (12, 0.002, "arcTol"),
    (13, 0, "Inch"), (20, 1, "softLim"), (21, 1, "hardLim"), (22, 1, "homeEn"), (23, 1, "homeDirMask"),
    (24, 30, "homeFine"), (25, 2000, "homeSeek"), (26, 1, "homeDelay"), (27, 0.5, "homePulloff"),
    (30, 8500, "rpmMax"), (31, 1360, "rpmMin"),
    (100, 400, "x:stp/mm"), (101, 400, "y:stp/mm"), (102, 400, "z:stp/mm"),
    (110, 2540, "x:mm/min"), (111, 3100, "y:mm/min"), (112, 3100, "z:mm/min"),
    (120, 500, "x:mm/s^2"), (121, 500, "y:mm/s^2"), (122, 500, "z:mm/s^2"),
    (130, 86.5, "x:mm"), (131, 241.5, "y:mm"), (132, 78.5, "z:mm"),
]
INTEGER_SETTINGS = {0, 1, 2, 3, 4, 5, 6, 10, 13, 20, 21, 22, 23, 26, 30, 31}
HOME = Point3(-86, -0.5, -0.5)


class _State:
    def __init__(self) -> None:
        self.open = False
        self.output = bytearray()
        self.partial_line = bytearray()
        self.rx_queue: list[str] = []
        self.rx_used = 0
        self.max_rx_used = 0
        self.overflowed = False
        self.silent = False
        self.alarm = False
        self.hold = False
        self.position = HOME
        self.offsets: dict[int, Point3] = {n: Point3() for n in range(54, 60)}
        self.wcs = 54
        self.faces: dict[str, float] = {}
        self.absolute = True
        self.inches = False
        self.spindle = "M5"
        self.rpm = 0.0
        self.overrides = MillOverrides()
        self.jogs: list[tuple[Point3, float]] = []
        self.jog_from = Point3()
        self.jog_start = 0.0
        self.received: list[str] = []
        self.realtime: list[int] = []
        self.pending_at_arrival: dict[str, int] = {}
        self.status_count = 0
        self.boot_at: float | None = None


def _fmt(v: float) -> str:
    return "%.3f" % v


def _norm(p: Point3) -> float:
    return math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)


class MockGRBL:
    def __init__(self, options: MockOptions | None = None) -> None:
        self.options = options or MockOptions()
        self._lock = threading.RLock()
        self._s = _State()

    # ---- test hooks
    @property
    def received_lines(self) -> list[str]:
        with self._lock:
            return list(self._s.received)

    @property
    def realtime_bytes(self) -> list[int]:
        with self._lock:
            return list(self._s.realtime)

    @property
    def max_rx_used(self) -> int:
        with self._lock:
            return self._s.max_rx_used

    @property
    def overflowed(self) -> bool:
        with self._lock:
            return self._s.overflowed

    @property
    def position(self) -> Point3:
        with self._lock:
            self._advance()
            return self._s.position

    @property
    def overrides(self) -> MillOverrides:
        with self._lock:
            return self._s.overrides

    @property
    def spindle(self) -> tuple[str, float]:
        with self._lock:
            return self._s.spindle, self._s.rpm

    @property
    def silent(self) -> bool:
        with self._lock:
            return self._s.silent

    @silent.setter
    def silent(self, v: bool) -> None:
        """Simulates the hardware e-stop: the controller stops answering."""
        with self._lock:
            self._s.silent = v

    def set_offset(self, wcs: int, point: Point3) -> None:
        with self._lock:
            self._s.offsets[wcs] = point

    def offset(self, wcs: int) -> Point3:
        with self._lock:
            return self._s.offsets.get(wcs, Point3())

    def set_position(self, point: Point3) -> None:
        with self._lock:
            self._s.position = point

    def pending_lines(self, when_received: str) -> int | None:
        with self._lock:
            return self._s.pending_at_arrival.get(when_received)

    # ---- transport
    @property
    def is_open(self) -> bool:
        with self._lock:
            return self._s.open

    def open(self) -> None:
        with self._lock:
            s = self._s
            s.open = True
            s.output.clear()
            s.rx_queue.clear()
            s.rx_used = 0
            s.boot_at = monotonic_now() + 0.2

    def close(self) -> None:
        with self._lock:
            self._s.open = False

    def write(self, data: bytes) -> None:
        if not self.is_open:
            raise MillError(K.FAILED_WRITE)
        for byte in data:
            self._receive(byte)

    def read_available(self) -> bytes:
        with self._lock:
            s = self._s
            should_boot = s.boot_at is not None and monotonic_now() >= s.boot_at
            if should_boot:
                s.boot_at = None
        if should_boot:
            self._boot()
        self._process(self.options.lines_per_poll)
        with self._lock:
            out = bytes(self._s.output)
            self._s.output.clear()
            return out

    # ---- controller behaviour
    def _emit(self, line: str) -> None:
        with self._lock:
            if not self._s.silent:
                self._s.output += (line + "\r\n").encode()

    def _boot(self) -> None:
        with self._lock:
            s = self._s
            s.rx_queue.clear()
            s.rx_used = 0
            s.hold = False
            s.alarm = self.options.start_locked
            self._advance()
            s.jogs.clear()
            s.overrides = MillOverrides()
            s.spindle = "M5"
        self._emit("")
        self._emit("Grbl 1.1g [help:'$']")
        if self.options.start_locked:
            self._emit("[MSG:$H/$X]")

    def _receive(self, byte: int) -> None:
        with self._lock:
            s = self._s
            if byte == ord("?"):
                s.realtime.append(byte)
                report = self.status_report()
                self._emit(report)
            elif byte == ord("!"):
                s.realtime.append(byte)  # a feed hold during a jog cancels the jog
                if not self._cancel_jogs():
                    s.hold = True
            elif byte == ord("~"):
                s.realtime.append(byte)
                s.hold = False
            elif byte == 0x18:
                s.realtime.append(byte)
                self._boot()
            elif byte == 0x85:
                s.realtime.append(byte)
                self._cancel_jogs()
            elif byte == ord("|"):
                s.realtime.append(byte)
            elif byte >= 0x80:
                s.realtime.append(byte)
                command = MillOverride.for_byte(byte)
                if command is not None:
                    s.overrides = command.applied(s.overrides)
            elif byte == 0x0A:
                line = s.partial_line.decode("utf-8", "replace").replace("\r", "")
                s.partial_line.clear()
                s.received.append(line)
                s.pending_at_arrival.setdefault(line, len(s.rx_queue))
                s.rx_used += len(line.encode()) + 1
                s.max_rx_used = max(s.max_rx_used, s.rx_used)
                if s.rx_used > RX_BUFFER_SIZE:
                    s.overflowed = True
                s.rx_queue.append(line)
            else:
                s.partial_line.append(byte)

    def _process(self, limit: int) -> None:
        handled = 0
        while handled < limit:
            with self._lock:
                s = self._s
                self._advance()
                if s.silent or s.hold or not s.rx_queue:
                    return
                first = s.rx_queue[0]
                # Other lines wait for the jogs to finish; more jogs queue behind them.
                if s.jogs and not first.upper().startswith("$J="):
                    return
                line = s.rx_queue.pop(0)
                s.rx_used -= len(line.encode()) + 1
            self._execute(line)
            handled += 1

    def status_report(self) -> str:
        with self._lock:
            s = self._s
            self._advance()
            s.status_count += 1
            state = "Alarm" if s.alarm else ("Hold:0" if s.hold else ("Idle" if not s.jogs else "Jog"))
            p, w = s.position, s.offsets.get(s.wcs, Point3())
            report = f"<{state}|M:{_fmt(p.x)},{_fmt(p.y)},{_fmt(p.z)}|B:15,{RX_BUFFER_SIZE - s.rx_used}|L:0|0000"
            if s.status_count % 3 == 1:  # like GRBL, the work offset every few reports
                report += f"|W:{_fmt(w.x)},{_fmt(w.y)},{_fmt(w.z)}"
            if self.options.reports_overrides and s.status_count % 3 == 2:
                report += f"|Ov:{s.overrides.feed},{s.overrides.rapid},{s.overrides.spindle}"
            return report + ">"

    def _advance(self) -> None:
        """`timed_jogs`: moves the machine along its queued jogs to where it is now."""
        s = self._s
        now = monotonic_now()
        while s.jogs:
            target, feed = s.jogs[0]
            d = target - s.jog_from
            length = _norm(d)
            duration = length / (feed / 60) if feed > 0 else 0
            t = now - s.jog_start
            if t >= duration:
                s.position = target
                s.jog_from = target
                s.jog_start += duration
                s.jogs.pop(0)
                continue
            f = t / duration
            s.position = Point3(s.jog_from.x + d.x * f, s.jog_from.y + d.y * f, s.jog_from.z + d.z * f)
            return

    def _cancel_jogs(self) -> bool:
        self._advance()
        if not self._s.jogs:
            return False
        self._s.jogs.clear()
        return True

    def _execute(self, raw: str) -> None:
        line = "".join(c for c in raw if not c.isspace()).upper()
        if self.options.reply_override is not None:
            reply = self.options.reply_override(raw)
            if reply is not None:
                self._emit(reply)
                return
        if not line:
            self._emit("ok")
            return
        if line.startswith("$"):
            self._execute_system(line)
            return
        with self._lock:
            alarm = self._s.alarm
        if alarm:
            self._emit("error:9")
            return
        self._execute_gcode(line)

    def _execute_system(self, line: str) -> None:
        if line == "$$":
            t = self.options.soft_limit_travel
            for k, v, name in STANDARD_SETTINGS:
                value = {130: t.x, 131: t.y, 132: t.z}.get(k, v)
                text = str(int(value)) if k in INTEGER_SETTINGS else _fmt(value)
                self._emit(f"${k}={text} ({name})")
            self._emit("ok")
        elif line == "$#":
            with self._lock:
                offsets = dict(self._s.offsets)
            for n in range(54, 60):
                p = offsets.get(n, Point3())
                self._emit(f"[G{n}:{_fmt(p.x)},{_fmt(p.y)},{_fmt(p.z)}]")
            for text in ("[G28:0.000,0.000,0.000]", "[G30:0.000,0.000,0.000]", "[G92:0.000,0.000,0.000]",
                         "[TLO:0.000]", "[PRB:0.000,0.000,0.000:0]", "ok"):
                self._emit(text)
        elif line == "$G":
            with self._lock:
                s = self._s
                text = (f"[GC:G0 G{s.wcs} G17 {'G20' if s.inches else 'G21'} {'G90' if s.absolute else 'G91'} "
                        f"G94 {s.spindle} M9 T0 F0 S{int(s.rpm)}]")
            self._emit(text)
            self._emit("ok")
        elif line == "$I":
            self._emit(self.options.firmware_info)
            self._emit("ok")
        elif line == "$X":
            with self._lock:
                self._s.alarm = False
            self._emit("[MSG:Caution: Unlocked]")
            self._emit("ok")
        elif line in ("$H", "$HZ", "$HX", "$HY"):
            with self._lock:
                s = self._s
                s.alarm = False
                if line == "$H":
                    s.position = HOME
                if line == "$HZ":
                    s.position = s.position.replacing(Axis.Z, -0.5)
                if line == "$HX":
                    s.position = s.position.replacing(Axis.X, -86)
            self._emit("ok")
        elif line.startswith("$J="):
            self._jog(line[3:])
        elif line.startswith("$RST"):
            if line == "$RST=#":
                with self._lock:
                    for k in self._s.offsets:
                        self._s.offsets[k] = Point3()
            self._emit("ok")
        else:
            self._emit("ok")

    @staticmethod
    def _words(line: str) -> list[tuple[str, float]]:
        result: list[tuple[str, float]] = []
        letter, number = None, ""

        def flush() -> None:
            if letter is not None:
                try:
                    result.append((letter, float(number)))
                except ValueError:
                    pass

        for c in line:
            if c.isalpha():
                flush()
                letter, number = c, ""
            else:
                number += c
        flush()
        return result

    def _outside(self, target: Point3) -> bool:
        t = self.options.soft_limit_travel
        return (target.x > 1e-6 or target.y > 1e-6 or target.z > 1e-6
                or target.x < -t.x - 1e-6 or target.y < -t.y - 1e-6 or target.z < -t.z - 1e-6)

    def _jog(self, body: str) -> None:
        """`$J=`: relative unless it has G90 (work) or G53 (machine). Outside the travel: error:15."""
        w = self._words(body)
        with self._lock:
            s = self._s
            self._advance()
            g = [v for l, v in w if l == "G"]
            scale = 25.4 if 20 in g else 1.0
            target = s.jogs[-1][0] if s.jogs else s.position
            for letter, value in w:
                axis = Axis.from_letter(letter)
                if axis is None:
                    continue
                if 53 in g:
                    target = target.replacing(axis, value * scale)
                elif 90 in g:
                    target = target.replacing(axis, value * scale + s.offsets.get(s.wcs, Point3())[axis])
                else:
                    target = target.replacing(axis, target[axis] + value * scale)
            if self._outside(target):
                reply = "error:15"
            elif not self.options.timed_jogs:
                s.position = target
                reply = "ok"
            else:
                if not s.jogs:
                    s.jog_from = s.position
                    s.jog_start = monotonic_now()
                feed = next((v for l, v in reversed(w) if l == "F"), 1000.0)
                s.jogs.append((target, feed))
                reply = "ok"
        self._emit(reply)

    def _execute_gcode(self, line: str) -> None:
        w = self._words(line)
        g_codes = [v for l, v in w if l == "G"]
        probe = next((g for g in g_codes if abs(g - 38.2) < 0.01 or abs(g - 38.3) < 0.01), None)
        contact_z = self.options.probe_contact_z
        with self._lock:
            replies = self._gcode_replies(w, g_codes, probe, contact_z)
        for r in replies:
            self._emit(r)

    def _gcode_replies(self, w, g_codes, probe, contact_z) -> list[str]:
        s = self._s
        machine_coordinates = False
        for letter, value in w:
            if letter == "M":
                if value == 3:
                    s.spindle = "M3"
                elif value == 4:
                    s.spindle = "M4"
                elif value == 5:
                    s.spindle = "M5"
            elif letter == "S":
                s.rpm = value
        for g in g_codes:
            if g == 20:
                s.inches = True
            elif g == 21:
                s.inches = False
            elif g == 90:
                s.absolute = True
            elif g == 91:
                s.absolute = False
            elif g == 53:
                machine_coordinates = True
            elif 54 <= g <= 59 and g == int(g):
                s.wcs = int(g)
        scale = 25.4 if s.inches else 1.0
        if 10 in g_codes:
            # G10 L2 Pn: the offset itself. G10 L20 Pn: the offset that makes the current position the value.
            p = next((v for l, v in w if l == "P"), None)
            if p is None or not 1 <= int(p) <= 6:
                return ["error:3"]
            l_word = next((v for l, v in w if l == "L"), 2.0)
            n = 53 + int(p)
            point = s.offsets.get(n, Point3())
            for letter, value in w:
                axis = Axis.from_letter(letter)
                if axis is not None:
                    point = point.replacing(axis, s.position[axis] - value * scale if l_word == 20 else value * scale)
            s.offsets[n] = point
            return ["ok"]
        offset = Point3() if machine_coordinates else s.offsets.get(s.wcs, Point3())
        target = s.position
        for letter, value in w:
            axis = Axis.from_letter(letter)
            if axis is None:
                continue
            # G53 is a machine position in G90 and G91 alike (as in GRBL).
            v = value * scale + offset[axis] if (s.absolute or machine_coordinates) else s.position[axis] + value * scale
            target = target.replacing(axis, v)
        if self._outside(target):  # soft limits: ALARM:2, as GRBL does
            s.alarm = True
            return ["ALARM:2"]
        if probe is None:
            s.position = target
            return ["ok"]
        start = s.position
        if contact_z is None:
            # G38.3: no contact is not an alarm; the report says so (`:0`). G38.2 alarms.
            if abs(probe - 38.3) < 0.01:
                s.position = target
                return [f"[PRB:{_fmt(target.x)},{_fmt(target.y)},{_fmt(target.z)}:0]", "ok"]
            s.alarm = True
            return ["ALARM:5"]
        d = target - start
        length = _norm(d)
        contact = target
        moving = [a for a in AXES if d[a] != 0]
        if self.options.probe_faces and len(moving) == 1:
            axis = moving[0]
            key = axis.value + ("+" if d[axis] > 0 else "-")
            low, high = min(start[axis], target[axis]), max(start[axis], target[axis])
            face = s.faces.get(key)
            if face is not None and low <= face <= high:
                contact = contact.replacing(axis, face)
            else:
                contact = contact.replacing(axis, start[axis] + d[axis] / 2)
                s.faces[key] = contact[axis]
        elif d.x == 0 and d.y == 0 and min(start.z, target.z) <= contact_z <= max(start.z, target.z):
            contact = contact.replacing(Axis.Z, contact_z)
        elif length > 0:
            f = min(2.0, length / 2) / length
            contact = Point3(start.x + d.x * f, start.y + d.y * f, start.z + d.z * f)
        s.position = contact
        return [f"[PRB:{_fmt(contact.x)},{_fmt(contact.y)},{_fmt(contact.z)}:1]", "ok"]
