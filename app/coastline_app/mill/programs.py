"""Program checks and helpers for the Control page and the guided runner. Port of
Session/GoTo.swift, Session/JobPrograms.swift, Session/TestPrograms.swift and
Session/TestProgramLibrary.swift."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass, field, replace
from enum import Enum

from .geometry import AXES, Axis, Point3
from .session_types import MillEnvelope, MillOffset, MillRefusal
from .status import MillSettings


def blocked(why: str) -> MillRefusal:
    return MillRefusal("blocked", why)


_COMMENTS = re.compile(r"\(.*?\)|;.*")
_WORD = re.compile(r"([A-Z])([+-]?(?:\d+\.?\d*|\.\d+))")


def _g(value: float) -> str:
    return "%g" % value


def _words(line: str) -> tuple[list[tuple[str, float]], str]:
    matches = list(_WORD.finditer(line))
    words = []
    for m in matches:
        try:
            words.append((m.group(1), float(m.group(2))))
        except ValueError:
            words.append((m.group(1), float("nan")))
    return words, "".join(m.group(0) for m in matches)


def _round(v: float, scale: float) -> float:
    # Swift `.rounded()`: half away from zero
    x = v * scale
    return (int(abs(x) + 0.5) * (1 if x >= 0 else -1)) / scale


# ---------------------------------------------------------------- go to

class GoToFrame(Enum):
    WORK = "work"  # the active work offset (G54…G59)
    MACHINE = "machine"


def go_to_lines(x: float | None, y: float | None, z: float | None, frame: GoToFrame, work_offset: Point3 | None,
                envelope: MillEnvelope, retract_first: bool) -> list[str]:
    """The lines that go to x, y, z (None: that axis stays), every target in machine coordinates
    (G53). With `retract_first`, Z goes fully up, then X and Y move, then Z goes to its target.
    Raises MillRefusal."""
    import math
    if x is None and y is None and z is None:
        raise blocked("Enter at least one coordinate.")
    offset = Point3()
    if frame is GoToFrame.WORK:
        if work_offset is None:
            raise blocked("The work offset is not known yet. Wait for a status report.")
        offset = work_offset
    target: dict[Axis, float] = {}
    for axis, value in ((Axis.X, x), (Axis.Y, y), (Axis.Z, z)):
        if value is None:
            continue
        if not math.isfinite(value):
            raise blocked(f"{axis.value} is not a number.")
        machine = value + offset[axis]
        rng = envelope[axis]
        if _round(machine, 1000) not in rng:
            raise blocked("%s would go to %.3f (machine), outside the travel %.1f … %.1f." % (axis.value, machine, rng.lower, rng.upper))
        target[axis] = machine
    f = lambda v: "%.3f" % v  # noqa: E731
    lines = ["G21", "G90"]
    if retract_first:
        top = envelope.z.upper
        lines.append("G53G0Z" + f(top))
        xy = "".join(a.value + f(target[a]) for a in (Axis.X, Axis.Y) if a in target)
        if xy:
            lines.append("G53G0" + xy)
        if Axis.Z in target and abs(target[Axis.Z] - top) >= 0.0005:
            lines.append("G53G0Z" + f(target[Axis.Z]))
    else:
        lines.append("G53G0" + "".join(a.value + f(target[a]) for a in AXES if a in target))
    return lines


# ---------------------------------------------------------------- M100 / M101

@dataclass(frozen=True)
class M100Call:
    a: tuple[int, Axis]
    b: tuple[int, Axis]
    destination: tuple[int, Axis]


class M100:
    """The original software's `M100`: `M100 G56X G57X G55X` → G55 X = (G56 X + G57 X) / 2.
    Coastline runs it, not the controller."""

    @staticmethod
    def parse(line: str) -> M100Call | None:
        body = line[4:]
        refs = [(50 + int(m.group(1)), Axis(m.group(2))) for m in re.finditer(r"G5([4-9])([XYZ])", body)]
        if len(refs) != 3 or re.sub(r"G5[4-9][XYZ]", "", body):
            return None
        return M100Call(refs[0], refs[1], refs[2])

    @staticmethod
    def value(offsets: list[MillOffset], ref: tuple[int, Axis]) -> float | None:
        p = next((o.point for o in offsets if o.name == f"G{ref[0]}"), None)
        return None if p is None else p[ref[1]]


@dataclass(frozen=True)
class M101Call:
    offsets: tuple[int, ...]
    axis: Axis
    tolerance: float


class M101:
    """The original software's `M101`: `M101 G57 G58 G59 X 0.152` stops the program when the X
    values of G57, G58 and G59 spread by 0.152 mm or more."""

    @staticmethod
    def parse(line: str) -> M101Call | None:
        m = re.fullmatch(r"M101G5([4-9])G5([4-9])G5([4-9])([XYZ])(\d*\.?\d+)", line)
        if m is None:
            return None
        tolerance = float(m.group(5))
        if not tolerance > 0:
            return None
        return M101Call(tuple(50 + int(m.group(i)) for i in (1, 2, 3)), Axis(m.group(4)), tolerance)

    @staticmethod
    def problem(call: M101Call, offsets: list[MillOffset]) -> str | None:
        values = []
        for wcs in call.offsets:
            p = next((o.point for o in offsets if o.name == f"G{wcs}"), None)
            if p is not None:
                values.append(p[call.axis])
        if len(values) != 3:
            return "the controller did not report " + ", ".join(f"G{w}" for w in call.offsets) + "."
        lo, hi = min(values), max(values)
        if not hi - lo < call.tolerance:
            return ("the part is out of tolerance: %s %s spread %.3f mm (%s), the limit is %.3f mm."
                    % ("/".join(f"G{w}" for w in call.offsets), call.axis.value, hi - lo,
                       ", ".join("%.3f" % v for v in values), call.tolerance))
        return None


# ---------------------------------------------------------------- M102 / M106

@dataclass(frozen=True)
class M102Call:
    destination: tuple[int, Axis]
    expression: str  # without spaces


class M102:
    """`M102`: arithmetic over the work offsets, written into one of them.
    `M102 G55X ((G56X + G57X)/2)` sets G55 X to the midpoint of G56 X and G57 X. The forms
    `M102 G55 X = …` and `M102 WCS G55 X …` are accepted too. Coastline runs it, not the controller:
    G4 P0, `$#`, G10 L2, `$#` (check)."""

    _RE = re.compile(r"M102\s*(?:WCS\s*)?G5([4-9])\s*([XYZ])\s*=?\s*(.+)", re.IGNORECASE)

    @staticmethod
    def parse(line: str) -> M102Call | None:
        from .contour import WCSExpression, WCSExpressionError
        m = M102._RE.fullmatch(line.strip())
        if m is None:
            return None
        expression = "".join(m.group(3).split())
        try:
            WCSExpression.evaluate(expression, lambda _name: 1.0)  # the syntax only
        except WCSExpressionError:
            return None
        return M102Call((50 + int(m.group(1)), Axis(m.group(2).upper())), expression)

    @staticmethod
    def references(call: M102Call) -> list[tuple[int, Axis]]:
        return [(50 + int(m.group(1)), Axis(m.group(2))) for m in re.finditer(r"G5([4-9])([XYZ])", call.expression.upper())]

    @staticmethod
    def value(call: M102Call, offsets: list[MillOffset]) -> tuple[float | None, str]:
        """The value from a `$#` reply, else (None, why)."""
        import math
        from .contour import WCSExpression, WCSExpressionError
        names = {o.name for o in offsets}
        missing = [r for r in M102.references(call) if f"G{r[0]}" not in names]
        if missing:
            return None, f"the controller did not report G{missing[0][0]}."

        def register(name: str) -> float | None:
            upper = name.upper()
            p = next((o.point for o in offsets if o.name == upper[:3]), None)
            return None if p is None else p[Axis(upper[3])]

        try:
            value = WCSExpression.evaluate(call.expression, register)
        except (WCSExpressionError, ValueError, OverflowError):
            return None, f"the expression {call.expression} could not be worked out."
        if not math.isfinite(value):
            return None, f"{call.expression} is not a number (a division by zero?)."
        return value, ""


@dataclass(frozen=True)
class M106Call:
    text: str  # the comparison and its message, as written (without `M106`)


class M106:
    """`M106`: a check on the work offsets that stops the program when it fails.
    `M106 G58X > 3.2 error: bore 1 too small - not found`. Coastline runs it: G4 P0, `$#`, compare."""

    @staticmethod
    def parse(line: str) -> M106Call | None:
        from .contour import M106Check
        from .errors import MillError
        text = line.strip()
        if not text.upper().startswith("M106"):
            return None
        rest = text[4:].strip()
        try:
            M106Check.parse(rest)
        except MillError:
            return None
        return M106Call(rest)

    @staticmethod
    def statement(call: M106Call) -> str:
        at = call.text.lower().rfind("error")
        return (call.text[:at] if at >= 0 else call.text).strip()

    @staticmethod
    def problem(call: M106Call, offsets: list[MillOffset]) -> str | None:
        """None when the check passes, else what the operator is told."""
        from .contour import M106Check
        from .errors import MillError
        try:
            check = M106Check.parse(call.text)
        except MillError:
            return f"the check {call.text} could not be read."
        names = {o.name for o in offsets}
        for register in (check.left.register, check.right.register):
            if register and register not in names:
                return f"the controller did not report {register}."
        try:
            passed = check.evaluate([(o.name, o.point) for o in offsets])
        except MillError:
            return f"the check {call.text} could not be worked out."
        if passed:
            return None
        message = check.error_message.strip()
        return message or f"the check {M106.statement(call)} failed."


# ---------------------------------------------------------------- job program check

@dataclass(frozen=True)
class JobProgram:
    lines: list[str]  # as sent (comments and spaces removed)
    starts_with_home: bool  # `$H` first: may start from Alarm, before the machine is homed


JOB_CODES = {"G0", "G1", "G2", "G3", "G4", "G10", "G17", "G21", "G40", "G38.2", "G38.3", "G53",
             "G54", "G55", "G56", "G57", "G58", "G59", "G90", "G91", "G91.1", "G92.1", "G94",
             "M2", "M3", "M4", "M5", "M9", "M30"}


def check_job_program(lines: list[str], settings: MillSettings, envelope: MillEnvelope) -> JobProgram:
    """Checks a guided job's program before it runs: the words a job may use, the spindle limit,
    and machine-coordinate moves against the envelope. Raises MillRefusal."""
    import math
    max_rpm = settings.values.get(30, 8000)
    cleaned: list[str] = []
    for index, raw in enumerate(lines):
        n = index + 1
        # M102 and M106 keep their text: their expressions use parentheses (not comments here) and
        # M106's message is shown as written. Coastline runs them, not the controller.
        host = re.sub(r"^\s*[Nn]\d+\s*", "", re.sub(r";.*", "", raw)).strip()
        if host.upper().startswith("M102"):
            if M102.parse(host) is None:
                raise blocked(f"Line {n}: M102 needs a work offset and an expression, e.g. M102 G55X ((G56X + G57X)/2).")
            cleaned.append(host)
            continue
        if host.upper().startswith("M106"):
            if M106.parse(host) is None:
                raise blocked(f"Line {n}: M106 needs a work offset, a comparison and a number or offset, "
                              "e.g. M106 G58X > 3.2 error: bore too small.")
            cleaned.append(host)
            continue
        line = _COMMENTS.sub("", raw).replace(" ", "").replace("\t", "").strip(" ").upper()
        # Files from other CAM: `%` tape markers, program numbers and line numbers carry no motion.
        if not line or set(line) == {"%"} or re.fullmatch(r"O\d+", line):
            continue
        numbered = re.match(r"^N\d+", line)
        if numbered:
            line = line[numbered.end():]
            if not line:
                continue
        if line == "$H":
            cleaned.append(line)
            continue
        if line == "$#":  # GRBL answers `$#` only when idle: G4 P0 waits for the moves first
            cleaned += ["G4P0", line]
            continue
        if line.startswith("$"):
            raise blocked(f"Line {n}: {raw} is not allowed in a job program.")
        if line.startswith("M101"):
            if M101.parse(line) is None:
                raise blocked(f"Line {n}: M101 needs three offsets, an axis and a tolerance, e.g. M101 G57 G58 G59 X 0.152.")
            cleaned.append(line)
            continue
        if line.startswith("M100"):
            if M100.parse(line) is None:
                raise blocked(f"Line {n}: M100 needs three offsets, e.g. M100 G56X G57X G55X.")
            cleaned.append(line)
            continue
        words, rebuilt = _words(line)
        if not words or rebuilt != line or not all(l in "GMXYZIJKRFSPL" and math.isfinite(v) for l, v in words):
            raise blocked(f"Line {n} is not allowed in a job program: {raw}")
        for letter, value in words:
            if letter in "GM":
                code = f"{letter}{_g(value)}"
                if code == "G20":
                    raise blocked(f"Line {n}: the program is in inches (G20). Convert it to mm first.")
                if code not in JOB_CODES:
                    raise blocked(f"Line {n}: {code} is not allowed in a job program.")
        s = next((v for l, v in words if l == "S"), None)
        if s is not None and s > max_rpm:
            raise blocked("Line %d: S%.0f is above the spindle's %.0f RPM." % (n, s, max_rpm))
        if ("G", 10.0) in words:
            l_word = next((v for l, v in words if l == "L"), None)
            p = next((v for l, v in words if l == "P"), None)
            if l_word not in (2.0, 20.0) or p is None or not 1.0 <= p <= 6.0 or round(p) != p:
                raise blocked(f"Line {n}: only G10 L2/L20 P1–P6 (work offsets) are allowed.")
        if ("G", 53.0) in words:  # machine coordinates: inside the envelope
            for letter, value in words:
                if letter in "XYZ" and _round(value, 1000) not in envelope[Axis(letter)]:
                    raise blocked("Line %d: G53 %s%.3f is outside the travel." % (n, letter, value))
        cleaned.append(line)
    return JobProgram(cleaned, bool(cleaned) and cleaned[0] == "$H")


# ---------------------------------------------------------------- test programs

TEST_CODES = {"G0", "G1", "G4", "G21", "G53", "G90", "G91", "M5"}


def check_test_program(lines: list[str], start: Point3, envelope: MillEnvelope) -> list[str]:
    """Only simple words, and every position inside the envelope, worked out from where the
    machine is now. Returns the cleaned lines; raises MillRefusal."""
    import math
    position = start
    relative = False
    cleaned: list[str] = []
    for index, raw in enumerate(lines):
        number = index + 1
        line = _COMMENTS.sub("", raw).replace(" ", "").strip(" ").upper()
        if not line:
            continue
        words, rebuilt = _words(line)
        if rebuilt != line or not all(l in "GMXYZFP" and math.isfinite(v) for l, v in words):
            raise blocked(f"Line {number} is not allowed in a test program: {raw}")
        codes = {f"{l}{_g(v)}" for l, v in words if l in "GM"}
        bad = sorted(codes - TEST_CODES)
        if bad:
            raise blocked(f"Line {number}: {bad[0]} is not allowed in a test program.")
        relative = (relative or "G91" in codes) and "G90" not in codes
        axes = [(l, v) for l, v in words if l in "XYZ"]
        if axes and relative == ("G53" in codes):
            raise blocked(f"Line {number}: absolute moves must use G53, relative moves must not.")
        for letter, value in axes:
            axis = Axis(letter)
            position = position.replacing(axis, position[axis] + value if relative else value)
            rng = envelope[axis]
            if _round(position[axis], 10_000) not in rng:
                raise blocked("Line %d: %s would go to %.3f, outside %.1f … %.1f." % (number, letter, position[axis], rng.lower, rng.upper))
        cleaned.append(line)
    return cleaned


class TestProgram(Enum):
    """Small built-in programs for checking a real machine from the Control page."""

    __test__ = False  # not a pytest class

    KOROBEINIKI = "korobeiniki"

    @property
    def title(self) -> str:
        return "Tetris Song (Korobeiniki)"

    @property
    def detail(self) -> str:
        return ("Plays the Tetris theme on the Y stepper. Y goes to −30, moves about ±1.3 mm for 28 s, then goes back "
                "to −0.5. The spindle stays off; X and Z do not move.")

    @property
    def lines(self) -> list[str]:
        return _song()


def _song() -> list[str]:
    """A stepper sings at its step rate, f = F / 60 × steps per mm, so each note is a G1 move at
    F = f × 60 / 400 (`$101`). Same as scripts/make-song.py."""
    steps_per_mm, beat = 400.0, 60.0 / 120
    notes = {"A4": 440.00, "B4": 493.88, "C5": 523.25, "D5": 587.33, "E5": 659.26, "F5": 698.46, "G5": 783.99, "A5": 880.00}
    part_a = [("E5", 1), ("B4", 0.5), ("C5", 0.5), ("D5", 1), ("C5", 0.5), ("B4", 0.5),
              ("A4", 1), ("A4", 0.5), ("C5", 0.5), ("E5", 1), ("D5", 0.5), ("C5", 0.5),
              ("B4", 1.5), ("C5", 0.5), ("D5", 1), ("E5", 1), ("C5", 1), ("A4", 1), ("A4", 1), (None, 1)]
    part_b = [(None, 0.5), ("D5", 1), ("F5", 0.5), ("A5", 1), ("G5", 0.5), ("F5", 0.5),
              ("E5", 1.5), ("C5", 0.5), ("E5", 1), ("D5", 0.5), ("C5", 0.5),
              ("B4", 1), ("B4", 0.5), ("C5", 0.5), ("D5", 1), ("E5", 1), ("C5", 1), ("A4", 1), ("A4", 1), (None, 1)]
    lines = ["G21", "G90", "M5", "G53 G1 Y-30.000 F1000", "G4 P0.5", "G91"]
    direction = -1.0
    for note, beats in part_a + part_b + part_a:
        seconds = beats * beat
        if note is None:
            lines.append("G4 P%.3f" % seconds)
            continue
        feed = notes[note] * 60 / steps_per_mm
        lines.append("G1 Y%.3f F%.2f" % (direction * feed / 60 * seconds, feed))
        direction = -direction
    return lines + ["G90", "G53 G1 Y-0.500 F1000"]


class SavedProgramKind(Enum):
    MOTION_CHECK = "motionCheck"
    SETUP = "setup"

    @property
    def title(self) -> str:
        return "Motion Check" if self is SavedProgramKind.MOTION_CHECK else "Setup Program"


def _clean(line: str) -> str:
    return _COMMENTS.sub("", line).replace(" ", "").replace("\t", "").upper()


@dataclass
class SavedTestProgram:
    """A reusable program. Motion checks use `check_test_program`; setup programs use the guided
    runner's `check_job_program`."""

    title: str
    detail: str = ""
    code: str = "G21\nG90\nM5\n"
    is_favorite: bool = False
    kind: SavedProgramKind = SavedProgramKind.MOTION_CHECK
    id: str = field(default_factory=lambda: str(uuid.uuid4()).upper())

    @staticmethod
    def built_in(program: TestProgram) -> "SavedTestProgram":
        return SavedTestProgram(program.title, program.detail, "\n".join(program.lines))

    @property
    def homes_first(self) -> bool:
        if self.kind is not SavedProgramKind.SETUP:
            return False
        first = next((c for c in map(_clean, self.code.splitlines()) if c), None)
        return first == "$H"

    @property
    def lines(self) -> list[str]:
        """Establish millimeters, absolute distance mode, and spindle off; `$H` stays first."""
        startup = ["G21", "G90", "M5"]
        source = self.code.split("\n")
        if self.kind is SavedProgramKind.SETUP:
            first = next((i for i, s in enumerate(source) if _clean(s)), None)
            if first is not None and _clean(source[first]) == "$H":
                return source[:first + 1] + startup + source[first + 1:]
        return startup + source

    @property
    def validation_message(self) -> str | None:
        if not self.title.strip():
            return "Give the program a name."
        executable = [_COMMENTS.sub("", s).strip() for s in self.code.splitlines()]
        if all(not e for e in executable):
            return "Add G-code to the program."
        return None

    def to_json(self) -> dict:
        return {"id": self.id, "title": self.title, "detail": self.detail, "code": self.code,
                "isFavorite": self.is_favorite, "kind": self.kind.value}

    @staticmethod
    def from_json(d: dict) -> "SavedTestProgram":
        return SavedTestProgram(d["title"], d["detail"], d["code"], bool(d["isFavorite"]),
                                SavedProgramKind(d.get("kind", "motionCheck")), d["id"])


@dataclass
class TestProgramLibrary:
    """Stored as a whole so an intentionally empty library stays empty across launches."""

    __test__ = False  # not a pytest class

    programs: list[SavedTestProgram] = field(default_factory=lambda: [SavedTestProgram.built_in(p) for p in TestProgram])

    @property
    def ordered(self) -> list[SavedTestProgram]:
        return [p for p in self.programs if p.is_favorite] + [p for p in self.programs if not p.is_favorite]

    def save(self, program: SavedTestProgram) -> None:
        for i, p in enumerate(self.programs):
            if p.id == program.id:
                self.programs[i] = program
                return
        self.programs.append(program)

    def remove(self, id: str) -> None:
        self.programs = [p for p in self.programs if p.id != id]

    def toggle_favorite(self, id: str) -> None:
        for i, p in enumerate(self.programs):
            if p.id == id:
                self.programs[i] = replace(p, is_favorite=not p.is_favorite)
                return

    def to_json(self) -> dict:
        return {"programs": [p.to_json() for p in self.programs]}

    @staticmethod
    def from_json(d: dict) -> "TestProgramLibrary":
        return TestProgramLibrary([SavedTestProgram.from_json(p) for p in d.get("programs", [])])
