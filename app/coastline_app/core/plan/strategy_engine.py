"""The smart planner: enumerate the sensible plans the inventory allows, cost each with models of
time, finish and risk, keep the Pareto front, and explain every choice. Generated toolpaths feed
real times back (`Calibration`). Port of Plan/StrategyEngine.swift."""

from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field

from ..codable import jfield
from ..feeds import OperationKind as K
from ..geometry import swift_round
from ..ids import new_id
from ..units import Length
from .operation import DEFAULT_MIN_POCKET, Operation, OperationPlanner

UNMADE_HOLE_FINISH = 200.0  # the finish (µm) a plan scores when it leaves holes out


@dataclass
class Facts:
    analysis: object  # PartAnalysis
    part: tuple  # part size in the work frame (X up, Y across, Z toward the spindle)
    stock: tuple
    material: object
    face_depth: float = 0.25
    hole_diameters: list[float] = field(default_factory=list)
    has_floors: bool = False
    pocket_widths: list[float] = field(default_factory=list)  # pockets in the outline (inscribed widths)
    floor_widths: list[float] = field(default_factory=list)
    floor_depths: list[float] = field(default_factory=list)
    cut_depth: float | None = None  # the deepest any side cuts below its material top

    @property
    def freeform(self) -> bool:
        return self.analysis.freeform_area > 1

    @property
    def steep_fraction(self) -> float:
        a = self.analysis
        return min(a.steep_area / a.freeform_area, 1) if a.freeform_area > 0 else 0.0

    @property
    def silhouette_area(self) -> float:
        p = self.part
        r = max(p[0], p[1]) / 2
        disc = self.analysis.circularity * math.pi * r * r if self.analysis.circularity > 0 else p[0] * p[1] * 0.8
        return min(disc, p[0] * p[1])

    @property
    def perimeter(self) -> float:
        return math.pi * (self.part[0] + self.part[1]) / 2


@dataclass
class Calibration:
    """Per-kind multipliers that turn the model's minutes into simulated minutes (learned)."""

    factor: dict[str, float] = jfield(default_factory=dict)

    def apply(self, kind, minutes: float) -> float:
        return minutes * self.factor.get(kind.value, 1.0)

    def learn(self, kind, estimated: float, simulated: float) -> None:
        """Moves the factor toward the observed ratio (exponential average)."""
        if not (estimated > 0.05 and simulated > 0):
            return
        ratio = min(max(simulated / estimated, 0.25), 4)
        old = self.factor.get(kind.value, 1.0)
        self.factor[kind.value] = old * 0.6 + ratio * 0.4


@dataclass
class Remedy:
    """A change that makes a plan less risky: ("finerRoughing",), ("slower", tool_id, pace) or ("swap", from, to)."""

    title: str
    change: tuple


@dataclass
class Candidate:
    name: str
    operations: list
    minutes_by_op: dict[str, float]
    minutes: float
    finish: float  # worst expected cusp on the finished surfaces, µm
    risk: float  # 0 (comfortable) … 1 (asking for trouble)
    reasons: list[str]
    tools: list
    remedies: list[Remedy] = field(default_factory=list)
    id: str = field(default_factory=new_id)

    @property
    def needs_tools(self) -> list:
        return [t for t in self.tools if t.is_suggestion]

    @property
    def signature(self) -> str:
        """The passes and their tools as one key: two plans that cut the same way share it."""
        out = []
        for op in self.operations:
            name = next((t.name for t in self.tools if t.id == op.tool_id), "") if op.tool_id is not None else ""
            out.append(op.kind.value + ":" + name + ("(pockets)" if op.pockets_only is True else ""))
        return " ".join(out)


def pool(cs: list[Candidate], score, tolerance: float = 0.1) -> list[Candidate]:
    """The candidates whose score is within `tolerance` of the best."""
    if not cs:
        return []
    best = min(score(c) for c in cs)
    return [c for c in cs if score(c) <= best + abs(best) * tolerance + 1e-9]


def pick(cs: list[Candidate], score, tolerance: float = 0.1) -> Candidate | None:
    """The lowest score; scores within `tolerance` count as equal, then the better finish, the lower
    risk, fewer tools, then the passes and tools by name."""
    p = pool(cs, score, tolerance)
    return min(p, key=lambda c: (c.finish, c.risk, len(c.tools), c.signature, c.minutes)) if p else None


