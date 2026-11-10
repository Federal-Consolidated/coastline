#!/usr/bin/env python3
"""Read STEP assemblies and write identity/kinematic evidence; never edits CAD.

Run with engine/.venv/bin/python. The source files and Fusion are not modified.
Optional --clamp-body/--fixed-body check the separately exported bookend bodies.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from OCP.Bnd import Bnd_Box
from OCP.BRepAdaptor import BRepAdaptor_Surface, BRepAdaptor_Curve
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepGProp import BRepGProp
from OCP.GeomAbs import GeomAbs_Cylinder, GeomAbs_Plane, GeomAbs_Circle
from OCP.GProp import GProp_GProps
from OCP.IFSelect import IFSelect_RetDone
from OCP.STEPCAFControl import STEPCAFControl_Reader
from OCP.STEPControl import STEPControl_Reader
from OCP.TCollection import TCollection_ExtendedString
from OCP.TDataStd import TDataStd_Name
from OCP.TDF import TDF_Label
from OCP.TDocStd import TDocStd_Document
from OCP.TopAbs import TopAbs_FACE, TopAbs_SOLID, TopAbs_EDGE
from OCP.TopExp import TopExp_Explorer
from OCP.TopoDS import TopoDS
from OCP.XCAFDoc import XCAFDoc_DocumentTool
from OCP.collections import Sequence_TDF_Label

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "resources/fixtures/bookends"
SOURCE_HASH = "341115f76ac3ede6f85058c05886872df52cf926588ceb9a20dee3b28acaf78b"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bounds(shape):
    box = Bnd_Box()
    BRepBndLib.AddOptimal_s(shape, box, False, False)
    return [list(box.CornerMin().Coord()), list(box.CornerMax().Coord())]


def volume(shape):
    props = GProp_GProps()
    BRepGProp.VolumeProperties_s(shape, props)
    return props.Mass()


def subshapes(shape, kind):
    result, explorer = [], TopExp_Explorer(shape, kind)
    while explorer.More():
        result.append(explorer.Current())
        explorer.Next()
    return result


def read(path, verify_leaf_volume=True):
    """Pair exact XDE leaf identities with the engine's flat TopExp solid order."""
    doc = TDocStd_Document(TCollection_ExtendedString("workholding-evidence"))
    reader = STEPCAFControl_Reader()
    reader.SetNameMode(True)
    assert reader.ReadFile(str(path)) == IFSelect_RetDone and reader.Transfer(doc)
    tool = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    leaves = []

    def name(label):
        attr = TDataStd_Name()
        return attr.Get().ToExtString() if label.FindAttribute(TDataStd_Name.GetID_s(), attr) else ""

    def visit(label, location, entity, names):
        children = Sequence_TDF_Label()
        tool.GetComponents_s(label, children)
        if len(children):
            for index, child in enumerate(children):
                ref = TDF_Label()
                assert tool.GetReferredShape_s(child, ref)
                visit(ref, location.Multiplied(tool.GetLocation_s(child)), f"{entity}/{index}", names + [name(ref)])
        else:
            shape = tool.GetShape_s(label).Moved(location)
            for local_index, solid in enumerate(subshapes(shape, TopAbs_SOLID)):
                leaves.append((entity, names, local_index, solid))

    roots = Sequence_TDF_Label()
    tool.GetFreeShapes(roots)
    for index, root in enumerate(roots):
        visit(root, tool.GetLocation_s(root), str(index), [name(root)])
    flat_reader = STEPControl_Reader()
    assert flat_reader.ReadFile(str(path)) == IFSelect_RetDone
    flat_reader.TransferRoots()
    flat = subshapes(flat_reader.OneShape(), TopAbs_SOLID)
    assert len(flat) == len(leaves)
    records = []
    for index, (shape, (entity, names, local_index, leaf)) in enumerate(zip(flat, leaves)):
        bb, leaf_bb = bounds(shape), bounds(leaf)
        assert max(abs(v - w) for a, b in zip(bb, leaf_bb) for v, w in zip(a, b)) < 1e-6
        measured_volume = volume(shape)
        if verify_leaf_volume:
            assert abs(measured_volume - volume(leaf)) < 1e-5
        records.append(dict(solidIndex=index, occurrencePath=entity, solidWithinLeaf=local_index,
                            names=names, boundsMM=bb, volumeMM3=measured_volume,
                            faceCount=len(subshapes(shape, TopAbs_FACE))))
    return records, flat


