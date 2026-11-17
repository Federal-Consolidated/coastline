"""Values the session hands to the screens. Port of Session/SessionTypes.swift."""

from __future__ import annotations

import math
import time
from dataclasses import dataclass, field, replace
from enum import Enum

from .geometry import Axis, Point3, Range
from .status import MillOverrides, MillSettings, RealTimeStatus
from .transport import MillDevice


@dataclass(frozen=True)
class MillPort:
    """Where a session connects: a device, or the simulated mill (`device is None`)."""

    device: MillDevice | None = None

    @staticmethod
    def simulated() -> "MillPort":
        return MillPort(None)

    @property
    def is_simulated(self) -> bool:
        return self.device is None

    @property
    def label(self) -> str:
        return "Simulated Mill" if self.device is None else self.device.path.replace("/dev/", "")


class MillLink(Enum):
    DISCONNECTED = "disconnected"
    CONNECTING = "connecting"  # port open; waiting for the controller's restart and answers
    CONNECTED = "connected"


@dataclass(frozen=True)
class MillEnvelope:
    """The travel the session allows, per axis, in machine coordinates (mm, all negative)."""

    x: Range
    y: Range
    z: Range

    def __getitem__(self, axis: Axis) -> Range:
        return {Axis.X: self.x, Axis.Y: self.y, Axis.Z: self.z}[axis]

    @staticmethod
    def from_settings(settings: MillSettings) -> "MillEnvelope | None":
        """From `$130`–`$132` (travel) and `$27` (pull-off): `-travel + m … -m`, `m = max(0.5, $27)`."""
        v = settings.values
        tx, ty, tz = v.get(130), v.get(131), v.get(132)
        if tx is None or ty is None or tz is None or not all(math.isfinite(t) and t > 1 for t in (tx, ty, tz)):
            return None
        pull_off = v.get(27, 0.5)
        if not math.isfinite(pull_off):
            return None
        m = max(0.5, pull_off)
        if m > min(tx, ty, tz) / 2:
            return None
        return MillEnvelope(Range(-tx + m, -m), Range(-ty + m, -m), Range(-tz + m, -m))


@dataclass(frozen=True)
class MillOffset:
    name: str  # G54…G59, G28, G30, G92
    point: Point3

    @property
    def id(self) -> str:
        return self.name


class ConsoleKind(Enum):
    SENT = "sent"
    RECEIVED = "received"
    REALTIME = "realtime"
    NOTE = "note"
    ERROR = "error"


@dataclass(frozen=True)
class MillConsoleLine:
    id: int
    time: float
    kind: ConsoleKind
    text: str


class MillRefusal(Exception):
    """Why a motion request was refused. `text` is shown to the operator as is."""

    def __init__(self, code: str, detail: str = "") -> None:
        self.code, self.detail = code, detail
        super().__init__(self.text)

    @property
    def text(self) -> str:
        return {
            "notConnected": "Connect to the machine first.",
            "silent": "No reply from the machine. The E-stop may be pressed: turn the red knob clockwise.",
            "statusStale": "Waiting for a status report from the machine.",
            "settings": self.detail,
            "needsReset": "The machine stopped with an alarm. Press Stop to reset it, then home.",
            "notHomed": "Home the machine first.",
            "homing": "Homing is in progress.",
            "busy": "Wait for the last command to finish.",
            "wrongState": f"Not possible while the machine is in {self.detail}.",
            "limitSwitch": "A limit switch is pressed.",
            "atLimit": "The axis is at the end of its travel.",
            "blocked": self.detail,
        }[self.code]

    def __eq__(self, other: object) -> bool:
        return isinstance(other, MillRefusal) and (self.code, self.detail) == (other.code, other.detail)

    def __hash__(self) -> int:
        return hash((self.code, self.detail))

    def __reduce__(self):
        return (MillRefusal, (self.code, self.detail))

    def __deepcopy__(self, memo) -> "MillRefusal":
        return self  # immutable

    def __copy__(self) -> "MillRefusal":
        return self

    def __repr__(self) -> str:
        return f"MillRefusal({self.code!r}{', ' + repr(self.detail) if self.detail else ''})"


NOT_CONNECTED = MillRefusal("notConnected")


@dataclass
class MillGates:
    """What the operator may start now. None means allowed."""

    home: MillRefusal | None = NOT_CONNECTED
    jog: MillRefusal | None = NOT_CONNECTED
    resume: MillRefusal | None = NOT_CONNECTED
    console: MillRefusal | None = NOT_CONNECTED
    run: MillRefusal | None = NOT_CONNECTED  # the same rules as a jog
    setup: MillRefusal | None = NOT_CONNECTED  # work offsets, active WCS, spindle start


