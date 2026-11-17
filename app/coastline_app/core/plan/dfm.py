"""Design for manufacturing against what the user owns: does the stock hold the part, which owned
tool reaches each pocket and hole (cutter, shank and collet nut), and which faces need another
side or position. Geometry only: forces, rigidity and holding are not judged. Port of Plan/DFM.swift."""

from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field
from enum import IntEnum

import numpy as np

from ..geometry import _swift, swift_round
from ..inventory.items import Accessory, AccessoryKind, Coating, Condition, ToolKind, ToolMaterial
from ..units import Length
from .part_analysis import Access, PartAccess, PartAnalysis


class Category(IntEnum):
    """Display order: what blocks the job first."""

    NOT_SUPPORTED = 0
    MISSING_RESOURCE = 1
    MISSING_INFORMATION = 2
    SETUP_CHANGE = 3
    OK = 4

    @property
    def title(self) -> str:
        return ["Can't be machined", "Missing tool or stock", "Needs info", "Setup change", "OK"][self]

    @property
    def symbol(self) -> str:
        return ["xmark.octagon", "shippingbox", "questionmark.circle", "arrow.triangle.2.circlepath", "checkmark.circle"][self]


@dataclass
class Remedy:
    """A way forward: `kind` is useStock, showTool, setStickout, reviewSetups, buyTool, addCollet or addTool."""

    kind: str
    id: str | None = None  # stock or tool
    axes: tuple[int, ...] | None = None  # useStock: Setup.stock_axes
    minimum: float | None = None  # setStickout
    size: float | None = None  # addCollet: shank, mm
    tool: object | None = None  # addTool: a tool Coastline specified

    @staticmethod
    def use_stock(id: str, axes) -> "Remedy":
        return Remedy("useStock", id=id, axes=tuple(axes))

    @staticmethod
    def show_tool(id: str) -> "Remedy":
        return Remedy("showTool", id=id)

    @staticmethod
    def set_stickout(tool_id: str, minimum: float) -> "Remedy":
        return Remedy("setStickout", id=tool_id, minimum=minimum)

    @staticmethod
    def review_setups() -> "Remedy":
        return Remedy("reviewSetups")

    @staticmethod
    def buy_tool(id: str) -> "Remedy":
        return Remedy("buyTool", id=id)

    @staticmethod
    def add_collet(d: float) -> "Remedy":
        return Remedy("addCollet", size=d)

    @staticmethod
    def add_tool(t) -> "Remedy":
        return Remedy("addTool", tool=t)

    @property
    def title(self) -> str:
        """Short button text without inventory names."""
        return {"useStock": "Use this stock", "showTool": "Show the tool",
                "setStickout": f"Set stick-out to {mm(self.minimum or 0, 0.1)} mm or more", "reviewSetups": "Review setups",
                "buyTool": "Tool to buy", "addCollet": f"Add a {size(self.size or 0)} collet", "addTool": "Add to buy"}[self.kind]

    def title_in(self, inventory, current_stock: str | None = None) -> str:
        """Button text naming the stock or tool (the job's own stock reads "Turn the stock")."""
        if self.kind == "useStock":
            if self.id == current_stock:
                return "Turn the stock"
            s = next((s for s in inventory.stock if s.id == self.id), None)
            if s is None:
                return self.title
            return f"Use the {dims((s.envelope.x, s.envelope.y, s.envelope.z))} mm {s.shape.title.lower()}"
        tool = next((t for t in inventory.tools if t.id == self.id), None) if self.id else None
        if self.kind == "showTool":
            return f"Show the {label(tool)}" if tool else self.title
        if self.kind == "setStickout":
            return f"Set the {label(tool)} stick-out to {mm(self.minimum, 0.1)} mm" if tool else self.title
        if self.kind == "buyTool":
            return f"Buy the {label(tool)}" if tool else self.title
        if self.kind == "addTool":
            t = self.tool
            return f"Buy the {t.name}" if any(x.id == t.id for x in inventory.tools) else f"Add to buy: {t.name}"
        return self.title


@dataclass
class DFMFinding:
    """One finding: what the part needs from the stock, tools and setups, with the faces it
    concerns and the ways forward. `id` is stable: "stock", "floor-<face>", "hole-<face>",
    "region-<face>", "profile", "back", "corner", "concave", "thin", "tools", "tools-info", "exact"."""

    id: str
    category: Category
    title: str
    summary: str  # what is wrong (or right), in one plain sentence
    details: list[str] = field(default_factory=list)
    faces: list[int] = field(default_factory=list)  # engine face indices to highlight
    remedies: list[Remedy] = field(default_factory=list)
    measure: str | None = None  # the key measurement
    fix: str | None = None  # what to do about it (None when nothing is needed)
    areas: list[list[int]] | None = None  # separate places it occurs: one pin each
    sides: list[str] = field(default_factory=list)  # directions a tool comes from to cut it

    def __post_init__(self) -> None:
        if self.areas is None:
            self.areas = [] if not self.faces else [list(self.faces)]


STANDARD_SIZES = [0.5, 0.8, 1.0, 1.5875, 2.0, 2.38, 3.0, 3.175, 4.0, 4.7625, 6.0, 6.35, 8.0]
MINIMUM_GRIP = 10.0  # shank left in the collet, mm
NOT_CHECKED = "Not checked: cutting force, rigidity, clamping, fixtures before toolpaths, and the spindle above the collet nut."
KEPT_TOLERANCE = 0.01  # a boundary face this close to the stock face stays as supplied
STANDARD_LENGTHS = [38.1, 50.8, 63.5, 76.2, 101.6]
SIDES = ["+z", "-z", "+x", "-x", "+y", "-y"]


@dataclass
class Input:
    analysis: PartAnalysis
    setup: object
    part_min: tuple  # the part's own bounds (part coordinates)
    part_max: tuple
    stock: object | None
    inventory: object
    machine: object = None
    two_sided: bool = False
    named: list = field(default_factory=list)  # NamedFeature
    room: object | None = None  # SetupRoom

    def __post_init__(self) -> None:
        if self.machine is None:
            from ..machine.profile import MachineProfile
            self.machine = MachineProfile.standard()


class Verdict:
    REACHES = "reaches"
    NEEDS_STICKOUT = "needsStickout"
    CANNOT = "cannot"


@dataclass
class Reach:
    verdict: str
    reason: str
    warnings: list[str] = field(default_factory=list)
    stickout: float | None = None  # with NEEDS_STICKOUT: the stick-out that reaches


# ---------------------------------------------------------------- words and numbers

def mm(v: float, step: float = 0.001) -> str:
    """Rounded to `step` first, so measured noise (19.998) reads as the designed size."""
    return Length.mm(swift_round(v / step) * step)


def size(d: float) -> str:
    """'1/4"' when it is a common inch size, else '6 mm'."""
    return Length.inch_fraction(d) or f"{mm(d)} mm"


def dims(v) -> str:
    return f"{mm(v[0], 0.1)} x {mm(v[1], 0.1)} x {mm(v[2], 0.1)}"


