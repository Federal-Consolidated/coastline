"""How much stock the machine takes with a side toward the spindle (SetupRoom), and what a job's
setups cut, read from the part check (PlanCoverage). Port of Plan/PlanCoverage.swift."""

from __future__ import annotations

from dataclasses import dataclass, field

from .dfm import Category, DFMFinding, mm, side_words

SIDES = ["+z", "-z", "+x", "-x", "+y", "-y"]


@dataclass
class Turn:
    """How far the stock may hang past the table's far edge for one side's turn, mm."""

    behind: float  # with the enclosure in place
    behind_open: float  # without it


@dataclass
class SetupRoom:
    table_depth: float  # how deep the table's seating surface is toward the spindle, mm
    turns: dict[str, Turn] = field(default_factory=dict)  # per side; missing: the table alone

    def fit(self, size, side: str) -> tuple[str, str | None]:
        """("fits", None), ("enclosureOpen", why) or ("no", why) for stock of this size (work frame:
        X up, Y across, Z toward the spindle) with this side toward the spindle."""
        past = size[2] - self.table_depth
        if not past > 0.05:
            return "fits", None
        turn = self.turns.get(side) or Turn(0, 0)
        depth = f"It is {mm(size[2], 0.1)} mm deep that way, {mm(past, 0.1)} mm past the {mm(self.table_depth, 0.1)} mm table"
        if past <= turn.behind + 0.05:
            return "fits", None
        if past <= turn.behind_open + 0.05:
            return "enclosureOpen", f"{depth}. That fits with the enclosure open: its panel leaves {mm(turn.behind, 0.1)} mm."
        return "no", f"{depth}, and the machine leaves {mm(turn.behind_open, 0.1)} mm there."

    def problem(self, size, side: str) -> str | None:
        kind, why = self.fit(size, side)
        return why if kind == "no" else None

    @staticmethod
    def size(stock, side: str) -> tuple[float, float, float]:
        """The stock's size with this side toward the spindle, from its size in the first setup."""
        s = (float(stock[0]), float(stock[1]), float(stock[2]))
        axis = side[1:]
        if axis == "x":
            return (s[2], s[1], s[0])
        if axis == "y":
            return (s[0], s[2], s[1])
        return s


@dataclass
class SetupCut:
    side: str  # toward the spindle
    number: int  # 1, 2, 3 … in the order of the job
    findings: list[str]
    titles: list[str]
    faces: list[int]
    toolpaths: bool  # Coastline makes this setup's toolpaths (False: proposed only)
    note: str | None = None

    @property
    def id(self) -> str:
        return self.side


@dataclass
class Unused:
    side: str
    why: str
    fits: bool

    @property
    def id(self) -> str:
        return self.side


@dataclass
class Gap:
    finding: str
    title: str
    category: Category
    reason: tuple  # ("cannotMachine",), ("needsSides", [sides]), ("needsTool",), ("noRoom", side)
    faces: list[int]

    @property
    def id(self) -> str:
        return self.finding

    @property
    def text(self) -> str:
        kind = self.reason[0]
        if kind == "cannotMachine":
            return "Can't be machined as drawn."
        if kind == "needsSides":
            sides = self.reason[1]
            names = [side_words(s) for s in sides]
            lst = names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]
            return ("Needs a setup from the back. Turn on Machine both sides in Setups." if sides == ["-z"]
                    else f"Needs a setup from the {lst}. The plan has no setup from there yet.")
        if kind == "needsTool":
            return "Needs a tool the plan doesn't use. Add it to buy, then build again."
        return f"Cut from the {side_words(self.reason[1])}, and the stock doesn't fit the machine that way."


NOTES = {"tools", "tools-info", "exact", "stock", "thin"}  # notes about tools, stock or CAD: not cuts


def is_cut(f: DFMFinding) -> bool:
    return f.id not in NOTES and f.category is not Category.MISSING_INFORMATION


