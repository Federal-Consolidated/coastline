#!/usr/bin/env python3
"""Export the reviewed Quick Release assembly without its reference machine table.

Only the known source fingerprint and exact first occurrence may be removed.
The source STEP remains untouched. Assembly names, placements and hardware are
transferred through XDE; the output is checked against every retained solid.
"""
import argparse
import importlib.util
import json
from pathlib import Path

from OCP.IFSelect import IFSelect_RetDone
from OCP.BRepAdaptor import BRepAdaptor_Surface, BRepAdaptor_Curve
from OCP.STEPCAFControl import STEPCAFControl_Reader, STEPCAFControl_Writer
from OCP.TCollection import TCollection_ExtendedString
from OCP.TDF import TDF_Label
from OCP.TDocStd import TDocStd_Document
from OCP.XCAFDoc import XCAFDoc_DocumentTool
from OCP.TopAbs import TopAbs_FACE, TopAbs_EDGE
from OCP.TopoDS import TopoDS
from OCP.collections import Sequence_TDF_Label

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "resources/fixtures/quick_release_jig_plate.step"
SOURCE_SHA = "06df20ac25bc5ab5268f1cc4cf124da6e7e32c7f25f91cd8525b316a0bdc83c1"
OUTPUT = ROOT / "resources/fixtures/quick-release"
spec = importlib.util.spec_from_file_location("workholding_audit", ROOT / "scripts/audit-vetted-workholding.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def geometry_samples(original, exported):
    """Check corresponding surface/boundary geometry independently of volume integration."""
    source_faces, output_faces = (audit.subshapes(shape, TopAbs_FACE) for shape in (original, exported))
    source_edges, output_edges = (audit.subshapes(shape, TopAbs_EDGE) for shape in (original, exported))
    assert len(source_faces) == len(output_faces) and len(source_edges) == len(output_edges)
    surface_error = 0
    for source, output in zip(source_faces, output_faces):
        a, b = BRepAdaptor_Surface(TopoDS.Face(source)), BRepAdaptor_Surface(TopoDS.Face(output))
        assert a.GetType() == b.GetType()
        for u, v in ((.2, .2), (.5, .5), (.8, .8), (.2, .8), (.8, .2)):
            p = a.Value(a.FirstUParameter() * (1 - u) + a.LastUParameter() * u,
                        a.FirstVParameter() * (1 - v) + a.LastVParameter() * v)
            q = b.Value(b.FirstUParameter() * (1 - u) + b.LastUParameter() * u,
                        b.FirstVParameter() * (1 - v) + b.LastVParameter() * v)
            surface_error = max(surface_error, p.Distance(q))
    boundary_error = 0
    for source, output in zip(source_edges, output_edges):
        a, b = BRepAdaptor_Curve(TopoDS.Edge(source)), BRepAdaptor_Curve(TopoDS.Edge(output))
        direct, reverse = [], []
        for t in (0, .25, .5, .75, 1):
            p = a.Value(a.FirstParameter() * (1 - t) + a.LastParameter() * t)
            q = b.Value(b.FirstParameter() * (1 - t) + b.LastParameter() * t)
            r = b.Value(b.FirstParameter() * t + b.LastParameter() * (1 - t))
            direct.append(p.Distance(q))
            reverse.append(p.Distance(r))
        boundary_error = max(boundary_error, min(max(direct), max(reverse)))
    assert surface_error < 1e-5 and boundary_error < 1e-5
    return dict(faceCount=len(source_faces), edgeCount=len(source_edges),
                maximumSampledSurfaceErrorMM=surface_error, maximumSampledBoundaryErrorMM=boundary_error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-existing", action="store_true", help="Check the existing export and write its definition/evidence without exporting again")
    args = parser.parse_args()
    assert audit.sha(SOURCE) == SOURCE_SHA, "Source changed; reference classification must be reviewed again."
    before, before_shapes = audit.read(SOURCE, verify_leaf_volume=False)
    removed = before[0]
    assert removed["occurrencePath"] == "0/0"
    assert removed["names"][-1] == "X Unibody - RevD v1"
    assert len(before) == 35
    bb = removed["boundsMM"]
    assert abs(bb[1][0] - bb[0][0] - 385) < .001
    assert abs(bb[1][1] - bb[0][1] - 74.93) < .001
    assert abs(bb[1][2] - bb[0][2] - 14.604964) < .001

    doc = TDocStd_Document(TCollection_ExtendedString("quick-release-physical-fixture"))
    reader = STEPCAFControl_Reader()
    reader.SetNameMode(True)
    reader.SetColorMode(True)
    assert reader.ReadFile(str(SOURCE)) == IFSelect_RetDone and reader.Transfer(doc)
    tool = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    roots = Sequence_TDF_Label()
    tool.GetFreeShapes(roots)
    assert len(roots) == 1
    root = roots.Value(1)
    children = Sequence_TDF_Label()
    tool.GetComponents_s(root, children)
    reference = TDF_Label()
    assert tool.GetReferredShape_s(children.Value(1), reference)
    tool.RemoveComponent(children.Value(1))
    tool.UpdateAssemblies()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    destination = OUTPUT / "fixture.step"
    if not args.verify_existing:
        writer = STEPCAFControl_Writer()
        writer.SetNameMode(True)
        writer.SetColorMode(True)
        # Transfer this root only: the detached reference definition is not a new free part.
        assert writer.Transfer(root)
        assert writer.Write(str(destination)) == IFSelect_RetDone

    after, after_shapes = audit.read(destination, verify_leaf_volume=False)
    assert len(after) == 34
    checks = []
    for original, exported, original_shape, exported_shape in zip(before[1:], after, before_shapes[1:], after_shapes):
        error = max(abs(x - y) for a, b in zip(original["boundsMM"], exported["boundsMM"]) for x, y in zip(a, b))
        delta = abs(original["volumeMM3"] - exported["volumeMM3"])
        # Threaded surfaces change quadrature behavior when written by OCCT.
        # Geometry is separately checked at faces and edges, rather than hiding
        # integration differences behind a volume-only identity claim.
        assert error < 1e-5 and delta < max(1e-4, abs(original["volumeMM3"]) * 2e-5)
        assert original["names"] == exported["names"]
        samples = geometry_samples(original_shape, exported_shape)
        checks.append(dict(sourceSolidIndex=original["solidIndex"], outputSolidIndex=exported["solidIndex"],
                           sourceOccurrencePath=original["occurrencePath"], outputOccurrencePath=exported["occurrencePath"],
                           maximumBoundsErrorMM=error, volumeDifferenceMM3=delta, **samples))
    digest = audit.sha(destination)
    paths = list(dict.fromkeys(row["occurrencePath"] for row in after))
    manifest = dict(schemaVersion=1, id="quick-release-jig-plate", revision=1, modelSHA256=digest, isAssembled=False,
                    components=[dict(id="jig-plate", name="Quick release jig plate", role="physical", modelEntities=paths)])
    (OUTPUT / "definition.json").write_text(json.dumps(manifest, indent=2) + "\n")
    evidence = dict(schemaVersion=1, sourceFile="../quick_release_jig_plate.step", sourceSHA256=SOURCE_SHA,
                    outputFile="fixture.step", outputSHA256=digest, sourceSolidCount=35, outputSolidCount=34,
                    removed=[dict(reason="Embedded machine table, not fixture hardware", **removed)],
                    preservationTolerances=dict(boundsMM=1e-5, sampledGeometryMM=1e-5, relativeVolume=2e-5, minimumAbsoluteVolumeMM3=1e-4),
                    retainedVolumeMM3=sum(row["volumeMM3"] for row in after), retainedSolids=after, preservationChecks=checks,
                    sourcePose="Exploded view: source FILE_NAME is Jig Plate Rev D - Metric Exploded View.step",
                    qualification="Only the source-bound machine-table occurrence is excluded. All other hardware, plates and unnamed bodies are retained. This cleaned display/reference geometry does not establish their assembled placement, independent adjustment or load suitability.")
    (OUTPUT / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Retained {len(after)} solids, removed only {removed['occurrencePath']}; SHA-256 {digest}")


if __name__ == "__main__":
    main()
