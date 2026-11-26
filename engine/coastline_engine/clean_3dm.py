"""A clean OpenCASCADE solid (clean_cad.build) as a joined Rhino polysurface in a .3dm, through the
openNURBS module (`_opennurbs`, built by native/build_opennurbs.sh).

The shape is converted to NURBS throughout (BRepBuilderAPI_NurbsConvert). Then every face gives
its B-spline surface; every edge, numbered once in an indexed map so the two faces that share it
share one Rhino edge, gives its 3D curve and two vertices; every trim gives its 2D curve on its
face, oriented along its loop.
"""
from __future__ import annotations

import numpy as np


def available() -> bool:
    try:
        from . import _opennurbs  # noqa: F401
        return True
    except ImportError:
        return False


def _on_knots(knots, mults) -> list[float]:
    """OCCT knots with multiplicities → openNURBS's knot vector (the flat vector without its first
    and last knot)."""
    flat = []
    for k in range(1, knots.Length() + 1):
        flat += [knots.Value(k)] * mults.Value(k)
    return flat[1:-1]


def _curve3(c) -> tuple:
    c = c.Copy() if hasattr(c, "Copy") else c
    if c.IsPeriodic():
        c.SetNotPeriodic()
    n = c.NbPoles()
    cvs = []
    for i in range(1, n + 1):
        p, w = c.Pole(i), c.Weight(i)
        cvs += [p.X() * w, p.Y() * w, p.Z() * w, w]
    return (3, c.Degree(), n, _on_knots(c.Knots(), c.Multiplicities()), cvs)


def _curve2(c) -> tuple:
    if c.IsPeriodic():
        c.SetNotPeriodic()
    n = c.NbPoles()
    cvs = []
    for i in range(1, n + 1):
        p, w = c.Pole(i), c.Weight(i)
        cvs += [p.X() * w, p.Y() * w, w]
    return (2, c.Degree(), n, _on_knots(c.Knots(), c.Multiplicities()), cvs)


def _surface(s) -> tuple:
    if s.IsUPeriodic():
        s.SetUNotPeriodic()
    if s.IsVPeriodic():
        s.SetVNotPeriodic()
    nu, nv = s.NbUPoles(), s.NbVPoles()
    cvs = []
    for i in range(1, nu + 1):
        for j in range(1, nv + 1):
            p, w = s.Pole(i, j), s.Weight(i, j)
            cvs += [p.X() * w, p.Y() * w, p.Z() * w, w]
    return (s.UDegree(), s.VDegree(), nu, nv, _on_knots(s.UKnots(), s.UMultiplicities()),
            _on_knots(s.VKnots(), s.VMultiplicities()), cvs)


def _snap_loop(curves2: list, ids: list[int]) -> None:
    """Each trim ends exactly where the next one starts (openNURBS checks this strictly): both
    ends move to their midpoint. Clamped NURBS start and end on their first and last control points."""
    def end(i, last):
        _, _, n, _, cvs = curves2[i]
        k = (n - 1) * 3 if last else 0
        w = cvs[k + 2]
        return np.array([cvs[k] / w, cvs[k + 1] / w]), k, w

    for a, b in zip(ids, ids[1:] + ids[:1]):
        pa, ka, wa = end(a, True)
        pb, kb, wb = end(b, False)
        m = (pa + pb) / 2
        curves2[a][4][ka:ka + 2] = [m[0] * wa, m[1] * wa]
        curves2[b][4][kb:kb + 2] = [m[0] * wb, m[1] * wb]


