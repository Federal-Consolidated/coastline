"""Engraving that follows the real surface of uneven stock, with the sender's contour mapping
(M114 clears the map, `M111 Z… F…` probes down and adds the hit, M112 turns the Z compensation
on, M113 off). Port of Export/SurfaceProbe.swift."""

from __future__ import annotations

import math
import re

from ..geometry import swift_round
from ..post.grbl_post import fmt

MAX_POINTS = 9


def _d(a, b) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def points(cuts, count: int = MAX_POINTS) -> list[tuple[float, float]] | None:
    """Up to `count` of the cut positions, spread out (the extremes first, then whichever is
    furthest from those taken). None: fewer than three distinct ones."""
    pts: list[tuple[float, float]] = []
    for p in cuts:
        p = (float(p[0]), float(p[1]))
        if not any(_d(q, p) < 0.5 for q in pts):
            pts.append(p)
    if len(pts) < 3:
        return None
    first = [min(pts, key=lambda p: p[0] + p[1]), max(pts, key=lambda p: p[0] + p[1]),
             min(pts, key=lambda p: p[0] - p[1]), max(pts, key=lambda p: p[0] - p[1])]
    chosen: list[tuple[float, float]] = []
    for p in first:
        if not any(_d(q, p) < 0.5 for q in chosen):
            chosen.append(p)
    while len(chosen) < min(count, len(pts)):
        nxt = max(pts, key=lambda a: min(_d(c, a) for c in chosen))
        if not min(_d(c, nxt) for c in chosen) > 0.5:
            break
        chosen.append(nxt)
    return chosen if len(chosen) >= 3 else None


def flat_face(cuts, depth: float, tolerance: float = 0.05) -> tuple[float | None, float]:
    """The face under an engraving if it's flat: the deepest cut at each spot within `tolerance`
    everywhere; the face's height is that plus the depth. (None, spread): curved."""
    deepest: dict[tuple[int, int], float] = {}
    for c in cuts:
        key = (int(swift_round(c[0] / 0.1)), int(swift_round(c[1] / 0.1)))
        deepest[key] = min(deepest.get(key, math.inf), c[2])
    if not deepest:
        return None, 0.0
    lo, hi = min(deepest.values()), max(deepest.values())
    return ((lo + hi) / 2 + depth if hi - lo <= tolerance else None), hi - lo


def program(pts, face: float, safe_z: float = 3, approach: float = 1, above: float = 2, below: float = 1.5,
            machine=None) -> str:
    """Clear the map, then at each point come down to `above` the face and probe to `below` it."""
    from ..machine.profile import MachineProfile
    machine = machine or MachineProfile.standard()
    lines = [f"(Surface probing for the engraving: {len(pts)} points)", "G21", "G90", "G54", "M114",
             f"G0 Z{fmt(safe_z)}", f"M4 S{int(machine.probe_spindle_rpm)}", "G4 P2"]
    start = face + above
    for p in pts:
        lines.append(f"G0 X{fmt(p[0])} Y{fmt(p[1])}")
        if start >= approach:
            lines.append(f"G0 Z{fmt(start)}")
        else:
            lines.append(f"G0 Z{fmt(approach)}")
            lines.append(f"G1 Z{fmt(start)} F200")
        lines.append(f"M111 Z{fmt(face - below)} F{int(machine.probe_feed)}")
        lines.append(f"G0 Z{fmt(safe_z)}")
    lines += ["M5", "G53 G0 Z-1"]
    return "\n".join(lines) + "\n"


_COMMENT = re.compile(r"\([^)]*\)")
_AXIS_WORD = re.compile(r"[XYZ]-?\d")
_Z_WORD = re.compile(r"Z(-?\d+(\.\d+)?)")


def follow(gcode: str, face: float) -> tuple[str, list[int]]:
    """The engraving program made to follow the probed surface: every work Z relative to the
    nominal face, compensation on before the moves and off before a G53 retract and at the end.
    `moved[k]`: where original line k is now."""
    out: list[str] = []
    moved: list[int] = []
    on = False
    for line in gcode.split("\n"):
        code = _COMMENT.sub("", line).upper()
        is_move = "G53" not in code and _AXIS_WORD.search(code) is not None
        if is_move:
            if not on:
                out.append("M112 (follow the probed surface)")
                on = True
            m = _Z_WORD.search(line)
            if m:
                line = line[:m.start()] + "Z" + fmt(float(m.group(1)) - face) + line[m.end():]
        elif on and "G53" in code:
            out.append("M113")
            on = False
        moved.append(len(out))
        out.append(line)
    if on:
        out.append("M113")
    return "\n".join(out), moved
