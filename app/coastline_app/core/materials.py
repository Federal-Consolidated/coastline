"""Materials and their starting cutting data. Port of Materials/Material.swift and
MaterialLibrary.swift (the built-in list is data/materials.json)."""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum
from functools import lru_cache

from . import codable, data
from .codable import Range


class MaterialFamily(Enum):
    ALUMINIUM = "aluminium"
    COPPER_ALLOY = "copperAlloy"
    STEEL = "steel"
    STAINLESS = "stainless"
    TITANIUM = "titanium"
    PLASTIC = "plastic"
    PRINTED_RESIN = "printedResin"
    WAX = "wax"

    @property
    def title(self) -> str:
        return {"aluminium": "Aluminium", "copperAlloy": "Brass, Copper & Bronze", "steel": "Steel",
                "stainless": "Stainless Steel", "titanium": "Titanium", "plastic": "Engineering Plastics",
                "printedResin": "Formlabs Printed", "wax": "Wax"}[self.value]


class Difficulty(Enum):
    """How hard this material is on the machine; it decides how conservative the planner is."""

    EASY = 0
    MODERATE = 1
    CAREFUL = 2
    EXPERIMENTAL = 3

    def __lt__(self, o: "Difficulty") -> bool:
        return self.value < o.value

    def __le__(self, o: "Difficulty") -> bool:
        return self.value <= o.value

    def __gt__(self, o: "Difficulty") -> bool:
        return self.value > o.value

    def __ge__(self, o: "Difficulty") -> bool:
        return self.value >= o.value

    @property
    def title(self) -> str:
        return ("Easy", "Moderate", "Careful mode", "Experimental")[self.value]

    @property
    def explanation(self) -> str:
        return ("Cuts cleanly on the machine with standard settings.",
                "Needs sharp tools and the right lubricant, but is routine.",
                "Light radial engagement, low speed and strict load limits. Expect faster tool wear.",
                "Possible on the machine, but at its limits. Make test cuts in scrap first.")[self.value]


@dataclass(frozen=True)
class Material:
    id: str
    name: str
    family: MaterialFamily
    grade: str  # "6061-T6", "C360", "Rigid 10K"
    difficulty: Difficulty
    density: float  # g/cm³
    hardness: str
    surface_speed: Range  # m/min
    chip_load_factor: float  # relative to 6061 at the same diameter
    adaptive_stepover_max: float  # fraction of tool diameter
    adaptive_depth_max: float  # multiple of tool diameter
    slot_depth_max: float  # multiple of tool diameter
    specific_cutting_force: float  # kc1.1, N/mm²
    tool_wear_factor: float  # 6061 = 1
    lubricant: str
    chips: str
    tooling: str
    notes: str = ""
    source: str | None = None  # where a custom definition's cutting data came from

    @property
    def needs_confirmation(self) -> bool:
        return self.difficulty >= Difficulty.CAREFUL

    @property
    def validation_issues(self) -> list[str]:
        """Structural checks shared by library installation and the material editor."""
        issues: list[str] = []
        if not self.id.strip():
            issues.append("Enter a material ID.")
        if not self.name.strip():
            issues.append("Enter a material name.")

        def positive(value: float, title: str, maximum: float) -> None:
            if not math.isfinite(value) or value <= 0 or value > maximum:
                issues.append(f"{title} must be greater than zero and no more than {_plain(maximum)}.")

        positive(self.density, "Density (g/cm³)", 100)
        positive(self.surface_speed.lower, "Minimum surface speed (m/min)", 1_000_000)
        positive(self.surface_speed.upper, "Maximum surface speed (m/min)", 1_000_000)
        positive(self.chip_load_factor, "Chip load factor", 1_000)
        positive(self.adaptive_stepover_max, "Adaptive stepover (fraction of tool diameter)", 1)
        positive(self.adaptive_depth_max, "Adaptive depth (multiple of tool diameter)", 1_000)
        positive(self.slot_depth_max, "Slot depth (multiple of tool diameter)", 1_000)
        positive(self.specific_cutting_force, "Specific cutting force (N/mm²)", 1_000_000_000)
        positive(self.tool_wear_factor, "Tool wear factor", 1_000)
        return issues

    def ideal_rpm(self, tool_diameter: float) -> float:
        """RPM at the middle of the surface-speed range, before the spindle's limits."""
        vc = self.surface_speed.lower / 2 + self.surface_speed.upper / 2
        return vc * 1000 / (math.pi * tool_diameter)

    def to_json(self) -> dict:
        return _encode(self)

    @staticmethod
    def from_json(d) -> "Material":
        return codable.decode_dataclass(Material, d)


def _encode(m: Material) -> dict:
    import dataclasses
    out = {}
    for f in dataclasses.fields(m):
        v = getattr(m, f.name)
        if v is None:
            continue
        out[codable.camel(f.name)] = codable.to_json(v)
    return out


def _plain(v: float) -> str:
    return str(int(v)) if float(v).is_integer() else repr(v)


class MaterialLibrary:
    @staticmethod
    @lru_cache(maxsize=1)
    def all() -> tuple[Material, ...]:
        return tuple(Material.from_json(d) for d in data.load("materials.json"))

    @staticmethod
    def material(id: str) -> Material | None:
        return _by_id().get(id)


@lru_cache(maxsize=1)
def _by_id() -> dict[str, Material]:
    out: dict[str, Material] = {}
    for m in MaterialLibrary.all():
        out.setdefault(m.id, m)
    return out
