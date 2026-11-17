"""Reads G-code written anywhere (an old .dd job, another CAM program, by hand) into moves, so it
shows, simulates and times like Coastline's own toolpaths. Port of Program/GCodeReader.swift.

Moves are in the work frame, mm. Machine-coordinate moves (G53) are counted but left out of the
preview. Probe moves (G38.x) are drawn to their target; the real move stops at the contact."""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from ..geometry import Vec3, swift_round
from ..inventory.checks import Issue, Severity
from ..post.toolpath import Motion, Move, Role


@dataclass
class Program:
    moves: list[Move] = field(default_factory=list)
    line_of_move: list[int] = field(default_factory=list)  # 1-based source line of each move
    issues: list[Issue] = field(default_factory=list)
    line_count: int = 0
    machine_moves: int = 0  # G53 moves, not in `moves`
    work_offsets: set[int] = field(default_factory=set)
    spindle_speeds: set[float] = field(default_factory=set)
    uses_inches: bool = False
    probes: int = 0
    offset_writes: int = 0  # G10 lines: the program sets work offsets itself
    macros: set[int] = field(default_factory=set)  # host M-codes M100…M114
    system_commands: list[str] = field(default_factory=list)  # `$H`, `$X`, `$J=`…
    relative_moves: int = 0  # moves in G91; an air cut is only safe without them
    dwell: float = 0.0  # seconds of G4
    probe_moves: set[int] = field(default_factory=set)
    unknown_start: set[int] = field(default_factory=set)  # first move, after G53 or a probe
    restarts: dict[int, Vec3] = field(default_factory=dict)  # a G10 L20 moved the position
    cut_min: Vec3 | None = None  # box of the feed moves
    cut_max: Vec3 | None = None

    def start(self, k: int):
        """Where move k starts (None for the first)."""
        r = self.restarts.get(k)
        if r is not None:
            return (r.x, r.y, r.z)
        return self.moves[k - 1].position if k > 0 else None

    @property
    def cut_length(self) -> float:
        length, previous = 0.0, None
        for m in self.moves:
            if previous is not None and m.role != Role.RAPID:
                length += math.dist(previous, m.position)
            previous = m.position
        return length


@dataclass
class Word:
    letter: str
    value: float
    text: str


def words(line: str) -> list[Word] | None:
    """Splits one line into words; comments `( … )` and `; …` are dropped; None if a word has no number."""
    result: list[Word] = []
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if c == "(":
            close = line.find(")", i)
            if close < 0:
                return result
            i = close + 1
            continue
        if c == ";":
            break
        if c in " \t\r%":
            i += 1
            continue
        if not c.isalpha():
            return None
        j = i + 1
        while j < n and line[j] == " ":
            j += 1
        start = end = j
        # GRBL drops every space before it parses, so `Z- 0.15` is `Z-0.15`.
        while j < n and (line[j].isdigit() or line[j] in ".-+ "):
            if line[j] != " ":
                end = j + 1
            j += 1
        number = line[start:end].replace(" ", "")
        try:
            value = float(number) if number else None
        except ValueError:
            value = None
        if value is None or number in ("+", "-", "."):
            return None
        result.append(Word(c.upper(), value, line[start:end]))
        i = j
    return result


def macro(line: str) -> int | None:
    """The M-code of a host macro line (M100…M114), which Coastline runs itself."""
    code = line.lstrip(" \t").upper()
    if not code.startswith("M1"):
        return None
    digits = ""
    for ch in code[1:]:
        if not ch.isdigit():
            break
        digits += ch
    if not digits:
        return None
    m = int(digits)
    return m if 100 <= m <= 114 else None


def arc_centre(a, b, radius: float, clockwise: bool):
    """The centre of an R-format arc in the XY plane (positive R: the short way)."""
    px, py, qx, qy = a[0], a[1], b[0], b[1]
    cx, cy = qx - px, qy - py
    d = math.hypot(cx, cy)
    if not (d > 0 and abs(radius) >= d / 2 - 1e-9):
        return None
    h = math.sqrt(max(0.0, radius * radius - d * d / 4))
    mx, my = (px + qx) / 2, (py + qy) / 2
    nx, ny = -cy / d, cx / d
    side = (-1 if clockwise else 1) * (-1 if radius < 0 else 1)
    return (mx + nx * h * side, my + ny * h * side)


