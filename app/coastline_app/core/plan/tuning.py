"""The quality ↔ time tuner and tool wear. Port of Plan/Tuning.swift: one finish setting and one
pace setting drive every operation, with the consequences shown before generating."""

from __future__ import annotations

import copy
from dataclasses import dataclass
from enum import Enum

from ..feeds import RoughingStyle

HIDDEN_CUSP_FACTOR = 3.0  # how much coarser the hidden side's 3D finishing is


class Preset(Enum):
    DRAFT = "draft"
    STANDARD = "standard"
    FINE = "fine"
    MIRROR = "mirror"

    @property
    def title(self) -> str:
        return self.value.capitalize()

    @property
    def explanation(self) -> str:
        return {"draft": "Prototype or wax: coarse cusps, brisk feeds. Fastest; expect to sand.",
                "standard": "Good machined finish, the maker's recommended feeds.",
                "fine": "Jewellery finish ready for light polishing; slower, gentler on tools.",
                "mirror": "Tiny cusps and light feeds for a near-polished surface. Slowest."}[self.value]


@dataclass
class Tuning:
    cusp: float = 0.008  # cusp height left by finishing passes, mm
    pace: float = 1.0  # feed and engagement relative to the recommended values
    roughing: RoughingStyle | None = None  # None: chip-thinned
    hidden_side: int | None = None  # the side nobody sees gets 3× coarser 3D finishing

    @staticmethod
    def make(cusp: float = 0.008, pace: float = 1.0, roughing: RoughingStyle | None = None,
             hidden_side: int | None = None) -> "Tuning":
        return Tuning(cusp, pace, None if roughing is RoughingStyle.THINNED else roughing, hidden_side)

    @property
    def roughing_style(self) -> RoughingStyle:
        return self.roughing or RoughingStyle.THINNED

    @staticmethod
    def preset_value(p: Preset) -> "Tuning":
        return {Preset.DRAFT: Tuning.make(0.020, 1.15, RoughingStyle.DEEP), Preset.STANDARD: Tuning.make(0.008, 1.0),
                Preset.FINE: Tuning.make(0.004, 0.9), Preset.MIRROR: Tuning.make(0.002, 0.8, RoughingStyle.TABLE)}[p]

    @property
    def preset(self) -> Preset | None:
        for p in Preset:
            t = Tuning.preset_value(p)
            t.hidden_side = self.hidden_side
            if t == self:
                return p
        return None

    def with_preset(self, p: Preset) -> "Tuning":
        t = Tuning.preset_value(p)
        t.hidden_side = self.hidden_side
        return t

    @property
    def ra(self) -> float:
        """Roughness from the cusp: Ra ≈ h / 4 for ball-end cusps (µm)."""
        return self.cusp * 1000 / 4

    def apply(self, ops: list) -> list:
        out = []
        for op in ops:
            o = copy.deepcopy(op)
            if o.kind.is_3d:
                o.scallop = self.cusp
            o.feed_scale = self.pace
            o.roughing = self.roughing
            out.append(o)
        return out


class ToolWear:
    """Taylor's tool-life equation: life falls steeply with speed."""

    @staticmethod
    def base_life(material) -> float:
        from ..materials import MaterialFamily as F
        return {F.ALUMINIUM: 900, F.COPPER_ALLOY: 600, F.PLASTIC: 1500, F.PRINTED_RESIN: 1500, F.WAX: 1500,
                F.STEEL: 150, F.STAINLESS: 90, F.TITANIUM: 60}[material.family]

    @staticmethod
    def life(tool, material, pace: float) -> float:
        from ..inventory.items import ToolMaterial
        l = ToolWear.base_life(material)
        if tool.tool_material is ToolMaterial.HSS:
            l *= 0.25
        if tool.diameter < 1.5:
            l *= 0.5
        return l * max(pace, 0.3) ** -4

    @staticmethod
    def fraction(tool, material, minutes: float, pace: float) -> float:
        return minutes / ToolWear.life(tool, material, pace)
