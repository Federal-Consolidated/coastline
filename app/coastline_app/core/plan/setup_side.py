"""The job's setups by the side of the stock toward the spindle. Port of Plan/SetupSide.swift.

Index 0 is the front (side A), 1 the back (side B, turned front-to-back), 2 and 3 the upper and
lower sides (+x, −x: a quarter about Y), 4 and 5 the ends (+y, −y: a quarter about X). Every
frame keeps the work-frame rules: origin at the centre of the face toward the spindle, the
stock below Z 0."""

from __future__ import annotations

import numpy as np

from .setup import quarter_rotation

NAMES = ["+z", "-z", "+x", "-x", "+y", "-y"]


class SetupSide:
    names = NAMES

    @staticmethod
    def index(side: str) -> int | None:
        return NAMES.index(side) if side in NAMES else None

    @staticmethod
    def words(side: int) -> str:
        from .dfm import DFM
        return DFM.side_words(NAMES[side]) if 0 <= side < len(NAMES) else f"side {side}"

    @staticmethod
    def rotation(side: int, flip_axis: int | None = None) -> np.ndarray:
        if side == 1:
            return quarter_rotation((0, 1, 0) if flip_axis == 1 else (1, 0, 0), 2)
        if side == 2:
            return quarter_rotation((0, 1, 0), -1)
        if side == 3:
            return quarter_rotation((0, 1, 0), 1)
        if side == 4:
            return quarter_rotation((1, 0, 0), 1)
        if side == 5:
            return quarter_rotation((1, 0, 0), -1)
        return np.identity(3)

    @staticmethod
    def axis_map(side: int) -> list[int]:
        """The side-A work axis along each of this side's work axes."""
        r = SetupSide.rotation(side)
        return [next(j for j in range(3) if abs(r[k, j]) > 0.5) for k in range(3)]

    @staticmethod
    def stock_size(a, side: int) -> np.ndarray:
        m = SetupSide.axis_map(side)
        return np.array([a[m[0]], a[m[1]], a[m[2]]], float)

    @staticmethod
    def to_a(p, side: int, stock, flip_axis: int | None = None) -> np.ndarray:
        """A point in this side's work frame, in side A's."""
        a = np.asarray(stock, float)
        s = SetupSide.stock_size(a, side)
        return SetupSide.rotation(side, flip_axis).T @ (np.asarray(p, float) - np.array([0, 0, -s[2] / 2])) + np.array([0, 0, -a[2] / 2])

    @staticmethod
    def from_a(q, side: int, stock) -> np.ndarray:
        """A point in side A's work frame, in this side's."""
        a = np.asarray(stock, float)
        s = SetupSide.stock_size(a, side)
        return SetupSide.rotation(side) @ (np.asarray(q, float) - np.array([0, 0, -a[2] / 2])) + np.array([0, 0, -s[2] / 2])