def read(text: str) -> Program:
    p = Program()
    issued: set[str] = set()

    def issue(severity: Severity, line: int, message: str) -> None:
        key = message[:48]
        if key in issued:
            return
        issued.add(key)
        p.issues.append(Issue(severity, f"Line {line}: {message}"))

    inches = relative = spindle_on = False
    motion = 0.0
    feed = rpm = 0.0
    pos = [0.0, 0.0, 10.0]  # unknown until the program says: Z above the work
    known = [False, False, False]
    wcs = 54
    moved = False
    lines = text.split("\n")
    p.line_count = len(lines)
    axis_index = {"X": 0, "Y": 1, "Z": 2}
    for index, raw in enumerate(lines):
        n = index + 1
        trimmed = raw.lstrip(" \t")
        if trimmed.startswith("$"):
            cmd = ""
            for ch in trimmed:
                if ch.isspace() or ch == "(":
                    break
                cmd += ch
            p.system_commands.append(cmd)
            continue
        m_code = macro(raw)
        if m_code is not None:
            p.macros.add(m_code)
            continue
        ws = words(raw)
        if ws is None:
            issue(Severity.ERROR, n, f'can\'t read "{raw.strip(" ")}".')
            continue
        if not ws:
            continue
        machine = False
        axes: dict[str, float] = {}
        arc: dict[str, float] = {}
        dwell = None
        sets_offset = False
        for w in ws:
            L = w.letter
            if L == "G":
                g = swift_round(w.value * 10) / 10
                if g in (0, 1, 2, 3):
                    motion = g
                elif g in (38.2, 38.3, 38.4, 38.5):
                    motion = g
                    p.probes += 1
                elif g == 20:
                    inches = True
                    p.uses_inches = True
                elif g == 21:
                    inches = False
                elif g == 90:
                    relative = False
                elif g == 91:
                    relative = True
                elif g == 53:
                    machine = True
                elif g in (54, 55, 56, 57, 58, 59):
                    p.work_offsets.add(int(g))
                    wcs = int(g)
                elif g == 4:
                    dwell = 0.0
                elif g == 10:
                    sets_offset = True
                    p.offset_writes += 1
                elif g in (17, 40, 49, 80, 90.1, 91.1, 94, 61):
                    pass
                elif g in (18, 19):
                    issue(Severity.ERROR, n, f"arcs outside the XY plane (G{int(g)}) are not supported.")
                elif g == 93:
                    issue(Severity.ERROR, n, "inverse-time feed (G93) is not supported.")
                elif g in (28, 30):
                    issue(Severity.WARNING, n, f"G{int(g)} moves to a stored position Coastline can't show.")
                elif g == 92:
                    issue(Severity.WARNING, n, "G92 offsets are not shown.")
                elif g in (92.1, 43.1):
                    pass
                else:
                    issue(Severity.WARNING, n, f"G{w.text} is not a machine command.")
            elif L == "M":
                mv = int(w.value)
                if mv in (3, 4):
                    spindle_on = True
                elif mv in (5, 2, 30):
                    spindle_on = False
                elif mv in (7, 8, 9, 17, 18):
                    pass
                elif mv in (0, 1):
                    issue(Severity.WARNING, n, f"M{mv} pauses the program.")
                elif mv == 6:
                    issue(Severity.WARNING, n, "M6 tool change: the machine changes tools by hand.")
                elif 100 <= mv <= 114:
                    p.macros.add(mv)
                else:
                    issue(Severity.WARNING, n, f"M{mv} is not a machine command.")
            elif L in "XYZ":
                axes[L] = w.value
            elif L in "IJKR":
                arc[L] = w.value
            elif L == "F":
                feed = w.value * (25.4 if inches else 1)
            elif L == "S":
                rpm = w.value
            elif L == "P":
                if dwell is not None:
                    dwell = w.value  # G4 P: seconds (G10 P is an offset number)
            elif L in "LNTHDQ":
                pass
            else:
                issue(Severity.WARNING, n, f"word {L} is not used by the machine.")
        if spindle_on and rpm > 0:
            p.spindle_speeds.add(rpm)
        if dwell is not None and not sets_offset and not axes:
            p.dwell += dwell
            continue
        if sets_offset:
            l_word = next((w.value for w in ws if w.letter == "L"), None)
            offset = next((w.value for w in ws if w.letter == "P"), None)
            scale = 25.4 if inches else 1.0
            for letter, value in axes.items():
                k = axis_index[letter]
                if l_word == 20 and offset is not None and int(offset) + 53 == wcs:
                    pos[k] = value * scale
                    known[k] = True
                    moved = True
                elif l_word == 2 and offset is not None and int(offset) + 53 == wcs:
                    known[k] = False
            continue
        if not axes:
            continue
        if machine:
            p.machine_moves += 1
            for letter in axes:
                known[axis_index[letter]] = False
            continue
        if relative:
            p.relative_moves += 1
        scale = 25.4 if inches else 1.0
        target = list(pos)
        for letter, value in axes.items():
            k = axis_index[letter]
            target[k] = pos[k] + value * scale if relative else value * scale
        if motion in (2, 3):
            i = arc.get("I", 0.0) * scale
            j = arc.get("J", 0.0) * scale
            if "R" in arc:
                r = arc["R"]
                centre = arc_centre(pos, target, r * scale, motion == 2)
                if centre is None:
                    issue(Severity.ERROR, n, f"arc radius R{_d(r)} is too small for its end point.")
                    pos = target
                    continue
                i, j = centre[0] - pos[0], centre[1] - pos[1]
            move = Move(Role.CUT, Motion.ARC_CW if motion == 2 else Motion.ARC_CCW, target[0], target[1], target[2], i, j, feed)
        elif motion == 0:
            move = Move(Role.RAPID, Motion.LINE, target[0], target[1], target[2])
        else:
            plunge = target[0] == pos[0] and target[1] == pos[1] and target[2] < pos[2]
            move = Move(Role.PLUNGE if (plunge or motion >= 38) else Role.CUT, Motion.LINE, target[0], target[1], target[2], feed=feed)
            if motion >= 1 and feed <= 0:
                issue(Severity.ERROR, n, "a feed move with no feed rate (F).")
        if move.role != Role.RAPID:
            lo = target if p.cut_min is None else [min(a, b) for a, b in zip(p.cut_min, target)]
            hi = target if p.cut_max is None else [max(a, b) for a, b in zip(p.cut_max, target)]
            p.cut_min, p.cut_max = Vec3.of(lo), Vec3.of(hi)
        if not all(known):
            p.unknown_start.add(len(p.moves))
        if moved:
            p.restarts[len(p.moves)] = Vec3.of(pos)
            moved = False
        for letter in axes:
            k = axis_index[letter]
            known[k] = False if motion >= 38 else (known[k] if relative else True)
        if motion >= 38:
            p.probe_moves.add(len(p.moves))
        p.moves.append(move)
        p.line_of_move.append(n)
        pos = target
    return p


def _d(v: float) -> str:
    return f"{v:.1f}" if float(v).is_integer() and abs(v) < 1e16 else repr(float(v))
