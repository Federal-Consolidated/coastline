"""Display units and length formatting (Swift: Units/DisplayUnits.swift, `Length` in
Inventory/InventoryItems.swift). Geometry, saved dimensions and controller commands stay in mm."""

from __future__ import annotations

import math
from decimal import ROUND_HALF_EVEN, Decimal
from enum import Enum

from .geometry import swift_round


class Locale:
    """Number formatting locale. Defaults to "." decimals (en_US_POSIX); the app sets the
    user's decimal separator so labels match the editable fields."""

    decimal_separator = "."


def _decimal_text(v: float, decimals: int) -> str:
    """`v` to `decimals` places the way ICU (Swift's `formatted`) rounds: half-even on the shortest
    decimal form of the double (1.5875 → "1.588"), not on its exact binary value ("1.587")."""
    if not math.isfinite(v):
        return f"{v:.{decimals}f}"
    d = Decimal(repr(float(v))).quantize(Decimal(1).scaleb(-decimals), rounding=ROUND_HALF_EVEN)
    return f"{d:.{decimals}f}"


def format_number(v: float, max_decimals: int = 3, min_decimals: int = 0) -> str:
    """Up to `max_decimals` decimals, trailing zeros removed, no grouping, in the locale."""
    text = _decimal_text(v, max_decimals)
    if "." in text:
        whole, frac = text.split(".")
        frac = frac.rstrip("0")
        if len(frac) < min_decimals:
            frac = frac + "0" * (min_decimals - len(frac))
        text = whole + ("." + frac if frac else "")
    if text in ("-0", "-0.0") or (text.startswith("-") and float(text) == 0):
        text = text[1:]
    return text.replace(".", Locale.decimal_separator)


class DisplayUnits(Enum):
    METRIC = "metric"
    IMPERIAL = "imperial"

    @property
    def title(self) -> str:
        return "Metric (mm)" if self is DisplayUnits.METRIC else "Imperial (in)"

    @property
    def symbol(self) -> str:
        return "mm" if self is DisplayUnits.METRIC else "in"

    @property
    def spoken_unit(self) -> str:
        return "millimeters" if self is DisplayUnits.METRIC else "inches"

    @property
    def coordinate_decimals(self) -> int:
        return 3 if self is DisplayUnits.METRIC else 4

    def symbol_for(self, metric_unit: str) -> str:
        """Only known length units are converted; angles, prices and times keep their meaning."""
        if self is not DisplayUnits.IMPERIAL:
            return metric_unit
        return {"mm": "in", "mm/min": "in/min", "mm/s²": "in/s²"}.get(metric_unit, metric_unit)

    def _scale(self, metric_unit: str) -> float:
        return 25.4 if self is DisplayUnits.IMPERIAL and metric_unit in ("mm", "mm/min", "mm/s²") else 1.0

    def displayed_value(self, millimeters: float, unit: str = "mm") -> float:
        return millimeters / self._scale(unit)

    def stored_value(self, displayed: float, unit: str = "mm") -> float:
        return displayed * self._scale(unit)

    def dimensions(self, *lengths: float) -> str:
        return " × ".join(self.format(length) for length in lengths) + " " + self.symbol

    def format(self, millimeters: float, max_decimals: int | None = None) -> str:
        return format_number(self.displayed_value(millimeters),
                             self.coordinate_decimals if max_decimals is None else max_decimals)


class Length:
    """Length formatting. Coastline works in mm but tools are often sold in inches, so common
    fractions are shown too."""

    @staticmethod
    def mm(v: float) -> str:
        """"6.35", "3", "0.8": up to 3 decimals, trailing zeros removed."""
        return format_number(v, 3)

    @staticmethod
    def inch_fraction(v: float) -> str | None:
        """The nearest common inch fraction (up to 1/64") within 0.01 mm, e.g. '1/4"'."""
        inches = v / 25.4
        for denominator in (1, 2, 4, 8, 16, 32, 64):
            numerator = swift_round(inches * denominator)
            if numerator <= 0 or abs(numerator / denominator * 25.4 - v) >= 0.01:
                continue
            n = int(numerator)
            whole, rest = n // denominator, n % denominator
            if rest == 0:
                return f'{whole}"'
            return f'{whole} {rest}/{denominator}"' if whole > 0 else f'{rest}/{denominator}"'
        return None

    @staticmethod
    def describe(v: float) -> str:
        """'6.35 mm (1/4")' or '6 mm'."""
        f = Length.inch_fraction(v)
        return f"{Length.mm(v)} mm ({f})" if f else f"{Length.mm(v)} mm"