class MillOverride(Enum):
    """GRBL 1.1's real-time override commands (single bytes: they act at once)."""

    FEED_RESET = (0x90, "feed 100%")
    FEED_PLUS_10 = (0x91, "feed +10%")
    FEED_MINUS_10 = (0x92, "feed −10%")
    FEED_PLUS_1 = (0x93, "feed +1%")
    FEED_MINUS_1 = (0x94, "feed −1%")
    RAPID_100 = (0x95, "rapid 100%")
    RAPID_50 = (0x96, "rapid 50%")
    RAPID_25 = (0x97, "rapid 25%")
    SPINDLE_RESET = (0x99, "spindle 100%")
    SPINDLE_PLUS_10 = (0x9A, "spindle +10%")
    SPINDLE_MINUS_10 = (0x9B, "spindle −10%")
    SPINDLE_PLUS_1 = (0x9C, "spindle +1%")
    SPINDLE_MINUS_1 = (0x9D, "spindle −1%")

    @property
    def byte(self) -> int:
        return self.value[0]

    @property
    def label(self) -> str:
        return self.value[1]

    def applied(self, o: MillOverrides) -> MillOverrides:
        """The overrides after this command, within GRBL's limits (feed and spindle 10–200%)."""
        def clamp(v: int) -> int:
            return min(max(v, 10), 200)
        o = replace(o)
        M = MillOverride
        if self is M.FEED_RESET:
            o.feed = 100
        elif self is M.FEED_PLUS_10:
            o.feed = clamp(o.feed + 10)
        elif self is M.FEED_MINUS_10:
            o.feed = clamp(o.feed - 10)
        elif self is M.FEED_PLUS_1:
            o.feed = clamp(o.feed + 1)
        elif self is M.FEED_MINUS_1:
            o.feed = clamp(o.feed - 1)
        elif self is M.RAPID_100:
            o.rapid = 100
        elif self is M.RAPID_50:
            o.rapid = 50
        elif self is M.RAPID_25:
            o.rapid = 25
        elif self is M.SPINDLE_RESET:
            o.spindle = 100
        elif self is M.SPINDLE_PLUS_10:
            o.spindle = clamp(o.spindle + 10)
        elif self is M.SPINDLE_MINUS_10:
            o.spindle = clamp(o.spindle - 10)
        elif self is M.SPINDLE_PLUS_1:
            o.spindle = clamp(o.spindle + 1)
        elif self is M.SPINDLE_MINUS_1:
            o.spindle = clamp(o.spindle - 1)
        return o

    @staticmethod
    def for_byte(byte: int) -> "MillOverride | None":
        return next((o for o in MillOverride if o.byte == byte), None)


class ProgramOutcome(Enum):
    RUNNING = "running"
    COMPLETED = "completed"  # every line acknowledged and the machine Idle again
    FAILED = "failed"
    STOPPED = "stopped"  # Stop, a reset, a restart or a disconnect


@dataclass
class MillProgramStatus:
    name: str
    total: int
    done: int = 0
    started_at: float = field(default_factory=time.time)
    finished_at: float | None = None
    outcome: ProgramOutcome = ProgramOutcome.RUNNING
    failure: str = ""  # the message when outcome is FAILED

    @property
    def fraction(self) -> float:
        return self.done / self.total if self.total > 0 else 0.0


