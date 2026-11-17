"""Operation kinds and cutting data. Port of Feeds/FeedsEngine.swift: anchored on the maker's
feeds & speeds master document (aluminium, 3-flute carbide) and scaled by material, tool and
operation."""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from enum import Enum

from .geometry import swift_round
from .units import Length


class OperationKind(Enum):
    FACING = "facing"
    ADAPTIVE = "adaptive"
    CONTOUR = "contour"
    FLOOR = "floor"
    DRILL = "drill"
    BORE = "bore"
    CHAMFER = "chamfer"
    # 3D finishing (raw values are the engine's strategy names)
    PARALLEL = "parallel"
    WATERLINE = "waterline"
    STEEP_SHALLOW = "steep_shallow"
    SCALLOP = "scallop"
    SPIRAL = "spiral"
    RADIAL = "radial"
    REST = "rest"
    ENGRAVE = "engrave"  # text along glyph outlines, following the surface
    THREAD = "thread"  # internal threads milled with a single-form thread mill

    @property
    def is_3d(self) -> bool:
        return self in _3D

    @property
    def title(self) -> str:
        return _TITLES[self.value]

    @property
    def explanation(self) -> str:
        return _EXPLANATIONS[self.value]


_3D = {OperationKind.PARALLEL, OperationKind.WATERLINE, OperationKind.STEEP_SHALLOW, OperationKind.SCALLOP,
       OperationKind.SPIRAL, OperationKind.RADIAL, OperationKind.REST}

_TITLES = {"facing": "Facing", "adaptive": "Adaptive roughing", "contour": "Contour finishing", "floor": "Floor finishing",
           "drill": "Drilling", "bore": "Helical boring", "chamfer": "Chamfer / deburr", "parallel": "Parallel finishing",
           "waterline": "Waterline finishing", "steep_shallow": "Steep & shallow finishing", "scallop": "Scallop finishing",
           "spiral": "Spiral finishing", "radial": "Radial finishing", "rest": "Rest / pencil finishing",
           "engrave": "Engraving", "thread": "Thread milling"}

_EXPLANATIONS = {
    "facing": "Flattens the stock face so Z0 is true. Light, fast passes.",
    "adaptive": "Roughing with constant tool engagement: deep cuts, small stepover, even wear, no full-width slotting.",
    "contour": "Finishes walls level by level with arc lead-ins and an optional spring pass.",
    "floor": "Finishes flat floors after roughing.",
    "drill": "Peck-drills holes along the tool axis.",
    "bore": "Helically mills holes that have no matching drill.",
    "chamfer": "Breaks sharp edges.",
    "parallel": "Straight passes over the whole surface at a fixed angle. Best on shallow, gently curved areas; steep walls get wider cusps.",
    "waterline": "Constant-Z contours. Best on steep walls; flat tops get few passes.",
    "steep_shallow": "Waterline on steep areas, parallel on shallow ones, with a small overlap: an even finish on mixed shapes like domed pendants.",
    "scallop": "Passes at a constant 3D distance from each other, following the shape: the most even finish on freeform jewellery, at the cost of time.",
    "spiral": "One continuous spiral from the centre out: ideal for domes, cabochons and ring tops, with no direction changes to mark the surface.",
    "radial": "Spokes from the centre: for rosettes and radially symmetric shapes.",
    "rest": "Cleans only where a bigger tool couldn't reach: inside corners, creases and small fillets. Runs after a larger finishing tool.",
    "engrave": "Traces text into the surface at a set depth, following its shape: names, dates, hallmarks.",
    "thread": "Mills internal threads with a single-form thread mill: one helical turn per pitch, climbing from the bottom up, in holes made at the tap-drill size first. No tap to break, any depth the cutter reaches.",
}


class RoughingStyle(Enum):
    """How hard roughing runs: it leaves stock for finishing, so it never shows on the part."""

    TABLE = "table"  # the maker's table as printed (chip thinning barely used: ×1.15)
    THINNED = "thinned"  # the feed raised so each tooth cuts the table's chip at light engagement (≤ ×1.6)
    DEEP = "deep"  # chip-thinned, and each level one tool diameter deep (tools ≥ 3 mm)

    @property
    def title(self) -> str:
        return {"table": "The machine table", "thinned": "Chip-thinned", "deep": "Deep"}[self.value]

    @property
    def explanation(self) -> str:
        return {"table": "The maker's printed feeds and ½-diameter levels. The gentlest; the slowest roughing.",
                "thinned": "At the light engagement adaptive roughing uses, the chip is thinner than the feed per tooth: the feed rises until each tooth cuts the table's chip again. Same load on the tool, roughly a third less roughing time.",
                "deep": "Chip-thinned, and each level a full tool diameter deep (tools 3 mm and up): about half the levels. Twice the cutting force of the table; listen for chatter on the first cut."}[self.value]


