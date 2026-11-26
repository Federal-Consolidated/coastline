"""Writes a closed triangle mesh (a sharp snapshot of the simulated stock, K12) as a Rhino .3dm,
a 3MF or a STEP file. Coordinates are millimetres.

STEP has no compact mesh entity: every triangle becomes a planar face. The mesh is welded,
built as one shell with shared edges (no sewing needed), and adjacent coplanar faces are merged
(ShapeUpgrade_UnifySameDomain), so flat floors, faces and walls come out as single faces and
only curved areas stay faceted.
"""
from __future__ import annotations

import io
import zipfile

import numpy as np


def weld(vertices: np.ndarray, triangles: np.ndarray, tol: float = 1e-5) -> tuple[np.ndarray, np.ndarray]:
    """Merges vertices closer than tol (on a grid) and drops triangles that collapse."""
    key = np.round(vertices / tol).astype(np.int64)
    _, first, inverse = np.unique(key, axis=0, return_index=True, return_inverse=True)
    v = vertices[first]
    t = inverse.reshape(-1)[triangles]
    keep = (t[:, 0] != t[:, 1]) & (t[:, 1] != t[:, 2]) & (t[:, 2] != t[:, 0])
    t = t[keep]
    # Zero-area slivers (three points on a line) can't be faces.
    a, b, c = v[t[:, 0]], v[t[:, 1]], v[t[:, 2]]
    area = np.linalg.norm(np.cross(b - a, c - a), axis=1)
    return v, t[area > tol * tol]


def write_3mf(path: str, vertices: np.ndarray, triangles: np.ndarray, name: str) -> None:
    vs = "\n".join(f'<vertex x="{x:.5f}" y="{y:.5f}" z="{z:.5f}"/>' for x, y, z in vertices.tolist())
    ts = "\n".join(f'<triangle v1="{a}" v2="{b}" v3="{c}"/>' for a, b, c in triangles.tolist())
    title = (name.replace("&", "&amp;").replace("<", "&lt;").replace('"', "&quot;"))
    model = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">\n'
        f'<metadata name="Title">{title}</metadata>\n'
        f'<resources><object id="1" type="model" name="{title}"><mesh>\n<vertices>\n{vs}\n</vertices>\n'
        f'<triangles>\n{ts}\n</triangles>\n</mesh></object></resources>\n'
        '<build><item objectid="1"/></build>\n</model>\n')
    types = ('<?xml version="1.0" encoding="UTF-8"?>\n'
             '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
             '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
             '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>\n')
    rels = ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Target="/3D/3dmodel.model" Id="rel0" '
            'Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>\n')
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", types)
        z.writestr("_rels/.rels", rels)
        z.writestr("3D/3dmodel.model", model)


def write_3dm(path: str, vertices: np.ndarray, triangles: np.ndarray, name: str) -> None:
    # openNURBS directly when the engine has it: the file then holds no path (rhino3dm's
    # File3dm.Write records the full path it was written to, with the user's folders).
    try:
        from . import _opennurbs
        if not _opennurbs.write_mesh(path, name, "Coastline snapshot", np.asarray(vertices, np.float32).ravel().tolist(),
                                     np.asarray(triangles, np.int64).ravel().tolist()):
            raise RuntimeError("openNURBS couldn't write the .3dm file")
        return
    except ImportError:
        pass
    import os
    import shutil
    import tempfile

    import rhino3dm
    # Without openNURBS: write it under a neutral name in a temporary folder, then move it.
    final, tmpdir = path, tempfile.mkdtemp()
    path = os.path.join(tmpdir, "snapshot.3dm")

    model = rhino3dm.File3dm()
    model.Settings.ModelUnitSystem = rhino3dm.UnitSystem.Millimeters
    layer = rhino3dm.Layer()
    layer.Name = "Coastline snapshot"
    li = model.Layers.Add(layer)
    mesh = rhino3dm.Mesh()
    for x, y, z in vertices.tolist():
        mesh.Vertices.Add(x, y, z)
    for a, b, c in triangles.tolist():
        mesh.Faces.AddFace(a, b, c)
    mesh.Normals.ComputeNormals()
    mesh.Compact()
    attrs = rhino3dm.ObjectAttributes()
    attrs.Name = name
    attrs.LayerIndex = li
    model.Objects.AddMesh(mesh, attrs)
    if not model.Write(path, 7):
        raise RuntimeError("rhino3dm couldn't write the file")
    shutil.move(path, final)
    shutil.rmtree(tmpdir, ignore_errors=True)