_KIND_WORDS = {ToolKind.FLAT_END_MILL: "flat", ToolKind.BALL_END_MILL: "ball", ToolKind.BULL_NOSE_END_MILL: "bull nose",
               ToolKind.CHAMFER_MILL: "chamfer", ToolKind.ENGRAVER: "engraver", ToolKind.DRILL: "drill",
               ToolKind.SPOT_DRILL: "spot drill", ToolKind.THREAD_MILL: "thread mill", ToolKind.FACE_MILL: "face mill"}


def short_label(t) -> str:
    return f"{size(t.diameter)} {_KIND_WORDS[t.kind]}"


def label(t) -> str:
    """'1/8" flat 81635': with the part number (or what follows '·' in the name)."""
    part = t.part_number.strip()
    if part:
        return f"{short_label(t)} {part}"
    pieces = [p for p in t.name.split("·") if p]
    if len(pieces) > 1 and pieces[1].strip():
        return f"{short_label(t)} {pieces[1].strip()}"
    return t.name


def side_name(s: str) -> str:
    return {"+z": "front", "-z": "back", "+x": "upper side", "-x": "lower side", "+y": "right side", "-y": "left side"}.get(s, s)


def side_words(side: str) -> str:
    return "back" if side == "-z" else side_name(side)


def inline(name: str) -> str:
    return name[:1].lower() + name[1:]


def has_collet(t, inventory) -> bool:
    from ..inventory.checks import InventoryChecks
    return any(abs(c - t.shank_diameter) <= InventoryChecks.COLLET_TOLERANCE for c in inventory.collet_sizes)


def _tool_issues(t) -> list[str]:
    from ..inventory.checks import ResourceLibraryValidation
    return ResourceLibraryValidation.tool_issues(t)


# ---------------------------------------------------------------- reach

def reach(t, opening: float | None, wall_depth: float, holder_depth: float, hole: float | None, machine, inventory) -> Reach:
    """Can this tool cut a feature: the cutter fits the opening, the flutes (or a shank no wider
    than the cutter) reach the wall depth, and the collet nut clears the part at the stick-out."""
    def no(reason: str) -> Reach:
        return Reach(Verdict.CANNOT, reason)

    if t.condition is Condition.BROKEN:
        return no("marked broken")
    if t.requires_specification_review or _tool_issues(t):
        return no("specs not confirmed")
    if t.shank_diameter > machine.max_shank_diameter + 1e-6:
        return no(f"shank over the {machine.collet_name} limit ({mm(machine.max_shank_diameter)} mm)")
    if t.overall_length > machine.max_tool_length + 1e-6:
        return no(f"{mm(t.overall_length)} mm long, over the {mm(machine.max_tool_length)} mm limit")
    if not has_collet(t, inventory):
        return no(f"no collet for its {size(t.shank_diameter)} shank")
    if t.kind is ToolKind.DRILL:
        if hole is None:
            return no("a drill only makes holes")
        if abs(t.diameter - hole) > 0.05:
            return no(f"{mm(t.diameter)} mm drill, {mm(hole)} mm hole")
        if t.flute_length + 0.05 < wall_depth:
            return no(f"flutes {mm(t.flute_length)} mm, hole {mm(wall_depth, 0.1)} mm deep")
    elif not t.kind.cuts_sideways:
        return no("doesn't cut sideways")
    elif hole is not None:
        if t.diameter >= hole - 0.1 - 1e-9:
            return no(f"too wide to bore it (needs under {mm(hole - 0.1)} mm)")
    elif opening is not None and t.diameter > opening - 0.02 + 1e-9:
        return no(f"too wide ({mm(t.diameter)} > {mm(opening, 0.01)} mm)")
    warnings: list[str] = []
    wide_shank = t.shank_diameter > t.diameter + 0.02
    if wide_shank and wall_depth > t.flute_length + 1e-6:
        return no(f"shank wider than the cutter stops it at {mm(t.flute_length)} mm")
    if not wide_shank and t.kind is not ToolKind.DRILL and wall_depth > t.flute_length + 0.05:
        warnings.append(f"shank rubs the wall below {mm(t.flute_length)} mm")
    longest = t.overall_length - MINIMUM_GRIP
    need = holder_depth - 0.005  # measured depths carry float noise
    stick = None
    if t.stickout >= need:
        verdict, used = Verdict.REACHES, t.stickout
    elif need <= longest:
        s = math.ceil(need * 2) / 2  # stated in half millimetres, never past the grip limit
        if s > longest + 1e-6:
            s = min(math.ceil(need * 10) / 10, longest)
        verdict, used, stick = Verdict.NEEDS_STICKOUT, s, s
    else:
        return no(f"the collet nut would hit the part (needs {mm(holder_depth, 0.1)} mm stick-out, at most {mm(longest, 0.1)})")
    if t.kind.cuts_sideways:
        fluted = min(t.flute_length, used)
        ratio = fluted / max(t.diameter, 0.01) + (used - fluted) / max(t.shank_diameter, 0.01)
        if ratio > 10:
            warnings.append(f"very slender at {mm(used, 0.1)} mm stick-out ({int(swift_round(ratio))}× its diameter)")
    if verdict == Verdict.NEEDS_STICKOUT:
        return Reach(verdict, f"reaches at {mm(stick, 0.1)} mm stick-out (now {mm(t.stickout)})", warnings, stick)
    return Reach(verdict, "reaches", warnings)


def rank(r: Reach) -> int | None:
    """0: reaches cleanly, 1: with more stick-out, 2/3: the same with warnings; None: cannot."""
    if r.verdict == Verdict.CANNOT:
        return None
    if r.verdict == Verdict.REACHES:
        return 0 if not r.warnings else 2
    return 1 if not r.warnings else 3


# ---------------------------------------------------------------- assessment