@dataclass
class CuttingData:
    rpm: float
    feed: float  # mm/min
    plunge_feed: float
    ramp_feed: float
    chip_load: float  # feed per tooth actually used, mm
    stepdown: float  # axial depth per pass, mm
    stepover: float  # radial engagement, mm
    ramp_angle: float  # degrees
    power: float  # estimated cutting power at full engagement, W
    notes: list[str] = field(default_factory=list)


ANCHOR_DIAMETERS = [1.0 / 16, 1.0 / 8, 5.0 / 32, 3.0 / 16, 1.0 / 4]
ANCHOR_ADAPTIVE = [0.0006, 0.0008, 0.0010, 0.0010, 0.0013]
ANCHOR_CONTOUR = [0.0003, 0.0004, 0.0005, 0.0006, 0.0006]
ANCHOR_SLOT = [0.0002, 0.0003, 0.0004, 0.0004, 0.0004]
ANCHOR_ADAPTIVE_STEPOVER = [0.012, 0.014, 0.016, 0.018, 0.020]
ANCHOR_FINISH_STEPOVER = [0.005, 0.006, 0.007, 0.008, 0.010]


def lookup(table: list[float], diameter: float) -> float:
    """Piecewise-linear lookup in the anchor table, in mm. Below the smallest anchor the value
    scales with diameter; above the largest it extrapolates gently (cap 1.4×)."""
    d = diameter
    xs = [x * 25.4 for x in ANCHOR_DIAMETERS]
    ys = [y * 25.4 for y in table]
    if d <= xs[0]:
        return ys[0] * d / xs[0]
    if d >= xs[-1]:
        return ys[-1] * min(d / xs[-1], 1.4)
    for i in range(len(xs) - 1):
        if d <= xs[i + 1]:
            t = (d - xs[i]) / (xs[i + 1] - xs[i])
            return ys[i] + t * (ys[i + 1] - ys[i])
    return ys[-1]


def scallop_stepover(tool, cusp: float) -> float:
    """Stepover that leaves cusps `cusp` mm high on flat ground: 2·√(2·R·h − h²) for a ball (or a
    bull nose's corner radius); flat end mills finish shallow areas at 30 % of the diameter."""
    from .inventory.items import ToolKind
    h = cusp
    if tool.kind is ToolKind.BALL_END_MILL:
        r = tool.diameter / 2
    elif tool.kind is ToolKind.BULL_NOSE_END_MILL and tool.corner_radius > 0.05:
        r = tool.corner_radius
    else:
        r = 0.0
    if r <= 0:
        return 0.3 * tool.diameter
    return 2 * math.sqrt(max(2 * r * h - h * h, 1e-9))


