"""G-code for the machine, following the maker's own Fusion post and the controller's rules.
Port of Post/GRBLPost.swift:
- explicit absolute mm, XY arcs and feed-per-minute;
- every program starts and ends with `G53 G0 G90 Z-1.` (full retract in machine Z);
- spindle start ramp S0 → 5000 → target with dwells; no M6 (tool changes are guided steps);
- no canned cycles (grbl has none): drilling is already expanded into moves;
- lines ≤ 79 characters, 3 decimals, F only when it changes; no M30 at the end.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from ..geometry import swift_round
from .toolpath import Motion, Role

ADAPTER_ID = "coastline.grbl.desktop.v1"


@dataclass
class Header:
    program_name: str
    setup_name: str
    tool: object
    operation_names: list[str]
    stock_description: str


def fmt(v: float) -> str:
    """3 decimals, trailing zeros trimmed ("12.5", "-3", "0.125")."""
    s = "%.3f" % v
    while "." in s and (s.endswith("0") or s.endswith(".")):
        s = s[:-1]
    return "0" if s == "-0" else s


def fmt_f(v: float) -> str:
    return str(int(v))


def rounded(v: float) -> float:
    return swift_round(v * 1000) / 1000


def _clean_comment(s: str) -> str:
    """One closed, byte-bounded ASCII comment; GRBL handles realtime characters before
    parsing comments, so labels must not contain those either."""
    out = []
    for ch in s:
        v = ord(ch)
        if v == 40:
            out.append("[")
        elif v == 41:
            out.append("]")
        elif 32 <= v <= 126 and v not in (33, 63, 124, 126):
            out.append(ch)
        else:
            out.append(" ")
    return "".join(out)


def program(header: Header, rpm: float, paths: list, machine=None) -> str:
    """One program per tool: the operations that tool runs, in order."""
    return program_with_line_map(header, rpm, paths, machine)[0]


def program_with_line_map(h: Header, rpm: float, paths: list, machine=None) -> tuple[str, list[list[int | None]]]:
    """The program plus, for each path and move, the 1-based G-code line it produced (None when
    the move was a no-op), for the viewer's click-to-line inspection."""
    from ..machine.profile import MachineProfile
    machine = machine or MachineProfile.standard()
    line_map: list[list[int | None]] = []
    lines: list[str] = []

    def comment(s: str) -> None:
        if machine.max_line_length < 2:
            return
        lines.append("(" + _clean_comment(s)[: machine.max_line_length - 2] + ")")

    comment(f"Coastline: {h.program_name}")
    comment(f"Setup: {h.setup_name}")
    comment(f"Stock: {h.stock_description}")
    comment(f"Tool: {h.tool.name}")
    comment(f"D={fmt(h.tool.diameter)} stick-out={fmt(h.tool.stickout)} flutes={h.tool.flutes}")
    for name in h.operation_names:
        comment(f"Op: {name}")
    comment("WCS G54: X/Y centre of the stock face, Z0 on the face")
    lines.append("G90 G17 G21")
    # Do not inherit G93 inverse-time feeds; tool-length offsets stay as set at touch-off.
    lines.append("G94 G40 G91.1")
    lines.append("G54")
    lines.append("G53 G0 G90 Z-1.")
    s = int(swift_round(min(max(rpm, machine.spindle_rpm.lower), machine.spindle_rpm.upper)))
    lines.append("S0 M3")
    lines.append("G4 P1.")
    if s > machine.spindle_ramp_intermediate_rpm:
        lines.append(f"S{int(machine.spindle_ramp_intermediate_rpm)}")
        lines.append("G4 P2.")
    lines.append(f"S{s} M3")
    lines.append("G4 P1.")

    last_motion = ""
    last_f = -1.0
    pos = None
    for path in paths:
        mapping: list[int | None] = []
        for m in path.moves:
            mapping.append(None)
            words: list[str] = []
            # grbl checks that the arc's end is as far from the centre as its start (within
            # 0.005 mm) using the rounded numbers it receives: the centre moves onto the
            # perpendicular bisector of the rounded start and end, or the arc becomes a line.
            motion = m.motion
            centre = None
            if m.motion != Motion.LINE and pos is not None:
                ax, ay, bx, by = rounded(pos[0]), rounded(pos[1]), rounded(m.x), rounded(m.y)
                cx, cy = pos[0] + m.i, pos[1] + m.j
                chx, chy = bx - ax, by - ay
                ln = math.sqrt(chx * chx + chy * chy)
                if ln < 1e-6:
                    centre = (cx, cy)  # full circle: start = end
                else:
                    mx, my = (ax + bx) / 2, (ay + by) / 2
                    nx, ny = -chy / ln, chx / ln
                    d = (cx - mx) * nx + (cy - my) * ny
                    fx, fy = mx + nx * d, my + ny * d
                    if math.sqrt((fx - cx) ** 2 + (fy - cy) ** 2) <= 0.05:
                        centre = (fx, fy)
                    else:
                        motion = Motion.LINE
            if m.role == Role.RAPID:
                code = "G0"
            elif motion == Motion.LINE:
                code = "G1"
            elif motion == Motion.ARC_CW:
                code = "G2"
            else:
                code = "G3"
            if code != last_motion or code in ("G2", "G3"):
                words.append(code)
            if pos is None or abs(pos[0] - m.x) > 5e-4 or motion != Motion.LINE:
                words.append("X" + fmt(m.x))
            if pos is None or abs(pos[1] - m.y) > 5e-4 or motion != Motion.LINE:
                words.append("Y" + fmt(m.y))
            if pos is None or abs(pos[2] - m.z) > 5e-4:
                words.append("Z" + fmt(m.z))
            if motion != Motion.LINE and pos is not None and centre is not None:
                words.append("I" + fmt(centre[0] - rounded(pos[0])))  # from the rounded start grbl measures from
                words.append("J" + fmt(centre[1] - rounded(pos[1])))
            elif motion != Motion.LINE:
                words.append("I" + fmt(m.i))
                words.append("J" + fmt(m.j))
            if code != "G0":
                f = max(swift_round(m.feed), 1.0)
                if f != last_f:
                    words.append("F" + fmt_f(f))
                    last_f = f
            pos = (m.x, m.y, m.z)
            # Skip moves that go nowhere; the modal motion only changes when a line is written.
            if not any(w[0] in "XYZ" for w in words):
                continue
            if words and words[0].startswith("G"):
                last_motion = words[0]
            lines.append(" ".join(words))
            mapping[-1] = len(lines)
        line_map.append(mapping)
    lines.append("G53 G0 G90 Z-1.")
    lines.append("S0 M3")
    lines.append("G4 P2.")
    lines.append("M5")
    return "\n".join(lines) + "\n", line_map