def assess(i: Input) -> list[DFMFinding]:
    """Findings sorted by category, then title. Without `analysis.access` only the stock fit and
    an "Exact CAD needed" note come back."""
    out: list[DFMFinding] = []
    finding, room = stock_fit(i)
    out.append(finding)
    access = i.analysis.access
    if access is None:
        out.append(DFMFinding("exact", Category.MISSING_INFORMATION, "Exact CAD needed",
                              "Tool reach is checked only on STEP parts, after analysis.", fix="Import the part as STEP or IGES."))
        return sorted_findings(out)
    if room is not None:
        back = access.boundary_faces("-z")
        if not i.two_sided and room.side("-z") > KEPT_TOLERANCE and back:
            out.append(DFMFinding("back", Category.SETUP_CHANGE, "Stock behind the part",
                                  f"{mm(room.side('-z'), 0.1)} mm of stock stays behind the part. Cut the part free, or machine the back.",
                                  ["Holding while it is cut free is not checked."], [f.index for f in back], [Remedy.review_setups()],
                                  sides=["-z"]))
        sides = [s for s in ("+x", "-x", "+y", "-y") if room.side(s) > KEPT_TOLERANCE]
        depth = profile_depth(access, i)
        if sides and depth > 0.05:
            per_side = " per side" if i.two_sided else ""
            each = " from each side" if i.two_sided else ""
            out.append(cut(["+z", "-z"] if i.two_sided else ["+z"], feature(Feature(
                "profile", f"Outside profile, {mm(depth, 0.1)} deep{per_side}",
                [f.index for f in access.faces if (f.boundary or "") in sides], None, depth, depth + 1, None,
                f"Walls {mm(depth, 0.1)} mm deep{each}, stick-out at least {mm(depth + 1, 0.1)} mm"), i)))
    for f in access.floors:
        if not f.wall_depth > 0.05:
            continue
        cx, cy = (f.min[0] + f.max[0]) / 2, (f.min[1] + f.max[1]) / 2
        # A flat-bottomed hole's floor is the hole's own business.
        if any(abs(f.width - h.diameter) <= 0.06 and math.hypot(cx - h.x, cy - h.y) <= h.diameter / 2 for h in access.holes):
            continue
        dx, dy = f.max[0] - f.min[0], f.max[1] - f.min[1]
        a, b = min(dx, dy), max(dx, dy)
        title = (f"{floor_kind(f, b >= 4 * a)} {mm(a, 0.1)} x {mm(b, 0.1)} mm, {mm(f.wall_depth, 0.1)} deep" if a > 0.05
                 else f"Floor {mm(f.width, 0.1)} mm wide, {mm(f.wall_depth, 0.1)} deep")
        out.append(cut(["+z"], feature(Feature(f"floor-{f.face}", title, [f.face], f.width, f.wall_depth, f.holder_depth, None,
                                               f"{mm(f.width, 0.01)} mm wide, {mm(f.wall_depth, 0.1)} mm deep, stick-out at least {mm(f.holder_depth, 0.1)} mm"), i)))
    for h in access.holes:
        if h.access is not Access.THIS_SIDE:
            continue
        d, length = mm(h.diameter), mm(h.length, 0.1)
        out.append(cut(["+z"], feature(Feature(
            f"hole-{h.faces[0] if h.faces else -1}", f"Through hole {d} mm, {length} deep" if h.through else f"Hole {d} mm, {length} deep",
            h.faces, h.diameter, h.length, h.holder_depth, h.diameter,
            f"{d} mm, {length} mm deep{', through' if h.through else ''}, stick-out at least {mm(h.holder_depth, 0.1)} mm"), i)))
    from .named_features import NamedFeature
    for g in region_groups(access.regions, i):
        f = region(g[0], i)
        if f is None:
            continue
        if g[0].thread is None:
            name = NamedFeature.name(g[0].faces, i.named)
            if name is not None:
                f.title = f"{name}: {inline(f.title)}"
        if len(g) > 1:
            f.faces = [k for r in g for k in r.faces]
            f.areas = [list(r.faces) for r in g]
        out.append(room_checked(f, i))
    out += shape_findings(i)
    out += tool_findings(i)
    return sorted_findings(merged(out))


def sorted_findings(f: list[DFMFinding]) -> list[DFMFinding]:
    return sorted(f, key=lambda x: (x.category, x.title, x.id))


def merged(findings: list[DFMFinding]) -> list[DFMFinding]:
    """The same finding in several places reads once, with a pin on the part for each place."""
    out: list[DFMFinding] = []
    index: dict[str, int] = {}
    for f in findings:
        place = any(f.id.startswith(p) for p in ("floor-", "hole-", "region-"))
        key = f"{int(f.category)}|{f.title}|{f.summary}|{f.fix or ''}"
        k = index.get(key) if place else None
        if k is None:
            if place:
                index[key] = len(out)
            out.append(f)
            continue
        o = out[k]
        o.faces = o.faces + f.faces
        o.areas = o.areas + f.areas
        for r in f.remedies:
            if r not in o.remedies:
                o.remedies.append(r)
        for s in f.sides:
            if s not in o.sides:
                o.sides.append(s)
    for o in out:
        if len(o.areas) > 1:
            o.title += f" ({len(o.areas)} places)"
    return out


def room_checked(f: DFMFinding, i: Input) -> DFMFinding:
    """A cut from a side the stock doesn't fit the machine on: it can't be machined here."""
    from .plan_coverage import SetupRoom
    if i.room is None or i.stock is None:
        return f
    stock_size = i.setup.stock_size(i.stock)
    for side in f.sides:
        kind, why = i.room.fit(SetupRoom.size(stock_size, side), side)
        if kind == "fits":
            continue
        if kind == "enclosureOpen":
            line = f"With the {side_words(side)} toward the spindle: {why}"
            if line not in f.details:
                f.details.append(line)
            continue
        line = f"The stock doesn't fit the machine with the {side_words(side)} toward the spindle. {why}"
        if f.category is Category.NOT_SUPPORTED:
            f.details.append(line)
            return f
        f.category = Category.NOT_SUPPORTED
        f.summary = f"Cut from the {side_words(side)}. {line}"
        f.remedies = []
        f.fix = "Change the design so a side that fits reaches it, or make it on a machine with more room."
        return f
    return f


def cut(sides: list[str], f: DFMFinding) -> DFMFinding:
    f.sides = list(sides)
    return f


# ---------------------------------------------------------------- stock

@dataclass
class Room:
    """Stock left around the part per side, mm (negative: the part sticks out)."""

    low: np.ndarray
    high: np.ndarray

    def side(self, s: str) -> float:
        axis = {"x": 0, "y": 1, "z": 2}.get(s[1:], 2)
        return float(self.high[axis] if s.startswith("+") else self.low[axis])


def work_bounds(i: Input) -> tuple[np.ndarray, np.ndarray]:
    """The part's bounds in the work frame, exactly as SetupChecks.check places it."""
    m = i.setup.part_to_work(i.part_min, i.part_max)
    rlo, rhi = i.setup.rotated_part_bounds(i.part_min, i.part_max)
    shift = np.asarray(m, float)[:3, 3]
    return np.asarray(rlo, float) + shift, np.asarray(rhi, float) + shift