def compute(tool, material, kind: OperationKind, machine=None, roughing: RoughingStyle = RoughingStyle.TABLE) -> CuttingData:
    from .inventory.items import ToolKind, ToolMaterial
    from .machine.profile import MachineProfile
    from .materials import Difficulty
    machine = machine or MachineProfile.standard()
    K = OperationKind
    d = max(tool.diameter, 0.1)
    notes: list[str] = []
    hss = tool.tool_material is ToolMaterial.HSS
    flutes = float(max(tool.flutes, 1))

    vc = material.surface_speed.lower / 2 + material.surface_speed.upper / 2
    if hss:
        vc *= 0.4
        notes.append("HSS tool: surface speed reduced to 40%.")
    if kind in (K.CONTOUR, K.DRILL):
        vc *= 0.75
    elif kind is K.THREAD:
        vc *= 0.6  # the whole profile engages at once
    if kind.is_3d and tool.kind is ToolKind.BALL_END_MILL:
        vc *= 1.2  # a ball cuts at a smaller effective diameter near its tip
    ideal = vc * 1000 / (math.pi * d)
    lo, hi = machine.spindle_rpm.lower, machine.spindle_rpm.upper
    rpm = min(max(ideal, lo), hi)
    if ideal > hi:
        notes.append(f"Normal for a small tool: its ideal cutting speed would need {int(swift_round(ideal / 1000))} 000 RPM, far beyond any desktop spindle. At the machine's {int(hi)} RPM the feed is lowered to keep the right chip load, so it simply cuts slower.")
    elif ideal < lo:
        notes.append(f"Raised to the machine's minimum of {int(lo)} RPM; the chip load is kept, so the feed rises with it.")

    if kind in (K.FACING, K.ADAPTIVE, K.FLOOR, K.BORE, K.CHAMFER):
        fz = lookup(ANCHOR_ADAPTIVE, d)
    elif kind is K.CONTOUR:
        fz = lookup(ANCHOR_CONTOUR, d)
    elif kind is K.DRILL:
        fz = lookup(ANCHOR_ADAPTIVE, d) * 0.6
    elif kind.is_3d:
        fz = lookup(ANCHOR_CONTOUR, d)
    elif kind is K.ENGRAVE:
        fz = lookup(ANCHOR_CONTOUR, d) * 0.5  # a fine tip in a full-width slot
    else:  # thread
        fz = lookup(ANCHOR_CONTOUR, d) * 0.4  # a full thread profile, a thin neck
    fz *= material.chip_load_factor
    if hss:
        fz *= 0.8

    depth_scale = material.adaptive_depth_max / 2.0
    reach = max(tool.flute_length * 0.9, 0.1)
    if kind is K.FACING:
        stepover = 0.4 * d
        stepdown = min(0.04 * d * max(material.chip_load_factor, 0.5), 0.3)
    elif kind is K.ADAPTIVE:
        stepover = lookup(ANCHOR_ADAPTIVE_STEPOVER, d) * (material.adaptive_stepover_max / 0.10)
        stepdown = min((1.0 if roughing is RoughingStyle.DEEP and d >= 3 else 0.5) * d * depth_scale, reach)
        ae = min(stepover, d / 2)
        thinning = min(d / (2 * math.sqrt(d * ae - ae * ae)), 1.15 if roughing is RoughingStyle.TABLE else 1.6)
        if thinning > 1.01:
            fz *= thinning
            notes.append(f"Chip thinning at {int(swift_round(ae / d * 100))}% engagement: feed raised {int(swift_round((thinning - 1) * 100))}%.")
    elif kind is K.CONTOUR:
        stepover = lookup(ANCHOR_FINISH_STEPOVER, d)
        stepdown = min(1.5 * d * depth_scale, reach)
    elif kind is K.FLOOR:
        stepover, stepdown = 0.4 * d, 0.0
    elif kind is K.DRILL:
        stepover = 0.0
        stepdown = min(max(0.25 * d * material.chip_load_factor, 0.2 * d), d)  # peck depth
    elif kind is K.BORE:
        stepover = 0.0
        stepdown = min(0.25 * d * depth_scale, reach)  # depth per helix turn
    elif kind is K.CHAMFER:
        stepover = stepdown = 0.0
    elif kind.is_3d:
        stepover = scallop_stepover(tool, 0.008)
        stepdown = stepover
        notes.append(f"Stepover {Length.mm(stepover)} mm leaves cusps about 8 µm high.")
    elif kind is K.THREAD:
        stepover = stepdown = 0.0
        notes.append("The feed is at the cutting edge; on the inside of the thread the tool's centre runs slower (the engine scales it), so the edge's chip stays as set.")
    else:  # engrave
        stepover = 0.0
        stepdown = min(0.1 * d, 0.2)

    feed = rpm * flutes * fz
    if kind is K.DRILL:
        feed = rpm * fz * 2  # drills: feed per rev ≈ two "teeth"
    cap = machine.max_feed_any_direction
    if feed > cap:
        notes.append(f"Feed capped at the machine's {int(cap)} mm/min.")
        feed = cap
    plunge = feed if kind is K.DRILL else feed * 0.35
    ramp = feed * 0.8
    ae = stepover if kind in (K.ADAPTIVE, K.FACING, K.FLOOR) else (stepover if kind is K.CONTOUR else d)
    ap = stepdown if kind is K.FACING else (d if kind in (K.DRILL, K.BORE) else stepdown)
    power = ae * ap * feed * material.specific_cutting_force / 60_000
    if power > machine.estimated_spindle_power * 0.8:
        notes.append(f"Estimated {int(power)} W is near the spindle's estimated {int(machine.estimated_spindle_power)} W. Coastline will reduce the depth of cut.")
    if not notes:
        notes.append(f"The maker's aluminium values for this tool size, scaled for {material.name}.")
    return CuttingData(swift_round(rpm), swift_round(feed), swift_round(plunge), swift_round(ramp), fz, stepdown, stepover,
                       1.0 if material.difficulty >= Difficulty.CAREFUL else 2.0, power, notes)
