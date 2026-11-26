"""K12: a snapshot mesh written as 3MF, Rhino .3dm and STEP, and read back."""
import zipfile

import numpy as np

from coastline_engine import mesh_export


def block_with_pocket(n=40):
    """A closed heightfield block 20 × 20 × 5 mm with a 2 mm pocket and a dome: top grid, four
    walls, bottom fan (as SharpSim.mesh builds it)."""
    xs = np.linspace(-10, 10, n)
    X, Y = np.meshgrid(xs, xs)
    Z = np.zeros_like(X)
    Z[(abs(X) < 4.9) & (abs(Y) < 4.9)] = -2.0
    R = np.hypot(X - 6, Y + 6)
    Z = np.where(R < 3, -1.5 + 0.3 * np.sqrt(np.maximum(9 - R ** 2, 0)), Z)
    v = [(x, y, z) for x, y, z in zip(X.ravel(), Y.ravel(), Z.ravel())]
    t = []
    for r in range(n - 1):
        for c in range(n - 1):
            a = r * n + c
            t += [(a, a + 1, a + n + 1), (a, a + n + 1, a + n)]
    loop = list(range(n)) + [j * n + n - 1 for j in range(1, n)] + [(n - 1) * n + i for i in range(n - 2, -1, -1)] \
        + [j * n for j in range(n - 2, 0, -1)]
    base = len(v)
    v += [(v[g][0], v[g][1], -5.0) for g in loop]
    m = len(loop)
    for k in range(m):
        t0, t1, b0, b1 = loop[k], loop[(k + 1) % m], base + k, base + (k + 1) % m
        t += [(t0, b0, b1), (t0, b1, t1)]
    centre = len(v)
    v.append((0.0, 0.0, -5.0))
    t += [(centre, base + (k + 1) % m, base + k) for k in range(m)]
    return np.array(v, dtype=np.float64), np.array(t, dtype=np.int64)


def test_3mf_and_3dm(tmp_path):
    import rhino3dm

    v, t = block_with_pocket()
    mesh_export.export("3mf", str(tmp_path / "s.3mf"), v, t, "Side A · 1:02:14")
    with zipfile.ZipFile(tmp_path / "s.3mf") as z:
        model = z.read("3D/3dmodel.model").decode()
        assert "[Content_Types].xml" in z.namelist() and 'unit="millimeter"' in model
        assert model.count("<triangle ") == len(t) and model.count("<vertex ") == len(v)
    mesh_export.export("3dm", str(tmp_path / "s.3dm"), v, t, "Side A · 1:02:14")
    f = rhino3dm.File3dm.Read(str(tmp_path / "s.3dm"))
    assert f.Settings.ModelUnitSystem == rhino3dm.UnitSystem.Millimeters
    obj = f.Objects[0]
    assert obj.Attributes.Name == "Side A · 1:02:14" and obj.Geometry.Faces.Count == len(t)


def test_step_merges_flat_faces_into_a_closed_solid(tmp_path):
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.STEPControl import STEPControl_Reader
    from OCP.TopAbs import TopAbs_FACE
    from OCP.TopExp import TopExp_Explorer

    v, t = block_with_pocket()
    r = mesh_export.export("step", str(tmp_path / "s.step"), v, t, "snapshot")
    # The flat top, the pocket floor, its walls, the outer walls and the bottom merge; the
    # dome's triangles stay. Far fewer faces than triangles, and a closed, valid solid.
    assert r["solid"] and r["faces"] < len(t) / 3, r
    reader = STEPControl_Reader()
    assert int(reader.ReadFile(str(tmp_path / "s.step"))) == 1
    reader.TransferRoots()
    shape = reader.OneShape()
    assert BRepCheck_Analyzer(shape).IsValid()
    n = 0
    ex = TopExp_Explorer(shape, TopAbs_FACE)
    while ex.More():
        n += 1
        ex.Next()
    assert n == r["faces"]


def test_weld_drops_collapsed_triangles():
    v = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 0.0000001], [2, 0, 0]], dtype=float)
    t = np.array([[0, 1, 2], [0, 3, 1], [0, 1, 4]])
    wv, wt = mesh_export.weld(v, t)
    assert len(wv) == 4 and len(wt) == 1
