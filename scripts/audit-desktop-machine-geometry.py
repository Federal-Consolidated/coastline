#!/usr/bin/env python3
"""Check the desktop profile against exact STEP solids, without Fusion or a machine.

Run with engine/.venv/bin/python. These are selected geometric checks, not a full
machine collision certificate or a measurement of the installed controller.
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
from pathlib import Path

import numpy as np
from OCP.Bnd import Bnd_Box
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.BRepAlgoAPI import BRepAlgoAPI_Common
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepClass3d import BRepClass3d_SolidClassifier
from OCP.BRepExtrema import BRepExtrema_DistShapeShape
from OCP.BRepGProp import BRepGProp
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCP.GeomAbs import GeomAbs_Cylinder, GeomAbs_Plane
from OCP.GProp import GProp_GProps
from OCP.IFSelect import IFSelect_ReturnStatus
from OCP.STEPCAFControl import STEPCAFControl_Reader
from OCP.TCollection import TCollection_ExtendedString
from OCP.TDataStd import TDataStd_Name
from OCP.TDF import TDF_Label
from OCP.TDocStd import TDocStd_Document
from OCP.TopAbs import TopAbs_FACE, TopAbs_IN, TopAbs_OUT, TopAbs_SOLID
from OCP.TopExp import TopExp_Explorer
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS
from OCP.XCAFDoc import XCAFDoc_DocumentTool
from OCP.collections import Sequence_TDF_Label
from OCP.gp import gp_Pnt, gp_Trsf, gp_Vec


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GEOMETRY = ROOT / "resources/machine-profile-sources/desktop-cnc-full.step"
TOLERANCE_MM = 0.001


def leaves(path: Path) -> list[tuple[list[str], object]]:
    """Return occurrence shapes in world millimetres; STEP declares its units."""
    document = TDocStd_Document(TCollection_ExtendedString("desktop-geometric-evidence"))
    reader = STEPCAFControl_Reader()
    reader.SetNameMode(True)
    if reader.ReadFile(str(path)) != IFSelect_ReturnStatus.IFSelect_RetDone or not reader.Transfer(document):
        raise ValueError("Cannot read the machine STEP assembly")
    tool = XCAFDoc_DocumentTool.ShapeTool_s(document.Main())
    result = []

    def name(label):
        value = TDataStd_Name()
        return value.Get().ToExtString() if label.FindAttribute(TDataStd_Name.GetID_s(), value) else ""

    def visit(label, location, names):
        children = Sequence_TDF_Label()
        tool.GetComponents_s(label, children)
        if not len(children):
            result.append((names, tool.GetShape_s(label).Moved(location)))
        for child in children:
            referred = TDF_Label()
            if not tool.GetReferredShape_s(child, referred):
                raise ValueError("STEP occurrence lacks its referenced shape")
            visit(referred, location.Multiplied(tool.GetLocation_s(child)), names + [name(referred)])

    roots = Sequence_TDF_Label()
    tool.GetFreeShapes(roots)
    for root in roots:
        visit(root, tool.GetLocation_s(root), [name(root)])
    return result


def bounds(shape) -> list[list[float]]:
    box = Bnd_Box()
    BRepBndLib.AddOptimal_s(shape, box, False, False)
    return [list(box.CornerMin().Coord()), list(box.CornerMax().Coord())]


def volume(shape) -> float:
    properties = GProp_GProps()
    BRepGProp.VolumeProperties_s(shape, properties)
    return properties.Mass()


def count_solids(shape) -> int:
    solids = TopExp_Explorer(shape, TopAbs_SOLID)
    count = 0
    while solids.More():
        count += 1
        solids.Next()
    return count


def translated(shape, displacement):
    transform = gp_Trsf()
    transform.SetTranslation(gp_Vec(*displacement))
    return shape.Moved(TopLoc_Location(transform))


def overlap(a, b) -> float:
    common = BRepAlgoAPI_Common(a, b)
    common.Build()
    if not common.IsDone():
        raise ValueError("OpenCascade could not complete a contact check")
    return max(0.0, volume(common.Shape()))


def table_surface(table) -> dict:
    """Find the broad upper plane, ignoring small fastener pads at the same X."""
    candidates = []
    faces = TopExp_Explorer(table, TopAbs_FACE)
    while faces.More():
        face = TopoDS.Face(faces.Current())
        surface = BRepAdaptor_Surface(face)
        if surface.GetType() == GeomAbs_Plane:
            plane = surface.Plane()
            box = bounds(face)
            if abs(plane.Axis().Direction().X()) > 1 - 1e-9 and box[1][1] - box[0][1] > 300:
                candidates.append((plane.Location().X(), box))
        faces.Next()
    if not candidates:
        raise ValueError("No broad planar table support surface found")
    top = max(candidate[0] for candidate in candidates)
    support = [box for x, box in candidates if abs(x - top) < TOLERANCE_MM]
    return {"worldX": top, "normal": [1, 0, 0],
            "minimum": np.min([b[0] for b in support], axis=0).tolist(),
            "maximum": np.max([b[1] for b in support], axis=0).tolist()}


def check_seating_frame(surface: dict, frame: dict) -> dict:
    """Compare an asymmetric stock prism with the independently measured CAD plane."""
    vector = lambda field: np.array([frame[field][axis] for axis in "xyz"], dtype=float)
    origin, x, z = vector("origin"), vector("xDirection"), vector("zDirection")
    y = np.cross(z, x)
    matrix = np.column_stack((x, y, z))
    if not np.allclose(matrix.T @ matrix, np.eye(3), atol=1e-9):
        raise ValueError("Stock seating frame must be orthonormal")
    if not np.allclose(z, surface["normal"], atol=1e-9):
        raise ValueError("Stock thickness must point away from the actual table plane")
    dimensions = np.array([203.2, 37.0, 50.8])  # Deliberately asymmetric; swapping axes is observable.
    corners = np.array([origin + matrix @ (dimensions * corner)
                        for corner in itertools.product((0, 1), repeat=3)])
    bottom = np.array([origin + matrix @ [a, b, 0]
                       for a, b in itertools.product((0, dimensions[0]), (0, dimensions[1]))])
    plane_error = float(np.max(np.abs(bottom[:, 0] - surface["worldX"])))
    if plane_error > TOLERANCE_MM:
        raise ValueError("Stock bottom does not sit on the CAD table plane")
    lo, hi = corners.min(axis=0), corners.max(axis=0)
    if any(lo[i] < surface["minimum"][i] - TOLERANCE_MM or
           hi[i] > surface["maximum"][i] + TOLERANCE_MM for i in (1, 2)):
        raise ValueError("Reference stock footprint extends beyond the raised table surface")
    if not np.allclose(hi - lo, [50.8, 203.2, 37], atol=1e-6):
        raise ValueError("Asymmetric stock dimensions are rotated incorrectly")
    return {"localDimensionsMM": dimensions.tolist(), "worldBoundsMM": [lo.tolist(), hi.tolist()],
            "maximumBottomPlaneErrorMM": plane_error, "tableNormal": z.tolist(),
            "worldFromLocalBasisColumns": matrix.T.tolist()}


def check_bookend_slot(table, surface) -> dict:
    """Test a conservative rectangular M5 nut/key envelope against actual table material."""
    top = surface["worldX"]
    centers = [78.7585941251, 118.7635941251]
    results = []
    for center in centers:
        # Source wh_build2.py: M5x0.8 nut 11 x 11.6 x 2.8; key 6 x 1.8.
        nut = BRepPrimAPI_MakeBox(gp_Pnt(top - 4.8, -255.5, center - 5.8), 2.8, 11, 11.6).Shape()
        key = BRepPrimAPI_MakeBox(gp_Pnt(top - 1.8, -255, center - 3), 1.8, 10, 6).Shape()
        nut_overlap, key_overlap = overlap(table, nut), overlap(table, key)
        if nut_overlap > 1e-6 or key_overlap > 1e-6:
            raise ValueError("Bookend mounting envelope intersects the CAD table")
        # Sample either side of neck/cavity widths to prove these are voids with solid walls.
        samples = [(1.0, 3.0, TopAbs_OUT), (1.0, 3.1, TopAbs_IN),
                   (3.0, 5.9, TopAbs_OUT), (3.0, 6.1, TopAbs_IN)]
        for depth, offset, expected in samples:
            state = BRepClass3d_SolidClassifier(table, gp_Pnt(top - depth, -250, center + offset), 1e-6).State()
            if state != expected:
                raise ValueError("T-slot neck/cavity does not match the vetted mounting envelope")
        results.append({"centerWorldZ": center, "nutOverlapMM3": nut_overlap, "keyOverlapMM3": key_overlap})
    return {"hardwareDefinition": "Bookend M5x0.8 custom T-nut, not a machine-wide screw-size restriction",
            "nutEnvelopeMM": [11.0, 11.6, 2.8], "keyWidthDepthMM": [6.0, 1.8], "slots": results,
            "scope": "Seated geometric fit only; no insertion-path, thread-strength, torque or installed-hardware claim."}


def check_tool_axis(tube, nut, surface, frame: dict) -> dict:
    """Compare the declared tool frame with the largest cylindrical spindle face."""
    cylinders = []
    faces = TopExp_Explorer(tube, TopAbs_FACE)
    while faces.More():
        face = TopoDS.Face(faces.Current())
        adaptor = BRepAdaptor_Surface(face)
        if adaptor.GetType() == GeomAbs_Cylinder:
            properties = GProp_GProps()
            BRepGProp.SurfaceProperties_s(face, properties)
            cylinders.append((properties.Mass(), adaptor.Cylinder()))
        faces.Next()
    if not cylinders:
        raise ValueError("No cylindrical spindle surface found")
    _, cylinder = max(cylinders, key=lambda value: value[0])
    axis = np.array(cylinder.Axis().Direction().Coord())
    line_origin = np.array(cylinder.Axis().Location().Coord())
    origin = np.array([frame["origin"][a] for a in "xyz"])
    direction = np.array([frame["zDirection"][a] for a in "xyz"])
    radial_error = float(np.linalg.norm(np.cross(origin - line_origin, axis)))
    nose_error = abs(float(origin[2] - bounds(nut)[0][2]))
    # Source attach frames were rounded to hundredths of a millimetre.
    if abs(abs(float(direction @ axis)) - 1) > 1e-9 or radial_error > 0.01 or nose_error > 0.01:
        raise ValueError("Tool frame does not agree with the CAD spindle axis and nut nose")
    if float(direction @ (line_origin - origin)) <= 0:
        raise ValueError("Tool frame positive Z must point from the nose into the spindle")
    normal_dot = float(direction @ surface["normal"])
    if abs(normal_dot) > 1e-9:
        raise ValueError("This machine's spindle must run parallel to the table support plane")
    return {"cylinderAxis": axis.tolist(), "radialOriginErrorMM": radial_error,
            "nutNosePlaneErrorMM": nose_error, "toolAxisDotTableNormal": normal_dot}


def compare_native_body_bounds(parts, native_audit: Path) -> dict:
    """Require one STEP solid for each independently audited Fusion body proxy."""
    actual = []
    for _, shape in parts:
        solids = TopExp_Explorer(shape, TopAbs_SOLID)
        while solids.More():
            actual.append(np.array(bounds(solids.Current())))
            solids.Next()
    native = json.loads(native_audit.read_text())
    expected = [np.array(body["bounds_mm"]) for item in native["bodies"] for body in item["bodies"]]
    if len(expected) != len(actual):
        raise ValueError("STEP solid count differs from the native Fusion body audit")
    errors = []
    for box in expected:
        index = min(range(len(actual)), key=lambda i: float(np.max(np.abs(actual[i] - box))))
        errors.append(float(np.max(np.abs(actual.pop(index) - box))))
    if max(errors) > TOLERANCE_MM:
        raise ValueError("STEP bodies do not preserve all audited native world bounds")
    return {"bodyCount": len(expected), "maximumBoundsErrorMM": max(errors),
            "nativeAuditSHA256": hashlib.sha256(native_audit.read_bytes()).hexdigest(),
            "scope": "One-to-one body count and world-bounds agreement; not a proof of identical topology."}


def audit(geometry: Path, frame: dict | None = None, native_audit: Path | None = None,
          tool_frame: dict | None = None) -> dict:
    parts = leaves(geometry)
    named = lambda name: next(shape for path, shape in parts if path[-1] == name)
    table = named("X Unibody")
    surface = table_surface(table)
    frame = frame or {"origin": {"x": 15.865, "y": -343, "z": 79.04},
                      "xDirection": {"x": 0, "y": 1, "z": 0}, "zDirection": {"x": 1, "y": 0, "z": 0}}
    tool_frame = tool_frame or {"origin": {"x": 105.43, "y": -176.80, "z": 112.26},
                               "zDirection": {"x": 0, "y": 0, "z": 1}}
    result = {"geometrySHA256": hashlib.sha256(geometry.read_bytes()).hexdigest(),
              "leafOccurrenceCount": len(parts), "assembledSolidCount": sum(count_solids(s) for _, s in parts),
              "coverSolidCount": sum(count_solids(s) for p, s in parts if "Cover" in p),
              "tableSurface": surface, "stockSeating": check_seating_frame(surface, frame),
              "bookendMounting": check_bookend_slot(table, surface),
              "toolAlignment": check_tool_axis(named("Spindle Outer Tube"), named("Spindle ER11A Nut"), surface, tool_frame)}
    if native_audit:
        result["nativeBodyAgreement"] = compare_native_body_bounds(parts, native_audit)
    z_body, y_body = named("Z Unibody"), named("YZ Translator Unibody")
    checks = []
    for q, expected_overlap in [(-0.01, True), (1.4, False), (79.9, False), (80.01, True)]:
        moving = translated(z_body, [0, 0, q])
        common_volume = overlap(moving, y_body)
        if (common_volume > 1e-5) != expected_overlap:
            raise ValueError(f"Z contact check at q={q} disagrees with the measured CAD stops")
        checks.append({"qZ": q, "overlapMM3": common_volume,
                       "separationMM": BRepExtrema_DistShapeShape(moving, y_body).Value()})
    result["zContactChecks"] = {"moving": "Z Unibody", "fixed": "YZ Translator Unibody", "samples": checks}
    guards = [shape for path, shape in parts if path[-1] == "Chip Guard - X Top"]
    if guards:
        checks = []
        for q, expected_overlap in [(69.0, False), (69.84, True)]:
            moving = translated(named("Spindle Mount - Lower"), [0, q, 1.4])
            common_volume = sum(overlap(moving, guard) for guard in guards)
            separation = min(BRepExtrema_DistShapeShape(moving, guard).Value() for guard in guards)
            if (common_volume > 1e-5) != expected_overlap:
                raise ValueError(f"Y contact check at q={q} disagrees with the measured CAD stop")
            checks.append({"qY": q, "qZ": 1.4, "overlapMM3": common_volume, "separationMM": separation})
        result["yUpperContactChecks"] = {"moving": "Spindle Mount - Lower", "fixed": "Chip Guard - X Top", "samples": checks}
    result["scope"] = "Exact selected CAD contact and seating checks. Not physical controller calibration or a complete travel/collision envelope."
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--geometry", type=Path, default=DEFAULT_GEOMETRY)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--native-audit", type=Path, default=ROOT / "docs/machine-profile-fusion-audit.json")
    parser.add_argument("--frame", default="table-surface")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    frame = tool_frame = None
    if args.manifest:
        manifest = json.loads(args.manifest.read_text())
        frame = next((item for item in manifest["frames"] if item["id"] == args.frame), None)
        if frame is None:
            raise ValueError(f"Manifest has no seating frame {args.frame!r}")
        tool_frame = next(item for item in manifest["frames"] if item["id"] == "tool")
    report = audit(args.geometry, frame, args.native_audit, tool_frame)
    encoded = json.dumps(report, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