def stock_fit(i: Input) -> tuple[DFMFinding, Room | None]:
    from .job_library_guide import stock_choices
    plo, phi = work_bounds(i)
    part = phi - plo
    part_line = f"Part {dims(part)} mm (up x along x deep)."
    choices = stock_choices(part, i.inventory, i.setup.stock_axes)
    stock = i.stock
    if stock is None:
        remedies = [Remedy.use_stock(c.stock.id, c.axes) for c in choices]
        if not remedies:
            return DFMFinding("stock", Category.MISSING_RESOURCE, "No stock fits", "None of your stock holds the part.", [part_line]), None
        n = len(remedies)
        return DFMFinding("stock", Category.MISSING_INFORMATION, "No stock chosen",
                          f"Choose stock. {n} of yours fit{'s' if n == 1 else ''}.", [part_line], remedies=remedies), None
    bmin, bmax = (np.asarray(v, float) for v in i.setup.stock_box(stock))
    room = Room(plo - bmin, bmax - phi)
    stock_size = bmax - bmin
    faces = i.analysis.access.faces if i.analysis.access is not None else []
    out = [s for s in SIDES if room.side(s) < -1e-6]
    if out:
        fits_as_is = all(stock_size[k] + 1e-6 >= part[k] for k in range(3))
        remedies = [Remedy.review_setups()] if fits_as_is else []
        current = np.asarray(i.setup.raw_stock_size(stock), float)
        for c in choices:
            # The current stock only when another orientation is what makes it fit.
            if c.stock.id == stock.id:
                turned = i.setup.copy()
                turned.stock_axes = list(c.axes)
                if fits_as_is or np.linalg.norm(np.asarray(turned.raw_stock_size(stock), float) - current) < 1e-6:
                    continue
            remedies.append(Remedy.use_stock(c.stock.id, c.axes))
        details = [part_line, f"Stock {dims(stock_size)} mm as set up."]
        details += [f"Sticks out {mm(-room.side(s), 0.1)} mm at the {side_name(s)}." for s in out]
        has_stock = any(r.kind == "useStock" for r in remedies)
        if not fits_as_is and not has_stock:
            details.append("None of your stock holds the part.")
        worst = max(-room.side(s) for s in out)
        out_faces = [f.index for f in faces if (f.boundary or "") in out]
        if fits_as_is:
            return DFMFinding("stock", Category.SETUP_CHANGE, "Part outside the stock",
                              "The stock is big enough, but the part sits partly outside it.", details, out_faces, remedies,
                              part_line, "Move the part inside the stock in Setups."), None
        return DFMFinding("stock", Category.MISSING_RESOURCE, "Stock too small",
                          f"The part sticks out of this stock by {mm(worst, 0.1)} mm.", details, out_faces, remedies, part_line,
                          "Use bigger stock you own (below)." if has_stock else f"Get stock at least {dims(part)} mm. The part keeps its size."), None
    # Fits. A face on the stock boundary needs no cut: zero allowance is valid there.
    kept_sides = [s for s in SIDES if room.side(s) <= KEPT_TOLERANCE]
    kept = [f for f in faces if (f.boundary or "") in kept_sides]
    named = kept_sides if i.analysis.access is None else [s for s in kept_sides if any(f.boundary == s for f in kept)]
    exact = len(kept_sides) == len(SIDES)
    summary = "Exact size." if exact else "Fits."
    if kept:
        n = len(kept)
        summary += f" {n} face{'' if n == 1 else 's'} stay{'s' if n == 1 else ''} as supplied."
    cut_sides = [s for s in SIDES if room.side(s) > KEPT_TOLERANCE]
    e = stock.envelope
    details = [f"Stock {dims((e.x, e.y, e.z))} mm.",
               "Stock to cut: none." if not cut_sides else
               "Stock to cut: " + ", ".join(f"{side_name(s)} {mm(room.side(s), 0.01)}" for s in cut_sides) + " mm."]
    if named:
        details.append("Kept as supplied: " + ("all six faces" if len(named) == len(SIDES) else ", ".join(side_name(s) for s in named)) + ".")
    return DFMFinding("stock", Category.OK, "Stock fits", summary, details, [f.index for f in kept], measure=part_line), room


# ---------------------------------------------------------------- features

@dataclass
class Feature:
    id: str
    title: str
    faces: list[int]
    opening: float | None
    wall_depth: float
    holder_depth: float
    hole: float | None
    measure: str


def stable_id(key: str) -> str:
    """The same ID for the same specified tool on every run."""
    def fnv(seed: int) -> int:
        h = seed
        for b in key.encode():
            h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
        return h
    c = f"{fnv(0xCBF29CE484222325):016X}{fnv(0x84222325CBF29CE4):016X}"
    return f"{c[0:8]}-{c[8:12]}-5{c[13:16]}-A{c[17:20]}-{c[20:32]}"


def shanks(i: Input) -> list[float]:
    """Shank sizes the machine holds with your collets (else the common 1/8" and 1/4")."""
    owned = sorted(c for c in i.inventory.collet_sizes if c <= i.machine.max_shank_diameter + 1e-6)
    return owned if owned else [d for d in (3.175, 6.35) if d <= i.machine.max_shank_diameter + 1e-6]


def length_for_stickout(s: float, m) -> float | None:
    options = sorted([v for v in STANDARD_LENGTHS if v <= m.max_tool_length + 1e-6] + [m.max_tool_length])
    return next((v for v in options if v - MINIMUM_GRIP >= s - 1e-6), None)


def suggested_tool(f: Feature, i: Input):
    """A tool to buy for a cut nothing in the library does: the largest common end mill through the
    opening, on a shank you have a collet for, long enough, within the machine's limits."""
    from ..inventory.catalogs import ToolCatalog
    from ..inventory.items import Tool
    sh = shanks(i)
    if not sh:
        return None
    max_shank = max(sh)
    limit = f.hole - 0.1 - 1e-6 if f.hole is not None else f.opening - 0.02 if f.opening is not None else math.inf
    fits = [d for d in STANDARD_SIZES if d <= min(limit, max_shank) + 1e-9]
    if not fits:
        return None
    d = max(fits)
    shank = next((s for s in sh if s >= d - 1e-6), d)
    reach_length = float(math.ceil(f.wall_depth + 0.5))
    stick = math.ceil(max(f.holder_depth, reach_length) * 2) / 2
    oal = length_for_stickout(stick, i.machine)
    if oal is None:
        return None
    neck = reach_length > 3 * d + 1e-6
    through = f" through {mm(f.opening, 0.1)} mm" if f.opening is not None else ""
    t = Tool.make(f"{size(d)} flat end mill, {mm(reach_length)} mm {'reach' if neck else 'flutes'}", ToolKind.FLAT_END_MILL,
                  d, shank, 3, reach_length, stick, oal,
                  id=stable_id(f"endmill|{_swift(d)}|{_swift(shank)}|{_swift(reach_length)}|{_swift(oal)}"),
                  vendor="Long reach (reduced neck), e.g. Harvey Tool" if neck else "", tool_material=ToolMaterial.CARBIDE,
                  coating=Coating.NONE, intended_for="Aluminium", quantity=0, condition=Condition.NEW,
                  notes=f"Coastline suggests it for a cut {mm(f.wall_depth, 0.1)} mm deep{through}. Pick the nearest real tool from a catalogue and check its sizes here.",
                  source=ToolCatalog.SOURCE)
    r = reach(t, f.opening, f.wall_depth, f.holder_depth, f.hole, i.machine, i.inventory)
    return None if r.verdict == Verdict.CANNOT else t


