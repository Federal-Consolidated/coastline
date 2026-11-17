"""Material-removal simulation for 3-axis milling from +Z: a grid of heights over the stock face.
Port of Sim/Heightmap.swift (the cutting loop is C++, native/src/kernels.cpp)."""

from __future__ import annotations

import numpy as np

from ... import _kernels as K
from ..post.toolpath import Role, ToolpathGeometry


class Heightmap:
    def __init__(self, stock_min, stock_max, max_cells: int = 300_000) -> None:
        self._h = K.Heightmap(float(stock_min[0]), float(stock_min[1]), float(stock_min[2]),
                              float(stock_max[0]), float(stock_max[1]), float(stock_max[2]), int(max_cells))

    origin = property(lambda s: (s._h.origin_x, s._h.origin_y))
    cell = property(lambda s: s._h.cell)
    cols = property(lambda s: s._h.cols)
    rows = property(lambda s: s._h.rows)
    top = property(lambda s: s._h.top)
    bottom = property(lambda s: s._h.bottom)

    @property
    def heights(self) -> np.ndarray:
        """(rows, cols) float32, live: changes as the grid is cut."""
        return self._h.heights

    def height(self, col: int, row: int) -> float:
        return float(self._h.heights[row, col])

    def cut(self, a, b, radius: float, corner_radius: float) -> None:
        """Lowers the material under a tool moving from a to b (straight line, any Z)."""
        self._h.cut(float(a[0]), float(a[1]), float(a[2]), float(b[0]), float(b[1]), float(b[2]), radius, corner_radius)

    def apply(self, m, start, radius: float, corner_radius: float) -> None:
        """Applies one toolpath move (arcs subdivided)."""
        if m.role == Role.RAPID:
            return
        pts = [start] + ToolpathGeometry.points(m, start, 0.08)
        self._h.cut_path(np.asarray(pts, float), radius, corner_radius)

    def copy(self) -> "Heightmap":
        """An independent copy (a saved state of the simulation)."""
        c = Heightmap.__new__(Heightmap)
        c._h = self._h.copy()
        return c

    def mark_all_dirty(self) -> None:
        self._h.mark_all_dirty()

    def take_dirty(self) -> tuple[int, int, int, int] | None:
        return self._h.take_dirty()

    @property
    def removed_volume(self) -> float:
        return self._h.removed_volume()
