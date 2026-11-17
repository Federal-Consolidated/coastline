"""What limits machining a part, as measured by the engine, and which way a tool sees each face.
Port of Plan/PartAnalysis.swift (PartAnalysis, PartAccess, EngineClient.analyse)."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

import numpy as np

from ..engine.client import row_major

ZERO3 = (0.0, 0.0, 0.0)


class Access(Enum):
    THIS_SIDE = "this"
    OPPOSITE_SIDE = "opposite"
    OTHER_DIRECTION = "other"
    NO_ACCESS = "none"


@dataclass
class Face:
    index: int  # B-rep face index (TopExp_Explorer order on the transformed shape)
    area: float = 0.0
    kind: str = "plane"  # "plane", "cylinder" or "other"
    boundary: str | None = None  # "+x" … "-z": on the part's own bounding-box plane, facing out
    plane_offset: float | None = None
    access: Access = Access.THIS_SIDE
    visible: dict[str, float] = field(default_factory=dict)  # line-of-sight share per direction


@dataclass
class RegionSide:
    side: str  # the direction the tool comes from
    depth: float  # how deep that share lies from the part's outside on that side, mm
    share: float = 1.0


@dataclass
class ThreadEnd:
    side: str
    depth: float
    open: bool


@dataclass
class Thread:
    sides: list[ThreadEnd]  # open ends first, then the shallower
    major: float
    minor: float
    length: float


@dataclass
class Region:
    """Connected faces (not on the bounding box) the tool can't see from +Z."""

    faces: list[int]
    access: Access
    area: float = 0.0
    directions: list[str] = field(default_factory=list)  # axis directions seeing every sample
    min: tuple = ZERO3
    max: tuple = ZERO3
    sides: list[RegionSide] = field(default_factory=list)
    sides_two: list[RegionSide] | None = None  # when both sides are machined (None: as `sides`)
    thread: Thread | None = None

    def __post_init__(self) -> None:
        if self.sides_two is None:
            self.sides_two = list(self.sides)


@dataclass
class Floor:
    """An up-facing flat floor below the part top that the tool sees from +Z."""

    face: int
    z: float
    width: float  # largest circle that fits in the floor
    wall_depth: float  # highest finished material within 1 mm around, above it
    holder_depth: float  # shortest stick-out keeping the collet nut 1 mm above the part
    area: float = 0.0
    min: tuple = ZERO3
    max: tuple = ZERO3
    enclosed: float | None = None  # share of the ring round the floor where a wall rises


@dataclass
class Hole:
    faces: list[int]
    diameter: float
    z_top: float
    z_bottom: float
    holder_depth: float
    x: float = 0.0
    y: float = 0.0
    through: bool = False
    access: Access = Access.THIS_SIDE

    @property
    def length(self) -> float:
        return self.z_top - self.z_bottom


