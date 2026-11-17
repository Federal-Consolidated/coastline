"""A live connection to a machine, for Coastline's Control page. Port of Session/MillSession.swift.

One I/O thread owns the port: it is the only reader, sends one line at a time, waits for its
`ok`, and polls `?` every 250 ms. Feed hold, resume, jog cancel and soft reset do not go through
it: they are written on their own queue, so they are never refused or delayed while the port is
open. Motion (home, jog, console moves) starts only from a request, and only if the gates allow
it both when it is asked for and again just before the line is sent.

Rules from the real machine (grbl 1.1g XY:3A): opening the port restarts the board (banner after
about 2 s), it boots in Alarm and must be homed; `$H` runs 3–8 s with no status at all; an E-stop
makes the controller completely silent.
"""

from __future__ import annotations

import copy
import math
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field, replace
from enum import Enum

from .errors import ALARM_CODES, ERROR_CODES
from .geometry import AXES, Axis, Point3
from .mock import MockGRBL, MockOptions
from .programs import (M100, M100Call, M101, M101Call, M102, M102Call, M106, M106Call, blocked, check_job_program,
                       check_test_program)
from .protocol import GRBLProtocol
from .session_types import (ConsoleKind, JogRequest, MillConsoleLine, MillEnvelope, MillGates, MillLink, MillOffset,
                            MillOverride, MillPort, MillProgramStatus, MillRefusal, MillSnapshot, ProgramOutcome)
from .status import MillOverrides, MillSettings, RealTimeStatus, StatusParseError
from .support import monotonic_now
from .transport import PortFinder, SerialPort

POLL_INTERVAL = 0.25
SILENCE_LIMIT = 2.0  # no bytes for this long (outside homing): E-stop pressed or power off
FRESH_STATUS = 0.5  # an older status report cannot be used to start motion
HOMING_LIMIT = 60.0  # `$H` gets this long before the session resets the controller
JOG_FEEDS = [100.0, 300.0, 1000.0, 2000.0]
JOG_STEPS = [0.01, 0.1, 1.0, 10.0]
# Hold-to-jog: each `$J` is this many seconds of motion, about two stay planned ahead.
HOLD_SEGMENT = 0.25
# Hold-to-jog stops (0x85) when the app has not renewed the hold for this long.
HOLD_TIMEOUT = 0.4

QUERIES = ["$$", "$I", "$#", "$G"]


class _Phase(Enum):
    WAITING_FOR_BANNER = 0
    BOOT_MESSAGES = 1
    PROBING = 2
    READY = 3


class _Kind(Enum):
    QUERY = "query"
    HOME = "home"
    JOG = "jog"
    HOLD_JOG = "holdJog"
    CONSOLE = "console"
    SETUP = "setup"
    PROGRAM = "program"
    MACRO = "macro"


@dataclass
class _Request:
    kind: str  # home, jog, console, setup, program, resetSent
    jog: JogRequest | None = None
    generation: int = 0
    line: str = ""
    name: str = ""
    lines: list[str] = field(default_factory=list)
    homes_first: bool = False


class _Link:
    def __init__(self, port: MillPort, transport) -> None:
        self.port = port
        self.transport = transport
        self.stop_requested = threading.Event()


@dataclass
class _HoldControl:
    request: JogRequest | None = None
    generation: int = 0
    renewed: float = 0.0


@dataclass
class _IOHold:
    generation: int
    request: JogRequest
    target: Point3 | None = None  # where the jogs sent so far end (machine coordinates)


@dataclass
class _ProgramRun:
    lines: list[str]
    next: int = 0
    macro: M100Call | None = None
    macro_step: int = 0
    midpoint: float = 0.0
    check: M101Call | None = None
    expression: M102Call | None = None  # an M102 in progress (G4 P0 → `$#` → G10 L2 → `$#`)
    value: float = 0.0  # the value it writes
    assertion: M106Call | None = None  # an M106 in progress (G4 P0 → `$#` → compare)
    homing: bool = False  # the line sent last was `$H`

    @property
    def in_macro(self) -> bool:
        return self.macro is not None or self.check is not None or self.expression is not None or self.assertion is not None


@dataclass
class _Pending:
    line: str
    kind: _Kind
    deadline: float
    replies: list[str] = field(default_factory=list)
    jog_generation: int | None = None


@dataclass
class _IOState:
    s: MillSnapshot = field(default_factory=MillSnapshot)
    phase: _Phase = _Phase.WAITING_FOR_BANNER
    phase_deadline: float = 0.0
    partial: bytearray = field(default_factory=bytearray)
    last_rx: float = 0.0
    last_poll: float = 0.0
    poll_paused_until: float = 0.0
    status_mono: float = 0.0
    pending: _Pending | None = None
    queue: list[tuple[str, _Kind]] = field(default_factory=list)
    homing_started: float | None = None
    check_home_on_next_status: bool = False
    program: _ProgramRun | None = None
    last_port_check: float = 0.0
    hold: _IOHold | None = None
    last_hold_generation: int = 0
    jog_generation: int = 0
    last_jog_generation: int | None = None
    cancel_after_jog_ack: int | None = None


class _Console:
    def __init__(self) -> None:
        self.lines: list[MillConsoleLine] = []
        self.next_id = 1

    def add(self, kind: ConsoleKind, text: str) -> None:
        self.lines.append(MillConsoleLine(self.next_id, time.time(), kind, text))
        self.next_id += 1
        if len(self.lines) > 2000:
            del self.lines[:len(self.lines) - 2000]


class _SerialQueue:
    """A serial queue with delayed submission (DispatchQueue + asyncAfter)."""

    def __init__(self) -> None:
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mill-realtime")

    def submit(self, fn) -> None:
        self._executor.submit(fn)

    def after(self, seconds: float, fn) -> None:
        timer = threading.Timer(seconds, lambda: self._executor.submit(fn))
        timer.daemon = True
        timer.start()

    def sync(self) -> None:
        self._executor.submit(lambda: None).result()


def _fmt_point(p: Point3) -> str:
    return "X%.3f Y%.3f Z%.3f" % (p.x, p.y, p.z)


