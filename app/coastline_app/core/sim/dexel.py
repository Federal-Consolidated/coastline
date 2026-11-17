"""Z-dexel material removal and the cut check. Port of Sim/DexelSim.swift; the grid itself is
C++ (native/src/kernels.cpp, built by scripts/build_native.py)."""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum

import numpy as np

from ... import _kernels as K
from ..post.toolpath import Role, ToolpathGeometry


class ToolShapeKind(Enum):
    FLAT = "flat"
    BALL = "ball"
    DRILL = "drill"
    DISC = "disc"


_KIND = {ToolShapeKind.FLAT: K.ToolKind.flat, ToolShapeKind.BALL: K.ToolKind.ball,
         ToolShapeKind.DRILL: K.ToolKind.drill, ToolShapeKind.DISC: K.ToolKind.disc}


@dataclass(frozen=True)
class ToolShape:
    """The shape a tool sweeps (work frame: the tool axis is Z, the tip at 0)."""

    kind: ToolShapeKind
    radius: float
    length: float  # how far the tool reaches above its tip (the stick-out)
    disc_thickness: float = 0.0
    shank_radius: float = 0.0

    @staticmethod
    def from_spec(tool, stickout: float) -> "ToolShape":
        """From a job's tool (ProgramJob.ToolSpec), with the stick-out it is used at."""
        try:
            kind = ToolShapeKind(tool.shape or "")
        except ValueError:
            kind = ToolShapeKind.DRILL if "drill" in tool.kind.lower() else ToolShapeKind.FLAT
        return ToolShape(kind, tool.diameter / 2, max(stickout, 1.0),
                         tool.disc_thickness if tool.disc_thickness is not None else tool.diameter,
                         (tool.shank_diameter if tool.shank_diameter is not None else tool.diameter) / 2)

    @property
    def native(self):
        return K.ToolShape(_KIND[self.kind], self.radius, self.length, self.disc_thickness, self.shank_radius)

    def ranges(self, r: float) -> tuple[float, float]:
        return self.native.ranges(r)