@dataclass
class PartAccess:
    faces: list[Face] = field(default_factory=list)
    regions: list[Region] = field(default_factory=list)
    floors: list[Floor] = field(default_factory=list)
    holes: list[Hole] = field(default_factory=list)
    part_min: tuple = ZERO3  # the finished part's bounds, work frame
    part_max: tuple = ZERO3
    triangles: np.ndarray = field(default_factory=lambda: np.zeros(0, np.float32))  # 9 floats per triangle
    face_triangles: dict[int, range] = field(default_factory=dict)

    def __eq__(self, o) -> bool:
        return (isinstance(o, PartAccess) and (self.faces, self.regions, self.floors, self.holes, self.part_min, self.part_max,
                                               self.face_triangles) == (o.faces, o.regions, o.floors, o.holes, o.part_min,
                                                                        o.part_max, o.face_triangles)
                and np.array_equal(self.triangles, o.triangles))

    @staticmethod
    def from_json(j: dict, triangles=None) -> "PartAccess":
        def num(v):
            return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None

        def integer(v) -> int:
            return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else -1

        def vec(v) -> tuple:
            a = [float(x) for x in v if num(x) is not None] if isinstance(v, list) else []
            return (a[0], a[1], a[2]) if len(a) == 3 else ZERO3

        def ints(v) -> list[int]:
            return [int(x) for x in v if num(x) is not None] if isinstance(v, list) else []

        def access(v) -> Access:
            try:
                return Access(v)
            except ValueError:
                return Access.NO_ACCESS

        def lst(key):
            v = j.get(key)
            return [x for x in v if isinstance(x, dict)] if isinstance(v, list) else []

        faces = [Face(integer(f.get("index")), num(f.get("area")) or 0.0, f.get("kind") if isinstance(f.get("kind"), str) else "other",
                      f.get("boundary") if isinstance(f.get("boundary"), str) else None, num(f.get("plane_offset")),
                      access(f.get("access")),
                      {k: num(v) for k, v in (f.get("visible") or {}).items() if num(v) is not None}) for f in lst("faces")]

        def sides(v) -> list[RegionSide]:
            out = []
            for s in v if isinstance(v, list) else []:
                if isinstance(s, dict) and isinstance(s.get("side"), str) and num(s.get("depth")) is not None:
                    out.append(RegionSide(s["side"], num(s["depth"]), num(s.get("share")) or 0.0))
            return out

        regions = []
        for r in lst("regions"):
            t = r.get("thread")
            thread = None
            if isinstance(t, dict):
                ends = [ThreadEnd(e["side"], num(e["depth"]), e.get("open") is True) for e in t.get("sides") or []
                        if isinstance(e, dict) and isinstance(e.get("side"), str) and num(e.get("depth")) is not None]
                thread = Thread(ends, num(t.get("major")) or 0.0, num(t.get("minor")) or 0.0, num(t.get("length")) or 0.0)
            regions.append(Region(ints(r.get("faces")), access(r.get("access")), num(r.get("area")) or 0.0,
                                  [d for d in r.get("directions") or [] if isinstance(d, str)], vec(r.get("min")), vec(r.get("max")),
                                  sides(r.get("sides")), None if r.get("sides_two") is None else sides(r.get("sides_two")), thread))
        floors = [Floor(integer(f.get("face")), num(f.get("z")) or 0.0, num(f.get("width")) or 0.0, num(f.get("wall_depth")) or 0.0,
                        num(f.get("holder_depth")) or 0.0, num(f.get("area")) or 0.0, vec(f.get("min")), vec(f.get("max")),
                        num(f.get("enclosed"))) for f in lst("floors")]
        holes = [Hole(ints(h.get("faces")), num(h.get("diameter")) or 0.0, num(h.get("z_top")) or 0.0, num(h.get("z_bottom")) or 0.0,
                      num(h.get("holder_depth")) or 0.0, num(h.get("x")) or 0.0, num(h.get("y")) or 0.0, h.get("through") is True,
                      access(h.get("access"))) for h in lst("holes")]
        ranges = {}
        for row in j.get("face_triangles") or []:
            v = ints(row)
            if len(v) == 3 and v[1] >= 0 and v[2] >= 0:
                ranges[v[0]] = range(v[1], v[1] + v[2])
        tri = np.asarray(triangles if triangles is not None else [], np.float32).reshape(-1)
        return PartAccess(faces, regions, floors, holes, vec(j.get("part_min")), vec(j.get("part_max")), tri, ranges)

    def triangles_for_faces(self, ids) -> np.ndarray:
        """The triangles of these faces (work frame, 9 floats each), for highlighting."""
        out, seen = [], set()
        for i in ids:
            if i in seen:
                continue
            seen.add(i)
            r = self.face_triangles.get(i)
            if r is None:
                continue
            n = len(self.triangles)
            out.append(self.triangles[min(r.start * 9, n):min(r.stop * 9, n)])
        return np.concatenate(out) if out else np.zeros(0, np.float32)

    def bounds_for_faces(self, ids) -> tuple[np.ndarray, np.ndarray] | None:
        t = self.triangles_for_faces(ids)
        if len(t) < 3:
            return None
        p = t[: len(t) // 3 * 3].astype(float).reshape(-1, 3)
        return p.min(axis=0), p.max(axis=0)

    def face(self, index: int) -> Face | None:
        return next((f for f in self.faces if f.index == index), None)

    def boundary_faces(self, side: str) -> list[Face]:
        return [f for f in self.faces if f.boundary == side]


@dataclass
class PartAnalysis:
    min_corner_radius: float | None = None
    min_concave_radius: float | None = None
    undercut_area: float = 0.0
    thinnest_wall: float | None = None
    depth: float = 0.0
    parting_z: float | None = None  # where the cross-section is largest: the split for two-sided jobs
    undercut_triangles: np.ndarray = field(default_factory=lambda: np.zeros(0, np.float32))
    freeform_area: float = 0.0  # faces 2.5D operations can't finish, mm²
    flat_area: float = 0.0
    wall_area: float = 0.0
    steep_area: float = 0.0
    volume: float = 0.0
    circularity: float = 0.0  # 1 = a disc
    access: PartAccess | None = None

    def __eq__(self, o) -> bool:
        if not isinstance(o, PartAnalysis):
            return False
        keys = ("min_corner_radius", "min_concave_radius", "undercut_area", "thinnest_wall", "depth", "parting_z", "freeform_area",
                "flat_area", "wall_area", "steep_area", "volume", "circularity", "access")
        return all(getattr(self, k) == getattr(o, k) for k in keys) and np.array_equal(self.undercut_triangles, o.undercut_triangles)


NUT_RADIUS = 8.0


def analyse(engine, part_id: str, transform, access: bool = False, nut_radius: float = NUT_RADIUS) -> PartAnalysis:
    """`access`: also measure line of sight per face, floors, holes and holder depth (slower; DFM needs it)."""
    params = {"part_id": part_id, "transform": row_major(transform)}
    if access:
        params["access"] = True
        params["nut_radius"] = nut_radius
    r, blobs = engine.call("analyse", params)
    if r.get("exact") is not True:
        return PartAnalysis()

    def f32(b: bytes) -> np.ndarray:
        return np.frombuffer(b, "<f4", len(b) // 4).astype(np.float32)

    def num(k):
        v = r.get(k)
        return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None

    triangles = f32(blobs[1]) if len(blobs) > 1 else np.zeros(0, np.float32)
    a = r.get("access")
    return PartAnalysis(num("min_corner_radius"), num("min_concave_radius"), num("undercut_area") or 0.0, num("thinnest_wall"),
                        num("depth") or 0.0, num("parting_z"), f32(blobs[0]) if blobs else np.zeros(0, np.float32),
                        num("freeform_area") or 0.0, num("flat_area") or 0.0, num("wall_area") or 0.0, num("steep_area") or 0.0,
                        num("volume") or 0.0, num("circularity") or 0.0,
                        PartAccess.from_json(a, triangles) if isinstance(a, dict) else None)