def write_step(path: str, vertices: np.ndarray, triangles: np.ndarray, name: str) -> dict:
    from OCP.BRep import BRep_Builder
    from OCP.BRepBuilderAPI import (BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeFace,
                                    BRepBuilderAPI_MakeVertex, BRepBuilderAPI_MakeWire)
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.gp import gp_Pnt
    from OCP.Interface import Interface_Static
    from OCP.ShapeUpgrade import ShapeUpgrade_UnifySameDomain
    from OCP.STEPControl import STEPControl_AsIs, STEPControl_Writer
    from OCP.TopAbs import TopAbs_FACE
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopoDS import TopoDS_Shell

    v, t = weld(np.asarray(vertices, dtype=np.float64), np.asarray(triangles, dtype=np.int64))
    verts = [BRepBuilderAPI_MakeVertex(gp_Pnt(x, y, z)).Vertex() for x, y, z in v.tolist()]
    edges: dict[tuple[int, int], object] = {}

    def edge(i: int, j: int):
        k = (i, j) if i < j else (j, i)
        e = edges.get(k)
        if e is None:
            e = BRepBuilderAPI_MakeEdge(verts[k[0]], verts[k[1]]).Edge()
            edges[k] = e
        return e

    builder = BRep_Builder()
    shell = TopoDS_Shell()
    builder.MakeShell(shell)
    skipped = 0
    for a, b, c in t.tolist():
        try:
            w = BRepBuilderAPI_MakeWire(edge(a, b), edge(b, c), edge(c, a)).Wire()
            f = BRepBuilderAPI_MakeFace(w, True)
        except Exception:
            skipped += 1
            continue
        if f.IsDone():
            builder.Add(shell, f.Face())
        else:
            skipped += 1
    # A closed shell becomes a solid first (ShapeFix orients its faces outward); then the
    # coplanar faces merge. An open one (a hole in the mesh) goes out as a shell.
    from OCP.ShapeFix import ShapeFix_Shell, ShapeFix_Solid
    from OCP.BRep import BRep_Tool
    solid = False
    shape = shell
    try:
        fix = ShapeFix_Shell(shell)
        fix.Perform()
        fixed = fix.Shell()
        if BRep_Tool.IsClosed_s(fixed):
            s0 = ShapeFix_Solid().SolidFromShell(fixed)
            if BRepCheck_Analyzer(s0).IsValid():
                shape, solid = s0, True
    except Exception:
        pass
    unify = ShapeUpgrade_UnifySameDomain(shape, True, True, False)
    unify.Build()
    if not solid or BRepCheck_Analyzer(unify.Shape()).IsValid():
        shape = unify.Shape()
    faces = 0
    ex = TopExp_Explorer(shape, TopAbs_FACE)
    while ex.More():
        faces += 1
        ex.Next()
    Interface_Static.SetCVal_s("write.step.unit", "MM")
    Interface_Static.SetCVal_s("write.step.product.name", name[:60] or "Coastline snapshot")
    w = STEPControl_Writer()
    w.Transfer(shape, STEPControl_AsIs)
    if int(w.Write(path)) != 1:  # IFSelect_RetDone
        raise RuntimeError("OpenCASCADE couldn't write the STEP file")
    return {"faces": faces, "solid": solid, "skipped": skipped, "triangles": int(len(t))}


def export(fmt: str, path: str, vertices: np.ndarray, triangles: np.ndarray, name: str) -> dict:
    fmt = fmt.lower()
    if fmt == "3mf":
        write_3mf(path, vertices, triangles, name)
        return {"triangles": int(len(triangles))}
    if fmt == "3dm":
        write_3dm(path, vertices, triangles, name)
        return {"triangles": int(len(triangles))}
    if fmt in ("step", "stp"):
        return write_step(path, vertices, triangles, name)
    raise ValueError(f"unknown mesh format {fmt}")