class JogRequest:
    """Signed relative distances in mm. A diagonal is one coordinated motion, shortened
    proportionally if any requested axis reaches the envelope first. `feed`: path speed in
    mm/min; each axis's component is capped by `$110`–`$112`."""

    def __init__(self, x: float = 0.0, y: float = 0.0, z: float = 0.0, feed: float = 1000.0,
                 axis: Axis | None = None, distance: float | None = None) -> None:
        if axis is not None:
            d = distance or 0.0
            x, y, z = (d if axis is Axis.X else 0.0), (d if axis is Axis.Y else 0.0), (d if axis is Axis.Z else 0.0)
            self._empty_axis = axis
        else:
            self._empty_axis = Axis.X if x != 0 else Axis.Y if y != 0 else Axis.Z if z != 0 else Axis.X
        self.x, self.y, self.z, self.feed = x, y, z, feed

    @property
    def axis(self) -> Axis:
        """Compatibility for single-axis clients. For a vector, the first nonzero axis."""
        return Axis.X if self.x != 0 else Axis.Y if self.y != 0 else Axis.Z if self.z != 0 else self._empty_axis

    @axis.setter
    def axis(self, axis: Axis) -> None:
        d = self.distance
        self.x, self.y, self.z = (d if axis is Axis.X else 0.0), (d if axis is Axis.Y else 0.0), (d if axis is Axis.Z else 0.0)
        self._empty_axis = axis

    @property
    def distance(self) -> float:
        return self[self.axis]

    @distance.setter
    def distance(self, value: float) -> None:
        axis = self.axis
        if axis is Axis.X:
            self.x = value
        elif axis is Axis.Y:
            self.y = value
        else:
            self.z = value

    def __getitem__(self, axis: Axis) -> float:
        return {Axis.X: self.x, Axis.Y: self.y, Axis.Z: self.z}[axis]

    @property
    def length(self) -> float:
        return math.hypot(math.hypot(self.x, self.y), self.z)

    @property
    def is_valid(self) -> bool:
        return (all(math.isfinite(v) for v in (self.x, self.y, self.z, self.feed)) and self.feed >= 1
                and math.isfinite(self.length) and self.length > 0)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, JogRequest) and (self.x, self.y, self.z, self.feed, self.axis) == (other.x, other.y, other.z, other.feed, other.axis)

    def __repr__(self) -> str:
        return f"JogRequest(x={self.x}, y={self.y}, z={self.z}, feed={self.feed})"


@dataclass
class MillSnapshot:
    """Everything the Control page shows, copied out of the session's I/O thread."""

    revision: int = 0
    link: MillLink = MillLink.DISCONNECTED
    port: MillPort | None = None
    banner: str | None = None  # `Grbl 1.1g [help:'$']`
    firmware: str | None = None  # the `$I` line
    settings: MillSettings = field(default_factory=MillSettings)
    status: RealTimeStatus | None = None
    status_time: float | None = None
    work_offset: Point3 | None = None  # the last `W:` (sent about every tenth report)
    parser_state: str | None = None  # `$G`, e.g. `G0 G54 G17 G21 G90 G94 M5 M9 T0 F0 S0`
    active_wcs: int = 54
    offsets: list[MillOffset] = field(default_factory=list)
    envelope: MillEnvelope | None = None
    home_target: Point3 | None = None  # where `$H` must end, from `$23`, `$27` and `$130`–`$132`
    homed: bool = False  # only after `$H` in this controller boot ended at `home_target`
    homing_since: float | None = None
    locked: bool = False  # sent its "home or unlock" message and not homed since
    needs_reset: bool = False  # an alarm stopped the controller
    silent_since: float | None = None  # no bytes for 2 s (outside homing)
    restarts: int = 0
    last_error: str | None = None
    last_alarm: str | None = None
    program: MillProgramStatus | None = None
    gates: MillGates = field(default_factory=MillGates)
    overrides: MillOverrides = field(default_factory=MillOverrides)
    holding: bool = False  # a hold-to-jog is streaming short jogs

    def copy(self) -> "MillSnapshot":
        import copy
        return copy.deepcopy(self)

    @property
    def state(self) -> str:
        return self.status.state if self.status is not None else "—"

    @property
    def is_open(self) -> bool:
        return self.link is not MillLink.DISCONNECTED

    @property
    def is_moving(self) -> bool:
        return ((self.status.state if self.status else "") in ("Run", "Jog", "Home") or self.homing_since is not None
                or (self.program is not None and self.program.outcome is ProgramOutcome.RUNNING))

    @property
    def work_position(self) -> Point3 | None:
        if self.status is None or self.work_offset is None:
            return None
        return self.status.machine_position - self.work_offset

    def offset(self, wcs: int) -> Point3 | None:
        return next((o.point for o in self.offsets if o.name == f"G{wcs}"), None)

    @property
    def spindle(self) -> tuple[str, float] | None:
        """The spindle as the controller last reported it (`$G`): `M3`, `M4` or `M5`, and `S`."""
        if not self.parser_state:
            return None
        words = self.parser_state.split(" ")
        mode = next((w for w in words if w in ("M3", "M4", "M5")), None)
        if mode is None:
            return None
        s = next((w for w in words if w.startswith("S")), None)
        try:
            rpm = float(s[1:]) if s else 0.0
        except ValueError:
            rpm = 0.0
        return mode, rpm
