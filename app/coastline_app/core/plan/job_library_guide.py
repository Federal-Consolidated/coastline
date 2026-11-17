"""Inventory proposals before workholding constraints: a blank can contain a part without having a
sacrificial frame; a matching jig is a preference, not a fit requirement. Port of Plan/JobLibraryGuide.swift."""

from __future__ import annotations

from dataclasses import dataclass

from .library_workholding import eligibility
from .stock_orientation import stock_options


@dataclass
class StockChoice:
    stock: object
    axes: list[int]
    matching_fixtures: int


def stock_choices(part_size, inventory, preferred_axes: list[int] | None = None) -> list[StockChoice]:
    out = []
    for item in inventory.stock:
        if item.quantity <= 0 or item.is_suggestion or item.material is None:
            continue
        options = [o for o in stock_options(item, part_size, preferred_axes) if o.workable]
        if not options:
            continue
        matches = [(o, sum(1 for f in inventory.fixtures if not eligibility(f, o.raw))) for o in options]
        chosen = max(matches, key=lambda m: m[1]) if matches else None
        count = chosen[1] if chosen else 0
        out.append(StockChoice(item, chosen[0].axes if count > 0 else options[0].axes, count))
    out.sort(key=lambda c: (not c.matching_fixtures > 0, c.stock.volume, c.stock.id))
    return out