def suggested_thread_mill(minor: float, depth: float, i: Input):
    from ..inventory.catalogs import ToolCatalog
    from ..inventory.items import Tool
    sh = shanks(i)
    if not sh:
        return None
    fits = [d for d in STANDARD_SIZES if d <= min(minor - 1, max(sh)) + 1e-9]
    if not fits:
        return None
    d = max(fits)
    shank = next((s for s in sh if s >= d - 1e-6), d)
    reach_ = float(math.ceil(depth + 1))
    stick = math.ceil((depth + 1) * 2) / 2
    oal = length_for_stickout(max(stick, reach_), i.machine)
    if oal is None:
        return None
    return Tool.make(f"Single-profile thread mill, {size(d)} head, {mm(reach_)} mm reach", ToolKind.THREAD_MILL, d, shank, 1,
                     reach_, max(stick, reach_), oal,
                     id=stable_id(f"threadmill|{_swift(d)}|{_swift(shank)}|{_swift(reach_)}|{_swift(oal)}"),
                     vendor="", tool_material=ToolMaterial.CARBIDE, coating=Coating.NONE, intended_for="Aluminium", quantity=0,
                     condition=Condition.NEW,
                     notes=f"Coastline suggests it for a thread with a {mm(minor, 0.1)} mm hole, {mm(depth, 0.1)} mm deep. Single-profile: one tool for many pitches.",
                     source=ToolCatalog.SOURCE)


def spec(t) -> str:
    """The sizes that matter when buying a tool, in one line."""
    reach_word = "reach" if t.kind is ToolKind.THREAD_MILL or t.flute_length > 3 * t.diameter else "flutes"
    return (f"{t.name}: {mm(t.diameter, 0.01)} mm cutter, {size(t.shank_diameter)} shank, {mm(t.flute_length, 0.1)} mm {reach_word}, "
            f"{mm(t.overall_length, 0.1)} mm long, set at {mm(t.stickout, 0.1)} mm stick-out")


def feature(f: Feature, i: Input) -> DFMFinding:
    m = i.machine

    def check(t, inv) -> Reach:
        return reach(t, f.opening, f.wall_depth, f.holder_depth, f.hole, m, inv)

    def in_pool(t) -> bool:
        if t.condition is Condition.BROKEN:
            return False
        if t.kind is ToolKind.DRILL:
            return f.hole is not None and abs(t.diameter - f.hole) <= 0.05
        return t.kind in (ToolKind.FLAT_END_MILL, ToolKind.BULL_NOSE_END_MILL)

    pool = [t for t in i.inventory.tools if in_pool(t)]
    owned = [t for t in pool if t.quantity > 0 and not t.is_suggestion]
    results = [(t, check(t, i.inventory)) for t in owned if not t.requires_specification_review]

    def key(e):
        r = rank(e[1])
        return (r, -e[0].diameter, 1 if e[0].kind is ToolKind.BULL_NOSE_END_MILL else 0, len(e[1].warnings),
                e[0].stickout if r <= 1 else -e[0].flute_length, e[0].name)

    candidates = [e for e in results if rank(e[1]) is not None]
    best = min(candidates, key=key) if candidates else None
    collets: list[float] = []
    for t, r in results:
        if r.verdict == Verdict.CANNOT and not has_collet(t, i.inventory) and t.shank_diameter <= m.max_shank_diameter + 1e-6:
            more = copy.copy(i.inventory)
            more.accessories = list(i.inventory.accessories) + [Accessory.make("collet", AccessoryKind.COLLET, size=t.shank_diameter)]
            if check(t, more).verdict != Verdict.CANNOT and not any(abs(c - t.shank_diameter) <= 0.05 for c in collets):
                collets.append(t.shank_diameter)

    def clean_reach(t) -> bool:
        r = check(t, i.inventory)
        return r.verdict == Verdict.REACHES and not r.warnings

    buys = sorted((t for t in pool if (t.quantity <= 0 or t.is_suggestion) and not t.requires_specification_review and clean_reach(t)),
                  key=lambda t: (-t.diameter, t.name))[:2]
    unconfirmed = [t for t in owned if t.requires_specification_review]

    def might(t) -> bool:
        c = copy.copy(t)
        c.unconfirmed_specifications = None
        return check(c, i.inventory).verdict != Verdict.CANNOT

    maybe = [t for t in unconfirmed if might(t)]
    entries = [(t, "; ".join([r.reason] + r.warnings))
               for t, r in sorted(results, key=lambda e: (rank(e[1]) if rank(e[1]) is not None else 9, -e[0].diameter, e[0].name))]
    entries += [(t, "specs not confirmed" + (", might reach" if t in maybe else "")) for t in unconfirmed]
    buy_lines = [f"{label(t)} (not owned): reaches" for t in buys]
    made = suggested_tool(f, i) if not buys else None
    to_buy = buys[0] if buys else made

    def listed(t) -> bool:
        return any(x.id == t.id for x in i.inventory.tools)

    def buy_remedy(t) -> Remedy:
        return Remedy.buy_tool(t.id) if listed(t) else Remedy.add_tool(t)

    def buy_text(t) -> str:
        r = check(t, i.inventory)
        how = "it reaches cleanly" if not r.warnings else f"it reaches ({'; '.join(r.warnings)})"
        return f"Buy the {label(t)}, on your list: {how}." if listed(t) else f"Add a {inline(t.name)} to buy: {how}."

    made_line = [f"Coastline suggests: {spec(made)}."] if made is not None else []
    details: list[str] = []
    fix = None
    remedies: list[Remedy] = []
    deep = mm(f.wall_depth, 0.1)
    collet_fix = "" if not collets else f" Or add a {' and '.join(size(c) for c in collets)} collet."
    if best is not None:
        t, r = best
        stickout = r.stickout if r.verdict == Verdict.NEEDS_STICKOUT else None
        rk = rank(r)
        if rk == 0:
            category = Category.OK
            summary = f"The {label(t)} reaches it."
            details.append(f"{label(t)}: reaches")
        elif rk == 1:
            category = Category.SETUP_CHANGE
            summary = f"The {label(t)} reaches it only with more stick-out: {mm(stickout, 0.1)} mm (now {mm(t.stickout)})."
            fix = f"Set the {label(t)} to stick out {mm(stickout, 0.1)} mm for this cut."
            remedies = [Remedy.set_stickout(t.id, stickout), Remedy.show_tool(t.id)]
            details += lines(entries)
        else:
            category = Category.MISSING_RESOURCE
            rub = "; ".join(r.warnings)
            at = f" at {mm(stickout, 0.1)} mm stick-out" if stickout is not None else ""
            summary = f"The {label(t)} reaches it{at}, but its {rub}."
            if to_buy is not None:
                fix = buy_text(to_buy)
            elif f.opening is not None and f.opening < 20:
                fix = f"Use a tool under {mm(f.opening, 0.01)} mm with {deep} mm of flute."
            else:
                fix = f"Use an end mill with {deep} mm of flute."
            fix += collet_fix
            if to_buy is not None:
                remedies.append(buy_remedy(to_buy))
            if stickout is not None:
                remedies.append(Remedy.set_stickout(t.id, stickout))
            remedies.append(Remedy.show_tool(t.id))
            remedies += [Remedy.buy_tool(b.id) for b in buys[1:]] + [Remedy.add_collet(c) for c in collets]
            details += lines(entries) + buy_lines + made_line
    else:
        details += lines(entries) + buy_lines
        too_narrow = (f.opening if f.opening is not None else math.inf) < 0.5
        too_deep = f.holder_depth > m.max_tool_length - MINIMUM_GRIP + 1e-6
        closest = next((e for e in results if not any(e[1].reason.startswith(p) for p in ("too wide", "doesn't cut", "a drill only", "marked broken"))), None)
        why = f" The {label(closest[0])}: {closest[1].reason}." if closest else ""
        if too_narrow or too_deep:
            category = Category.NOT_SUPPORTED
            summary = (f"Too narrow for any tool ({mm(f.opening, 0.01)} mm)." if too_narrow
                       else f"No tool this machine can hold reaches it: it needs {mm(f.holder_depth, 0.1)} mm stick-out.")
            fix = f"Change the design: make it {'wider' if too_narrow else 'shallower'}."
            details.append(f"Longest tool: {mm(m.max_tool_length)} mm, with {mm(MINIMUM_GRIP)} mm in the collet.")
        else:
            remedies = (([buy_remedy(to_buy)] if to_buy is not None else []) + [Remedy.buy_tool(b.id) for b in buys[1:]]
                        + [Remedy.add_collet(c) for c in collets] + [Remedy.show_tool(t.id) for t in maybe])
            details += made_line
            if maybe and not buys and not collets:
                category = Category.MISSING_INFORMATION
                summary = f"Only the {label(maybe[0])} might reach it. Confirm its specs first."
                fix = f"Measure the {label(maybe[0])} and confirm its specs in Tools."
            elif to_buy is not None:
                category = Category.MISSING_RESOURCE
                where = f"{mm(f.opening, 0.1)} mm wide and {deep} mm deep" if f.opening is not None else f"{deep} mm deep"
                summary = f"None of your tools reaches it ({where}). One that fits this machine does." + why
                fix = buy_text(to_buy) + collet_fix
            else:
                category = Category.MISSING_RESOURCE
                if f.hole is not None:
                    summary = f"Needs a {mm(f.hole)} mm drill, or a smaller end mill, that reaches {deep} mm." + why
                    fix = f"Get a {mm(f.hole)} mm drill with {deep} mm of flute that fits this machine." + collet_fix
                elif f.opening is not None:
                    summary = f"Needs a tool under {mm(f.opening, 0.01)} mm that reaches {deep} mm." + why
                    fix = f"Get an end mill under {mm(f.opening, 0.01)} mm that reaches {deep} mm (long neck), or widen it." + collet_fix
                else:
                    summary = f"Needs an end mill that reaches {deep} mm." + why
                    fix = f"Get an end mill with {deep} mm of flute." + collet_fix
    return DFMFinding(f.id, category, f.title, summary, details, list(f.faces), remedies, f.measure, fix)