class MillSession:
    poll_interval = POLL_INTERVAL
    jog_feeds = JOG_FEEDS
    jog_steps = JOG_STEPS

    def __init__(self) -> None:
        self._lock = threading.Lock()  # guards everything shared below
        self._published = MillSnapshot()
        self._inbox: list[_Request] = []
        self._console = _Console()
        self._link: _Link | None = None
        self._hold = _HoldControl()
        self._jog_generation = 0  # invalidates jog requests accepted before Lock, Feed Hold or a reset
        self._overrides = MillOverrides()
        self._wake = threading.Semaphore(0)
        self._realtime = _SerialQueue()

    @staticmethod
    def available_ports():
        """Plugged-in mills (USB IDs 2341:0043, 2341:003E and 1A86:7523)."""
        return PortFinder.available_mills()

    # ---------------------------------------------------------------- public API

    @property
    def snapshot(self) -> MillSnapshot:
        with self._lock:
            return self._published

    def console(self, after: int) -> list[MillConsoleLine]:
        """Console lines with an id greater than `after`."""
        with self._lock:
            return [l for l in self._console.lines if l.id > after]

    def note_in_console(self, text: str) -> None:
        """A note in the console from the app (ports found and removed)."""
        self._log(ConsoleKind.NOTE, text)

    def clear_console(self) -> None:
        with self._lock:
            self._console.lines.clear()

    def connect(self, port: MillPort, transport=None) -> None:
        """Opens the port and starts the I/O thread. Opening restarts the controller."""
        if transport is None:
            if port.is_simulated:
                transport = MockGRBL(MockOptions(start_locked=True, soft_limit_travel=Point3(86.5, 241.5, 78.5),
                                                 probe_faces=True, timed_jogs=True))
            else:
                transport = SerialPort(port.device.path)
        with self._lock:
            if self._link is not None:
                return
            session = _Link(port, transport)
            self._link = session
            self._inbox = []
            s = MillSnapshot(revision=self._published.revision + 1, link=MillLink.CONNECTING, port=port)
            self._published = s
        self._note(f"Connecting to {port.label}. The controller restarts when the port opens.")
        threading.Thread(target=self._run, args=(session,), name="mill-io", daemon=True).start()

    def disconnect(self) -> None:
        """Stops motion first if the machine moves, then closes the port."""
        self._drop_hold()
        with self._lock:
            session = self._link
        if session is None:
            return

        def close() -> None:
            session.stop_requested.set()
            self._wake.release()

        if self.snapshot.is_moving:
            self.stop()
            self._realtime.after(1.5, close)  # close after the stop has had time to act
        else:
            close()

    def shutdown(self) -> None:
        """For app quit: stops any motion before returning, then closes the port."""
        self._drop_hold()
        with self._lock:
            session = self._link
        if session is None:
            return
        if self.snapshot.is_moving:
            self.stop()
            self._realtime.sync()
            time.sleep(0.4)
            if self.snapshot.is_moving:
                self.soft_reset()
                self._realtime.sync()
        session.stop_requested.set()
        self._wake.release()

    def home(self) -> MillRefusal | None:
        """Sends `$H`. The operator must have confirmed that the machine is clear."""
        refusal = self.snapshot.gates.home
        if refusal is not None:
            return refusal
        self._post(_Request("home"))
        return None

    def jog(self, request: JogRequest) -> MillRefusal | None:
        """A relative jog, shortened to stay inside the envelope."""
        refusal = self.snapshot.gates.jog
        if refusal is not None:
            return refusal
        if not request.is_valid:
            return blocked("Choose finite jog distances, at least one axis, and a feed of at least 1 mm/min.")
        with self._lock:
            generation = self._jog_generation
        self._post(_Request("jog", jog=request, generation=generation))
        return None

    def run(self, name: str, lines: list[str]) -> MillRefusal | None:
        """Runs a test program after checking it from the current machine position."""
        s = self.snapshot
        if s.gates.run is not None:
            return s.gates.run
        if s.status is None or s.envelope is None:
            return MillRefusal("statusStale")
        try:
            cleaned = check_test_program(lines, s.status.machine_position, s.envelope)
        except MillRefusal as refusal:
            return refusal
        self._post(_Request("program", name=name, lines=cleaned, homes_first=False))
        return None

    def run_job(self, name: str, lines: list[str]) -> MillRefusal | None:
        """Runs one program of a guided job: arcs, probing, work offsets, the spindle, `$H`, M100
        and M101 are allowed. A program that starts with `$H` may start from Alarm."""
        s = self.snapshot
        if s.envelope is None:
            return MillRefusal("statusStale") if s.is_open else MillRefusal("notConnected")
        try:
            program = check_job_program(lines, s.settings, s.envelope)
        except MillRefusal as refusal:
            return refusal
        refusal = s.gates.home if program.starts_with_home else s.gates.run
        if refusal is not None:
            return refusal
        self._post(_Request("program", name=name, lines=program.lines, homes_first=program.starts_with_home))
        return None

    def send_console(self, text: str) -> MillRefusal | None:
        """A line typed in the console. Settings changes and resets are blocked; moves need homing."""
        line = text.strip(" \t")
        if not line:
            return None
        if line == "?":
            return None if self._realtime_byte(ord("?"), "?") else MillRefusal("notConnected")
        if line == "!":
            self.feed_hold()
            return None
        if line == "~":
            return self.resume()
        if self.snapshot.gates.console is not None:
            return self.snapshot.gates.console
        upper = line.upper().replace(" ", "")
        if upper == "$H":
            return self.home()
        why = self.blocked_console_reason(upper)
        if why is not None:
            return blocked(why)
        if self.is_motion(upper) and self.snapshot.gates.jog is not None:
            return self.snapshot.gates.jog
        self._post(_Request("console", line=line))
        return None

    def feed_hold(self) -> None:
        """`!`: always sent while the port is open."""
        self._drop_hold()
        self._cancel_queued_jogs()
        self._realtime_byte(ord("!"), "! feed hold")

    def resume(self) -> MillRefusal | None:
        """`~`, only from Hold or Door."""
        refusal = self.snapshot.gates.resume
        if refusal is not None:
            return refusal
        self._realtime_byte(ord("~"), "~ resume")
        return None

    def jog_cancel(self) -> None:
        """0x85: always sent while the port is open."""
        self._drop_hold()
        self._cancel_queued_jogs()
        self._realtime_byte(0x85, "0x85 jog cancel")

    def soft_reset(self) -> None:
        """0x18: always sent while the port is open. The controller restarts; home again after it."""
        self._drop_hold()
        self._cancel_queued_jogs()
        if self._realtime_byte(0x18, "0x18 soft reset"):
            self._post(_Request("resetSent"))

    def _cancel_queued_jogs(self) -> None:
        with self._lock:
            self._jog_generation += 1
        self._wake.release()

    def stop(self) -> None:
        """Stops whatever moves, the gentlest way that is safe: a jog is cancelled (0x85) and
        keeps the position; a program is held (`!`) before the reset so the position is not lost;
        homing and everything else get a soft reset at once."""
        self._drop_hold()
        s = self.snapshot
        state = s.status.state if s.status else ""
        if s.homing_since is not None or state == "Home":
            self.soft_reset()
        elif state == "Jog":
            self.jog_cancel()

            def later() -> None:
                if self.snapshot.is_moving:
                    self.soft_reset()
            self._realtime.after(1.0, later)
        elif state == "Run" or state.startswith("Hold:1"):
            self.feed_hold()
            self._realtime.after(0.6, self.soft_reset)
        else:
            self.soft_reset()

    # ---- hold to jog
    def start_hold(self, x: float = 0.0, y: float = 0.0, z: float = 0.0, feed: float = 1000.0,
                   axis: Axis | None = None, direction: float = 0.0) -> MillRefusal | None:
        """Starts a hold-to-jog toward a direction until `end_hold`, the end of the travel, or
        HOLD_TIMEOUT without `renew_hold`. Same gates as a jog."""
        if axis is not None:
            r = JogRequest(axis=axis, distance=direction, feed=feed)
            x, y, z = r.x, r.y, r.z
        refusal = self.snapshot.gates.jog
        if refusal is not None and refusal != MillRefusal("wrongState", "Jog"):
            return refusal  # in Jog (the last jog still stopping) the hold waits for Idle
        request = JogRequest(x=x, y=y, z=z, feed=feed)
        if not request.is_valid:
            return blocked("Choose a finite jog direction and a feed of at least 1 mm/min.")
        with self._lock:
            self._hold.generation += 1
            self._hold.request = request
            self._hold.renewed = monotonic_now()
        self._wake.release()
        return None

    def renew_hold(self) -> None:
        """Keeps a hold going: call it at least every 0.1 s while the operator holds."""
        with self._lock:
            if self._hold.request is not None:
                self._hold.renewed = monotonic_now()

    def end_hold(self) -> None:
        """The operator let go: the jog is cancelled at once."""
        if self._drop_hold():
            self._realtime_byte(0x85, "0x85 jog cancel")

    def _drop_hold(self) -> bool:
        with self._lock:
            was = self._hold.request is not None
            self._hold.request = None
        if was:
            self._wake.release()
        return was

    # ---- work offsets, spindle, overrides
    def set_work_position(self, values: dict[Axis, float], wcs: int) -> MillRefusal | None:
        """`G10 L20`: the current position becomes these work coordinates in `wcs` (54…59)."""
        if not 54 <= wcs <= 59 or not values or not all(math.isfinite(v) for v in values.values()):
            return blocked("Choose G54 to G59 and at least one axis.")
        words = "".join("%s%.3f" % (a.value, values[a]) for a in AXES if a in values)
        return self._setup(f"G10L20P{wcs - 53}" + words)

    def set_offset(self, point: Point3, wcs: int) -> MillRefusal | None:
        """`G10 L2`: writes the offset of `wcs` itself (to undo a change)."""
        if not 54 <= wcs <= 59:
            return blocked("Choose G54 to G59.")
        return self._setup("G10L2P%dX%.3fY%.3fZ%.3f" % (wcs - 53, point.x, point.y, point.z))

    def select_wcs(self, wcs: int) -> MillRefusal | None:
        if not 54 <= wcs <= 59:
            return blocked("Choose G54 to G59.")
        return self._setup(f"G{wcs}")

    def spindle_on(self, rpm: float) -> MillRefusal | None:
        """`M3 S…`: the spindle on, forward, at a speed inside `$31`…`$30`."""
        v = self.snapshot.settings.values
        low, high = v.get(31, 0.0), v.get(30, 0.0)
        if not (high > 0 and math.isfinite(rpm) and low <= rpm <= high):
            return blocked("Choose a speed from %.0f to %.0f RPM." % (low, high))
        return self._setup("M3S%.0f" % rpm)

    def spindle_off(self) -> MillRefusal | None:
        """`M5`: allowed whenever a console line is."""
        refusal = self.snapshot.gates.console
        if refusal is not None:
            return refusal
        self._post(_Request("console", line="M5"))
        return None

    def _setup(self, line: str) -> MillRefusal | None:
        refusal = self.snapshot.gates.setup
        if refusal is not None:
            return refusal
        self._post(_Request("setup", line=line))
        return None

    def override(self, command: MillOverride) -> None:
        """A feed, rapid or spindle override (a real-time byte): always sent while the port is open."""
        if not self._realtime_byte(command.byte, "0x%02X %s" % (command.byte, command.label)):
            return
        with self._lock:
            self._overrides = command.applied(self._overrides)

    # ---- console rules
    @staticmethod
    def blocked_console_reason(upper: str) -> str | None:
        if upper.startswith("$RST"):
            return "Restoring defaults or clearing offsets is blocked in Coastline."
        if upper.startswith("$N") and "=" in upper:
            return "Changing the startup lines is blocked in Coastline."
        if re.match(r"^\$\d+=", upper):
            return "Changing controller settings is blocked in Coastline."
        if upper.startswith("$I="):
            return "Changing the build info is blocked in Coastline."
        if upper.startswith("$L"):
            return "Use Auto-Level on the Control page."
        if upper.startswith("$H"):
            return "Home all axes with $H or the Home button."
        return None

    @staticmethod
    def is_motion(upper: str) -> bool:
        """Lines that can move an axis: jogs and G-code with axis words or a motion code."""
        if upper.startswith("$J="):
            return True
        if upper.startswith("$"):
            return False
        code = re.sub(r"\(.*?\)|;.*", "", upper)
        return re.search(r"[XYZ][-+.0-9]|G0*(0|1|2|3|28|30|38\.\d)(?![0-9.])", code) is not None

    # ---------------------------------------------------------------- requests, real-time path

    def _post(self, request: _Request) -> None:
        with self._lock:
            self._inbox.append(request)
        self._wake.release()

    def _realtime_byte(self, byte: int, label: str) -> bool:
        """Writes one real-time byte on its own queue. False if no port is open."""
        with self._lock:
            session = self._link
        if session is None or not session.transport.is_open:
            return False
        if byte != ord("?"):
            self._log(ConsoleKind.REALTIME, label)

        def send() -> None:
            try:
                session.transport.write(bytes([byte]))
            except Exception as e:  # noqa: BLE001
                self._log(ConsoleKind.ERROR, f"Could not send {label}: {e}")
        self._realtime.submit(send)
        return True

    def _log(self, kind: ConsoleKind, text: str) -> None:
        with self._lock:
            self._console.add(kind, text)

    def _note(self, text: str) -> None:
        self._log(ConsoleKind.NOTE, text)

    # ---------------------------------------------------------------- I/O thread

    def _run(self, session: _Link) -> None:
        io = _IOState()
        with self._lock:
            io.s = copy.deepcopy(self._published)
            io.jog_generation = self._jog_generation
        try:
            session.transport.open()
        except Exception as e:  # noqa: BLE001
            self._log(ConsoleKind.ERROR, f"Could not open {session.port.label}: {e}")
            self._finish(session, io, f"Could not open {session.port.label}. Is another program using it?")
            return
        start = monotonic_now()
        io.last_rx = start
        io.phase_deadline = start + 4.0
        while not session.stop_requested.is_set():
            now = monotonic_now()
            with self._lock:
                requests, self._inbox = self._inbox, []
            for request in requests:
                self._handle_request(request, io, session, now)
            if not session.transport.is_open:
                self._log(ConsoleKind.ERROR, "The port closed.")
                self._finish(session, io, "The connection to the machine was lost.")
                return
            data = session.transport.read_available()
            if data:
                io.last_rx = now
                if io.s.silent_since is not None:
                    io.s.silent_since = None
                    self._note("The machine answers again.")
                for line in self._split(data, io.partial):
                    self._handle_line(line, io, session, now)
            self._tick(io, session, now)
            if not session.port.is_simulated and now - io.last_port_check > 1:
                io.last_port_check = now
                if not any(m.path == session.port.device.path for m in PortFinder.available_mills()):
                    self._finish(session, io, "The machine was unplugged.")
                    return
            self._publish(io, now)
            # While a program streams, answer each `ok` at once: short segments need ~50 lines/s.
            self._wake.acquire(timeout=0.001 if io.program is not None else 0.01)
        self._finish(session, io, None)

    def _finish(self, session: _Link, io: _IOState, last_error: str | None) -> None:
        session.transport.close()
        with self._lock:
            if self._link is session:
                self._link = None
            self._hold.request = None
        s = io.s
        s.link = MillLink.DISCONNECTED
        s.holding = False
        s.homed = False
        s.homing_since = None
        s.silent_since = None
        s.gates = MillGates()
        if s.program is not None and s.program.outcome is ProgramOutcome.RUNNING:
            s.program.outcome = ProgramOutcome.STOPPED
            s.program.finished_at = time.time()
        if last_error is not None:
            s.last_error = last_error
        with self._lock:
            s.revision = self._published.revision + 1
            self._published = copy.deepcopy(s)
        self._note(last_error or "Disconnected.")

    @staticmethod
    def _split(data: bytes, partial: bytearray) -> list[str]:
        lines = []
        for byte in data:
            if byte == 0x0A:
                text = partial.decode("utf-8", "replace").strip()
                if text:
                    lines.append(text)
                partial.clear()
            elif byte != 0x0D:
                partial.append(byte)
        return lines

    def _write(self, text: str, session: _Link, realtime: bool = False) -> None:
        try:
            session.transport.write(text.encode() if realtime else (text + "\n").encode())
        except Exception as e:  # noqa: BLE001
            self._log(ConsoleKind.ERROR, f"Could not send {text}: {e}")

    def _write_byte(self, byte: int, session: _Link) -> None:
        try:
            session.transport.write(bytes([byte]))
        except Exception as e:  # noqa: BLE001
            self._log(ConsoleKind.ERROR, "Could not send 0x%02X: %s" % (byte, e))

    def _handle_request(self, request: _Request, io: _IOState, session: _Link, now: float) -> None:
        kind = request.kind
        if kind == "home":
            io.queue.append(("$H", _Kind.HOME))
        elif kind == "jog":
            # The target is worked out just before the line is sent, from a fresh status.
            with self._lock:
                current = self._jog_generation
            if request.generation != current:
                return
            io.queue.append((self._encode(request.jog, request.generation), _Kind.JOG))
        elif kind == "console":
            io.queue.append((request.line, _Kind.CONSOLE))
        elif kind == "setup":
            io.queue.append((request.line, _Kind.SETUP))
        elif kind == "program":
            io.s.gates = self._gates(io, now)
            refusal = io.s.gates.home if request.homes_first else io.s.gates.run
            if refusal is not None:
                self._refuse(request.name, refusal)
                return
            io.program = _ProgramRun(list(request.lines))
            io.s.program = MillProgramStatus(request.name, len(request.lines))
            io.s.last_error = None
            self._note(f"Running {request.name}: {len(request.lines)} lines.")
        elif kind == "resetSent":
            self._end_program(io, ProgramOutcome.STOPPED)
            self._clear_hold_io(io)
            with self._lock:
                self._overrides = MillOverrides()
            io.s.homed = False
            io.s.homing_since = None
            io.homing_started = None
            io.pending = None
            io.queue.clear()
            io.poll_paused_until = now + 0.25
            io.last_rx = now

    @staticmethod
    def _encode(jog: JogRequest, generation: int) -> str:
        """A queued jog keeps its vector until send time, when a fresh position is available."""
        return f"JOGV {generation} {jog.x!r} {jog.y!r} {jog.z!r} {jog.feed!r}"

    @staticmethod
    def _decode(line: str) -> tuple[JogRequest, int] | None:
        parts = line.split(" ")
        if len(parts) != 6 or parts[0] != "JOGV":
            return None
        try:
            generation = int(parts[1])
            x, y, z, feed = (float(p) for p in parts[2:])
        except ValueError:
            return None
        request = JogRequest(x=x, y=y, z=z, feed=feed)
        return (request, generation) if request.is_valid else None

    def _handle_line(self, line: str, io: _IOState, session: _Link, now: float) -> None:
        is_status = line.startswith("<") and line.endswith(">")
        if not is_status:
            self._log(ConsoleKind.RECEIVED, line)
        if re.match(r"^Grbl \d+\.\d+", line):
            io.s.banner = line
            if io.phase is not _Phase.READY:
                io.phase = _Phase.BOOT_MESSAGES
            else:
                # A banner after connect: the controller restarted (soft reset, E-stop release, brown-out).
                io.s.restarts += 1
                io.s.homed = False
                io.s.homing_since = None
                io.homing_started = None
                io.s.needs_reset = False
                io.s.locked = False
                if io.pending is not None:
                    self._note(f"{io.pending.line} was cancelled by the restart.")
                self._end_program(io, ProgramOutcome.STOPPED)
                self._clear_hold_io(io)
                with self._lock:
                    self._overrides = MillOverrides()
                io.pending = None
                io.queue.clear()
                io.queue += [(q, _Kind.QUERY) for q in QUERIES]
                self._note("The controller restarted. Home the machine again.")
            return
        if GRBLProtocol.is_lock_message(line):
            io.s.locked = True
            return
        if line.startswith("[MSG:Reset"):
            io.s.needs_reset = True
            return
        if is_status:
            self._handle_status(line, io, session, now)
            return
        if line.startswith("ALARM:"):
            try:
                code = int(line[6:])
            except ValueError:
                code = -1
            io.s.last_alarm = f"ALARM:{code} — {ALARM_CODES.get(code, 'Unknown alarm.')}"
            io.s.needs_reset = True
            io.s.homed = False
            io.s.homing_since = None
            io.homing_started = None
            io.pending = None
            io.queue = [q for q in io.queue if q[1] is _Kind.QUERY]
            self._clear_hold_io(io)
            self._log(ConsoleKind.ERROR, io.s.last_alarm)
            self._end_program(io, ProgramOutcome.FAILED, io.s.last_alarm)
            return
        if line.startswith("error:"):
            try:
                code = int(line[6:])
            except ValueError:
                code = -1
            entry = ERROR_CODES.get(code)
            text = f"{entry[0]}: {entry[1]}" if entry else "Unknown error."
            source = io.pending.line if io.pending is not None else "a command"
            io.s.last_error = f"{source} — error:{code} {text}"
            self._log(ConsoleKind.ERROR, io.s.last_error)
            pending_kind = io.pending.kind if io.pending is not None else None
            if pending_kind is _Kind.HOME:
                io.s.homing_since = None
                io.homing_started = None
            if pending_kind is _Kind.HOLD_JOG:
                self._end_hold_io(io, session, None)
            if pending_kind in (_Kind.PROGRAM, _Kind.MACRO):
                # Stop sending and hold what is already in the planner; Stop clears it, Resume runs it out.
                self._write("!", session, realtime=True)
                self._log(ConsoleKind.REALTIME, "! feed hold after the error")
                self._end_program(io, ProgramOutcome.FAILED, io.s.last_error)
            io.pending = None
            return
        # Only the reply to a probe move: `$#` also lists the last probe (`[PRB:…:0]` before any).
        if (line.startswith("[PRB:") and line.endswith(":0]") and io.program is not None and io.pending is not None
                and io.pending.kind is _Kind.PROGRAM and "G38" in io.pending.line):
            # G38.3 ends without an alarm when nothing was touched; stop here, and stop the spindle.
            why = ("The probe did not touch the part. Check the probe cable (the green LED must be off), the chips, "
                   "and that the part conducts.")
            io.s.last_error = why
            self._log(ConsoleKind.ERROR, why)
            self._end_program(io, ProgramOutcome.FAILED, why)
            io.pending = None
            io.queue.append(("M5", _Kind.CONSOLE))
            return
        if line in ("ok", "0k", "1k", "2k", "3k") or GRBLProtocol.is_hex_ok(line):
            pending = io.pending
            if pending is None:
                return
            io.pending = None
            self._complete(pending, io, session, now)
            return
        if io.pending is not None:
            io.pending.replies.append(line)

    def _handle_status(self, line: str, io: _IOState, session: _Link, now: float) -> None:
        unit = io.s.settings.report_unit
        status = None
        for parse in (RealTimeStatus.parse, RealTimeStatus.parse_v0):
            try:
                status = parse(line, io.s.active_wcs, unit, 21, 90)
                break
            except StatusParseError:
                continue
        if status is None:
            self._log(ConsoleKind.RECEIVED, line)
            return
        io.s.status = status
        io.s.status_time = time.time()
        io.status_mono = now
        if status.work_offset is not None:
            io.s.work_offset = status.work_offset
        if status.overrides is not None:
            with self._lock:
                self._overrides = status.overrides
        if io.phase is _Phase.PROBING:
            self._start_queries(io)
        elif io.s.settings.is_empty and io.pending is None and not io.queue:
            io.queue += [(q, _Kind.QUERY) for q in QUERIES]
        if io.check_home_on_next_status:
            # The first report after `ok` decides: Idle at the home position, or no homing.
            io.check_home_on_next_status = False
            target = io.s.home_target
            if status.state == "Idle" and target is not None and all(
                    abs(status.machine_position[a] - target[a]) <= 0.1 for a in AXES):
                io.s.homed = True
                io.s.locked = False
                self._note("Homed in %.1f s." % (now - (io.homing_started if io.homing_started is not None else now)))
            else:
                io.s.last_error = (f"Homing ended in {status.state} at {_fmt_point(status.machine_position)}, not Idle at "
                                   f"the home position {_fmt_point(target) if target else '?'}. Jog stays off.")
                self._log(ConsoleKind.ERROR, io.s.last_error)
            io.homing_started = None

    def _complete(self, pending: _Pending, io: _IOState, session: _Link, now: float) -> None:
        kind = pending.kind
        if kind is _Kind.QUERY:
            self._parse_query(pending, io)
        elif kind is _Kind.HOME:
            io.s.homing_since = None
            io.check_home_on_next_status = True
            io.last_poll = 0.0  # ask for a status now
            if io.program is not None and io.s.program is not None:
                io.s.program.done += 1
        elif kind is _Kind.PROGRAM:
            if io.s.program is not None:
                io.s.program.done += 1
            if pending.line == "$#":
                io.s.offsets = [o for o in map(self.parse_offset, pending.replies) if o]
                self._update_work_offset(io)
        elif kind is _Kind.MACRO:
            self._macro_step(pending, io, session, now)
        elif kind in (_Kind.CONSOLE, _Kind.SETUP):
            self._refresh(pending.line, io)

    def _parse_query(self, pending: _Pending, io: _IOState) -> None:
        if pending.line == "$$":
            settings = MillSettings()
            for line in pending.replies:
                parsed = GRBLProtocol.parse_setting(line)
                if parsed is not None:
                    settings.update(*parsed)
            io.s.settings = settings
            io.s.envelope = MillEnvelope.from_settings(settings)
            io.s.home_target = self.home_target(settings)
        elif pending.line == "$I":
            io.s.firmware = next((l for l in pending.replies if l.startswith("[")), None)
        elif pending.line == "$#":
            io.s.offsets = [o for o in map(self.parse_offset, pending.replies) if o]
            self._update_work_offset(io)
        elif pending.line == "$G":
            line = next((l for l in pending.replies if l.startswith("[GC:")), None)
            if line is not None:
                words = [w for w in line[4:-1].split(" ") if w]
                io.s.parser_state = " ".join(words)
                wcs = next((w for w in words if re.fullmatch(r"G5[4-9]", w)), None)
                if wcs is not None:
                    io.s.active_wcs = int(wcs[1:])
                self._update_work_offset(io)

    def _refresh(self, line: str, io: _IOState) -> None:
        """After a line that changes the offsets, the active work offset or the spindle, reads
        them back (`$#`, `$G`)."""
        code = re.sub(r"\(.*?\)|;.*|\s", "", line.upper())
        if code.startswith("$"):
            return
        if re.search(r"G10|G92", code) and not any(q[0] == "$#" for q in io.queue):
            io.queue.append(("$#", _Kind.QUERY))
        if re.search(r"G5[4-9](?![0-9.])|M[345](?![0-9])|S[0-9.]", code) and not any(q[0] == "$G" for q in io.queue):
            io.queue.append(("$G", _Kind.QUERY))

    def _update_work_offset(self, io: _IOState) -> None:
        """The work offset from `$#` at once: the active `G54`…`G59` plus `G92`."""
        base = io.s.offset(io.s.active_wcs)
        if base is None:
            return
        g92 = next((o.point for o in io.s.offsets if o.name == "G92"), Point3())
        io.s.work_offset = base + g92

    def _start_queries(self, io: _IOState) -> None:
        io.phase = _Phase.READY
        io.s.link = MillLink.CONNECTED
        io.queue += [(q, _Kind.QUERY) for q in QUERIES]

    def _tick(self, io: _IOState, session: _Link, now: float) -> None:
        self._cancel_stale_jogs(io, session)
        if io.phase is _Phase.WAITING_FOR_BANNER:
            if now > io.phase_deadline:
                # No restart banner (some boards do not reset on open): ask once.
                io.phase = _Phase.PROBING
                io.phase_deadline = now + 1.0
                self._write("?", session, realtime=True)
            return
        if io.phase is _Phase.PROBING:
            if now > io.phase_deadline:
                io.phase = _Phase.READY
                io.s.link = MillLink.CONNECTED
                io.s.silent_since = time.time()
                self._note("No reply from the machine. The E-stop may be pressed: turn the red knob clockwise.")
            return
        if io.phase is _Phase.BOOT_MESSAGES:
            if now - io.last_rx > 0.3:
                self._start_queries(io)
            return

        # The machine sends nothing while it homes: no polls and no silence check until `ok`.
        homing = io.pending is not None and io.pending.kind is _Kind.HOME
        if io.homing_started is not None and homing and now - io.homing_started > HOMING_LIMIT:
            self._log(ConsoleKind.ERROR, "No reply during homing. The controller was reset.")
            io.s.last_error = f"Homing did not finish in {int(HOMING_LIMIT)} s. The controller was reset."
            self._write("\x18", session, realtime=True)
            self._handle_request(_Request("resetSent"), io, session, now)
        if not homing and io.s.silent_since is None and now - io.last_rx > SILENCE_LIMIT:
            io.s.silent_since = time.time()
            io.s.homed = False
            if io.s.status is not None and io.s.status.state == "Jog":
                self._write_byte(0x85, session)
            self._log(ConsoleKind.ERROR, "No reply from the machine for 2 s. The E-stop may be pressed: turn the red knob clockwise.")
        interval = 1.0 if io.s.silent_since is not None else (0.1 if io.hold is not None else POLL_INTERVAL)
        if not homing and now >= io.poll_paused_until and now - io.last_poll >= interval:
            io.last_poll = now
            self._write("?", session, realtime=True)

        if io.pending is not None and now > io.pending.deadline and io.pending.kind is not _Kind.HOME:
            pending = io.pending
            self._log(ConsoleKind.ERROR, f"No reply to {pending.line}.")
            if pending.kind in (_Kind.PROGRAM, _Kind.MACRO):
                self._write("!", session, realtime=True)
                self._end_program(io, ProgramOutcome.FAILED, f"No reply to {pending.line}. Feed hold is on: press Stop.")
            io.pending = None
        self._hold_tick(io, session, now)
        if io.pending is None and io.queue:
            line, kind = io.queue.pop(0)
            self._send(line, kind, io, session, now)
        elif io.pending is None and io.program is not None and not io.check_home_on_next_status:
            program = io.program
            if program.homing:
                # `$H` in the program: go on only from the home position.
                if not io.s.homed:
                    self._end_program(io, ProgramOutcome.FAILED, io.s.last_error or "Homing did not end at the home position.")
                    return
                program.homing = False
            if program.in_macro:
                return  # the macro's next line goes out when the last one is answered
            if program.next < len(program.lines):
                line = program.lines[program.next]
                program.next += 1
                if line == "$H":
                    program.homing = True
                    io.homing_started = now
                    io.s.homing_since = time.time()
                    io.s.homed = False
                    self._log(ConsoleKind.SENT, line)
                    self._write(line, session)
                    io.pending = _Pending(line, _Kind.HOME, now + HOMING_LIMIT + 5)
                    return
                expression = M102.parse(line)
                if expression is not None:
                    # M102: G4 P0, read the offsets, work out the expression, write it, read them again.
                    program.expression = expression
                    program.macro_step = 0
                    self._log(ConsoleKind.NOTE, f"M102: G{expression.destination[0]} {expression.destination[1].value} = {expression.expression}.")
                    self._send_macro("G4P0", io, session, now)
                    return
                assertion = M106.parse(line)
                if assertion is not None:
                    # M106: G4 P0, read the offsets, check them.
                    program.assertion = assertion
                    program.macro_step = 0
                    self._log(ConsoleKind.NOTE, f"M106: {assertion.text}")
                    self._send_macro("G4P0", io, session, now)
                    return
                call = M101.parse(line)
                if call is not None:
                    # Coastline's M101: wait for the moves to finish, read the offsets, compare them.
                    program.check = call
                    program.macro_step = 0
                    self._log(ConsoleKind.NOTE, "M101: %s %s must agree within %.3f mm."
                              % (", ".join(f"G{o}" for o in call.offsets), call.axis.value, call.tolerance))
                    self._send_macro("G4P0", io, session, now)
                    return
                m100 = M100.parse(line)
                if m100 is not None:
                    # Coastline's M100: G4 P0, read the offsets, write the midpoint, read them again.
                    program.macro = m100
                    program.macro_step = 0
                    self._log(ConsoleKind.NOTE, f"M100: the midpoint of G{m100.a[0]} {m100.a[1].value} and G{m100.b[0]} "
                                                f"{m100.b[1].value} into G{m100.destination[0]} {m100.destination[1].value}.")
                    self._send_macro("G4P0", io, session, now)
                    return
                self._log(ConsoleKind.SENT, line)
                self._write(line, session)
                io.pending = _Pending(line, _Kind.PROGRAM, now + 30)
            elif io.s.status is not None and io.s.status.state == "Idle" and now - io.status_mono < FRESH_STATUS:
                self._end_program(io, ProgramOutcome.COMPLETED)
                # The offsets, work offset and spindle the program left, for the operator.
                io.queue += [("$#", _Kind.QUERY), ("$G", _Kind.QUERY)]

    def _cancel_stale_jogs(self, io: _IOState, session: _Link) -> None:
        """The immediate real-time byte can race a line already written; cancel again here, after
        reading its replies, and once more after its acknowledgement if necessary."""
        with self._lock:
            generation = self._jog_generation
        if generation != io.jog_generation:
            io.jog_generation = generation
            io.queue = [(l, k) for l, k in io.queue
                        if not (k is _Kind.JOG and (self._decode(l) or (None, None))[1] != generation)]
            sent = io.last_jog_generation
            if sent is not None and sent != generation:
                self._write_byte(0x85, session)
                self._log(ConsoleKind.REALTIME, "0x85 jog cancel (discarded queued jogs)")
                if io.pending is not None and io.pending.jog_generation == sent:
                    io.cancel_after_jog_ack = sent
                io.last_jog_generation = None
        cancelled = io.cancel_after_jog_ack
        if cancelled is not None and (io.pending is None or io.pending.jog_generation != cancelled):
            io.cancel_after_jog_ack = None
            self._write_byte(0x85, session)
            self._log(ConsoleKind.REALTIME, "0x85 jog cancel (last jog acknowledged)")

    def _hold_tick(self, io: _IOState, session: _Link, now: float) -> None:
        """Starts, keeps and ends the operator's hold, keeping about two short jogs planned ahead
        of the machine. Every way out sends a jog cancel from this thread, after its last `$J`."""
        with self._lock:
            shared = replace(self._hold)
        if io.hold is not None and (shared.request is None or shared.generation != io.hold.generation):
            self._end_hold_io(io, session, None)  # let go, or a new hold
        request = shared.request
        if request is None:
            return
        if io.hold is None:
            if shared.generation == io.last_hold_generation:
                return  # this hold already ended
            io.last_hold_generation = shared.generation
            io.hold = _IOHold(shared.generation, request)
            io.s.holding = True
            io.s.last_error = None
        hold = io.hold
        if now - shared.renewed > HOLD_TIMEOUT:
            self._end_hold_io(io, session, "the app stopped confirming the hold.")
            return
        if io.pending is not None or io.queue:
            return
        io.s.gates = self._gates(io, now)
        refusal = io.s.gates.jog
        if refusal is not None:
            if refusal != MillRefusal("wrongState", "Jog"):
                self._end_hold_io(io, session, refusal.text)
                return
            if hold.target is None:
                return
        if io.s.status is None or io.s.envelope is None:
            return
        mpos = io.s.status.machine_position
        length = request.length
        unit = Point3(request.x / length, request.y / length, request.z / length)
        feed = self.jog_feed(request, io.s.settings)
        if feed is None:
            self._end_hold_io(io, session, "the jog feed is not valid.")
            return
        segment = feed / 60 * HOLD_SEGMENT
        planned = hold.target if hold.target is not None else mpos
        ahead = (planned.x - mpos.x) * unit.x + (planned.y - mpos.y) * unit.y + (planned.z - mpos.z) * unit.z
        if ahead >= 2 * segment:
            return  # enough planned ahead
        nxt = JogRequest(x=unit.x * segment, y=unit.y * segment, z=unit.z * segment, feed=feed)
        move = self.jog_move(nxt, planned, io.s.envelope, io.s.settings)
        if move is None:
            # At the end of the travel: the machine stops there and waits for the operator to let go.
            if hold.target is None:
                self._end_hold_io(io, session, MillRefusal("atLimit").text)
            return
        with self._lock:
            generation = self._jog_generation
            current = replace(self._hold)
        if current.request is None or current.generation != hold.generation:
            return
        delta, move_feed = move
        text = self.jog_line(delta, move_feed)
        self._log(ConsoleKind.SENT, text)
        self._write(text, session)
        io.last_jog_generation = generation
        io.pending = _Pending(text, _Kind.HOLD_JOG, now + 3, jog_generation=generation)
        hold.target = planned + delta

    def _end_hold_io(self, io: _IOState, session: _Link, why: str | None) -> None:
        hold = io.hold
        if hold is None:
            return
        io.hold = None
        io.s.holding = False
        with self._lock:
            if self._hold.generation == hold.generation:
                self._hold.request = None
        if hold.target is not None:
            self._write_byte(0x85, session)
            self._log(ConsoleKind.REALTIME, "0x85 jog cancel (end of the hold)")
        if why is not None:
            io.s.last_error = f"Hold-to-jog stopped: {why}"
            self._log(ConsoleKind.ERROR, io.s.last_error)

    def _clear_hold_io(self, io: _IOState) -> None:
        """After a restart, an alarm or a reset the controller has no jog left: only forget the hold."""
        hold = io.hold
        if hold is None:
            return
        io.hold = None
        io.s.holding = False
        with self._lock:
            if self._hold.generation == hold.generation:
                self._hold.request = None

    def _send(self, line: str, kind: _Kind, io: _IOState, session: _Link, now: float) -> None:
        """Sends a queued line after checking the gates again with the freshest state (fail closed)."""
        io.s.gates = self._gates(io, now)
        text = line
        generation = None
        if kind is _Kind.HOME:
            if io.s.gates.home is not None:
                self._refuse("Home", io.s.gates.home)
                return
            io.homing_started = now
            io.s.homing_since = time.time()
            io.s.homed = False
            io.s.last_error = None
            io.s.last_alarm = None
        elif kind is _Kind.JOG:
            if io.s.gates.jog is not None:
                self._refuse("Jog", io.s.gates.jog)
                return
            queued = self._decode(line)
            with self._lock:
                current = self._jog_generation
            if queued is None or queued[1] != current or io.s.status is None or io.s.envelope is None:
                return
            jog, generation = queued
            move = self.jog_move(jog, io.s.status.machine_position, io.s.envelope, io.s.settings)
            if move is None:
                self._refuse("Jog", MillRefusal("atLimit"))
                return
            text = self.jog_line(*move)
            io.s.last_error = None
        elif kind is _Kind.CONSOLE:
            upper = line.upper().replace(" ", "")
            if io.s.gates.console is not None:
                self._refuse(line, io.s.gates.console)
                return
            if self.is_motion(upper) and io.s.gates.jog is not None:
                self._refuse(line, io.s.gates.jog)
                return
        elif kind is _Kind.SETUP:
            if io.s.gates.setup is not None:
                self._refuse(line, io.s.gates.setup)
                return
            io.s.last_error = None
        if generation is not None:
            with self._lock:
                if generation != self._jog_generation:
                    return
        self._log(ConsoleKind.SENT, text)
        self._write(text, session)
        if generation is not None:
            io.last_jog_generation = generation
        timeout = HOMING_LIMIT + 5 if kind is _Kind.HOME else (30.0 if kind is _Kind.CONSOLE else 3.0)
        io.pending = _Pending(text, kind, now + timeout, jog_generation=generation)

    def _send_macro(self, line: str, io: _IOState, session: _Link, now: float) -> None:
        self._log(ConsoleKind.SENT, line)
        self._write(line, session)
        io.pending = _Pending(line, _Kind.MACRO, now + 60)

    def _macro_step(self, pending: _Pending, io: _IOState, session: _Link, now: float) -> None:
        """One answered line of an M100: G4 P0 → `$#` → G10 L2 → `$#` (check)."""
        program = io.program
        if program is None:
            return
        if program.check is not None:
            self._check_step(program.check, pending, io, session, now)
            return
        if program.expression is not None:
            self._expression_step(program.expression, pending, io, session, now)
            return
        if program.assertion is not None:
            self._assertion_step(program.assertion, pending, io, session, now)
            return
        call = program.macro
        if call is None:
            return

        def fail(why: str) -> None:
            io.s.last_error = f"M100: {why}"
            self._log(ConsoleKind.ERROR, io.s.last_error)
            self._end_program(io, ProgramOutcome.FAILED, io.s.last_error)

        if program.macro_step == 0:
            program.macro_step = 1
            self._send_macro("$#", io, session, now)
        elif program.macro_step == 1:
            offsets = [o for o in map(self.parse_offset, pending.replies) if o]
            io.s.offsets = offsets
            a, b = M100.value(offsets, call.a), M100.value(offsets, call.b)
            if a is None or b is None:
                fail(f"the controller did not report G{call.a[0]} and G{call.b[0]}.")
                return
            program.midpoint = (a + b) / 2
            program.macro_step = 2
            self._send_macro("G10L2P%d%s%.3f" % (call.destination[0] - 53, call.destination[1].value, program.midpoint), io, session, now)
        elif program.macro_step == 2:
            program.macro_step = 3
            self._send_macro("$#", io, session, now)
        else:
            offsets = [o for o in map(self.parse_offset, pending.replies) if o]
            io.s.offsets = offsets
            got, a, b = M100.value(offsets, call.destination), M100.value(offsets, call.a), M100.value(offsets, call.b)
            if got is None or a is None or b is None:
                fail("the offsets could not be read back.")
                return
            # `$#` shows 3 decimals: the stored value must round to the midpoint and lie between the two.
            if not (abs(got - program.midpoint) <= 0.0015 and min(a, b) - 0.0015 <= got <= max(a, b) + 0.0015):
                fail("G%d %s is %.3f, expected %.3f." % (call.destination[0], call.destination[1].value, got, program.midpoint))
                return
            self._note("M100: G%d %s = %.3f (between %.3f and %.3f)." % (call.destination[0], call.destination[1].value, got, a, b))
            program.macro = None
            if io.s.program is not None:
                io.s.program.done += 1

    def _expression_step(self, call: M102Call, pending: _Pending, io: _IOState, session: _Link, now: float) -> None:
        """One answered line of an M102: G4 P0 → `$#` → G10 L2 → `$#` (check)."""
        program = io.program
        if program is None:
            return
        target = f"G{call.destination[0]} {call.destination[1].value}"

        def fail(why: str) -> None:
            io.s.last_error = f"M102: {why}"
            self._log(ConsoleKind.ERROR, io.s.last_error)
            self._end_program(io, ProgramOutcome.FAILED, io.s.last_error)
            io.queue.append(("M5", _Kind.CONSOLE))

        if program.macro_step == 0:
            program.macro_step = 1
            self._send_macro("$#", io, session, now)
        elif program.macro_step == 1:
            offsets = [o for o in map(self.parse_offset, pending.replies) if o]
            io.s.offsets = offsets
            value, why = M102.value(call, offsets)
            if value is None:
                fail(why)
                return
            program.value = value
            program.macro_step = 2
            self._send_macro("G10L2P%d%s%.3f" % (call.destination[0] - 53, call.destination[1].value, value), io, session, now)
        elif program.macro_step == 2:
            program.macro_step = 3
            self._send_macro("$#", io, session, now)
        else:
            offsets = [o for o in map(self.parse_offset, pending.replies) if o]
            io.s.offsets = offsets
            p = next((o.point for o in offsets if o.name == f"G{call.destination[0]}"), None)
            if p is None:
                fail("the offsets could not be read back.")
                return
            got = p[call.destination[1]]
            # `$#` shows 3 decimals: the stored value must round to the one worked out.
            if not abs(got - program.value) <= 0.0015:
                fail("%s is %.3f, expected %.3f." % (target, got, program.value))
                return
            self._note("M102: %s = %.3f." % (target, got))
            program.expression = None
            if io.s.program is not None:
                io.s.program.done += 1

    def _assertion_step(self, call: M106Call, pending: _Pending, io: _IOState, session: _Link, now: float) -> None:
        """One answered line of an M106: G4 P0 → `$#` → compare."""
        program = io.program
        if program is None:
            return
        if program.macro_step == 0:
            program.macro_step = 1
            self._send_macro("$#", io, session, now)
            return
        offsets = [o for o in map(self.parse_offset, pending.replies) if o]
        io.s.offsets = offsets
        why = M106.problem(call, offsets)
        if why is not None:
            io.s.last_error = f"M106: {why}"
            self._log(ConsoleKind.ERROR, io.s.last_error)
            self._end_program(io, ProgramOutcome.FAILED, io.s.last_error)
            io.queue.append(("M5", _Kind.CONSOLE))
            return
        self._note(f"M106: {M106.statement(call)} holds.")
        program.assertion = None
        if io.s.program is not None:
            io.s.program.done += 1

    def _check_step(self, call: M101Call, pending: _Pending, io: _IOState, session: _Link, now: float) -> None:
        """One answered line of an M101: G4 P0 → `$#` → compare."""
        program = io.program
        if program is None:
            return
        if program.macro_step == 0:
            program.macro_step = 1
            self._send_macro("$#", io, session, now)
            return
        offsets = [o for o in map(self.parse_offset, pending.replies) if o]
        io.s.offsets = offsets
        why = M101.problem(call, offsets)
        if why is not None:
            io.s.last_error = f"M101: {why}"
            self._log(ConsoleKind.ERROR, io.s.last_error)
            self._end_program(io, ProgramOutcome.FAILED, io.s.last_error)
            io.queue.append(("M5", _Kind.CONSOLE))
            return
        self._note("M101: %s %s agree within %.3f mm." % (", ".join(f"G{o}" for o in call.offsets), call.axis.value, call.tolerance))
        program.check = None
        if io.s.program is not None:
            io.s.program.done += 1

    def _end_program(self, io: _IOState, outcome: ProgramOutcome, failure: str = "") -> None:
        if io.program is None:
            return
        io.program = None
        p = io.s.program
        if p is not None:
            p.outcome = outcome
            p.failure = failure
            p.finished_at = time.time()
        if outcome is ProgramOutcome.COMPLETED:
            seconds = time.time() - p.started_at if p else 0.0
            self._note("%s finished in %.1f s." % (p.name if p else "The program", seconds))
        elif outcome is ProgramOutcome.STOPPED:
            self._note(f"{p.name if p else 'The program'} was stopped.")

    def _refuse(self, what: str, refusal: MillRefusal) -> None:
        self._log(ConsoleKind.ERROR, f"{what} was not sent: {refusal.text}")

    # ---------------------------------------------------------------- jog geometry

    @staticmethod
    def jog_feed(request: JogRequest, settings: MillSettings) -> float | None:
        """GRBL's F is path speed: limit each component's speed by `$110`–`$112`."""
        if not request.is_valid:
            return None
        feed = request.feed
        for index, axis in enumerate(AXES):
            if request[axis] == 0:
                continue
            limit = settings.values.get(110 + index)
            if limit is None or not math.isfinite(limit) or limit <= 0:
                return None
            feed = min(feed, limit / (abs(request[axis]) / request.length))
        feed = math.floor(feed)
        return feed if feed >= 1 else None

    @staticmethod
    def jog_move(request: JogRequest, position: Point3, envelope: MillEnvelope,
                 settings: MillSettings) -> tuple[Point3, float] | None:
        """Clip the whole vector to the first boundary; rounding toward zero cannot carry a
        component past it, and never creates motion on an unrequested axis."""
        if not request.is_valid or not all(math.isfinite(v) for v in (position.x, position.y, position.z)):
            return None
        fraction = 1.0
        for axis in AXES:
            if request[axis] == 0:
                continue
            rng = envelope[axis]
            available = rng.upper - position[axis] if request[axis] > 0 else position[axis] - rng.lower
            fraction = min(fraction, max(0.0, available) / abs(request[axis]))

        def component(v: float) -> float:
            return math.trunc(v * fraction * 1000) / 1000

        delta = Point3(component(request.x), component(request.y), component(request.z))
        feed = MillSession.jog_feed(JogRequest(x=delta.x, y=delta.y, z=delta.z, feed=request.feed), settings)
        return None if feed is None else (delta, feed)

    @staticmethod
    def jog_line(delta: Point3, feed: float) -> str:
        words = " ".join("%s%.3f" % (a.value, delta[a]) for a in AXES if delta[a] != 0)
        return "$J=G21 G91 " + words + " F%.0f" % feed

    # ---------------------------------------------------------------- gates

    def _gates(self, io: _IOState, now: float) -> MillGates:
        g = MillGates()
        if io.phase is not _Phase.READY or io.s.link is not MillLink.CONNECTED:
            return g
        s = io.s
        fresh = s.status is not None and now - io.status_mono <= FRESH_STATUS
        state = s.status.state if s.status else ""
        limit = s.status is not None and (s.status.limit_x or s.status.limit_y or s.status.limit_z)
        line_busy = (io.pending is not None and io.pending.kind is not _Kind.QUERY) or io.program is not None
        settings = self.settings_problem(s.settings)

        def common() -> MillRefusal | None:
            if s.silent_since is not None:
                return MillRefusal("silent")
            if (io.pending is not None and io.pending.kind is _Kind.HOME) or io.check_home_on_next_status:
                return MillRefusal("homing")
            if s.needs_reset:
                return MillRefusal("needsReset")
            if not fresh:
                return MillRefusal("statusStale")
            if settings is not None:
                return MillRefusal("settings", settings)
            if limit:
                return MillRefusal("limitSwitch")
            if line_busy:
                return MillRefusal("busy")
            return None

        c = common()
        g.home = c or (None if state in ("Alarm", "Idle") else MillRefusal("wrongState", state))
        g.jog = c or (MillRefusal("notHomed") if not s.homed else (None if state == "Idle" else MillRefusal("wrongState", state)))
        g.run = g.jog
        g.setup = g.jog
        if s.silent_since is not None:
            g.resume = MillRefusal("silent")
        else:
            g.resume = None if (state.startswith("Hold") or state.startswith("Door")) else MillRefusal("wrongState", state)
        if s.silent_since is not None:
            g.console = MillRefusal("silent")
        elif s.homing_since is not None:
            g.console = MillRefusal("homing")
        elif io.program is not None:
            g.console = MillRefusal("busy")
        else:
            g.console = None
        return g

    @staticmethod
    def settings_problem(settings: MillSettings) -> str | None:
        """Motion needs mm reports, soft limits, hard limits, homing and a full travel/rate table."""
        v = settings.values
        if not v:
            return "The controller settings ($$) were not read."
        if v.get(13) != 0:
            return "The controller reports inches ($13=1). Coastline needs $13=0."
        if v.get(20) != 1:
            return "Soft limits are off ($20=0). Coastline needs them on."
        if v.get(22) != 1:
            return "Homing is off ($22=0). Coastline needs it on."
        for n in (110, 111, 112, 130, 131, 132):
            if v.get(n, 0) <= 0:
                return f"Setting ${n} is missing."
        if MillEnvelope.from_settings(settings) is None:
            return "The travel and homing pull-off do not leave a valid working range. Check $130–$132 and $27."
        return None

    @staticmethod
    def home_target(settings: MillSettings) -> Point3 | None:
        """Per axis: `-$13n + $27` if the axis homes to its negative end (bit set in `$23`), else `-$27`."""
        v = settings.values
        try:
            mask, pulloff, tx, ty, tz = v[23], v[27], v[130], v[131], v[132]
        except KeyError:
            return None
        bits = int(mask)

        def axis(bit: int, travel: float) -> float:
            return -travel + pulloff if bits & (1 << bit) else -pulloff

        return Point3(axis(0, tx), axis(1, ty), axis(2, tz))

    @staticmethod
    def parse_offset(line: str) -> MillOffset | None:
        if not line.startswith("[G") or ":" not in line:
            return None
        colon = line.index(":")
        name = line[1:colon]
        numbers = []
        for part in line[colon + 1:-1].split(",")[:3]:
            try:
                numbers.append(float(part))
            except ValueError:
                pass
        if len(numbers) != 3:
            return None
        return MillOffset(name, Point3(*numbers))

    # ---------------------------------------------------------------- publishing

    def _publish(self, io: _IOState, now: float) -> None:
        io.s.gates = self._gates(io, now)
        with self._lock:
            io.s.overrides = replace(self._overrides)
            current = self._published
        nxt = copy.deepcopy(io.s)
        nxt.revision = current.revision
        if nxt == current:
            return
        nxt.revision = current.revision + 1
        io.s.revision = nxt.revision
        with self._lock:
            self._published = nxt
