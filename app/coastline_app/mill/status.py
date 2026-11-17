"""Parsed `?` status reports, settings and overrides (Swift: RealTimeStatus.swift)."""

from __future__ import annotations

from dataclasses import dataclass, field, replace

from .geometry import Axis, LengthUnit, Point3, Range
from .support import leading_integer, parse_double


@dataclass
class MillOverrides:
    """Feed, rapid and spindle overrides, in percent. `reported`: the controller sent them
    (`Ov:`); otherwise they are what Coastline sent since the last restart."""

    feed: int = 100
    rapid: int = 100
    spindle: int = 100
    reported: bool = False


class StatusParseError(Exception):
    pass


@dataclass
class RealTimeStatus:
    """A parsed `?` status report (GRBL 1.1 compact format, e.g.
    `<Idle|M:-86.000,-0.500,-0.500|B:15,127|L:0|0000|W:0.000,0.000,0.000>`)."""

    raw: str
    state: str  # Idle, Run, Hold, Jog, Home, Alarm, Check, Sleep
    sub_state: int
    machine_position: Point3
    work_offset: Point3 | None
    wcs: int
    free_planner_blocks: int
    free_rx_bytes: int
    line_number: int
    probe_tripped: bool = False
    limit_x: bool = False
    limit_y: bool = False
    limit_z: bool = False
    feed_rate: int | None = None
    spindle_speed: int | None = None
    overrides: MillOverrides | None = None
    parser_units: int = 21
    distance_mode: int = 90

    @property
    def work_position(self) -> Point3 | None:
        return None if self.work_offset is None else self.machine_position - self.work_offset

    @property
    def any_limit_tripped(self) -> bool:
        return self.probe_tripped or self.limit_x or self.limit_y or self.limit_z

    def copy(self, **changes) -> "RealTimeStatus":
        return replace(self, **changes)

    @staticmethod
    def parse(text: str, wcs: int, report_unit: LengthUnit, parser_units: int, distance_mode: int) -> "RealTimeStatus":
        """`RealTimeStatus::Parse` (GRBL 1.1 format)."""
        if len(text) < 2 or text[0] != "<" or text[-1] != ">":
            raise StatusParseError()
        fields = text[1:-1].split("|")
        if len(fields) < 4:
            raise StatusParseError()
        state_name, sub_text = split_once(fields[0], ":")
        sub_state = -1 if not sub_text else _int(sub_text)
        is_machine, coordinates = parse_position(fields[1], report_unit)
        planner, rx = parse_buffer(fields[2])
        line_number = 0
        if fields[3].startswith("L"):
            t = split_once(fields[3], ":")[1]
            line_number = 0 if not t else _int(t)
            if len(fields) <= 4:
                raise StatusParseError()
            limits = fields[4]
        else:
            limits = fields[3]
        if len(limits) != 4:
            raise StatusParseError()
        status = RealTimeStatus(
            raw=text, state=state_name, sub_state=sub_state, machine_position=coordinates, work_offset=None, wcs=54,
            free_planner_blocks=planner, free_rx_bytes=rx, line_number=line_number,
            probe_tripped=limits[0] == "P", limit_x=limits[1] == "X", limit_y=limits[2] == "Y", limit_z=limits[3] == "Z",
            parser_units=parser_units, distance_mode=distance_mode)
        # The original starts at index 5 regardless of whether a line-number field was present.
        for f in fields[5:]:
            key, value = split_once(f, ":")
            if key == "W":
                status.wcs = wcs
                status.work_offset = parse_coordinates(value, report_unit)
            elif key == "FS":
                feed, speed = split_once(value, ",")
                status.feed_rate, status.spindle_speed = _int(feed), _int(speed)
            elif key == "F":
                status.feed_rate, status.spindle_speed = _int(value), 0
            elif key == "Ov":
                values = [_int(v) for v in value.split(",") if v != ""]
                if len(values) != 3:
                    raise StatusParseError()
                status.overrides = MillOverrides(values[0], values[1], values[2], True)
        if not is_machine and status.work_offset is not None:
            # Position was reported as work position; convert when the offset is known.
            status.machine_position = coordinates + status.work_offset
        return status

    @staticmethod
    def parse_v0(text: str, wcs: int, report_unit: LengthUnit, parser_units: int, distance_mode: int) -> "RealTimeStatus":
        """`RealTimeStatus::ParseV0` (GRBL 1.0: `<Idle,MPos:0,0,0,WPos:0,0,0>`)."""
        if len(text) < 2 or text[0] != "<" or text[-1] != ">":
            raise StatusParseError()
        status_part, coords = split_once(text[1:-1], ",")
        state_name, sub_text = split_once(status_part, ":")
        sub_state = -1 if not sub_text else _int(sub_text)
        parts = coords.split(",")
        if len(parts) < 6:
            raise StatusParseError()
        _, machine = parse_position(",".join(parts[0:3]), report_unit)
        work = parse_coordinates(split_once(",".join(parts[3:6]), ":")[1], report_unit)
        return RealTimeStatus(raw=text, state=state_name, sub_state=sub_state, machine_position=machine,
                              work_offset=machine - work, wcs=wcs, free_planner_blocks=0, free_rx_bytes=0,
                              line_number=0, parser_units=parser_units, distance_mode=distance_mode)