def lines(entries) -> list[str]:
    """'1/8" flat: reaches' lines; a size and kind with different answers lists each tool."""
    order: list[str] = []
    groups: dict[str, list] = {}
    for t, text in entries:
        k = short_label(t)
        if k not in groups:
            order.append(k)
            groups[k] = []
        groups[k].append((t, text))
    out: list[str] = []
    for k in order:
        g = groups[k]
        if len({text for _, text in g}) == 1:
            out.append(f"{k}: {g[0][1]}")
        else:
            for t, text in g:
                line = f"{label(t)}: {text}"
                if line not in out:
                    out.append(line)
    return out


# ---------------------------------------------------------------- access regions

def profile_depth(access: PartAccess, i: Input) -> float:
    """How deep the outside walls go: the whole part, or with both sides machined, the deeper of
    the two halves at the split (side B cuts a little past it)."""
    top, bottom = access.part_max[2], access.part_min[2]
    if not i.two_sided:
        return top - bottom
    pz = i.analysis.parting_z if i.analysis.parting_z is not None else (top + bottom) / 2
    split = min(max(pz, bottom), top)
    return max(top - split, split - bottom) + 0.3


def floor_kind(f, long: bool) -> str:
    e = f.enclosed
    if e is None or e >= 0.95:
        return "Slot" if long else "Pocket"
    if e >= 0.5:
        return "Open slot" if long else "Open pocket"
    return "Step"


def opening(r, side: str) -> float | None:
    """The widest cutter that goes in from a side: the region's narrower size across that side."""
    k = {"x": 0, "y": 1, "z": 2}.get(side[1:], 2)
    s = [r.max[j] - r.min[j] for j in range(3)]
    w = min(s[j] for j in range(3) if j != k)
    return w if w >= 1 else None


def needed(r, i: Input) -> list:
    return [s for s in (r.sides_two if i.two_sided else r.sides) if s.side != "+z"]


def region_groups(regions: list, i: Input) -> list[list]:
    """Regions deepest first; one bore seen through several windows (the same cross-section,
    reached deepest from the same side) is one group, judged at its deepest."""
    def deepest(r):
        n = needed(r, i)
        return max(n, key=lambda s: s.depth) if n else None

    order = sorted(regions, key=lambda r: -(deepest(r).depth if deepest(r) is not None else 0))
    groups: list[list] = []
    for r in order:
        d = deepest(r)
        k = {"x": 0, "y": 1, "z": 2}.get(d.side[1:]) if d is not None else None
        target = None
        if r.thread is None and r.access is not Access.NO_ACCESS and d is not None and k is not None:
            for gi, g in enumerate(groups):
                first = g[0]
                if first.thread is not None or first.access is Access.NO_ACCESS:
                    continue
                fd = deepest(first)
                if fd is None or fd.side != d.side:
                    continue
                if all(abs(first.min[j] - r.min[j]) <= 0.1 and abs(first.max[j] - r.max[j]) <= 0.1 for j in range(3) if j != k):
                    target = gi
                    break
        if target is not None:
            groups[target].append(r)
        else:
            groups.append([r])
    return groups


def region(r, i: Input) -> DFMFinding | None:
    rid = f"region-{r.faces[0] if r.faces else -1}"
    if r.thread is not None:
        return cut([r.thread.sides[0].side if r.thread.sides else "+z"], thread(r.thread, r, rid, i))
    s = [r.max[j] - r.min[j] for j in range(3)]
    area = f"{dims(s)} mm area"
    if r.access is Access.THIS_SIDE:
        return None
    if r.access is Access.NO_ACCESS:
        return DFMFinding(rid, Category.NOT_SUPPORTED, "No straight path for the tool",
                          "No straight line from the 6 main directions reaches these faces.",
                          ["Only the six main directions are checked. Special cutters (T-slot, lollipop) are not."],
                          list(r.faces), [], area, "Change the design so the tool can get in, or plan it by hand.")
    need = needed(r, i)
    if not need:
        return cut(["-z"] if r.access is Access.OPPOSITE_SIDE else list(r.directions[:1]), legacy_region(r, rid, area, i))
    every = [x.side for x in (r.sides_two if i.two_sided else r.sides)]
    return cut((["+z"] if "+z" in every else []) + [x.side for x in need], side_region(r, need, rid, i))


