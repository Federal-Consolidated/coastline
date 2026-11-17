"""Holding tabs (bridges): small bars of uncut material that keep the part in the stock frame when
the last side cuts all the way through. Port of Plan/HoldingTabs.swift."""

from __future__ import annotations

import base64
from dataclasses import dataclass, field

from ..codable import Range
from ..geometry import swift_round


@dataclass
class TabFrame:
    """A grid over the stock (side B's work frame): which cells are frame that stays at the tabs'
    height once the other side is cut. Row-major bits, most significant first, base64."""

    origin: tuple[float, float]
    cell: float
    cols: int
    rows: int
    bits: str

    @staticmethod
    def make(origin, cell: float, cols: int, rows: int, frame: list[bool]) -> "TabFrame":
        data = bytearray((len(frame) + 7) // 8)
        for i, f in enumerate(frame):
            if f:
                data[i >> 3] |= 0x80 >> (i & 7)
        return TabFrame((float(origin[0]), float(origin[1])), cell, cols, rows, base64.b64encode(bytes(data)).decode())

    def is_frame(self, p) -> bool:
        c = int(swift_round((p[0] - self.origin[0]) / self.cell))
        r = int(swift_round((p[1] - self.origin[1]) / self.cell))
        if not (0 <= c < self.cols and 0 <= r < self.rows):
            return False
        try:
            d = base64.b64decode(self.bits)
        except ValueError:
            return False
        i = r * self.cols + c
        return bool(d[i >> 3] & (0x80 >> (i & 7)))

    @property
    def description(self) -> str:
        """Short, for cache keys: the grid and a hash of the bits."""
        h = 0xCBF29CE484222325
        for b in self.bits.encode():
            h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
        return f"TabFrame({_d(self.origin[0])},{_d(self.origin[1])},{_d(self.cell)},{self.cols}x{self.rows},{h:x})"


def _d(v: float) -> str:
    return f"{v:.1f}" if float(v).is_integer() and abs(v) < 1e16 else repr(float(v))


@dataclass
class HoldingTabs:
    count: int = 4
    width: float = 2.0  # along the outline, mm
    height: float = 0.8  # along the tool axis, mm
    reach: float | None = None  # how far each tab runs out from the part
    frame: TabFrame | None = None
    avoid: list[tuple[float, float, float]] | None = None  # circles no tab may cross (x, y, r)
    within_x: Range | None = None  # where the tools can go all the way round a tab's end
    lift: bool | None = None  # one side cut through: the tabs are gaps the finishing contour lifts over
    skin_top: float | None = None

    @staticmethod
    def suggested(material, part_size) -> "HoldingTabs":
        from ..materials import MaterialFamily as F
        span = max(part_size[0], part_size[1])
        t = HoldingTabs(count=6 if span > 120 else 4)
        family = material.family if material is not None else None
        if family in (F.WAX, F.PLASTIC, F.PRINTED_RESIN):
            t.width, t.height = 3.0, 1.2
        elif family in (F.STEEL, F.STAINLESS, F.TITANIUM):
            t.width, t.height = 1.5, 0.6
        return t


@dataclass
class PlacedTab:
    """A tab the engine placed (work frame of the side that cuts through)."""

    centre: tuple[float, float]
    normal: tuple[float, float]  # outward from the part
    corners: list[tuple[float, float]] = field(default_factory=list)  # the kept rectangle
