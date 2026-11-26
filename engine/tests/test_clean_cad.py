"""K12: clean CAD from a simulated heightfield: planes, line/arc walls and a B-spline surface,
not a voxel mesh."""
import numpy as np

from coastline_engine import clean_cad as C


def heights(dish: bool):
    cell = 0.05
    xs = np.arange(-15 + cell / 2, 15, cell)
    ys = np.arange(-10 + cell / 2, 10, cell)
    X, Y = np.meshgrid(xs, ys)
    h = np.zeros_like(X)
    h[np.hypot(X + 6, Y) < 5] = -2.0      # a round pocket
    h[X > 9] = -1.0                       # a step out to the edge
    if dish:                              # a 3D-finished bowl, 2.4 mm deep, sides easing out to its rim
        R = np.hypot(X - 3, Y - 2)
        h = np.where(R < 4, np.minimum(h, -2.4 * (1 - (R / 4) ** 2) ** 2), h)
    h += np.random.default_rng(1).normal(0, 0.002, h.shape) * (h > -0.5)  # micron noise on top
    return h.astype(np.float32), (float(xs[0]), float(ys[0])), cell


def volume(shape):
    from OCP.BRepGProp import BRepGProp
    from OCP.GProp import GProp_GProps
    g = GProp_GProps()
    BRepGProp.VolumeProperties_s(shape, g)
    return g.Mass()


def test_pocket_and_step_come_out_as_planes_and_arcs():
    from OCP.BRepCheck import BRepCheck_Analyzer
    h, origin, cell = heights(dish=False)
    shape, info = C.build(h, origin, cell, 0.0, -6.0)
    kinds = C.faces_by_type(shape)
    assert BRepCheck_Analyzer(shape).IsValid()
    assert kinds.get("Cylinder", 0) >= 1 and sum(kinds.values()) <= 16, kinds  # the round wall is true arcs
    expected = float(np.sum(np.where(h > -0.5, 0.0, h) + 6.0)) * cell * cell
    assert abs(volume(shape) - expected) / expected < 0.005


def test_a_dish_becomes_one_nurbs_surface_in_a_valid_solid():
    from OCP.BRepCheck import BRepCheck_Analyzer
    h, origin, cell = heights(dish=True)
    shape, info = C.build(h, origin, cell, 0.0, -6.0)
    kinds = C.faces_by_type(shape)
    assert BRepCheck_Analyzer(shape).IsValid() and info["patches"] == 1
    assert kinds.get("BSplineSurface", 0) == 1 and sum(kinds.values()) <= 24, kinds
    expected = float(np.sum(np.where(h > -0.5, 0.0, h) + 6.0)) * cell * cell
    assert abs(volume(shape) - expected) / expected < 0.01


def test_outline_fit_finds_the_circle():
    cell = 0.05
    m = np.zeros((300, 300), bool)
    yy, xx = np.mgrid[0:300, 0:300]
    m[np.hypot(xx - 150, yy - 150) < 100] = True    # r = 5 mm
    loop = C.trace_loops(m)[0]
    start, segs = C.fit_outline(C.smooth_loop(loop) * cell, cell * 0.6)
    arcs = [s for s in segs if s[0] == "arc"]
    assert len(segs) <= 3 and len(arcs) >= 1
    assert all(abs(np.hypot(*(s[1] - s[2])) - 5.0) < 0.05 for s in arcs)


def _thin_faces(shape, width: float) -> int:
    """Faces narrower than `width` (twice the area over the perimeter): slivers."""
    from OCP.BRepGProp import BRepGProp
    from OCP.GProp import GProp_GProps
    from OCP.TopAbs import TopAbs_FACE
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopoDS import TopoDS
    n = 0
    ex = TopExp_Explorer(shape, TopAbs_FACE)
    while ex.More():
        f = TopoDS.Face(ex.Current())
        a, p = GProp_GProps(), GProp_GProps()
        BRepGProp.SurfaceProperties_s(f, a)
        BRepGProp.LinearProperties_s(f, p)
        n += 2 * a.Mass() / max(p.Mass(), 1e-9) < width
        ex.Next()
    return n


def test_exact_part_with_the_leftover_has_no_slivers():
    """A plate (the exact part) in a slot cut round it, its hole drilled 0.5 mm on into the bar:
    the leftover's walls take the part's exact circle and lines, so the two merge cleanly."""
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder
    from OCP.gp import gp_Ax2, gp_Dir, gp_Pnt

    plate = BRepPrimAPI_MakeBox(gp_Pnt(-10, -8, -6), 20, 16, 5).Shape()
    part = BRepAlgoAPI_Cut(plate, BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(2, 1, -7), gp_Dir(0, 0, 1)), 3, 8).Shape()).Shape()
    cell = 0.1
    xs = np.arange(-16 + cell / 2, 16, cell)
    ys = np.arange(-12 + cell / 2, 12, cell)
    X, Y = np.meshgrid(xs, ys)
    on = (np.abs(X) < 10) & (np.abs(Y) < 8)
    hole = np.hypot(X - 2, Y - 1) < 3
    h = np.zeros_like(X)                                       # the uncut frame
    h[(np.abs(X) < 13) & (np.abs(Y) < 11)] = -6.0              # the slot round the part
    h[on] = -1.0                                               # the part's top, finished
    h[hole] = -6.5                                             # drilled on into the bar
    top = np.where(on & ~hole, -1.0, np.nan)
    under = np.where(on & ~hole, -6.0, np.nan)
    shape, info = C.build_with_part(h.astype(np.float32), (float(xs[0]), float(ys[0])), cell, 0.0, -8.0,
                                    part, top, under)
    assert info["exact_part"]
    assert BRepCheck_Analyzer(shape).IsValid()
    assert _thin_faces(shape, 0.02) == 0
    kinds = C.faces_by_type(shape)
    assert kinds.get("Cylinder", 0) <= 2 and kinds.get("BSplineSurface", 0) == 0
    from coastline_engine import clean_3dm
    if clean_3dm.available():
        import tempfile, os
        with tempfile.TemporaryDirectory() as d:
            r = clean_3dm.write(os.path.join(d, "t.3dm"), shape, "t")
        assert r["valid3dm"], r["log"][:500]