def side_region(r, need: list, rid: str, i: Input) -> DFMFinding:
    """Faces the front doesn't reach: which sides do, and whether an owned tool reaches from there."""
    checks = []
    for s in need:
        w = opening(r, s.side)
        checks.append((s, w, feature(Feature(rid, "", list(r.faces), w, s.depth, s.depth + 1, None, ""), i)))
    worst = min(checks, key=lambda c: c[2].category)
    back = len(need) == 1 and need[0].side == "-z"
    names = [side_words(s.side) for s in need]
    lst = names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]
    title = "Cut from the back" if back else f"Cut from the {names[0]}" if len(need) == 1 else f"Cut from {len(need)} sides"
    if back:
        setup_fix = "Check side B in Setups." if i.two_sided else "Add a back-side setup: turn the part over in Setups."
        way = "Side B gets to it." if i.two_sided else "The tool can't reach it from the front, only from the back."
    elif len(need) == 1:
        setup_fix = f"Add a setup with the {names[0]} toward the spindle, in Setups."
        way = f"The tool can only get in from the {names[0]}."
    else:
        setup_fix = f"Add setups with the {lst} toward the spindle, in Setups."
        way = f"No one side reaches all of it: it needs the {lst}."
    measure = ". ".join(f"From the {side_words(c[0].side)}: {mm(c[0].depth, 0.1)} mm deep" + (f", {mm(c[1], 0.1)} mm wide" if c[1] is not None else "")
                        for c in checks) + "."
    details = [f"{side_words(c[0].side).title()}: {c[2].summary}" for c in checks] if len(checks) > 1 else list(worst[2].details)
    details.append("Holding on side B is not checked." if back and i.two_sided else "Holding from there is not checked.")
    where = f"From the {side_words(worst[0].side)}: " if len(checks) > 1 else ""

    def lower_first(t: str) -> str:
        return t if not where else t[:1].lower() + t[1:]

    wf = worst[2]
    if wf.category in (Category.OK, Category.SETUP_CHANGE):
        return DFMFinding(rid, Category.SETUP_CHANGE, title, f"{way} {where}{lower_first(wf.summary)}", details, list(r.faces),
                          [Remedy.review_setups()] + wf.remedies, measure, " ".join(x for x in (setup_fix, wf.fix) if x is not None))
    deep = wf.category is Category.NOT_SUPPORTED
    why = "No tool this machine can hold reaches that deep." if deep and (worst[1] if worst[1] is not None else 1) >= 0.5 else wf.summary
    if deep:
        fix = f"{wf.fix} Or open it up so a shorter tool gets in." if wf.fix is not None else setup_fix
    else:
        fix = " ".join(x for x in (wf.fix, setup_fix) if x is not None)
    return DFMFinding(rid, wf.category, f"Too deep from the {side_words(worst[0].side)}" if deep else title,
                      f"{way} {where}{lower_first(why)}", details, list(r.faces), wf.remedies + [Remedy.review_setups()], measure, fix)


def legacy_region(r, rid: str, measure: str, i: Input) -> DFMFinding:
    """Without the engine's side depths: the access alone, reach not checked."""
    if r.access is Access.OPPOSITE_SIDE:
        return DFMFinding(rid, Category.SETUP_CHANGE, "Needs the back side",
                          "Side B is planned for these faces. Its holding and tool reach are not checked yet." if i.two_sided
                          else "The tool can't reach these faces from the front. Holding and tool reach from the back are not checked yet.",
                          ["Turning the part over alone doesn't prove it can be cut."], list(r.faces), [Remedy.review_setups()], measure,
                          "Check side B in Setups." if i.two_sided else "Add a back-side setup: turn the part over in Setups.")
    frm = " or the ".join(side_name(d) for d in r.directions)
    return DFMFinding(rid, Category.SETUP_CHANGE, "Needs another position",
                      "The tool can't get in from the front or the back." if not frm else f"The tool can only get in from the {frm}.",
                      ["Holding and tool reach from there are not checked."], list(r.faces), [Remedy.review_setups()], measure,
                      "Add a setup with the part turned, in Setups." if not frm else f"Add a setup with the {frm} toward the spindle, in Setups.")


def thread(t, r, rid: str, i: Input) -> DFMFinding:
    """A modelled thread: cut along its axis from an open end, with a thread mill that fits the
    hole and reaches its far end (or tapped by hand)."""
    from .part_analysis import ThreadEnd
    end = t.sides[0] if t.sides else ThreadEnd("+z", t.length, True)
    name = "front" if end.side == "+z" else side_words(end.side)
    title = f"Thread {mm(t.major, 0.1)} mm, {mm(t.length, 0.1)} long"
    measure = f"{mm(t.minor, 0.1)} to {mm(t.major, 0.1)} mm across, {mm(t.length, 0.1)} mm long, {mm(end.depth, 0.1)} mm in from the {name}."
    mills = [x for x in i.inventory.tools if x.kind is ToolKind.THREAD_MILL and x.quantity > 0 and not x.is_suggestion
             and x.condition is not Condition.BROKEN]
    fits = [x for x in mills if x.diameter < t.minor - 0.05]

    def chk(x) -> Reach:
        return reach(x, t.minor, end.depth, end.depth + 1, None, i.machine, i.inventory)

    checked = [(x, chk(x)) for x in fits]
    reaches = sorted((e for e in checked if e[1].verdict != Verdict.CANNOT),
                     key=lambda e: (0 if e[1].verdict == Verdict.REACHES else 1, -e[0].diameter))
    details = ["Its peaks hide each other, so the check finds it by its shape.",
               "The pitch is not read from the model. Check it on the drawing.",
               f"Make the {mm(t.minor, 0.1)} mm hole first."]
    if not end.open:
        details.append("Neither end reaches the outside. The way in is not checked.")
    setup_fix = None if end.side == "+z" else f"Add a setup with the {name} toward the spindle, in Setups."
    if not reaches:
        if not mills:
            details.append("You have no thread mills.")
        else:
            details += [f"{label(x)}: " + (f"too wide for the {mm(t.minor, 0.1)} mm hole" if x.diameter >= t.minor - 0.05
                                            else f"doesn't reach {mm(end.depth, 0.1)} mm") for x in mills]
        listed = next((x for x in i.inventory.tools if x.kind is ToolKind.THREAD_MILL and x.quantity <= 0
                       and x.condition is not Condition.BROKEN and x.diameter < t.minor - 0.05 and chk(x).verdict != Verdict.CANNOT), None)
        buy = listed or suggested_thread_mill(t.minor, end.depth, i)
        remedies: list[Remedy] = []
        fix = f"Get a thread mill smaller than the {mm(t.minor, 0.1)} mm hole that reaches {mm(end.depth, 0.1)} mm, or tap it by hand."
        if buy is not None:
            on_list = any(x.id == buy.id for x in i.inventory.tools)
            remedies.append(Remedy.buy_tool(buy.id) if on_list else Remedy.add_tool(buy))
            fix = (f"Buy the {inline(buy.name)}, on your list. Or tap it by hand." if on_list
                   else f"Add a {inline(buy.name)} to buy. Or tap it by hand.")
            if not on_list:
                details.append(f"Coastline suggests: {spec(buy)}.")
        if setup_fix is not None:
            remedies.append(Remedy.review_setups())
        return DFMFinding(rid, Category.MISSING_RESOURCE, title,
                          f"Cut from the {name}. None of your thread mills fits and reaches it." + ("" if buy is None else " One that fits this machine does."),
                          details, list(r.faces), remedies, measure, fix + (f" {setup_fix}" if setup_fix else ""))
    tool, rr = reaches[0]
    remedies = [] if setup_fix is None else [Remedy.review_setups()]
    fix = setup_fix
    if rr.verdict == Verdict.NEEDS_STICKOUT:
        remedies.append(Remedy.set_stickout(tool.id, rr.stickout))
        fix = " ".join(x for x in (fix, f"Set the {label(tool)} to stick out {mm(rr.stickout, 0.1)} mm.") if x is not None)
    return DFMFinding(rid, Category.OK if setup_fix is None and fix is None else Category.SETUP_CHANGE, title,
                      f"Cut from the {name} with the {label(tool)}.", details, list(r.faces), remedies, measure, fix)