def describe(shape) -> dict:
    """The brep as plain lists for the openNURBS module."""
    from OCP.BRep import BRep_Tool
    from OCP.BRepBuilderAPI import BRepBuilderAPI_NurbsConvert
    from OCP.BRepTools import BRepTools, BRepTools_WireExplorer
    from OCP.collections import IndexedMap_TopoDS_Shape_TopTools_ShapeMapHasher as ShapeMap
    from OCP.Geom import Geom_TrimmedCurve
    from OCP.Geom2d import Geom2d_TrimmedCurve
    from OCP.Geom2dConvert import Geom2dConvert
    from OCP.GeomConvert import GeomConvert
    from OCP.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_FORWARD, TopAbs_REVERSED, TopAbs_VERTEX, TopAbs_WIRE
    from OCP.TopExp import TopExp, TopExp_Explorer
    from OCP.TopoDS import TopoDS

    from OCP.BRepLib import BRepLib
    nurbs = BRepBuilderAPI_NurbsConvert(shape, True).Shape()
    BRepLib.BuildCurves3d_s(nurbs)  # edges that only had curves on their faces
    vmap, emap = ShapeMap(), ShapeMap()
    TopExp.MapShapes_s(nurbs, TopAbs_VERTEX, vmap)
    TopExp.MapShapes_s(nurbs, TopAbs_EDGE, emap)

    vertices = []
    for i in range(1, vmap.Extent() + 1):
        v = TopoDS.Vertex(vmap.FindKey(i))
        p = BRep_Tool.Pnt_s(v)
        vertices.append((p.X(), p.Y(), p.Z(), max(BRep_Tool.Tolerance_s(v), 1e-5)))

    curves3, edges = [], []
    # emap index → Rhino edge index, or a vertex for a zero-length (degenerated) edge: Rhino
    # makes that a singular trim at the vertex, with no edge.
    edge_of: dict[int, int] = {}
    singular_at: dict[int, int] = {}
    for i in range(1, emap.Extent() + 1):
        e = TopoDS.Edge(emap.FindKey(i).Oriented(TopAbs_FORWARD))
        first, last = BRep_Tool.Range_s(e)
        if BRep_Tool.Degenerated_s(e) or not BRep_Tool.IsGeometric_s(e):
            singular_at[i - 1] = vmap.FindIndex(TopExp.FirstVertex_s(e)) - 1
            continue
        c = BRep_Tool.Curve_s(e, first, last)
        bs = GeomConvert.CurveToBSplineCurve_s(Geom_TrimmedCurve(c, first, last))
        curves3.append(_curve3(bs))
        v0 = vmap.FindIndex(TopExp.FirstVertex_s(e)) - 1
        v1 = vmap.FindIndex(TopExp.LastVertex_s(e)) - 1
        # A closed edge (both ends on one spot) starts and ends on one vertex in Rhino.
        if v0 != v1:
            a, b = np.array(vertices[v0][:3]), np.array(vertices[v1][:3])
            if np.linalg.norm(a - b) <= max(vertices[v0][3], vertices[v1][3], 1e-4) * 2:
                v1 = v0
        edges.append((v0, v1, len(curves3) - 1, max(BRep_Tool.Tolerance_s(e), 1e-5)))
        edge_of[i - 1] = len(edges) - 1

    surfaces, curves2, faces = [], [], []
    dropped_faces = dropped_loops = 0
    fx = TopExp_Explorer(nurbs, TopAbs_FACE)
    while fx.More():
        face = TopoDS.Face(fx.Current())
        reversed_face = face.Orientation() == TopAbs_REVERSED
        fwd = TopoDS.Face(face.Oriented(TopAbs_FORWARD))
        s = GeomConvert.SurfaceToBSplineSurface_s(BRep_Tool.Surface_s(fwd))
        surfaces.append(_surface(s))
        si = len(surfaces) - 1
        outer = BRepTools.OuterWire_s(fwd)
        loops = []
        wx = TopExp_Explorer(fwd, TopAbs_WIRE)
        while wx.More():
            wire = TopoDS.Wire(wx.Current())
            trims = []
            ordered = []
            we = BRepTools_WireExplorer(wire, fwd)
            while we.More():
                ordered.append(we.Current())  # oriented as the loop runs
                we.Next()
            if not ordered:  # a single closed edge (a whole circle): the walker skips it
                ex = TopExp_Explorer(wire, TopAbs_EDGE)
                while ex.More():
                    ordered.append(TopoDS.Edge(ex.Current()))
                    ex.Next()
            for e in ordered:
                f2, l2 = BRep_Tool.Range_s(e)
                pc = BRep_Tool.CurveOnSurface_s(e, fwd, f2, l2)
                bs2 = Geom2dConvert.CurveToBSplineCurve_s(Geom2d_TrimmedCurve(pc, f2, l2))
                rev = e.Orientation() == TopAbs_REVERSED
                if rev:
                    bs2.Reverse()
                curves2.append(_curve2(bs2))
                k = emap.FindIndex(e) - 1
                if k in singular_at:
                    trims.append((-1, False, len(curves2) - 1, singular_at[k]))
                else:
                    trims.append((edge_of[k], rev, len(curves2) - 1, -1))
            _snap_loop(curves2, [t[2] for t in trims])
            loops.append((wire.IsSame(outer), trims))
            wx.Next()
        # A loop of one edge that's closed on the surface but open in 3D can't be a Rhino loop:
        # an inner one is left out (that hole closes), a broken outer one leaves the face out.
        def broken(trims):
            if len(trims) != 1:
                return False
            if trims[0][0] < 0:
                return False
            v0, v1, _, tol = edges[trims[0][0]]
            return v0 != v1
        if any(o and broken(t) for o, t in loops):
            dropped_faces += 1
            fx.Next()
            continue
        dropped_loops += sum(1 for o, t in loops if broken(t))
        loops = [(o, t) for o, t in loops if not broken(t)]
        loops.sort(key=lambda l: not l[0])  # the outer loop first
        faces.append((si, reversed_face, loops))
        fx.Next()
    return dict(surfaces=surfaces, curves3=curves3, curves2=curves2, vertices=vertices, edges=edges, faces=faces,
                dropped_faces=dropped_faces, dropped_loops=dropped_loops)


def write(path: str, shape, name: str, layer: str = "Coastline snapshot") -> dict:
    from . import _opennurbs

    d = describe(shape)
    written, valid, log = _opennurbs.write_brep(path, name, layer, d["surfaces"], d["curves3"], d["curves2"],
                                                d["vertices"], d["edges"], d["faces"])
    if not written:
        raise RuntimeError("openNURBS couldn't write the .3dm file")
    return {"faces": len(d["faces"]), "edges": len(d["edges"]), "valid3dm": bool(valid),
            "dropped": d["dropped_faces"] + d["dropped_loops"],
            "log": log[:4000]}
