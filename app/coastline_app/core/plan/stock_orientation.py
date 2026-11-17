"""The ways a bar can sit for a part. Port of Plan/StockOrientation.swift: only ways the part
fits are workable; the best keeps the extrusion along the table and leaves the least material
beyond the part."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from ..units import Length


@dataclass
class StockOption:
    axes: list[int]  # Setup.stock_axes: envelope index for work X, Y, Z
    raw: np.ndarray  # the stock as bought in this orientation (work X, Y, Z)
    workable: bool
    reason: str | None
    removal: float  # material beyond the part's depth, mm³
    summary: str
    along_extrusion: bool = True

    @property
    def id(self) -> tuple[int, ...]:
        return tuple(self.axes)


def stock_options(stock, part, preferred_axes: list[int] | None = None) -> list[StockOption]:
    """`part`: the part's size in the work frame."""
    e = [stock.envelope.x, stock.envelope.y, stock.envelope.z]
    perms = [[1, 0, 2], [0, 1, 2], [2, 0, 1], [0, 2, 1], [2, 1, 0], [1, 2, 0]]
    if preferred_axes is not None and preferred_axes in perms:
        perms.remove(preferred_axes)
        perms.insert(0, list(preferred_axes))
    # The extrusion: given on the stock, else its longest side (the first of equals, as Swift's max(by:)).
    ext = stock.extrusion_axis if stock.extrusion_axis is not None else max(range(3), key=lambda k: e[k])
    out, seen = [], set()
    for p in perms:
        raw = np.array([e[p[0]], e[p[1]], e[p[2]]], float)
        key = tuple(raw)
        if key in seen:
            continue
        seen.add(key)
        missing = next((k for k in range(3) if raw[k] + 1e-6 < part[k]), None)
        reason = None if missing is None else f"only {Length.mm(raw[missing])} mm {['tall', 'long', 'deep'][missing]}: the part needs {Length.mm(part[missing])}"
        dims = f"{Length.mm(raw[0])} up · {Length.mm(raw[1])} along · {Length.mm(raw[2])} deep"
        out.append(StockOption(p, raw, reason is None, reason, max(raw[2] - part[2], 0) * raw[0] * raw[1],
                               f"{dims}: {('no, ' + reason) if reason else 'contains the part'}", p[1] == ext))
    # Workable first; then the extrusion along Y; then the least material beyond the part.
    return sorted(out, key=lambda o: (not o.workable, not o.along_extrusion, o.removal))
