"""Two-sided registration from machined reference features. Port of Plan/ReferenceBores.swift.

Side A bores two holes in the frame (from the same zero as the part); after the flip, side B opens
them from the back ("windows"), probes each bore's centre and sets X0 Y0 from the two centres,
checking each bore's diameter, their spacing and that the line between them isn't turned. The pair
sits off the stock's centre line, so a stock turned the wrong way mirrors it away."""

from __future__ import annotations

from dataclasses import dataclass

from ..codable import Range
from ..post.grbl_post import fmt as n

DIAMETER = 10.0  # fits a 1/4" tool with 1.8 mm to spare each side, or the edge finder's tip
WINDOW_DIAMETER = 13.0  # the window opened from side B: wider, so the bore keeps its walls
SKIN = 1.0  # material side A leaves under each bore
OVERLAP = 1.0  # the window reaches this far into the bore
PROBE_BELOW_WINDOW = 1.5
OFF_CENTRE = 7.0  # the pair's offset from the stock's centre line
WALL = 2.5  # wall left between a bore and anything else


@dataclass
class Plan:
    centres_a: list[tuple[float, float]]  # side A work frame (X up, Y along the stock)
    depth_a: float  # how deep side A bores, mm
    thickness: float  # stock thickness, mm
    flip_axis: int | None = None  # side B's flip axis

    @property
    def centres_b(self) -> list[tuple[float, float]]:
        """Turned front-to-back about X, Y mirrors; rolled over about Y, X mirrors."""
        return [(-c[0], c[1]) if self.flip_axis == 1 else (c[0], -c[1]) for c in self.centres_a]

    @property
    def window_depth(self) -> float:
        return self.thickness - self.depth_a + OVERLAP

    @property
    def probe_z(self) -> float:
        return -(self.window_depth + PROBE_BELOW_WINDOW)


def place(stock, part_min, part_max, clear: float, keep_out=(), x_reach: Range | None = None,
          tool_diameter: float = 6.35, max_depth: float = 1e9) -> Plan | None:
    """Where the bores go: in the frame, past `clear` from the part's outline box, `wall` from the
    stock's edges, out of the clamped strips and (along X) within reach. None: no frame wide enough."""
    r = DIAMETER / 2
    cx, cy = (part_min[0] + part_max[0]) / 2, (part_min[1] + part_max[1]) / 2
    reach = Range(x_reach.lower + r + 0.5, x_reach.upper - r - 0.5) if x_reach is not None else None

    def fits(p) -> bool:
        if not (abs(p[0]) <= stock[0] / 2 - r - WALL and abs(p[1]) <= stock[1] / 2 - r - WALL):
            return False
        if reach is not None and p[0] not in reach:
            return False
        g = clear + r + WALL
        if part_min[0] - g < p[0] < part_max[0] + g and part_min[1] - g < p[1] < part_max[1] + g:
            return False
        for k in keep_out:
            (kx0, ky0), (kx1, ky1) = k
            if kx0 - r - WALL < p[0] < kx1 + r + WALL and ky0 - r - WALL < p[1] < ky1 + r + WALL:
                return False
        return True

    depth = min(stock[2] - SKIN, max_depth)
    if not depth > stock[2] / 2 + 1:
        return None
    offsets = [OFF_CENTRE, -OFF_CENTRE, 4.5, -4.5, 0.0]
    inner = part_max[1] - cy + clear + r + WALL
    outer = min(stock[1] / 2 - cy, stock[1] / 2 + cy) - r - WALL
    if outer >= inner:
        d = (inner + outer) / 2
        for e in offsets:
            pair = [(e, cy - d), (e, cy + d)]
            if all(fits(p) for p in pair):
                return Plan(pair, depth, stock[2])
    inner_x = part_max[0] - cx + clear + r + WALL
    outer_x = min(stock[0] / 2 - cx, stock[0] / 2 + cx) - r - WALL
    if outer_x >= inner_x:
        d = (inner_x + outer_x) / 2
        for e in offsets:
            pair = [(cx - d, e), (cx + d, e)]
            if all(fits(p) for p in pair):
                return Plan(pair, depth, stock[2])
    return None


PROBE_ON = ["M4 S1500", "G4 P2"]  # the tool turns slowly backwards, so a touch never cuts
PROBE_FEED = 20.0


