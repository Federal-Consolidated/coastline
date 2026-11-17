"""A G-code line reduced to its minimal form and classified for GRBL streaming.
Port of GCodeLine.swift (`GCodeLine`, `GCodeFile` in the original)."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class LineKind(Enum):
    UNKNOWN = "unknown"
    AXIS_FEED_SPINDLE = "axisFeedSpindle"  # starts with an axis, feed, spindle or parameter word
    GCODE = "gcode"
    MCODE = "mcode"
    GRBL = "grbl"  # a `$` system command, a real-time character, or an empty line


class LineGroup(Enum):
    UNKNOWN = "unknown"
    NON_MODAL = "nonModal"
    MOTION = "motion"
    PLANE_SELECTION = "planeSelection"
    DISTANCE = "distance"
    FEED_RATE_MODE = "feedRateMode"
    UNITS = "units"
    TOOL_LENGTH_OFFSET = "toolLengthOffset"
    COORDINATE_SYSTEM = "coordinateSystem"
    STOPPING = "stopping"
    SPINDLE = "spindle"
    COOLANT = "coolant"
    USER_DEFINED = "userDefined"
    EMPTY = "empty"
    COMMAND = "command"
    HOME = "home"
    UNLOCK = "unlock"
    SPECIAL = "special"
    STATUS = "status"
    CHECK_MODE = "checkMode"
    WCS_INFO = "wcsInfo"
    JOG = "jog"
    LEVEL = "level"


@dataclass(frozen=True)
class GCodeLine:
    original: str
    cleaned: str  # without comments and whitespace: what is sent to GRBL
    kind: LineKind
    group: LineGroup
    value: int  # the G or M number, 0 otherwise
    is_blocking: bool  # needs GRBL's planner buffer empty before sending
    is_probe: bool
    is_injected: bool  # inserted by the sender, not from the user's file
    mcode_options: str | None  # text after the M number
    wcs: int | None
    units: int | None
    distance_mode: int | None

    @staticmethod
    def make(line: str, injected: bool = False) -> "GCodeLine":
        return _parse(line, injected)

    @staticmethod
    def injected(line: str) -> "GCodeLine":
        return _parse(line, True)

    @property
    def is_gcode(self) -> bool:
        return self.kind is LineKind.GCODE

    @property
    def is_mcode(self) -> bool:
        return self.kind is LineKind.MCODE

    @property
    def is_grbl(self) -> bool:
        return self.kind is LineKind.GRBL

    @property
    def is_home(self) -> bool:
        return self.group is LineGroup.HOME

    @property
    def is_unlock(self) -> bool:
        return self.group is LineGroup.UNLOCK

    @property
    def is_level(self) -> bool:
        return self.group is LineGroup.LEVEL


def _is_digit(c: str) -> bool:
    return c.isascii() and c.isdigit()


def _prefix_digits(s: str) -> str:
    out = ""
    for c in s:
        if not _is_digit(c):
            break
        out += c
    return out


def g_number(upper: str) -> str | None:
    """`^G0*(\\d+).*` → the number with leading zeros removed (but at least one digit)."""
    if not upper.startswith("G"):
        return None
    digits = _prefix_digits(upper[1:])
    if not digits:
        return None
    trimmed = digits.lstrip("0")
    return trimmed or "0"


def m_number(clean: str) -> tuple[str, str] | None:
    """`^M(\\d+)(.*)` → number as written (leading zeros kept: "M03" ≠ "3") and the remainder."""
    if not clean or clean[0] not in "Mm":
        return None
    digits = _prefix_digits(clean[1:])
    if not digits:
        return None
    return digits, clean[1 + len(digits):]


def is_grbl(line: str) -> bool:
    if line.startswith("$"):
        return True
    if len(line) == 1:
        return line in ("~", "?", "|")
    return False


def _parse(line: str, injected: bool) -> GCodeLine:
    s = line
    # A line starting with "(" gets a closing ")" appended.
    if s.startswith("("):
        s += ")"
    s = s.replace("%", " ")
    clean_chars = []
    in_comment = False
    for c in s:
        if c in (";", "\r", "\n"):
            break
        if c == "(":
            in_comment = True
        elif c == ")":
            in_comment = False
        elif not in_comment and c not in (" ", "\t"):
            clean_chars.append(c)
    clean = "".join(clean_chars)

    kind, group, value = LineKind.UNKNOWN, LineGroup.UNKNOWN, 0
    blocking = probe = False
    options = wcs = units = distance = None
    upper = clean.upper()
    number = g_number(upper)
    m = m_number(clean) if number is None else None
    if not clean:
        kind, group = LineKind.GRBL, LineGroup.EMPTY
    elif upper[0] in "FIJKLNPRSTXYZ":
        kind, group = LineKind.AXIS_FEED_SPINDLE, LineGroup.MOTION
    elif number is not None:
        kind = LineKind.GCODE
        value = int(number)
        if number in ("4", "10", "28", "30", "53", "92"):
            group, blocking = LineGroup.NON_MODAL, True
        elif number in ("0", "1", "2", "3", "38", "80"):
            probe = number == "38"
            group = LineGroup.MOTION
        elif number in ("17", "18", "19"):
            group = LineGroup.PLANE_SELECTION
        elif number in ("90", "91"):
            # G91.1 selects incremental arc centres; it does not make XYZ moves relative.
            word = ""
            for c in upper[1:]:
                if _is_digit(c) or c == ".":
                    word += c
                else:
                    break
            try:
                mode = float(word)
            except ValueError:
                mode = None
            if mode in (90.0, 91.0):
                group, distance = LineGroup.DISTANCE, int(mode)
        elif number in ("93", "94"):
            group = LineGroup.FEED_RATE_MODE
        elif number in ("20", "21"):
            group, units = LineGroup.UNITS, int(number)
        elif number in ("43", "49"):
            group = LineGroup.TOOL_LENGTH_OFFSET
        elif number in ("54", "55", "56", "57", "58", "59"):
            group, blocking, wcs = LineGroup.COORDINATE_SYSTEM, True, int(number)
    elif m is not None:
        mnum, rest = m
        kind, value, options = LineKind.MCODE, int(mnum), rest
        if mnum in ("0", "1", "2", "30"):
            group = LineGroup.STOPPING
        elif mnum in ("3", "4", "5"):
            group = LineGroup.SPINDLE
        elif mnum in ("7", "8", "9"):
            group = LineGroup.COOLANT
        elif mnum in ("100", "101", "102", "106", "111", "112", "113", "114"):
            group = LineGroup.USER_DEFINED
    elif is_grbl(clean):
        kind = LineKind.GRBL
        if clean[0] == "$":
            blocking = True
            if len(clean) == 1:
                group = LineGroup.COMMAND
            else:
                group = {"H": LineGroup.HOME, "X": LineGroup.UNLOCK, "?": LineGroup.STATUS, "#": LineGroup.WCS_INFO,
                         "C": LineGroup.CHECK_MODE, "J": LineGroup.JOG, "L": LineGroup.LEVEL}.get(clean[1], LineGroup.COMMAND)
        else:
            group = LineGroup.SPECIAL
    return GCodeLine(s, clean, kind, group, value, blocking, probe, injected, options, wcs, units, distance)


def chunk_gcode_line(line: str) -> list[str]:
    """Splits a cleaned line into words: a new chunk starts at each letter except `P` and `L`.
    `G10L2P1X0` → `["G10L2P1", "X0"]`."""
    result: list[str] = []
    current = ""
    for c in line:
        if current and c.isascii() and c.isalpha() and c not in ("P", "L"):
            result.append(current)
            current = ""
        current += c
    result.append(current)
    return result


def program_from_source(source: list[str]) -> list[GCodeLine]:
    """Builds a program from file lines, inserting the helper lines the original added: a status
    query `?` before probe moves (`G38.`) and a 0.1 s dwell before `M101`."""
    out: list[GCodeLine] = []
    # The original only checks lines 1…29 here (a match on line 0 is ignored).
    if any("G38." in s for s in source[1:30]):
        out.append(GCodeLine.injected("?"))
    for i, line in enumerate(source):
        if i > 0 and "G38." in line:
            out.append(GCodeLine.make("?"))
        if i > 0 and "M101" in line:
            out.append(GCodeLine.make("G4 P0.1"))
        out.append(GCodeLine.make(line))
    return out