# ---------------------------------------------------------------- corners, curves, thin walls

def shape_findings(i: Input) -> list[DFMFinding]:
    from .operation import OperationPlanner
    a = i.analysis
    usable = OperationPlanner.usable_tools(i.inventory, machine=i.machine)
    out: list[DFMFinding] = []
    if a.min_corner_radius is not None:
        r = a.min_corner_radius
        title = f"Inside corners R{mm(r)} mm"
        flats = [t for t in usable if t.kind in (ToolKind.FLAT_END_MILL, ToolKind.BULL_NOSE_END_MILL) and t.diameter <= 2 * r * 0.98]
        buy = [d for d in STANDARD_SIZES if d <= 2 * r * 0.98]
        if flats:
            t = max(flats, key=lambda t: t.diameter)
            out.append(DFMFinding("corner", Category.OK, title, f"The {label(t)} fits the tightest corner."))
        elif buy:
            out.append(DFMFinding("corner", Category.MISSING_RESOURCE, title,
                                  "None of your end mills is small enough for the tightest inside corner.",
                                  fix=f"Get a {size(max(buy))} or smaller end mill, or accept rounder corners."))
        else:
            out.append(DFMFinding("corner", Category.NOT_SUPPORTED, title, "Too tight for any end mill.",
                                  fix="Round the inside corners to at least R0.3 mm."))
    if a.min_concave_radius is not None:
        r = a.min_concave_radius
        title = f"Curves down to R{mm(r)} mm"
        balls = [t for t in usable if t.kind is ToolKind.BALL_END_MILL and t.diameter / 2 <= r * 0.98]
        if balls:
            t = max(balls, key=lambda t: t.diameter)
            out.append(DFMFinding("concave", Category.OK, title, f"The {label(t)} fits them."))
        else:
            buy = [d for d in STANDARD_SIZES if d / 2 <= r * 0.98]
            out.append(DFMFinding("concave", Category.MISSING_RESOURCE, title,
                                  "None of your ball end mills is small enough for a clean finish there.",
                                  fix=f"Get a {size(max(buy)) if buy else 'under 0.5 mm'} or smaller ball end mill."))
    w = a.thinnest_wall
    if w is not None and 0.1 <= w < 0.5:  # below 0.1 mm the slice search is at its limit
        out.append(DFMFinding("thin", Category.MISSING_INFORMATION, f"Thin wall, about {mm(w)} mm",
                              "Rough measure. Strength is not checked.", fix="Check it can take the cutting load, or make it thicker."))
    return out


def tool_findings(i: Input) -> list[DFMFinding]:
    """Owned tools OperationPlanner leaves out, with why. Broken tools are skipped."""
    from .operation import OperationPlanner
    m = i.machine
    usable = {t.id for t in OperationPlanner.usable_tools(i.inventory, machine=m)}
    blocked, unconfirmed = [], []
    collets: list[float] = []
    shown: list[str] = []
    for t in i.inventory.tools:
        if not (t.quantity > 0 and not t.is_suggestion and t.condition is not Condition.BROKEN and t.id not in usable):
            continue
        if t.requires_specification_review or _tool_issues(t):
            fields = ", ".join(t.unconfirmed_specifications or [])
            unconfirmed.append((t, "confirm its specs" + (f" ({fields})" if fields else "")))
            continue
        why = []
        if t.shank_diameter > m.max_shank_diameter + 1e-6:
            why.append(f"shank over the {m.collet_name} limit ({mm(m.max_shank_diameter)} mm)")
        if t.overall_length > m.max_tool_length + 1e-6:
            why.append(f"{mm(t.overall_length)} mm long, over the {mm(m.max_tool_length)} mm limit")
        needs_collet = t.shank_diameter <= m.max_shank_diameter + 1e-6 and not has_collet(t, i.inventory)
        if needs_collet:
            why.append(f"no collet for its {size(t.shank_diameter)} shank")
            if not any(abs(c - t.shank_diameter) <= 0.05 for c in collets):
                collets.append(t.shank_diameter)
        if not why:
            continue
        if len(why) > (1 if needs_collet else 0):
            shown.append(t.id)
        blocked.append((t, "; ".join(why)))
    out = []
    if blocked:
        n = len(blocked)
        cs = sorted(collets)
        out.append(DFMFinding("tools", Category.MISSING_RESOURCE, "Tools you can't use",
                              f"{n} owned tool{'' if n == 1 else 's'} can't be used: no collet or over the machine's limits.",
                              lines(blocked), remedies=[Remedy.add_collet(c) for c in cs] + [Remedy.show_tool(s) for s in shown],
                              fix="They don't fit this machine. Use other tools." if not collets
                              else f"Add a {' and '.join(size(c) for c in cs)} collet to use {'that size' if len(collets) == 1 else 'those sizes'}."))
    if unconfirmed:
        n = len(unconfirmed)
        out.append(DFMFinding("tools-info", Category.MISSING_INFORMATION, "Tool specs not confirmed",
                              f"{n} owned tool{' needs its' if n == 1 else 's need their'} specs confirmed before CAM.",
                              lines(unconfirmed), remedies=[Remedy.show_tool(t.id) for t, _ in unconfirmed],
                              fix="Measure them and confirm their specs in Tools."))
    return out


class DFM:
    """Namespace matching the Swift `DFM` enum for callers that use it that way."""

    side_words = staticmethod(side_words)
    side_name = staticmethod(side_name)
    mm = staticmethod(mm)
    size = staticmethod(size)
    dims = staticmethod(dims)
    label = staticmethod(label)
    short_label = staticmethod(short_label)
    reach = staticmethod(reach)
    assess = staticmethod(assess)
    MINIMUM_GRIP = MINIMUM_GRIP
    NOT_CHECKED = NOT_CHECKED