def axial_planes(shape):
    result = []
    for index, raw in enumerate(subshapes(shape, TopAbs_FACE)):
        face = TopoDS.Face(raw)
        surface = BRepAdaptor_Surface(face)
        if surface.GetType() != GeomAbs_Plane:
            continue
        plane = surface.Plane()
        if abs(plane.Axis().Direction().Y()) < 0.999:
            continue
        props = GProp_GProps()
        BRepGProp.SurfaceProperties_s(face, props)
        if props.Mass() > 1:
            result.append(dict(faceIndex=index, yMM=plane.Location().Y(), areaMM2=props.Mass()))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=BUNDLE / "evidence.json")
    parser.add_argument("--clamp-body", type=Path)
    parser.add_argument("--fixed-body", type=Path)
    args = parser.parse_args()
    source = BUNDLE / "assembly.step"
    assert sha(source) == SOURCE_HASH, "Unexpected Bookend revision; re-audit its topology before assigning roles."
    records, solids = read(source)
    assert len(solids) == 15
    fixed = {0, 2, 3, 4, 5, 6, 12}
    clamp = {1, 7, 8, 9, 10, 13, 14}
    for record in records:
        index = record["solidIndex"]
        record["role"] = "physical"
        record["componentID"] = "fixed-end" if index in fixed else "clamp-end" if index in clamp else "pressure-screw"
        record["hardwareRole"] = ("body" if index in {0, 1} else "t-slot-nut" if index in {2, 12, 13, 14}
                                  else "washer" if index in {4, 6, 8, 10} else "pressure-screw" if index == 11 else "mounting-screw")
    assert records[11]["occurrencePath"] == "0/3/4"
    planes = axial_planes(solids[11])
    for expected in (-139.8, -114.8, -109.8):
        assert any(abs(p["yMM"] - expected) < 1e-6 for p in planes)
    bore = None
    for index, raw in enumerate(subshapes(solids[1], TopAbs_FACE)):
        surface = BRepAdaptor_Surface(TopoDS.Face(raw))
        if surface.GetType() == GeomAbs_Cylinder:
            cylinder = surface.Cylinder()
            if abs(cylinder.Axis().Direction().Y()) > .999 and abs(cylinder.Radius() - 2.117) < .001:
                bore = dict(faceIndex=index, radiusMM=cylinder.Radius(), axisPointMM=list(cylinder.Location().Coord()), boundsMM=bounds(raw))
    assert bore is not None
    tip_face = subshapes(solids[11], TopAbs_FACE)[95]
    tip_edges = subshapes(tip_face, TopAbs_EDGE)
    assert len(tip_edges) == 3
    for edge in tip_edges:
        curve = BRepAdaptor_Curve(TopoDS.Edge(edge))
        assert curve.GetType() == GeomAbs_Circle
        assert abs(curve.Circle().Radius() - 1.98038475772934) < 1e-9
    for solid_index, face_index in ((0, 17), (1, 14)):
        surface = BRepAdaptor_Surface(TopoDS.Face(subshapes(solids[solid_index], TopAbs_FACE)[face_index]))
        assert surface.GetType() == GeomAbs_Plane
        assert abs(surface.Plane().Location().Z() - 79.0435941251268) < 1e-9
    comparisons = []
    for path, index in ((args.clamp_body, 1), (args.fixed_body, 0)):
        if path:
            _, independent = read(path)
            assert len(independent) == 1
            delta = abs(volume(solids[index]) - volume(independent[0]))
            error = max(abs(x - y) for a, b in zip(bounds(solids[index]), bounds(independent[0])) for x, y in zip(a, b))
            assert delta < 1e-6 and error < 1e-6
            comparisons.append(dict(file=str(path), sha256=sha(path), assemblySolidIndex=index,
                                    volumeDifferenceMM3=delta, maximumBoundsErrorMM=error,
                                    qualification="Bounds and volume identity check; not a claim of identical topology."))
    other = []
    for filename in ("universal_clamp_v96.step", "quick_release_jig_plate.step", "c_clamp.step"):
        path = ROOT / "resources/fixtures" / filename
        rows, _ = read(path)
        for row in rows:
            row["classification"] = "reference-machine-table" if filename == "quick_release_jig_plate.step" and row["solidIndex"] == 0 else "retained-physical-or-unreviewed"
        other.append(dict(file=filename, sha256=sha(path), solids=rows))
    result = dict(schemaVersion=1, units="mm", engineSolidOrder="STEPControl_Reader.OneShape → TopExp_Explorer(TopAbs_SOLID), zero-based",
                  sourceSHA256=SOURCE_HASH, sourceFile="assembly.step", sourceSolidCount=15,
                  referenceSolidIndices=[], solids=records, separateBodyComparisons=comparisons,
                  pressureScrew=dict(componentID="pressure-screw", solidIndex=11,
                      axisPointMM=[25.3651363565511, -139.8, 104.443594125127], advanceAxis=[0, -1, 0],
                      pitchMMPerRevolution=.8, thread="M5x0.8", manufacturerPart="91290A252",
                      contactFaceRadiusMM=1.98038475772934, majorRadiusMM=2.5,
                      referenceExtensionMM=4, geometricExtensionRangeMM=[0, 15], shaftLengthMM=25,
                      threadedWallThicknessMM=10, axialPlanes=planes, clampBore=bore,
                      limitMeaning="Shaft overlap and underhead stop only. Not a validated thread-engagement or load rating. Stock contact limits tightening before penetration.",
                      threadRepresentation="External screw thread is modeled. Clamp/nut internal threads are cosmetic; exact solid overlap at threaded pairs is expected."),
                  mounting=dict(tableSeatingXMM=15.8651364, tableNormal=[1, 0, 0], slideAxis=[0, 1, 0],
                      slotCentersZMM=[78.7585941251038, 118.763594125104], slotPitchMM=40.005,
                      nutSizeMM=[2.8, 11, 11.6], keySizeMM=[1.8, 10, 6],
                      fixedNutCenterYMM=-348, clampNutCenterYMM=-130.8,
                      fixedNutYRangeMM=[-353.5, -342.5], clampNutYRangeMM=[-136.3, -125.3],
                      fixedContactYMM=-343, clampInsideYMM=-135.8, lipStockContactZMM=79.0435941251268,
                      lipContactFaces=[dict(solidIndex=0, faceIndex=17, zMM=79.0435941251268, normal=[0, 0, 1]),
                                       dict(solidIndex=1, faceIndex=14, zMM=79.0435941251268, normal=[0, 0, 1])],
                      referenceStockBoundsMM=[[15.8651364, -343, 79.0435941251268], [66.6651364, -139.8, 129.8435941251268]]),
                  otherFixtureAudits=other)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Audited {len(records)} Bookend solids and {sum(len(x['solids']) for x in other)} other fixture solids; wrote {args.output}")


if __name__ == "__main__":
    main()