class DexelGrid:
    """Z-dexels over the work XY: per column (cell), the Z spans a tool swept."""

    def __init__(self, min, max, cell: float, _grid=None) -> None:
        self._g = _grid if _grid is not None else K.DexelGrid(float(min[0]), float(min[1]), float(max[0]), float(max[1]), float(cell))

    @staticmethod
    def _wrap(g) -> "DexelGrid":
        return DexelGrid(None, None, 0, _grid=g)

    @property
    def origin(self) -> tuple[float, float]:
        return (self._g.origin_x, self._g.origin_y)

    @property
    def cell(self) -> float:
        return self._g.cell

    @property
    def cols(self) -> int:
        return self._g.cols

    @property
    def rows(self) -> int:
        return self._g.rows

    def centre(self, c: int, r: int) -> tuple[float, float]:
        return (self._g.origin_x + c * self._g.cell, self._g.origin_y + r * self._g.cell)

    def copy(self) -> "DexelGrid":
        return DexelGrid._wrap(self._g.copy())

    def spans(self, index: int) -> list[tuple[float, float]]:
        return self._g.spans(index)

    def set_spans(self, index: int, spans: list[tuple[float, float]]) -> None:
        self._g.set_spans(index, spans)

    def merge(self, other: "DexelGrid") -> None:
        """Adds every span of `other` (same layout): the union of two solids."""
        self._g.merge(other._g)

    def flat(self) -> tuple[np.ndarray, np.ndarray]:
        """All spans: rows offsets[k] … offsets[k + 1] of the (m, 2) float32 array are cell k's."""
        return self._g.flat()

    def covered(self, cells, lo, hi) -> np.ndarray:
        """Per query: whether [lo, hi] in cell `cells[q]` is covered by its spans."""
        return self._g.covered(np.asarray(cells, np.int64), np.asarray(lo, float), np.asarray(hi, float))

    def near(self, cols, rows, w, tol: float) -> np.ndarray:
        """Per query point: a span within `tol` of w in the 3×3 cells around (col, row)."""
        return self._g.near(np.asarray(cols, np.int64), np.asarray(rows, np.int64), np.asarray(w, float), float(tol))

    def add(self, index: int, lo: float, hi: float) -> None:
        self._g.add(index, lo, hi)

    def sweep(self, a, b, tool: ToolShape) -> None:
        """Sweeps the tool from tip a to tip b (work frame)."""
        self._g.sweep(float(a[0]), float(a[1]), float(a[2]), float(b[0]), float(b[1]), float(b[2]), tool.native)

    def sweep_path(self, points, tool: ToolShape) -> None:
        """Sweeps along consecutive tip positions (N×3)."""
        self._g.sweep_path(np.asarray(points, float).reshape(-1, 3), tool.native)

    def fill(self, vertices, indices) -> None:
        """Fills the grid with the inside of a closed mesh (work frame)."""
        self._g.fill(np.asarray(vertices, np.float32).reshape(-1), np.asarray(indices, np.uint32).reshape(-1))

    def intersection(self, other: "DexelGrid", minimum: float = 0.0) -> "DexelGrid":
        return DexelGrid._wrap(self._g.intersection(other._g, minimum))

    def clipped(self, lo, hi) -> "DexelGrid":
        return DexelGrid._wrap(self._g.clipped(float(lo[0]), float(lo[1]), float(lo[2]), float(hi[0]), float(hi[1]), float(hi[2])))

    def subtracting(self, other: "DexelGrid", minimum: float = 0.0) -> "DexelGrid":
        return DexelGrid._wrap(self._g.subtracting(other._g, minimum))

    @property
    def volume(self) -> float:
        return self._g.volume()

    @property
    def is_empty(self) -> bool:
        return self._g.empty()

    def mesh(self) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Tops, bottoms, and the walls where a neighbour's spans don't cover them."""
        return self._g.mesh()


@dataclass
class CutCheckResult:
    removed: DexelGrid
    gouge: DexelGrid | None = None
    rapid_hits: DexelGrid | None = None

    @property
    def gouge_volume(self) -> float:
        return self.gouge.volume if self.gouge is not None else 0.0

    @property
    def rapid_hit_volume(self) -> float:
        return self.rapid_hits.volume if self.rapid_hits is not None else 0.0


class CutCheck:
    """What a program cuts: the volume its tool sweeps while cutting, the part of that inside the
    finished part (a gouge), and rapid moves that pass through the part."""

    @staticmethod
    def run(program, tool: ToolShape, part=None, cell: float = 0.2, part_minimum: float = 0.05) -> CutCheckResult | None:
        """`part` is (vertices, indices) of the finished part in the work frame (None: no gouge
        check). Moves with an unknown start and probe moves are left out."""
        probe = set(program.probe_moves)
        positions = [m.position for k, m in enumerate(program.moves) if k not in probe]
        if not positions:
            return None
        arr = np.array(positions, float)
        lo, hi = arr.min(axis=0), arr.max(axis=0)
        pad = tool.radius + 2
        gmin, gmax = (lo[0] - pad, lo[1] - pad), (hi[0] + pad, hi[1] + pad)
        cut = DexelGrid(gmin, gmax, cell)
        rapid = DexelGrid(gmin, gmax, cell)
        unknown = set(program.unknown_start)
        for k, move in enumerate(program.moves):
            start = program.start(k)
            if start is None or k in unknown or k in probe:
                continue
            pts = [start] + ToolpathGeometry.points(move, start)
            (rapid if move.role == Role.RAPID else cut).sweep_path(pts, tool)
        if part is None:
            return CutCheckResult(cut)
        vertices, indices = part
        solid = DexelGrid(gmin, gmax, cell)
        solid.fill(vertices, indices)
        v = np.asarray(vertices, float).reshape(-1, 3)
        bmin, bmax = v.min(axis=0), v.max(axis=0)
        return CutCheckResult(cut.clipped(bmin, bmax), cut.intersection(solid, part_minimum),
                              rapid.intersection(solid, part_minimum).subtracting(cut, part_minimum))