def apply(r: Remedy, ops: list) -> list:
    out = []
    for op in ops:
        op = op.copy()
        kind = r.change[0]
        if kind == "finerRoughing":
            if op.kind is K.ADAPTIVE:
                op.stepdown_override = 1.0
                op.leave_axial = 0.15
        elif kind == "slower":
            if op.tool_id == r.change[1]:
                op.feed_scale = min(op.feed_scale, r.change[2])
        elif kind == "swap":
            if op.tool_id == r.change[1]:
                op.tool_id = r.change[2]
        out.append(op)
    return out


# ---------------------------------------------------------------- search

def candidates(facts: Facts, inventory, calibration: Calibration | None = None, include_suggestions: bool = False,
               machine=None) -> list[Candidate]:
    from ..inventory.items import ToolKind
    from ..machine.profile import MachineProfile
    calibration = calibration or Calibration()
    machine = machine or MachineProfile.standard()
    tools = OperationPlanner.usable_tools(inventory, include_suggestions=include_suggestions, machine=machine)
    flats = sorted((t for t in tools if t.kind is ToolKind.FLAT_END_MILL), key=lambda t: -t.diameter)
    roughers = [t for t in flats if 1.5 <= t.diameter <= 6.36][:2]
    if not roughers:
        return []
    a = facts.analysis
    concave = a.min_concave_radius if a.min_concave_radius is not None else math.inf
    balls = sorted((t for t in tools if t.kind is ToolKind.BALL_END_MILL or (t.kind is ToolKind.BULL_NOSE_END_MILL and t.corner_radius > 0.2)),
                   key=lambda t: -t.diameter)
    fitting = [b for b in balls if b.diameter / 2 <= concave + 1e-6 and b.diameter <= 6.36]
    finishers: list = []
    for b in [b for b in balls if 1.5 <= b.diameter <= 6.36][:2] + fitting[:1] + balls[-1:]:
        if not any(abs(f.diameter - b.diameter) < 0.05 for f in finishers) and len(finishers) < 2:
            finishers.append(b)
    strategies = [K.STEEP_SHALLOW, K.SCALLOP, K.PARALLEL]
    if a.circularity > 0.65:
        strategies.append(K.SPIRAL)
    cusps = [0.004, 0.008, 0.015]
    steps = [None, 1.0] if facts.freeform else [None]
    out: list[Candidate] = []
    for rougher in roughers:
        for step in steps:
            if not facts.freeform or not finishers:
                out.append(build(facts, tools, rougher, step, None, None, 0.008, None, calibration, machine))
                continue
            for ball in finishers:
                smaller = next((b for b in balls if b.diameter < ball.diameter - 0.4), None)
                for strategy in strategies:
                    for cusp in cusps:
                        for rest in ([None, smaller] if smaller is not None else [None]):
                            out.append(build(facts, tools, rougher, step, ball, strategy, cusp, rest, calibration, machine))
    return out


def pareto(cs: list[Candidate], tolerance: float = 0.1) -> list[Candidate]:
    """The candidates no other beats on time, finish and risk together (times within `tolerance`
    count as equal)."""
    out = []
    for c in cs:
        band = abs(c.minutes) * tolerance + 1e-9
        beaten = any(o.id != c.id and o.minutes <= c.minutes + band and o.finish <= c.finish and o.risk <= c.risk
                     and (o.minutes < c.minutes - band or o.finish < c.finish or o.risk < c.risk) for o in cs)
        if not beaten:
            out.append(c)
    return out


def recommend(cs: list[Candidate]) -> list[Candidate]:
    """Three plans: the fastest acceptable one, the finest, and the knee of the front between them."""
    front = [c for c in pareto(cs) if c.risk < 0.6]
    if any(c.finish < UNMADE_HOLE_FINISH for c in front):
        front = [c for c in front if c.finish < UNMADE_HOLE_FINISH]
    if not front:
        q = pick(cs, lambda c: c.minutes)
        if q is None:
            return []
        q = copy.copy(q)
        q.name = "Quickest (risky)"
        return [q]
    t_min, t_max = min(c.minutes for c in front), max(c.minutes for c in front)
    f_min, f_max = min(c.finish for c in front), max(c.finish for c in front)

    def norm(v, lo, hi):
        return 0 if hi - lo < 1e-9 else (v - lo) / (hi - lo)

    fastest = pick([c for c in front if c.finish <= 20], lambda c: c.minutes * (1 + c.risk)) or pick(front, lambda c: c.minutes * (1 + c.risk))
    finest = pick([c for c in front if c.finish <= f_min + 1e-9], lambda c: c.minutes)
    balanced = pick(front, lambda c: norm(c.minutes, t_min, t_max) + norm(c.finish, f_min, f_max) + c.risk * 0.5)
    picks: list[Candidate] = []
    for c in (fastest, balanced, finest):
        if not any([o.kind for o in p.operations] == [o.kind for o in c.operations] and abs(p.minutes - c.minutes) < 0.5 and p.finish == c.finish
                   for p in picks):
            picks.append(copy.copy(c))
    picks.sort(key=lambda c: (c.minutes, -c.finish))
    for p in picks:
        p.name = "Balanced"
    if len(picks) > 1:
        picks[0].name = "Fastest"
        f = min(range(1, len(picks)), key=lambda k: (picks[k].finish, picks[k].minutes))
        picks[f].name = "Finest"
    return picks


