"""The job journal: every job run on the machine, what it took and how it went. Recording one
updates the inventory (tool wear, the stock used, the offcut put back) and what Coastline learns
about feeds. Port of Journal/JobJournal.swift."""

from __future__ import annotations

import datetime as _dt
from dataclasses import dataclass, field, replace
from enum import Enum

from .codable import jfield
from .ids import new_id
from .materials import Material


def now() -> _dt.datetime:
    return _dt.datetime.now(_dt.timezone.utc)


def short_date(d: _dt.datetime) -> str:
    """Like DateFormatter's short date style: 16/11/2026 or 11/16/26, by the system's locale."""
    return d.astimezone().strftime("%x")


class Outcome(Enum):
    GOOD = "good"
    MINOR_ISSUES = "minorIssues"
    SCRAPPED = "scrapped"

    @property
    def title(self) -> str:
        return {"good": "Good part", "minorIssues": "Good, with issues", "scrapped": "Scrapped"}[self.value]


@dataclass
class ProgramRun:
    """One program as it ran: the tool and how long it cut."""

    title: str
    tool_id: str
    tool_name: str
    minutes: float
    distance: float  # cutting distance, mm


@dataclass
class Measurement:
    """A checkpoint: what to measure, what it should be, and what was measured."""

    what: str
    expected: float
    tolerance: float
    measured: float | None = None

    @property
    def in_tolerance(self) -> bool | None:
        return None if self.measured is None else abs(self.measured - self.expected) <= self.tolerance + 1e-9


@dataclass
class JournalEntry:
    part_name: str
    material_id: str
    stock_description: str
    programs: list[ProgramRun]
    measurements: list[Measurement]
    id: str = field(default_factory=new_id)
    date: _dt.datetime = field(default_factory=now)
    project_path: str | None = None
    material_snapshot: Material | None = None  # keeps the material's name and recipe if the library changes
    stock_id: str | None = None
    copies: int = 1
    outcome: Outcome = Outcome.GOOD
    chatter: bool = False  # chatter or squeal heard (that tool's feeds slow next time)
    chatter_tool_ids: list[str] = field(default_factory=list)
    finish: int = 3  # surface finish, 1 (rough) … 5 (mirror)
    notes: str = ""
    photos: list[str] = field(default_factory=list)  # photo file names in the journal's folder
    remnant_length: float | None = None  # stock left over (put back as an offcut)

    @property
    def cutting_minutes(self) -> float:
        return sum(p.minutes for p in self.programs)


def record(e: JournalEntry, inv) -> list[str]:
    """Applies a recorded job to the inventory: each tool's cutting minutes and distance, one
    piece of the stock used, and the offcut back as a remnant (same section, shorter)."""
    notes: list[str] = []
    per_tool: dict[str, list[float]] = {}
    for p in e.programs:
        t = per_tool.setdefault(p.tool_id, [0.0, 0.0])
        t[0] += p.minutes
        t[1] += p.distance
    for tid, (m, d) in per_tool.items():
        tool = next((t for t in inv.tools if t.id == tid), None)
        if tool is None:
            continue
        tool.cutting_minutes += m
        tool.cutting_distance += d
    if e.stock_id is not None:
        k = next((i for i, s in enumerate(inv.stock) if s.id == e.stock_id), None)
        if k is not None:
            used = inv.stock[k]
            if used.quantity > 1:
                inv.stock[k] = replace(used, quantity=used.quantity - 1)
            else:
                del inv.stock[k]
                notes.append(f"{used.size_description} used up: removed from the stock.")
            left = e.remnant_length
            if left is not None and left >= 10:
                # The offcut keeps the bar's section; its longest side becomes what's left.
                r = replace(used, id=new_id(), quantity=1, is_remnant=True,
                            notes=f"Offcut from {e.part_name}, {short_date(e.date)}.")
                sizes = [r.size_x, r.size_y, r.size_z]
                longest = r.extrusion_axis if r.extrusion_axis is not None else max(range(3), key=lambda i: sizes[i])
                if longest == 0:
                    r.size_x = left
                elif longest == 1:
                    r.size_y = left
                else:
                    r.size_z = left
                inv.stock.append(r)
                notes.append(f"Offcut {r.size_description} put back as a remnant.")
    return notes


@dataclass
class ToolLifeStatus:
    used: float  # fraction of the expected life
    minutes: float
    life_minutes: float

    @property
    def replace_soon(self) -> bool:
        return self.used >= 0.8

    @property
    def worn_out(self) -> bool:
        return self.used >= 1


class ToolLife:
    """How worn each tool is, from its recorded cutting minutes (Taylor life per material)."""

    @staticmethod
    def status(tool, material) -> ToolLifeStatus:
        from .plan.tuning import ToolWear
        life = ToolWear.life(tool, material, 1)
        return ToolLifeStatus(tool.cutting_minutes / max(life, 1), tool.cutting_minutes, life)

    @staticmethod
    def shopping_list(inv, material) -> list[tuple[object, str]]:
        """What to buy: tools near the end of their life with no spare, and worn or broken ones."""
        from .geometry import swift_round
        from .inventory.checks import ResourceLibraryValidation
        from .inventory.items import Condition
        out = []
        for t in inv.tools:
            if t.requires_specification_review or ResourceLibraryValidation.tool_issues(t):
                continue
            s = ToolLife.status(t, material)
            if t.condition is Condition.BROKEN:
                out.append((t, "Broken"))
            elif t.condition is Condition.WORN and t.quantity <= 1:
                out.append((t, "Marked worn, no spare"))
            elif s.replace_soon and t.quantity <= 1:
                out.append((t, f"Past its expected life ({int(s.minutes)} of ~{int(s.life_minutes)} min)" if s.worn_out
                            else f"{int(swift_round(s.used * 100))} % of its expected life used, no spare"))
        return out


@dataclass
class FeedLearning:
    """What the journal teaches the feeds: a factor per material and tool kind. Chatter slows
    that kind by 10 %; three clean jobs in a row give back 3 %. Bounded to 0.6…1.05."""

    factors: dict[str, float] = jfield(default_factory=dict)
    clean_streak: dict[str, int] = jfield(default_factory=dict)

    @staticmethod
    def key(material_id: str, kind) -> str:
        return f"{material_id}|{kind.value}"

    def factor(self, material_id: str, kind) -> float:
        return self.factors.get(self.key(material_id, kind), 1.0)

    def learn(self, e: JournalEntry, tools: list) -> None:
        by_id = {}
        for t in tools:
            by_id.setdefault(t.id, t)
        kinds = {by_id[p.tool_id].kind for p in e.programs if p.tool_id in by_id}
        noisy = {by_id[i].kind for i in e.chatter_tool_ids if i in by_id}
        for kind in kinds:
            k = self.key(e.material_id, kind)
            f = self.factors.get(k, 1.0)
            if e.chatter and (not noisy or kind in noisy):
                f *= 0.9
                self.clean_streak[k] = 0
            elif e.outcome is not Outcome.SCRAPPED:
                n = self.clean_streak.get(k, 0) + 1
                self.clean_streak[k] = n
                if n % 3 == 0:
                    f *= 1.03
            self.factors[k] = min(max(f, 0.6), 1.05)
