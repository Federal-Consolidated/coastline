"""What a setup from a side (upper, lower side or an end: SetupSide 2…5) cuts: only the features
sent to that side, inside a window around them, with the plan's own tools. Port of Plan/SideCuts.swift."""

from __future__ import annotations

import copy
import math
from dataclasses import dataclass

import numpy as np

from ..feeds import OperationKind as K
from .setup_side import SetupSide

KINDS = {K.ADAPTIVE, K.FLOOR, K.DRILL, K.BORE, K.THREAD}


@dataclass
class Window:
    """The window in the side's work frame: XY around the features, and how deep they go."""

    min: tuple[float, float]
    max: tuple[float, float]
    z_min: float


def window(feature_bounds, side: int, stock, margin: float) -> Window | None:
    """`feature_bounds`: [(min, max)] in the side-A work frame."""
    lo, hi = np.full(3, math.inf), np.full(3, -math.inf)
    for bmin, bmax in feature_bounds:
        for i in range(8):
            q = np.array([bmin[0] if i & 1 == 0 else bmax[0], bmin[1] if i & 2 == 0 else bmax[1], bmin[2] if i & 4 == 0 else bmax[2]], float)
            p = SetupSide.from_a(q, side, stock)
            lo, hi = np.minimum(lo, p), np.maximum(hi, p)
    if not (math.isfinite(lo[0]) and hi[0] >= lo[0]):
        return None
    s = SetupSide.stock_size(stock, side)
    wlo = (max(lo[0] - margin, -s[0] / 2 - margin), max(lo[1] - margin, -s[1] / 2 - margin))
    whi = (min(hi[0] + margin, s[0] / 2 + margin), min(hi[1] + margin, s[1] / 2 + margin))
    return Window(wlo, whi, max(lo[2] - 0.2, -s[2]))


def keep_out(w: Window, stock, reach: float = 50) -> list:
    """Rectangles covering everything around the window (out to `reach` past the stock)."""
    s = stock
    x0, x1, y0, y1 = -s[0] / 2 - reach, s[0] / 2 + reach, -s[1] / 2 - reach, s[1] / 2 + reach
    out = []
    if w.min[0] > x0:
        out.append(((x0, y0), (w.min[0], y1)))
    if w.max[0] < x1:
        out.append(((w.max[0], y0), (x1, y1)))
    if w.min[1] > y0:
        out.append(((w.min[0], y0), (w.max[0], w.min[1])))
    if w.max[1] < y1:
        out.append(((w.min[0], w.max[1]), (w.max[0], y1)))
    return out


def operations(base: list, w: Window, stock) -> list:
    """The side setup's operations from the plan's: the kinds above, each to the window's depth,
    roughing only this side's cavities inside it and leaving nothing on their walls."""
    ko = keep_out(w, stock)
    out = []
    for p in base:
        if p.operation.kind not in KINDS:
            continue
        p = copy.copy(p)
        p.operation = p.operation.copy()
        p.z_top = 0.0
        p.z_min = max(p.z_min if p.z_min is not None else -math.inf, w.z_min)
        p.window = (w.min, w.max)
        p.keep_out = []
        p.band = None
        p.frame_top = None
        p.tile = None
        if p.operation.kind is K.ADAPTIVE:
            p.keep_out = ko
            p.keep_out_below = 1  # every level: the keep-out holds from the face down
            p.operation.leave_radial = 0
            p.operation.leave_axial = 0
        out.append(p)
    return out
