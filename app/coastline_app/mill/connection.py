"""A live connection to one mill. Port of MillConnection.swift + CustomMCodes.swift
(`MillConnection`, `MillWriter` and `Commands/*` in the original).

All methods block and must be called off the UI thread. A recursive lock serialises compound
operations, while `emergency_stop()` and `execute_realtime()` can be called from another thread
to interrupt a running program.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from typing import Callable

from .contour import ContourMap, M106Check, WCSExpression, WCSExpressionError
from .errors import MillError, MillErrorKind as K, MillingError
from .gcode import GCodeLine, LineGroup, LineKind, chunk_gcode_line
from .geometry import Axis, Point3
from .protocol import FeedRate, GRBLProtocol, PositionAccumulator
from .serial_connection import LogKind, MachineLog, SerialConnection
from .state import ConnectionState
from .status import MillSettings, RealTimeStatus, split_once
from .support import cpp_float, monotonic_now, parse_double, sleep_ms
from .transport import MillDevice


@dataclass(frozen=True)
class MillProgress:
    completed: int = 0
    total: int = 0

    @property
    def percentage(self) -> float:
        return self.completed / self.total * 100 if self.total > 0 else 0.0


@dataclass
class _PreprobeState:
    position: Point3 = Point3()
    g_states: list[str] = field(default_factory=list)
    coolant_state: str = ""
    spindle_state: str = ""
    tool_number: str = ""
    feed_rate: str = ""
    spindle_rpm: str = ""


class MillConnection:
    def __init__(self, device: MillDevice, transport, log: MachineLog,
                 is_manual_operation: Callable[[], bool] = lambda: False,
                 enable_ls: Callable[[], bool] = lambda: False) -> None:
        self.device = device
        self.log = log
        self.is_manual_operation = is_manual_operation  # timeouts are not e-stops in manual mode
        self.enable_ls = enable_ls
        self.state = ConnectionState()
        self.serial = SerialConnection(transport, self.state, log)
        self.proto = GRBLProtocol(self.serial, self.state)
        self.proto.on_probe_result = self.save_probe_result
        self.feed_rate = FeedRate()
        self.lock = threading.RLock()
        self._small = threading.Lock()  # guards the small shared values below
        self._progress = MillProgress()
        self._estop_flag = False
        # Programs latch a stop generation, so an e-stop pressed while a program thread is busy
        # elsewhere still cancels it.
        self._stop_generation = 0
        self._program_generation: int | None = None
        self._probe_count = 0  # every `[PRB:` report (M111 waits for a new one)
        self._probe = Point3()
        self.accumulator = PositionAccumulator()
        self._saved_preprobe: _PreprobeState | None = None
        self.contour = ContourMap()

    @staticmethod
    def connect(device: MillDevice, transport, log: MachineLog,
                is_manual_operation: Callable[[], bool] = lambda: False,
                enable_ls: Callable[[], bool] = lambda: False) -> "MillConnection":
        """Opens the port, waits for the GRBL banner and loads `$$` settings."""
        if not device.path:
            raise MillError(K.FAILED_OPEN, "Path Empty")
        c = MillConnection(device, transport, log, is_manual_operation, enable_ls)
        c._connect()
        return c

    def _connect(self) -> None:
        with self.lock:
            self.serial.connect()
            self.state.set_connected(True)
            self.state.set_startup(True)
            self.serial.flush_reads()
            started = False
            deadline = monotonic_now() + 20
            while True:
                if monotonic_now() > deadline:
                    self.serial.disconnect()
                    self.state.set_connected(False)
                    raise MillError(K.FAILED_OPEN, f"no GRBL banner from {self.device.path}")
                line = self.serial.read_line()
                if line is not None:
                    version = self.grbl_version(line)
                    if version is not None:
                        self.proto.set_version(version)
                        started = True
                    continue
                self.state.update_state()
                if started and not self.state.is_startup:
                    break
                if self.state.is_timed_out and not self.reset(send_soft_reset=False):
                    raise MillError(K.ESTOP_PUSHED)
                sleep_ms(50)
            self.serial.flush_reads()
            self.execute_command(GCodeLine.injected("$$"))

    @staticmethod
    def grbl_version(line: str) -> str | None:
        """`^Grbl (\\d+\\.\\d+).*` (case-insensitive) → version."""
        if not line.lower().startswith("grbl "):
            return None
        rest = line[5:]
        major = ""
        for c in rest:
            if not c.isdigit():
                break
            major += c
        if not major or rest[len(major):len(major) + 1] != ".":
            return None
        minor = ""
        for c in rest[len(major) + 1:]:
            if not c.isdigit():
                break
            minor += c
        return f"{major}.{minor}" if minor else None

    def disconnect(self) -> None:
        if not self.state.is_connected:
            return
        with self._small:
            self._progress = MillProgress()
        self.state.reset()
        self.serial.disconnect()

    def verify_connected(self) -> None:
        if not self.state.is_connected:
            raise MillError(K.NOT_OPEN)

    # ---- public state
    @property
    def progress(self) -> MillProgress:
        with self._small:
            return self._progress

    def _set_progress(self, p: MillProgress) -> None:
        with self._small:
            self._progress = p

    @property
    def is_transport_open(self) -> bool:
        """False once the port was closed (e.g. a USB drop), even if the device path reappeared."""
        return self.serial.transport.is_open

    is_connected = property(lambda s: s.state.is_connected)
    is_locked = property(lambda s: s.state.is_locked)
    is_homing = property(lambda s: s.state.is_homing)
    settings_snapshot = property(lambda s: s.state.settings)
    cached_status = property(lambda s: s.state.status)
    parser_units = property(lambda s: s.state.units)
    current_wcs = property(lambda s: s.state.wcs)
    alarm_code = property(lambda s: s.state.alarm)

    @property
    def is_timed_out(self) -> bool:
        return self.updated_state().is_timed_out

    @property
    def last_probed_point(self) -> Point3:
        with self._small:
            return self._probe

    @property
    def feed_rate_slider(self) -> int:
        return self.feed_rate.slider

    @feed_rate_slider.setter
    def feed_rate_slider(self, v: int) -> None:
        self.feed_rate.slider = v

    def updated_state(self) -> ConnectionState:
        self.state.update_state()
        return self.state

    @property
    def current_error(self) -> MillingError | None:
        if self.state.error > 0:
            return MillingError.error(self.state.error, self.state.error_source)
        if self.state.alarm > 0:
            return MillingError.alarm(self.state.alarm)
        return None

    @property
    def is_estop_engaged(self) -> bool:
        return self.state.alarm == MillingError.ALARM_ESTOP

    # ---- reset
    def reset(self, send_soft_reset: bool = True) -> bool:
        """Clears local state; with `send_soft_reset` also resets GRBL with ^X.
        Returns False when the mill does not answer (e.g. e-stop pressed)."""
        self.verify_connected()
        sleep_ms(500)
        line = self.serial.read_line()
        if line is not None:
            self.proto.process_response(line)  # surfaces errors/alarms to the caller
        self.serial.flush_reads()
        self.serial.write_char(0x18 if send_soft_reset else ord("?"), wait_ms=1000)
        with self.lock:
            sleep_ms(5)
            line = self.serial.read_line()
            if line is None:
                return False
            while line is not None:
                try:
                    self.proto.process_response(line)
                except MillError:
                    pass
                line = self.serial.read_line()
            self._set_progress(MillProgress())
            self.state.reset(keep_connected=True)
            return True

    def probe_reset(self) -> None:
        """Recover after a failed probe (unlock, restore pre-probe state)."""
        self.verify_connected()
        sleep_ms(500)
        with self.lock:
            self.serial.flush_reads()
            self.serial.write_char(0x18, wait_ms=500)
            self.serial.write_line("$X", wait_ms=500)
            self.serial.flush_reads()
            self._set_progress(MillProgress())
            self.state.reset(keep_connected=True)
            self.state.retry_probe = True
            if self._saved_preprobe is not None:
                self.restore_preprobe_state()

    def emergency_stop(self) -> None:
        """Soft-reset immediately, then again after GRBL has settled."""
        with self._small:
            self._stop_generation += 1
            self._estop_flag = True
        try:
            self.execute_realtime(0x18)
        except MillError:
            pass
        with self._small:
            self._progress = MillProgress(0, self._progress.total)
        try:
            self.reset(send_soft_reset=False)  # an alarm is expected here
        except MillError:
            pass
        with self._small:
            self._estop_flag = False
        sleep_ms(200)
        try:
            self.execute_realtime(0x18)
        except MillError:
            pass

    # ---- execute
    def execute_command(self, line: GCodeLine, is_manual_entry: bool = False) -> None:
        """Run one line (manual entry, jogging, internal commands)."""
        self.verify_connected()
        with self.lock:
            self.state.reset_idle_time()
            self.state.clear_error()
            if not self.state.is_locked and not self.state.is_timed_out and not self.state.is_alarm:
                self.execute_line(line, use_buffer=False, manual_entry=True)
            elif line.is_unlock or line.is_home:
                # Manually entered commands should not automatically soft-reset GRBL.
                self.reset(send_soft_reset=not is_manual_entry)
                self.execute_line(line, use_buffer=False, manual_entry=True)
            elif line.cleaned == "|":
                self.reset(send_soft_reset=True)
            elif not line.is_injected:
                self.log.add(LogKind.ERROR, f'Failed to write "{line.original}"! The machine may be locked or the emergency stop may be engaged.')

    @property
    def stop_generation_snapshot(self) -> int:
        """Take it when a run is requested, so an e-stop pressed before the program thread
        starts still cancels it."""
        with self._small:
            return self._stop_generation

    def execute_program(self, lines: list[GCodeLine], is_manual_entry: bool = False,
                        stop_generation: int | None = None) -> None:
        """Stream a whole program with flow control and progress."""
        generation = self.stop_generation_snapshot if stop_generation is None else stop_generation
        with self.lock:
            with self._small:
                self._program_generation = generation
            try:
                self._check_stop_requested()
                self.verify_connected()
                self.contour.disable(self.log)  # M113: must be re-enabled explicitly on each run
                if self.current_error is not None and not self.reset(send_soft_reset=not is_manual_entry):
                    return
                self.state.reset_idle_time()
                if self.state.retry_probe:
                    self.serial.write_line("$X", wait_ms=1000)
                    self.state.retry_probe = False
                self.refresh_status()
                self.serial.flush_reads()
                self._set_progress(MillProgress(0, len(lines)))
                self.accumulator.clear()
                self.accumulator.wcs = self.current_wcs_offset()
                self.accumulator.position = self.current_position()
                for i, line in enumerate(lines):
                    self._check_stop_requested()
                    self.execute_line(line, use_buffer=True, manual_entry=is_manual_entry)
                    if self.feed_rate.is_update_required:
                        self.execute_line(GCodeLine.make(f"F{self.feed_rate.current_feed_rate()}", injected=True),
                                          use_buffer=True, manual_entry=is_manual_entry)
                    with self._small:
                        self._progress = MillProgress(i + 1, self._progress.total)
                self.execute_line(GCodeLine.make("G4 P0"), use_buffer=False, manual_entry=False)
            finally:
                with self._small:
                    self._program_generation = None

    def _check_stop_requested(self) -> None:
        with self._small:
            g = self._program_generation
            stop = g is not None and self._stop_generation > g
        if stop:
            raise MillError(K.SOFTWARE_ESTOP)

    def execute_realtime(self, byte: int) -> None:
        """Send a single real-time byte (`?`, `!`, `~`, `|`, 0x18, 0x85, overrides)."""
        self.verify_connected()
        self.serial.write_char(byte)
        if byte == ord("|"):
            self.state.wcs = 54
            self.state.units = 21

    def settings(self, refresh: bool = True) -> MillSettings:
        if refresh or self.state.settings.is_empty:
            self.execute_command(GCodeLine.injected("$$"))
        return self.state.settings

    def query_status(self) -> RealTimeStatus | None:
        self.verify_connected()
        return self.proto.query_status()

    def refresh_status(self) -> None:
        """`?` + newline; GRBL answers with a report and an `ok` for the empty line."""
        self.state.buffer_push(GCodeLine.injected("?"))
        self.serial.write_line("?")
        self.read_response(blocking=True)

    def execute_line(self, line: GCodeLine, use_buffer: bool, manual_entry: bool) -> None:
        if not line.cleaned:
            return
        if not self.state.buffer_is_empty:
            if not use_buffer or self.proto.requires_empty_buffer(line):
                self.read_response(blocking=True)
            while not self.state.buffer_fits(line):
                self.read_response(blocking=False)
        if not manual_entry and line.cleaned == "$LS" and not self.enable_ls():
            raise MillError(K.UNKNOWN_COMMAND, line.original)
        # GRBL system commands are only accepted when the machine is not running.
        if line.kind is LineKind.GRBL:
            status, missing = "Run", 0
            while status == "Run":
                self.refresh_status()
                current = self.state.status
                if current is not None:
                    status = current.state
                else:
                    missing += 1
                    if missing > 100:
                        break
        if not manual_entry and "G38" in line.cleaned:
            self.try_probe_operation(line)
            return
        cleaned = line.cleaned
        adjustable = "G53" not in cleaned and any(c in "XYZIJK" for c in cleaned)
        if self.contour.is_enabled and adjustable:
            self.transform_z_and_write_line(line)
        else:
            self.accumulator.apply(line)
            self.write(line)
        if not use_buffer or line.is_blocking:
            self.read_response(blocking=True)

    def read_response(self, blocking: bool) -> None:
        """Process incoming lines; when `blocking`, until every sent line is acknowledged. This is
        also where the e-stop heuristic lives: silence → timeout → hardware e-stop alarm."""
        while True:
            self.verify_connected()
            self._check_stop_requested()
            # The status poller may have processed an error/alarm meant for this operation.
            if self.state.error > 0:
                raise MillError(K.GRBL_ERROR, self.state.error_message)
            if self.state.alarm > 0:
                raise MillError(K.ALARM_PROBE if self.state.alarm in (4, 5) else K.ALARM)
            sleep_ms(5)
            line = self.serial.read_line()
            if line is not None:
                self.proto.process_response(line)
                continue
            with self._small:
                estop = self._estop_flag
            if estop:
                raise MillError(K.SOFTWARE_ESTOP)
            self.state.update_state()
            if self.state.is_timed_out:
                if self.is_manual_operation():
                    return  # timeouts are ignored in manual mode
                self.state.set_alarm(MillingError.ALARM_ESTOP)
                raise MillError(K.ESTOP_PUSHED)
            elif self.state.should_request_status():
                self.serial.write_char(ord("?"))
            if not blocking or self.state.buffer_is_empty:
                break
        # Only a completed blocking read ends homing.
        if blocking:
            self.state.set_homing(False)

    def read_response_without_processing(self) -> str:
        """Reads one line without processing it, waiting up to ~1 s."""
        sleep_ms(5)
        line = self.serial.read_line()
        tries = 0
        while line is None and tries < 200:
            tries += 1
            sleep_ms(5)
            line = self.serial.read_line()
            self.state.reset_idle_time()
        if line is None:
            raise MillError(K.ALARM)
        return line

    # ---- offsets / positions
    def offsets(self) -> list[tuple[str, Point3]]:
        """`$#` → [("G54", point), …, ("TLO", …), ("PRB", …)]. Empty on failure."""
        result: list[tuple[str, Point3]] = []
        with self.lock, self.serial.lock:
            try:
                self.verify_connected()
                self.serial.write_line("$#")
                response = ""
                while response != "ok":
                    response = self.read_response_without_processing()
                    if not response.startswith("[") or len(response) < 2:
                        continue
                    name, values = split_once(response[1:-1], ":")
                    numbers = [n for n in values.replace(":", ",").split(",") if n != ""]
                    x = parse_double(numbers[0]) if numbers else None
                    if x is None:
                        continue
                    if name == "TLO":
                        result.append((name, Point3(x, x, x)))
                    elif len(numbers) >= 3:
                        y, z = parse_double(numbers[1]), parse_double(numbers[2])
                        if y is not None and z is not None:
                            result.append((name, Point3(x, y, z)))
            except MillError:
                pass  # return what was collected, like the original
        return result

    def current_position(self) -> Point3:
        s = self.state.status
        return Point3() if s is None else s.machine_position

    def current_wcs_offset(self) -> Point3:
        s = self.state.status
        return (s.work_offset if s is not None and s.work_offset is not None else Point3())

    def save_probe_result(self, line: str) -> None:
        """`[PRB:-86.000,-0.500,-1.350:1]`."""
        if not line.startswith("[PRB:") or ":" not in line[5:]:
            return
        body = line[5:line.rindex(":")]
        parts = body.split(",")
        values = [parse_double(p) for p in parts]
        if len(parts) != 3 or any(v is None for v in values):
            return
        with self._small:
            self._probe = Point3(*values)
            self._probe_count += 1

    @property
    def probe_reports(self) -> int:
        with self._small:
            return self._probe_count

    def reset_progress(self) -> None:
        self._set_progress(MillProgress())

    # ---- probing
    def try_probe_operation(self, line: GCodeLine) -> None:
        """Remember modal state/position so a failed probe can be recovered."""
        self._saved_preprobe = None
        self.refresh_status()
        point = Point3(-86, -0.5, -0.5)  # default: home position
        status = self.state.status
        if status is not None:
            point = status.machine_position
        self.serial.write_line("$G")
        restore = self.read_response_without_processing()  # "[GC:G0 G54 G17 G21 G90 G94 M5 M9 T0 F0 S0]"
        restore = restore[4:-1] if len(restore) > 5 else ""
        try:
            # The line is pushed here AND again inside write(); the extra entry is balanced by
            # the `ok` that follows the `$G` response above. Kept exactly as in the original.
            self.state.buffer_push(line)
            self.write(line)
            self.read_response(blocking=True)
        except MillError:
            saved = _PreprobeState(position=point)
            for token in [t for t in restore.split(" ") if t]:
                if token == "M9":
                    saved.coolant_state = token
                elif token.startswith("M"):
                    saved.spindle_state = token
                elif token.startswith("T"):
                    saved.tool_number = token
                elif token.startswith("F"):
                    saved.feed_rate = token
                elif token.startswith("S"):
                    saved.spindle_rpm = token
                else:
                    saved.g_states.append(token)
            self._saved_preprobe = saved
            raise

    def restore_preprobe_state(self) -> None:
        saved = self._saved_preprobe
        if saved is None:
            return
        try:
            for text in (saved.coolant_state, saved.spindle_state, saved.tool_number, saved.feed_rate, saved.spindle_rpm):
                self.serial.write_line(text)
            p = saved.position
            move = f"G53 G0 X{cpp_float(p.x)} Y{cpp_float(p.y)} Z{cpp_float(p.z)}"
            self.state.buffer_push(GCodeLine.make(move))
            self.serial.write_line(move)
            self.read_response(blocking=True)
            for g in saved.g_states:
                self.serial.write_line("G0" if "G38." in g else g)
            self.serial.flush_reads()
            self.serial.write_line("$G")
            response = "ok"
            deadline = monotonic_now() + 5
            while not response.startswith("[") and monotonic_now() < deadline:
                sleep_ms(10)
                line = self.serial.read_line()
                if line is not None:
                    response = line
            self._saved_preprobe = None
        except MillError:
            self.log.add(LogKind.ERROR, "Error occurred while restoring probe state.")

    # ---- writer (MillWriter)
    def write(self, line: GCodeLine) -> None:
        self._update_connection_state(line)
        if line.kind is LineKind.GRBL:
            if line.is_unlock or line.is_home:
                self.state.set_locked(False)
            if line.is_home or line.is_level:  # GRBL is silent while homing: longer timeout
                self.state.set_homing(True)
            if line.group is LineGroup.CHECK_MODE:
                self.state.set_check_mode(not self.state.is_check_mode)
            self._write_line(line)
        elif line.kind is LineKind.MCODE:
            if line.group is LineGroup.USER_DEFINED:
                options = line.mcode_options
                if options is None:
                    raise MillError(K.UNKNOWN_COMMAND, line.original)
                if line.value == 100:
                    self.m100(options)
                elif line.value == 101:
                    self.m101(options)
                elif line.value == 102:
                    self.m102(line.original)  # parentheses are part of the expression
                elif line.value == 106:
                    self.m106(line.original)
                elif line.value == 111:
                    self.m111(options)
                elif line.value == 112:
                    self.contour.enable(self.log)
                elif line.value == 113:
                    self.contour.disable(self.log)
                elif line.value == 114:
                    self.contour.clear(self.log)
                return
            self._write_line(line)
        elif line.kind is LineKind.GCODE:
            if line.wcs is not None:
                self.state.wcs = line.wcs
            if line.distance_mode is not None:
                self.state.distance_mode = line.distance_mode
            if line.group is LineGroup.UNITS and line.units is not None:
                self.state.units = line.units
            self.state.last_gcode_group = line.group
            self._write_line(line)
        elif line.kind is LineKind.AXIS_FEED_SPINDLE:
            self.state.last_gcode_group = LineGroup.MOTION
            self._write_line(line)
        else:
            raise MillError(K.UNKNOWN_COMMAND, line.original)

    def _update_connection_state(self, line: GCodeLine) -> None:
        """Tracks units / WCS from any `Gnn` in the line (regex search `G(\\d{2})`)."""
        s = line.cleaned
        i = 0
        while i + 2 < len(s):
            if s[i] == "G" and s[i + 1].isascii() and s[i + 1].isdigit() and s[i + 2].isascii() and s[i + 2].isdigit():
                code = int(s[i + 1:i + 3])
                if code in (20, 21):
                    self.state.units = code
                if 54 <= code <= 58:
                    self.state.wcs = code
                i += 3
            else:
                i += 1

    def _write_line(self, line: GCodeLine) -> None:
        if self.state.is_check_mode:
            sleep_ms(500)
        cleaned = line.cleaned
        if not line.is_injected:
            programmed = self.last_feed_rate(cleaned)
            if programmed is not None:
                scaled = self.feed_rate.update(programmed)
                if scaled > 0:
                    cleaned = self.replace_feed_rates(cleaned, scaled)
        setting = GRBLProtocol.parse_setting(cleaned)
        if setting is not None:
            self.state.update_setting(*setting)
        # Account for the text actually sent (the feed override can make it longer).
        outgoing = line if cleaned == line.cleaned else GCodeLine.make(cleaned, injected=line.is_injected)
        while not self.state.buffer_is_empty and not self.state.buffer_fits(outgoing):
            self.read_response(blocking=False)
        self.state.buffer_push(outgoing)
        self.serial.write_line(cleaned)

    @staticmethod
    def last_feed_rate(s: str) -> int | None:
        """The digits after the LAST `F`/`f` followed by a digit."""
        result = None
        for i, c in enumerate(s):
            if c in "Ff":
                digits = ""
                for d in s[i + 1:]:
                    if not (d.isascii() and d.isdigit()):
                        break
                    digits += d
                if digits:
                    result = int(digits)
        return result

    @staticmethod
    def replace_feed_rates(s: str, value: int) -> str:
        """`regex_replace(cleaned, F\\d+ (icase), "F<value>")`."""
        out, i = [], 0
        while i < len(s):
            if s[i] in "Ff":
                j = i + 1
                while j < len(s) and s[j].isascii() and s[j].isdigit():
                    j += 1
                if j > i + 1:
                    out.append(f"F{value}")
                    i = j
                    continue
            out.append(s[i])
            i += 1
        return "".join(out)

    # ---- contour-map Z transform
    def transform_z_and_write_line(self, line: GCodeLine) -> None:
        previous = self.accumulator.position
        temp = self.accumulator.copy()
        temp.apply(line)
        target = temp.position
        wcs = self.current_wcs_offset()
        if temp.distance_mode == 90:
            chunks = chunk_gcode_line(line.original)
            found_z = False
            for chunk in chunks:
                if chunk.startswith("Z"):
                    self.contour.previous_z = chunk
                    found_z = True
            if found_z:
                transformed = self.contour.transform_absolute_z(line, target, wcs)
            else:
                chunks.append(self.contour.previous_z)
                with_z = GCodeLine.make("".join(chunks))
                acc = self.accumulator.copy()
                acc.apply(with_z)
                transformed = self.contour.transform_absolute_z(with_z, acc.position, wcs)
        else:
            transformed = self.contour.transform_relative_z(line, previous, target)
        transformed_line = GCodeLine.make(transformed)
        self.write(transformed_line)
        self.accumulator.apply(transformed_line)

    # ---- sender-only M-codes
    def execute_internal(self, command: str) -> None:
        """Errors are logged, not raised; a GRBL error stays recorded, so the running program
        stops at its next read."""
        try:
            self.execute_command(GCodeLine.make(command), is_manual_entry=True)
        except MillError as e:
            self.log.add(LogKind.ERROR, f"ExecuteCommand error: {e}")

    @staticmethod
    def offset_named(name: str, offsets: list[tuple[str, Point3]]) -> Point3 | None:
        return next((p for n, p in offsets if n == name), None)

    def m100(self, args: str) -> None:
        """`M100 Gaa U Gbb V Gcc W`: store the midpoint of WCS Gaa.U and Gbb.V into Gcc.W."""
        self.log.add(LogKind.WRITE, "M100 In Progress...")
        a = args
        axis_in = Axis.from_letter(a[3]) if len(a) >= 12 else None
        axis_out = Axis.from_letter(a[11]) if len(a) >= 12 else None
        if axis_in is None or axis_out is None:
            self.log.add(LogKind.ERROR, "M100 Failed")
            raise MillError(K.M100_OUT_OF_RANGE)
        g_in1, g_in2, g_out = a[0:3], a[4:7], a[8:11]
        p_code = ord(a[10]) - ord("3")  # '4'…'9' → 1…6
        offsets = self.offsets()
        points = [p for p in (self.offset_named(g_in1, offsets), self.offset_named(g_in2, offsets)) if p is not None]
        if len(points) != 2:
            self.log.add(LogKind.ERROR, "M100 Failed")
            raise MillError(K.M100_OUT_OF_RANGE)
        v1, v2 = points[0][axis_in], points[1][axis_in]
        center = min(v1, v2) + (max(v1, v2) - min(v1, v2)) / 2
        self.execute_internal(f"G10 L2 P{p_code} {axis_out.value}{center:.3f}")
        stored = self.offset_named(g_out, self.offsets())
        if stored is not None:
            value = stored[axis_out]
            if abs(v2 - value) > abs(v2 - v1):
                self.log.add(LogKind.ERROR, "M100 Failed")
                raise MillError(K.M100_OUT_OF_RANGE)
        self.log.add(LogKind.READ, "M100 Complete")

    def m101(self, args: str) -> None:
        """`M101 GaaGbbGccA tol`: fail if the A-axis values of three WCS differ by `tol` or more."""
        self.log.add(LogKind.WRITE, "M101 Initiated")
        a = args
        axis = Axis.from_letter(a[9]) if len(a) > 10 else None
        tolerance = parse_double(a[10:]) if len(a) > 10 else None
        if axis is None or tolerance is None:
            raise MillError(K.M101_FAIL, a[9] if len(a) > 9 else "")
        names = [a[0:3], a[3:6], a[6:9]]
        offsets = self.offsets()
        values = [p[axis] for p in (self.offset_named(n, offsets) for n in names) if p is not None]
        if not values or not abs(max(values) - min(values)) < tolerance:
            self.log.add(LogKind.ERROR, "M101 Check Failed")
            raise MillError(K.M101_FAIL, axis.value)
        self.log.add(LogKind.READ, "M101 Check Succeeded")

    def m102(self, original: str) -> None:
        """`M102 GaaU <expression>`: evaluate arithmetic over WCS registers and store it in GaaU."""
        line = original.replace("M102", "").replace("m102", "")
        line = "".join(c for c in line if not c.isspace())
        if len(line) < 4 or not WCSExpression.is_register(line[0:4]):
            self.log.add(LogKind.ERROR, "M102 Syntax Error - Invalid destination register. Must be G54-59(X,Y,Z)")
            raise MillError(K.M102_INVALID_DEST_REGISTER)
        destination, expression = line[0:4].upper(), line[4:]
        offsets = self.offsets()
        if not offsets:
            self.log.add(LogKind.ERROR, "M102 Failed - Could not get offsets")
            raise MillError(K.M102_OFFSETS_FAIL)

        def register(name: str) -> float | None:
            axis = Axis.from_letter(name[-1])
            p = self.offset_named(name[:3], offsets) if axis is not None else None
            return None if p is None else p[axis]

        try:
            result = WCSExpression.evaluate(expression, register)
        except WCSExpressionError:
            self.log.add(LogKind.ERROR, "M102 Syntax Error - Invalid exprtk expression")
            raise MillError(K.M102_INVALID_EXPRESSION) from None
        p = int(destination[2]) - 3
        self.execute_internal(f"G10 L2 P{p} {destination[-1]}{cpp_float(result)}")
        self.log.add(LogKind.READ, "M102 Complete")

    def m106(self, original: str) -> None:
        """`M106 <left> <op> <right> error: <message>`: boolean check on WCS values."""
        text = original
        for prefix in ("M106 ", "m106 ", "M106\t", "m106\t"):
            text = text.replace(prefix, "")
        check = M106Check.parse(text)
        if not check.evaluate(self.offsets()):
            raise MillError(K.M106_BOOL_TEST_FAIL, check.error_message)

    def m111(self, params: str) -> None:
        """`M111 <axes>`: probe with `G38.2<axes>` and add the hit to the contour map."""
        self.log.add(LogKind.WRITE, "Initiating M111")
        reports = self.probe_reports
        self.serial.write_line("G38.2" + params)
        while self.probe_reports == reports:
            sleep_ms(10)
            self.read_response(blocking=True)
        added = self.contour.add(self.last_probed_point)
        self.serial.flush_reads()
        self.log.add(LogKind.READ, "M111 Complete" if added else "M111 Failed. Duplicate X & Y values.")
