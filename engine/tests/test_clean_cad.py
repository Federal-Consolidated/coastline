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