# ---------------------------------------------------------------- one candidate

def build(f: Facts, tools: list, rougher, step: float | None, finisher3d, strategy, cusp: float, rest, calibration: Calibration,
          machine) -> Candidate:
    from ..inventory.catalogs import ToolCatalog
    from ..inventory.checks import InventoryChecks, Severity
    from ..inventory.inventory import Inventory
    from ..inventory.items import ToolKind
    from ..materials import Difficulty
    a, m = f.analysis, f.material
    ops: list = []
    minutes: dict[str, float] = {}
    reasons: list[str] = []
    remedies: list[Remedy] = []
    state = {"risk": 0.0, "finish": 0.0}

    def add(op, est: float) -> None:
        ops.append(op)
        minutes[op.id] = calibration.apply(op.kind, est)

    depth = max(f.part[2] + f.face_depth, 0.5)
    # Small tools go all the way down narrow pockets: they need the reach. A same-size tool that
    # reaches (owned first) is used instead; if there's none, it's a risk, with a long-reach one to buy.
    checked: dict[str, object] = {}

    def reaching(t):
        if t.id in checked:
            return checked[t.id]
        cd = f.cut_depth
        if cd is None or not t.flute_length < cd - 0.05:
            checked[t.id] = t
            return t
        same = [x for x in tools if x.kind is t.kind and abs(x.diameter - t.diameter) < 0.05 and x.flute_length >= cd - 0.05]
        if same:
            r = min(same, key=lambda x: (1 if x.is_suggestion else 0, x.flute_length))
            reasons.append(f"The cuts go {Length.mm(cd)} mm deep on a side: the {r.name} reaches that far{' (to buy)' if r.is_suggestion else ''}.")
            checked[t.id] = r
            return r
        state["risk"] += 0.2
        reasons.append(f"Risk: the cuts go {Length.mm(cd)} mm deep on a side, the {t.name} has {Length.mm(t.flute_length)} mm of flute: its shank rubs the walls.")
        buy = next((x for x in ToolCatalog.suggestions() if x.kind is t.kind and abs(x.diameter - t.diameter) < 0.05
                    and x.flute_length >= cd - 0.05
                    and all(i.severity < Severity.ERROR for i in InventoryChecks.check_tool(x, Inventory(), machine))), None)
        if buy is not None:
            remedies.append(Remedy(f"Use the {buy.name} (not owned): it reaches {Length.mm(buy.flute_length)} mm", ("swap", t.id, buy.id)))
        checked[t.id] = t
        return t

    rougher = reaching(rougher)  # its flutes reach the depth too (no shank rubbing)

    # Facing.
    if f.face_depth > 1e-6:
        face = Operation(K.FACING, tool_id=rougher.id, face_depth=f.face_depth)
        fd = face.cutting_data(rougher, m, machine)
        passes = max(1, math.ceil(f.face_depth / max(fd.stepdown, 0.05)))
        add(face, f.stock[0] * f.stock[1] / max(fd.stepover, 0.1) * passes / max(fd.feed, 1) * 1.1)
    else:
        reasons.append("Zero face allowance: keep the existing stock face, with no facing operation.")

    # Roughing: the band around the part plus what's above its curved top.
    rough = Operation(K.ADAPTIVE, tool_id=rougher.id, leave_radial=0.2, leave_axial=0.1 if step is None else 0.15)
    rough.stepdown_override = step
    rd = rough.cutting_data(rougher, m, machine)
    band = f.perimeter * (rougher.diameter + 1)
    above = max(f.silhouette_area * f.part[2] - a.volume, 0)
    volume = band * depth + above
    ap = min(rd.stepdown, depth)
    add(rough, volume / max(rd.feed * rd.stepover * ap, 1) * 1.35 + depth / ap * 0.15)
    stiff = ": the largest end mill you can hold, so the fastest and stiffest" if rougher.diameter >= 6 else ""
    how = f"deep steps ({Length.mm(ap)} mm) along the flute" if step is None else "1 mm steps so the ball finisher meets small terraces"
    reasons.append(f"Roughing with the {rougher.name}{stiff}, {how}.")
    if f.freeform and step is None and finisher3d is not None and finisher3d.diameter < 3.5:
        state["risk"] += 0.25
        reasons.append(f"Risk: deep roughing steps leave terraces up to {Length.mm(ap)} mm high for a {Length.mm(finisher3d.diameter)} mm ball to clean.")
        remedies.append(Remedy("Rough in 1 mm steps (small terraces, a little slower)", ("finerRoughing",)))

    # Pockets too narrow for the rougher: roughed with smaller end mills, each taking the pockets
    # the one before couldn't (the smallest takes all it fits).
    flats = sorted((t for t in tools if t.kind is ToolKind.FLAT_END_MILL), key=lambda t: -t.diameter)
    left = [w for w in f.pocket_widths if w < DEFAULT_MIN_POCKET * rougher.diameter]
    pocket_tools: list = []
    for cand in flats:
        if not (cand.diameter < (pocket_tools[-1] if pocket_tools else rougher).diameter - 0.5 and cand.diameter >= 0.75 and left):
            continue
        fits = [w for w in left if w >= 1.3 * cand.diameter]
        if not fits:
            continue
        t = reaching(cand)
        last = sum(1 for w in left if w >= 1.3 * t.diameter) == len(left) or cand.id == flats[-1].id
        op = Operation(K.ADAPTIVE, tool_id=t.id, leave_radial=0.15, leave_axial=0.1)
        op.pockets_only = True
        op.min_pocket = 1.2 if last else DEFAULT_MIN_POCKET
        d = op.cutting_data(t, m, machine)
        area = 0.0
        for w in fits:
            area += math.pi * w * w / 4
        add(op, area * depth / max(d.feed * d.stepover * min(d.stepdown, depth), 1) * 1.6)
        pocket_tools.append(t)
        left = [w for w in left if not (w >= 1.3 * t.diameter and (last or w < DEFAULT_MIN_POCKET * t.diameter))]
    if pocket_tools:
        n = sum(1 for w in f.pocket_widths if w < DEFAULT_MIN_POCKET * rougher.diameter)
        reasons.append(f"{n} pockets are too narrow for the {rougher.name}: roughed with the {', then the '.join(t.name for t in pocket_tools)}.")
    if left:
        state["risk"] += 0.3
        reasons.append(f"Risk: {len(left)} pocket{'' if len(left) == 1 else 's'} down to {Length.mm(min(left))} mm wide fit none of these end mills: they'd stay uncut.")

    # Walls and floors: the finisher must fit the tightest corners and pockets.
    corner = a.min_concave_radius if a.min_concave_radius is not None else math.inf
    narrow_pocket = min(f.pocket_widths) if f.pocket_widths else math.inf
    wall_options = [t for t in tools if t.kind is ToolKind.FLAT_END_MILL and t.diameter < rougher.diameter - 0.5 and t.diameter >= 0.75
                    and t.diameter < narrow_pocket / 1.2 and (t.diameter >= 2.9 or corner < 1.6)]
    if wall_options:
        w = max(wall_options, key=lambda t: t.diameter)
        wall_tool = w if not f.pocket_widths and not f.hole_diameters else reaching(w)  # holes are enclosed walls too
    else:
        wall_tool = rougher
    if a.wall_area > 1:
        wall = Operation(K.CONTOUR, tool_id=wall_tool.id, spring_pass=True)
        wd = wall.cutting_data(wall_tool, m, machine)
        add(wall, a.wall_area / max(wd.stepdown, 0.1) * 2 / max(wd.feed, 1) * 1.2)
    if f.has_floors:
        floor = Operation(K.FLOOR, tool_id=wall_tool.id)
        fl = floor.cutting_data(wall_tool, m, machine)
        add(floor, a.flat_area / max(fl.stepover, 0.1) / max(fl.feed, 1) * 1.2)
        # Floors narrower than that tool: a second pass with one that fits.
        narrow_idx = [k for k, w in enumerate(f.floor_widths) if w < wall_tool.diameter + 0.1]
        narrow = [f.floor_widths[k] for k in narrow_idx]
        depths = [f.floor_depths[k] for k in narrow_idx if k < len(f.floor_depths)]
        deepest = max(depths) if depths else (f.cut_depth if f.cut_depth is not None else depth)
        if narrow:
            w = min(narrow)
            fits = [t for t in tools if t.kind is ToolKind.FLAT_END_MILL and t.diameter < w - 0.2 and t.diameter >= 0.45]
            reaches_floors = [t for t in fits if t.flute_length >= deepest + 0.3]
            choice = reaches_floors or fits
            if choice:
                small = max(choice, key=lambda t: (0 if t.is_suggestion else 1, t.diameter))
                op2 = Operation(K.FLOOR, tool_id=small.id)
                op2.floor_max_width = wall_tool.diameter + 0.1  # only those the first pass couldn't do
                d2 = op2.cutting_data(small, m, machine)
                add(op2, a.flat_area * 0.1 / max(d2.stepover, 0.05) / max(d2.feed, 1) * 1.3)
                n = len(narrow)
                reasons.append(f"{n} floor{' is' if n == 1 else 's are'} narrower than the {wall_tool.name} (down to {Length.mm(w)} mm): "
                               f"the {small.name}{' (to buy)' if small.is_suggestion else ''} finishes {'it' if n == 1 else 'them'}.")
            else:
                state["risk"] += 0.2
                n = len(narrow)
                reasons.append(f"Risk: {n} floor{'' if n == 1 else 's'} down to {Length.mm(w)} mm wide fit none of these end mills: they stay unfinished.")

    # 3D finishing.
    if finisher3d is not None and strategy is not None:
        ball = reaching(finisher3d)
        op = Operation(strategy, tool_id=ball.id)
        op.scallop = cusp
        d = op.cutting_data(ball, m, machine)
        link = {K.SPIRAL: 1.03, K.PARALLEL: 1.15, K.SCALLOP: 1.15, K.STEEP_SHALLOW: 1.22, K.RADIAL: 1.3}.get(strategy, 1.2)
        add(op, a.freeform_area / max(d.stepover, 0.01) * link / max(d.feed, 1))
        h = cusp * 1000
        if strategy is K.PARALLEL:
            h *= 1 + 3 * f.steep_fraction
        elif strategy is K.SPIRAL and a.circularity < 0.8:
            h *= 1.4
        elif strategy is K.RADIAL:
            h *= 1.3
        state["finish"] = max(state["finish"], h)
        reasons.append(explain(strategy, f) + f" With the {ball.name}, {Length.mm(d.stepover)} mm stepover for ~{int(swift_round(cusp * 1000))} µm cusps.")
        r = a.min_concave_radius
        if r is not None and ball.diameter / 2 > r + 1e-6 and rest is None:
            state["finish"] = max(state["finish"], (ball.diameter / 2 - r) * 1000 * 0.3)
            reasons.append(f"Corners tighter than the ball (R{Length.mm(r)}) keep a little material.")
        need = max(f.part[2] + 3, ball.flute_length)
        if ball.stickout > need + 4:
            reasons.append(f"Stick the {ball.name} out only ~{Length.mm(math.ceil(need))} mm (not {Length.mm(ball.stickout)}): stiffer, finer finish, less chatter.")
        if need / ball.diameter > 6:
            state["risk"] += 0.2
            reasons.append(f"Risk: the depth needs the {ball.name} {int(need / ball.diameter)}× its diameter out; it can deflect.")
            cr = a.min_concave_radius if a.min_concave_radius is not None else math.inf
            stiffer = [t for t in tools if t.kind is ToolKind.BALL_END_MILL and t.diameter > ball.diameter + 0.3
                       and t.diameter / 2 <= cr + 1e-6 and need / t.diameter <= 6]
            longer = [t for t in tools if t.kind is ToolKind.BALL_END_MILL and abs(t.diameter - ball.diameter) < 0.05
                      and t.id != ball.id and t.flute_length >= need]
            if stiffer:
                s = min(stiffer, key=lambda t: t.diameter)
                remedies.append(Remedy(f"Use the {s.name}{' (not owned)' if s.is_suggestion else ''}: stiffer, still fits the corners", ("swap", ball.id, s.id)))
            elif longer:
                s = longer[0]
                remedies.append(Remedy(f"Use the {s.name}{' (not owned)' if s.is_suggestion else ''}: its neck clears the walls", ("swap", ball.id, s.id)))
            remedies.append(Remedy(f"Slow the {ball.name} to 75 % (less deflection, longer)", ("slower", ball.id, 0.75)))
        if rest is not None:
            rt = reaching(rest)
            rop = Operation(K.REST, tool_id=rt.id)
            rop.scallop = cusp
            rd2 = rop.cutting_data(rt, m, machine)
            add(rop, (a.freeform_area * 0.08 + a.wall_area * 0.05) * 2 / max(rd2.stepover, 0.01) / max(rd2.feed, 1) * 1.3)
            reasons.append(f"Then the {rt.name} cleans the creases and inside corners the bigger ball can't reach.")
            if rt.diameter < 1 and m.difficulty >= Difficulty.MODERATE:
                state["risk"] += 0.2
                reasons.append(f"Risk: a sub-millimetre ball in {m.name} breaks easily; keep the feeds conservative.")
                remedies.append(Remedy(f"Slow the {rt.name} to 70 %", ("slower", rt.id, 0.7)))
    elif f.freeform:
        state["finish"] = 40
        reasons.append(f"No ball end mill: curved surfaces keep the roughing terraces (~{Length.mm(ap)} mm steps). Buy a 1/8\" ball for a smooth finish.")
    else:
        state["finish"] = 2  # 2.5D walls and floors finish to size

    # Holes. One this plan's tools can't make is left out: it scores as unfinished.
    drills = [t for t in tools if t.kind is ToolKind.DRILL]
    unmade: list[float] = []
    for d in sorted({swift_round(h * 100) / 100 for h in f.hole_diameters}):
        drill = next((t for t in drills if abs(t.diameter - d) <= 0.05), None)
        fitting = [t for t in tools if t.kind is ToolKind.FLAT_END_MILL and d * 0.3 <= t.diameter <= d * 0.8]
        if drill is not None:
            add(Operation(K.DRILL, tool_id=drill.id), 1.0)
            if drill.is_suggestion:
                reasons.append(f"⌀{Length.mm(d)} holes: drilled with the {drill.name} (to buy).")
        elif fitting:
            mill = reaching(max(fitting, key=lambda t: t.diameter))
            add(Operation(K.BORE, tool_id=mill.id), 1.0)
            if mill.is_suggestion:
                reasons.append(f"⌀{Length.mm(d)} holes: bored with the {mill.name} (to buy).")
        elif not any(t.kind is ToolKind.FLAT_END_MILL and t.diameter <= d * 0.8 for t in tools):
            unmade.append(d)  # every end mill is too big for it
    if unmade:
        state["finish"] = max(state["finish"], UNMADE_HOLE_FINISH)
        reasons.append(f"Unfinished: the ⌀{', '.join(Length.mm(d) for d in unmade)} mm holes need a smaller drill or end mill than these tools: they're left out.")
    if max(depth + 3, rougher.flute_length) / rougher.diameter > 5:
        state["risk"] += 0.15
        reasons.append(f"Risk: the {rougher.name} reaches more than 5× its diameter: keep the stick-out short.")
        remedies.append(Remedy(f"Slow the {rougher.name} to 80 %", ("slower", rougher.id, 0.8)))
    used = {op.tool_id for op in ops if op.tool_id is not None}
    total = 0.0
    for v in minutes.values():
        total += v
    return Candidate("", ops, minutes, total, state["finish"], min(state["risk"], 1), reasons,
                     [t for t in tools if t.id in used], remedies)


def explain(k, f: Facts) -> str:
    steep = int(swift_round(f.steep_fraction * 100))
    if k is K.STEEP_SHALLOW:
        return f"Steep & shallow: {steep} % of the curved surface is steeper than 45°, so waterline there and parallel passes on the rest give an even finish."
    if k is K.SCALLOP:
        return "Scallop: passes at a constant distance over the surface, the most even finish on freeform shapes."
    if k is K.PARALLEL:
        return (f"Parallel: the surface is shallow ({steep} % steep), so straight passes finish it evenly and quickly." if steep < 10
                else f"Parallel: quick, but the {steep} % steep area gets wider cusps.")
    if k is K.SPIRAL:
        return f"Spiral: the part is round ({int(swift_round(f.analysis.circularity * 100))} % of a disc), so one continuous spiral with no direction changes."
    return k.explanation
