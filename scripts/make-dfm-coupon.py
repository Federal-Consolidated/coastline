"""DFM reference coupon: one block with a known answer for every finding.

Run with the engine's Python (writes resources/samples/dfm_coupon.step and checks it):

    engine/.venv/bin/python scripts/make-dfm-coupon.py

The block is exactly 203.2 x 50.8 x 50.8 mm, long along part X: the size of the owned 6061
block, so every outer face can stay as supplied (zero allowance). In part coordinates it spans
(0, 0, 0) .. (203.2, 50.8, 50.8).

Feature face: +Y. The app's default orientation (Setup.defaultOrientation) turns the part's
thinnest axis toward the spindle; Y and Z tie at 50.8 mm and the first index wins (strict "<"),
so +Y faces up. The re-imported bounds are checked below; float noise could break the tie, and
the script then builds the features on whichever axis wins. With that orientation (facing +Y,
spin 1: part X along work Y) the side groove F7 opens toward work +X.

Depths are from the feature face. The Bookends grip the two 50.8 x 50.8 end faces: every
feature is at least 15 mm from them and at least 10 mm from the next. Every inside vertical
corner is rounded. Expected findings with the user's owned tools, ER-11 collets 1/8" and 1/4",
and the Desktop CNC (8 mm max shank, 75 mm max tool length):

F1  pocket 30 x 20, 8 deep, R4 corners.
    OK: the 1/4" flat reaches (flutes >= 8, stick-out 28.575 >= 9 holder depth).
F2  deep narrow pocket, stadium 20 x 6 (full-round ends), 30 deep.
    Missing resource: only 1/8" and 3/16" fit; the 3/16" mills have no collet; 1/8" Helical
    81635 needs >= 31 mm stick-out (set 28.575; 50.8 - 10 grip allows it) and its 9.525 mm
    flutes are shorter than the 30 mm wall (the shank rubs); 1/8" 03017 can't (31 > 38.1 - 10);
    1/4" is too wide. Remedies: stick-out for 81635, add a 4.7625 collet.
F3  narrow slot, stadium 15 x 2, 8 deep.
    Missing resource: only the 1/16" flats fit, and their 3.175 shank is wider than the
    1.5875 cutter, so they stop at 6.35 mm.
F4  blind drilled hole dia 6.35, 20 deep, 118 degree drill point.
    Missing resource: the owned 1/4" drill is 76.2 mm long, over the 75 mm limit; 1/8" 81635
    can bore it (holder depth about 21 <= 28.575) but its shank rubs below 9.525 mm.
F5  recess on the OPPOSITE face, 20 x 20, 3 deep, R3 corners.
    Access "opposite": setup change (needs the back side; not marked solved).
F6  closed T-slot: neck stadium 30 x 6, 5 deep; below it a wider closed cavity, stadium
    36 x 12, 4 tall. Nothing opens to the ends or sides.
    Cavity faces access "none": can't be machined.
F7  side groove in the long side face (part +Z, work +X), stadium 40 x 3 seen from that
    side, 3 deep, 13.5 .. 16.5 mm below the feature face; open only on that side face.
    Access "other" with exactly one side direction: setup change (another orientation).
Stock: the owned 203.2 x 50.8 x 50.8 block fits with zero allowance; the six outer faces stay
as supplied. The 150 x 80 x 20 block is too small: missing resource, use the 203.2 block.
Tools: the two owned 3/16" end mills have no collet; the owned 1/4" drill is over the 75 mm
length limit: missing resource, add a 4.7625 collet.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCP.BRepBuilderAPI import (BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakeWire,
                                BRepBuilderAPI_Transform)
from OCP.BRepCheck import BRepCheck_Analyzer
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCone, BRepPrimAPI_MakeCylinder, BRepPrimAPI_MakePrism
from OCP.GC import GC_MakeArcOfCircle, GC_MakeSegment
from OCP.ShapeUpgrade import ShapeUpgrade_UnifySameDomain
from OCP.gp import gp_Ax1, gp_Ax2, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "resources/samples/dfm_coupon.step"

LENGTH, SIDE = 203.2, 50.8
FEATURE_AXIS = 1  # +Y; see the docstring (checked against the re-imported bounds)

# Local frame (feature face up): x along the length, centred; top at z = 0.
F1 = dict(x=-70.0, length=30.0, width=20.0, depth=8.0, radius=4.0)
F2 = dict(x=-33.0, length=20.0, width=6.0, depth=30.0)
F3 = dict(x=-3.5, length=15.0, width=2.0, depth=8.0)
F4 = dict(x=18.0, diameter=6.35, depth=20.0, point_angle=118.0)
F5 = dict(x=0.0, size=20.0, depth=3.0, radius=3.0)
F6 = dict(x=52.0, neck_length=30.0, neck_width=6.0, neck_depth=5.0, cavity_length=36.0, cavity_width=12.0,
          cavity_height=4.0)
F7 = dict(x=0.0, length=40.0, width=3.0, depth=3.0, z=-15.0)  # on the local -y side face


def _profile(cx: float, cy: float, length: float, width: float, radius: float, z: float):
    """A rounded rectangle (length along x) in the plane Z = z, as a face; radius = width/2
    makes a stadium."""
    r = min(radius, width / 2, length / 2)
    x0, x1, y0, y1 = cx - length / 2, cx + length / 2, cy - width / 2, cy + width / 2
    edges = []

    def line(a, b):
        if math.dist(a, b) > 1e-9:
            edges.append(BRepBuilderAPI_MakeEdge(GC_MakeSegment(gp_Pnt(*a, z), gp_Pnt(*b, z)).Value()).Edge())

    def arc(c, a0):
        pts = [gp_Pnt(c[0] + r * math.cos(a), c[1] + r * math.sin(a), z) for a in (a0, a0 + math.pi / 4, a0 + math.pi / 2)]
        edges.append(BRepBuilderAPI_MakeEdge(GC_MakeArcOfCircle(*pts).Value()).Edge())

    line((x0 + r, y0), (x1 - r, y0))
    arc((x1 - r, y0 + r), -math.pi / 2)
    line((x1, y0 + r), (x1, y1 - r))
    arc((x1 - r, y1 - r), 0.0)
    line((x1 - r, y1), (x0 + r, y1))
    arc((x0 + r, y1 - r), math.pi / 2)
    line((x0, y1 - r), (x0, y0 + r))
    arc((x0 + r, y0 + r), math.pi)
    wire = BRepBuilderAPI_MakeWire()
    for e in edges:
        wire.Add(e)
    return BRepBuilderAPI_MakeFace(wire.Wire()).Face()


def _prism(cx, cy, length, width, radius, z0, z1):
    """The rounded rectangle swept from Z = z0 up to z1."""
    return BRepPrimAPI_MakePrism(_profile(cx, cy, length, width, radius, z0), gp_Vec(0, 0, z1 - z0)).Shape()


def _moved(shape, trsf: gp_Trsf):
    return BRepBuilderAPI_Transform(shape, trsf, True).Shape()


def _cut(body, tool):
    op = BRepAlgoAPI_Cut(body, tool)
    assert op.IsDone()
    return op.Shape()


def local() -> object:
    """The coupon with the feature face up (+Z, top at z = 0), x along the length, centred."""
    body = BRepPrimAPI_MakeBox(gp_Pnt(-LENGTH / 2, -SIDE / 2, -SIDE), LENGTH, SIDE, SIDE).Shape()
    above = 1.0  # cutters start above the faces they open, for clean booleans
    # F1 pocket, F2 deep stadium, F3 narrow stadium (from the feature face).
    body = _cut(body, _prism(F1["x"], 0, F1["length"], F1["width"], F1["radius"], -F1["depth"], above))
    body = _cut(body, _prism(F2["x"], 0, F2["length"], F2["width"], F2["width"] / 2, -F2["depth"], above))
    body = _cut(body, _prism(F3["x"], 0, F3["length"], F3["width"], F3["width"] / 2, -F3["depth"], above))
    # F4 drilled hole: cylinder to the full depth, then the drill point's cone.
    r = F4["diameter"] / 2
    tip = r / math.tan(math.radians(F4["point_angle"] / 2))
    drill = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(F4["x"], 0, -F4["depth"]), gp_Dir(0, 0, 1)), r,
                                     F4["depth"] + above).Shape()
    point = BRepPrimAPI_MakeCone(gp_Ax2(gp_Pnt(F4["x"], 0, -F4["depth"]), gp_Dir(0, 0, -1)), r, 0.0, tip).Shape()
    body = _cut(body, BRepAlgoAPI_Fuse(drill, point).Shape())
    # F5 recess on the opposite face.
    body = _cut(body, _prism(F5["x"], 0, F5["size"], F5["size"], F5["radius"], -SIDE - above, -SIDE + F5["depth"]))
    # F6 closed T-slot: the cavity, then the neck (run into the cavity so the booleans meet).
    cav_top = -F6["neck_depth"]
    body = _cut(body, _prism(F6["x"], 0, F6["cavity_length"], F6["cavity_width"], F6["cavity_width"] / 2,
                             cav_top - F6["cavity_height"], cav_top))
    body = _cut(body, _prism(F6["x"], 0, F6["neck_length"], F6["neck_width"], F6["neck_width"] / 2,
                             cav_top - 0.5, above))
    # F7 groove in the -y side face: a stadium (40 along x, 3 along z) cut 3 deep into y.
    # Swept along z from -depth to +above, then turned (x, y, z) → (x, -z, y): y from -above to
    # depth, so moved to the side face it runs from 1 mm outside to 3 mm in.
    groove = _prism(F7["x"], 0, F7["length"], F7["width"], F7["width"] / 2, -F7["depth"], above)
    turn = gp_Trsf()
    turn.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(1, 0, 0)), math.pi / 2)
    shift = gp_Trsf()
    shift.SetTranslation(gp_Vec(0, -SIDE / 2, F7["z"]))
    body = _cut(body, _moved(_moved(groove, turn), shift))
    unify = ShapeUpgrade_UnifySameDomain(body, True, True, True)
    unify.Build()
    return unify.Shape()


def build(axis: int = FEATURE_AXIS):
    """The coupon in part coordinates, (0, 0, 0) .. (203.2, 50.8, 50.8), with the feature face
    toward + `axis` (1 = Y, 2 = Z)."""
    shape = local()
    t = gp_Trsf()
    if axis == 1:  # local +Z → part +Y: a quarter turn about X, (x, y, z) → (x, z, -y)
        t.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(1, 0, 0)), -math.pi / 2)
        shift = gp_Vec(LENGTH / 2, SIDE, SIDE / 2)
    elif axis == 2:
        shift = gp_Vec(LENGTH / 2, SIDE / 2, SIDE)
    else:
        raise ValueError("the feature face is on Y or Z: X is the long axis")
    move = gp_Trsf()
    move.SetTranslation(shift)
    return _moved(_moved(shape, t), move)


def _quarter(axis, q: int) -> np.ndarray:
    """Setup.rotation(axis:quarterTurns:) (Rodrigues with exact cos/sin)."""
    q %= 4
    c, s = [1.0, 0, -1, 0][q], [0.0, 1, 0, -1][q]
    x, y, z = axis
    return np.array([[c + x * x * (1 - c), x * y * (1 - c) - z * s, x * z * (1 - c) + y * s],
                     [y * x * (1 - c) + z * s, c + y * y * (1 - c), y * z * (1 - c) - x * s],
                     [z * x * (1 - c) - y * s, z * y * (1 - c) + x * s, c + z * z * (1 - c)]])


def default_axis(lo, hi) -> int:
    """Setup.defaultOrientation: the thinnest axis; on a tie the first index (strict <)."""
    size = np.asarray(hi, float) - np.asarray(lo, float)
    thin = 0
    for i in (1, 2):
        if size[i] < size[thin]:
            thin = i
    return thin


def work_transform(lo, hi, axis: int = FEATURE_AXIS) -> np.ndarray:
    """Part → work, 4 x 4 row-major, as the app's default setup with no top allowance: the
    feature face (+axis) toward +Z with its top at Z = 0, centred, the long side along work Y."""
    base = {0: _quarter((0, 1, 0), -1), 1: _quarter((1, 0, 0), 1), 2: np.eye(3)}[axis]
    corners = np.array([[a, b, c] for a in (lo[0], hi[0]) for b in (lo[1], hi[1]) for c in (lo[2], hi[2])])
    rot = base
    for spin in range(4):
        r = _quarter((0, 0, 1), spin) @ base
        w = corners @ r.T
        if np.ptp(w[:, 1]) >= np.ptp(w[:, 0]) - 1e-9:
            rot = r
            break
    w = corners @ rot.T
    m = np.eye(4)
    m[:3, :3] = rot
    m[:3, 3] = [-(w[:, 0].min() + w[:, 0].max()) / 2, -(w[:, 1].min() + w[:, 1].max()) / 2, -w[:, 2].max()]
    return m


def write_step(shape, path: Path) -> None:
    from OCP.IFSelect import IFSelect_RetDone
    from OCP.Interface import Interface_Static
    from OCP.STEPControl import STEPControl_AsIs, STEPControl_Writer

    w = STEPControl_Writer()
    Interface_Static.SetCVal_s("write.step.unit", "MM")
    w.Transfer(shape, STEPControl_AsIs)
    path.parent.mkdir(parents=True, exist_ok=True)
    assert w.Write(str(path)) == IFSelect_RetDone, f"couldn't write {path}"
    # A fixed timestamp (as the other samples): the same geometry gives the same file.
    import re
    text = path.read_text()
    path.write_text(re.sub(r"(FILE_NAME\('[^']*',')[^']*'", r"\g<1>2026-01-01T00:00:00'", text, count=1))


def main() -> int:
    from coastline_engine.cad_import import import_part

    axis = FEATURE_AXIS
    for _ in range(2):
        shape = build(axis)
        assert BRepCheck_Analyzer(shape).IsValid(), "the coupon is not a valid solid"
        write_step(shape, OUT)
        part = import_part(OUT)
        lo, hi = part.bounds
        size = np.asarray(hi) - np.asarray(lo)
        assert np.allclose(size, [LENGTH, SIDE, SIDE], atol=1e-6), size
        chosen = default_axis(lo, hi)
        if chosen == axis:
            break
        axis = chosen  # float noise broke the tie the other way: features on that face
    else:
        raise SystemExit("the default orientation does not settle on one axis")
    print(f"wrote {OUT.relative_to(ROOT)}: {size[0]:.4f} x {size[1]:.4f} x {size[2]:.4f} mm, "
          f"{part.face_count} faces, feature face +{'XYZ'[axis]}")
    if axis != FEATURE_AXIS:
        print(f"note: the default orientation picks +{'XYZ'[axis]}; update FEATURE_AXIS and the docstring")
    return 0


if __name__ == "__main__":
    sys.exit(main())