def bore_program(plan: Plan, bore: int, tool_diameter: float, electrical: bool) -> str:
    """Finds bore k's centre and stores it as G55 (k = 0) or G56 (k = 1); the measured diameter
    must match, otherwise the step stops with an error."""
    c = plan.centres_b[bore]
    wcs = "G55" if bore == 0 else "G56"
    gap = (DIAMETER - tool_diameter) / 2
    reach = gap + 1.5
    g = [f"(Reference bore {bore + 1}: find its centre)", "G21 G90", "G53 G0 Z-1", f"G54 G0 X{n(c[0])} Y{n(c[1])}", "G0 Z2"]
    g += PROBE_ON
    g += [f"G38.3 G91 Z-{n(2 - plan.probe_z)} F60", "G90"]
    for axis in ("X", "Y"):
        nominal = c[0] if axis == "X" else c[1]
        g += [f"G38.2 G91 {axis}{n(reach)} F{n(PROBE_FEED)}", f"G10 L20 P4 {axis}0", f"G91 G0 {axis}-0.3",
              f"G90 G54 G0 {axis}{n(nominal)}",
              f"G38.2 G91 {axis}-{n(reach)} F{n(PROBE_FEED)}", f"G10 L20 P5 {axis}0", f"G91 G0 {axis}0.3", "G90",
              f"M102 {wcs}{axis} ((G57{axis} + G58{axis})/2)",
              f"M102 G58{axis} (abs(G57{axis} - G58{axis}))",
              f"M106 G58{axis} > {n(2 * gap - 0.4)} error: bore {bore + 1} too small - not found",
              f"M106 G58{axis} < {n(2 * gap + 0.4)} error: bore {bore + 1} too big - not found",
              f"{wcs} G0 {axis}0"]
    g += ["G53 G0 Z-1", "M5", "G54"]
    return "\n".join(g) + "\n"


def zero_program(plan: Plan) -> str:
    """X0 Y0 from the two bore centres into G54, after checking their spacing and squareness."""
    b = plan.centres_b
    mid = ((b[0][0] + b[1][0]) / 2, (b[0][1] + b[1][1]) / 2)
    dx, dy, dxy = b[0][0] - b[1][0], abs(b[0][1] - b[1][1]), abs(b[0][0] - b[1][0])
    g = ["(X0 Y0 from the reference bores)", "G21 G90"]
    if dy >= dxy:
        g += [f"M102 G57X (abs(G55X - G56X - ({n(dx)})))", "M106 G57X < 0.1 error: stock turned - reseat it square",
              f"M102 G57Y (abs(abs(G55Y - G56Y) - {n(dy)}))", "M106 G57Y < 0.15 error: bore spacing wrong - check the flip"]
    else:
        ddy = b[0][1] - b[1][1]
        g += [f"M102 G57Y (abs(G55Y - G56Y - ({n(ddy)})))", "M106 G57Y < 0.1 error: stock turned - reseat it square",
              f"M102 G57X (abs(abs(G55X - G56X) - {n(dxy)}))", "M106 G57X < 0.15 error: bore spacing wrong - check the flip"]
    g += [f"M102 G54X ((G55X + G56X)/2 - ({n(mid[0])}))", f"M102 G54Y ((G55Y + G56Y)/2 - ({n(mid[1])}))",
          "G4 P0.5", "G54", "G53 G0 Z-1", f"G54 G0 X{n(b[0][0])} Y{n(b[0][1])}"]
    return "\n".join(g) + "\n"


def store_wall(axis: str, positive: bool) -> str:
    return f"G10 L20 P{4 if positive else 5} {axis}0\nG4 P0.5\n"


def store_centre(bore: int, axis: str, tool_diameter: float) -> str:
    wcs = "G55" if bore == 0 else "G56"
    gap = (DIAMETER - tool_diameter) / 2
    return (f"M102 {wcs}{axis} ((G57{axis} + G58{axis})/2)\n"
            f"M102 G58{axis} (abs(G57{axis} - G58{axis}))\n"
            f"M106 G58{axis} > {n(2 * gap - 0.4)} error: walls too close - find them again\n"
            f"M106 G58{axis} < {n(2 * gap + 0.4)} error: walls too far apart - find them again\n"
            "G4 P0.5\n")


def edge_program(axis: str, toward: float, store: int) -> str:
    """Probe toward an edge and store the touch in G55/G56 (the tool's radius cancels)."""
    return ("G21\n" + "\n".join(PROBE_ON) + "\n"
            f"G38.2 G91 {axis}{n(10 * toward)} F{n(PROBE_FEED)}\n"
            f"G10 L20 P{store} {axis}0\n"
            f"G91 G0 {axis}{n(-2 * toward)}\n"
            "M5\nG90\n")


def single_edge_program(axis: str, toward: float, edge_at: float, radius: float, electrical: bool) -> str:
    """One edge only (the other is out of reach): X0 from that edge and the stock's size."""
    at = edge_at - toward * radius
    if not electrical:
        return f"G10 L20 P1 {axis}{n(at)}\nG4 P0.5\n"
    return ("G21\n" + "\n".join(PROBE_ON) + "\n"
            f"G38.2 G91 {axis}{n(10 * toward)} F{n(PROBE_FEED)}\n"
            f"G10 L20 P1 {axis}{n(at)}\n"
            f"G91 G0 {axis}{n(-2 * toward)}\n"
            "M5\nG90\n")


def top_program(z: float) -> str:
    """Touch the tool down on the face: that height is `z`."""
    return ("G21\n" + "\n".join(PROBE_ON) + "\n"
            f"G38.2 G91 Z-8 F{n(PROBE_FEED)}\n"
            f"G10 L20 P1 Z{n(z)}\n"
            "G91 G0 Z3\nM5\nG90\nG54\n")