@dataclass
class PlanCoverage:
    setups: list[SetupCut]
    unused: list[Unused]
    gaps: list[Gap]
    waiting: list[str]  # findings in setups whose toolpaths Coastline doesn't make yet
    with_tools_to_buy: list[str]

    @property
    def open(self) -> int:
        return len(self.gaps) + len(self.waiting)

    @property
    def complete(self) -> bool:
        return self.open == 0

    @staticmethod
    def propose(findings: list[DFMFinding]) -> list[str]:
        """The fewest sides that cut the most features (the front always: the job starts there)."""
        needs = [set(f.sides) for f in findings if is_cut(f) and f.category is not Category.NOT_SUPPORTED and f.sides]
        best = (-1, 0, set())
        for mask in range(1 << len(SIDES)):
            if not mask & 1:
                continue
            chosen = {SIDES[k] for k in range(len(SIDES)) if mask >> k & 1}
            covered = sum(1 for n in needs if n <= chosen)
            if covered > best[0] or (covered == best[0] and len(chosen) < best[1]):
                best = (covered, len(chosen), chosen)
        return [s for s in SIDES if s in best[2]]

    @staticmethod
    def assess(findings: list[DFMFinding], sides: list[str], job_tools: set[str], toolpath_sides: set[str] | None = None,
               room: SetupRoom | None = None, stock=None) -> "PlanCoverage":
        order = [s for s in SIDES if s in sides]
        setups = [SetupCut(side, k + 1, [], [], [], toolpath_sides is None or side in toolpath_sides) for k, side in enumerate(order)]

        def no_room(side: str) -> str | None:
            if room is None or stock is None:
                return None
            return room.problem(SetupRoom.size(stock, side), side)

        if room is not None and stock is not None:
            for s in setups:
                kind, why = room.fit(SetupRoom.size(stock, s.side), s.side)
                if kind == "enclosureOpen":
                    s.note = why
        gaps: list[Gap] = []
        waiting: list[str] = []
        to_buy: list[str] = []
        for f in findings:
            if not is_cut(f):
                continue

            def gap(reason: tuple) -> None:
                gaps.append(Gap(f.id, f.title, f.category, reason, list(f.faces)))

            blocked = next((s for s in f.sides if no_room(s) is not None), None)
            if blocked is not None:
                gap(("noRoom", blocked))
                continue
            missing = [s for s in f.sides if s not in order]
            if f.category is Category.NOT_SUPPORTED:
                gap(("cannotMachine",))
                continue
            if missing:
                gap(("needsSides", missing))
                continue
            if f.category is Category.MISSING_RESOURCE:
                # Only the tools to buy that reach it: an owned one that doesn't is why it's here.
                tools = [r.id if r.kind == "buyTool" else r.tool.id for r in f.remedies if r.kind in ("buyTool", "addTool")]
                if any(t in job_tools for t in tools):
                    to_buy.append(f.id)
                else:
                    gap(("needsTool",))
            # The setup lists it even while it waits for a tool: that side is still where it's cut.
            for side in f.sides:
                s = next((s for s in setups if s.side == side), None)
                if s is None:
                    continue
                s.findings.append(f.id)
                s.titles.append(f.title)
                for face in f.faces:
                    if face not in s.faces:
                        s.faces.append(face)
            if (not gaps or gaps[-1].finding != f.id) and any(
                    next((s for s in setups if s.side == side), None) is not None
                    and not next(s for s in setups if s.side == side).toolpaths for side in f.sides):
                waiting.append(f.id)
        unused = []
        for side in SIDES:
            if side in order:
                continue
            why = no_room(side)
            if why is not None:
                unused.append(Unused(side, f"Doesn't fit the machine. {why}", False))
                continue
            needed = any(is_cut(f) and side in f.sides for f in findings)
            unused.append(Unused(side, "Its features can't be made from there." if needed else "Nothing needs it.", True))
        return PlanCoverage(setups, unused, gaps, waiting, to_buy)