def split_once(s: str, sep: str) -> tuple[str, str]:
    i = s.find(sep)
    return (s, "") if i < 0 else (s[:i], s[i + 1:])


def _int(s: str) -> int:
    v = leading_integer(s)
    if v is None:
        raise StatusParseError()
    return v


def parse_position(s: str, unit: LengthUnit) -> tuple[bool, Point3]:
    kind, value = split_once(s, ":")
    if not kind or kind[0] not in "MW":
        raise StatusParseError()
    return kind[0] == "M", parse_coordinates(value, unit)


def parse_coordinates(s: str, unit: LengthUnit) -> Point3:
    parts = s.split(",")
    if len(parts) < 3:
        raise StatusParseError()
    values = [parse_double(p) for p in parts[:3]]
    if any(v is None for v in values):
        raise StatusParseError()
    scale = 25.4 if unit is LengthUnit.INCHES else 1.0
    return Point3(values[0] * scale, values[1] * scale, values[2] * scale)


def parse_buffer(s: str) -> tuple[int, int]:
    parts = s.split(":")
    if len(parts) != 2 or parts[0] != "B":
        raise StatusParseError()
    values = parts[1].split(",")
    if len(values) != 2:
        raise StatusParseError()
    return _int(values[0]), _int(values[1])


@dataclass(frozen=True)
class SoftLimits:
    enabled: bool
    travel_x: float
    travel_y: float
    travel_z: float

    def range(self, axis: Axis) -> Range:
        if axis is Axis.X:
            return Range(-(self.travel_x - 0.5), -0.5)
        if axis is Axis.Y:
            return Range(-self.travel_y, -0.5)
        return Range(-self.travel_z, -0.5)


@dataclass
class MillSettings:
    """GRBL `$n=value` settings."""

    values: dict[int, float] = field(default_factory=dict)

    @property
    def is_empty(self) -> bool:
        return not self.values

    def update(self, setting: int, value: float) -> None:
        self.values[setting] = value

    def copy(self) -> "MillSettings":
        return MillSettings(dict(self.values))

    @property
    def report_unit(self) -> LengthUnit:
        v = self.values.get(13)
        return LengthUnit.INCHES if v is not None and int(v) == 1 else LengthUnit.MILLIMETERS

    @property
    def soft_limits(self) -> SoftLimits | None:
        x, y, z = (self.values.get(k) for k in (130, 131, 132))
        if x is None or y is None or z is None:
            return None
        return SoftLimits(int(self.values.get(20, 0)) == 1, x, y, z)
