#!/usr/bin/env python3
"""Reproduce the reviewed desktop-CNC digital package from pinned Fusion exports.

Run with engine/.venv/bin/python: OpenCascade is used only to inspect the STEP, not
to edit it. This generator is specific to the reviewed v31 export. A new source
revision requires deliberate mapping review rather than silently reusing its paths.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


INPUTS = {
    "Desktop CNC Machine.mch": "c7492a394592ee32571aaf2453c39533dd2cb4ecf5c71f4b1db4391a9cb7fc52",
    "CNC simplified v31.step": "c485b7053d1d20f89e27e950628d3359c084bf1900547ceb7ba40b3ec9955ce0",
    "README.md": "7ee11e8a3e8020a3a4fecce8b8441d5c818237a1cb3a34e6856a35d80698a6c8",
}
ROOT = Path(__file__).resolve().parents[1]
FULL_GEOMETRY_SHA256 = "7035295044ea6c8e84ef12289cb68a4bb3dab5bb70ad5d86477fa82e9f720cc3"

BINDINGS = {
    "0/0": ("base", "01 Fixed Frame and Drives"),
    "0/1": ("y", "02 Y Carriage and Z Guides"),
    "0/2": ("z", "03 Spindle Head"),
    "0/2/0": ("head", "Spindle Cartridge"),
    "0/3": ("table", "04 X Table"),
    "0/4": ("cover", "Cover"),
}


def encoded(value: object) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode()


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def vec(x: float, y: float, z: float) -> dict:
    return {"x": x, "y": y, "z": z}


def inspect_step(path: Path) -> dict:
    from OCP.BRepBndLib import BRepBndLib
    from OCP.Bnd import Bnd_Box
    from OCP.IFSelect import IFSelect_ReturnStatus
    from OCP.STEPCAFControl import STEPCAFControl_Reader
    from OCP.TCollection import TCollection_ExtendedString
    from OCP.TDataStd import TDataStd_Name
    from OCP.TDF import TDF_Label
    from OCP.TDocStd import TDocStd_Document
    from OCP.TopAbs import TopAbs_SOLID
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopLoc import TopLoc_Location
    from OCP.XCAFDoc import XCAFDoc_DocumentTool
    from OCP.collections import Sequence_TDF_Label

    def name(label):
        value = TDataStd_Name()
        return value.Get().ToExtString() if label.FindAttribute(TDataStd_Name.GetID_s(), value) else ""

    doc = TDocStd_Document(TCollection_ExtendedString("machine-package-audit"))
    reader = STEPCAFControl_Reader()
    reader.SetNameMode(True)
    if reader.ReadFile(str(path)) != IFSelect_ReturnStatus.IFSelect_RetDone:
        raise ValueError("STEP reader could not load the source model")
    if not reader.Transfer(doc):
        raise ValueError("STEP reader could not transfer the source assembly")
    shape_tool = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    entities = []
    seen = set()

    def visit(label, location, indices, ancestors):
        components = Sequence_TDF_Label()
        shape_tool.GetComponents_s(label, components)
        for index, component in enumerate(components):
            referred = TDF_Label()
            if not shape_tool.GetReferredShape_s(component, referred):
                raise ValueError("STEP occurrence has no referred shape")
            component_name = name(referred)
            child_indices = indices + [index]
            key = "/".join(map(str, child_indices))
            current_location = location.Multiplied(shape_tool.GetLocation_s(component))
            children = Sequence_TDF_Label()
            shape_tool.GetComponents_s(referred, children)
            matches = [binding for binding in BINDINGS if key == binding or key.startswith(binding + "/")]
            binding = max(matches, key=len) if matches else None
            entry = {
                "path": key,
                "name": component_name,
                "ancestors": ancestors,
                "kind": "assembly" if len(children) else "shape",
                "componentID": BINDINGS[binding][0] if binding else None,
            }
            if key in BINDINGS:
                if component_name != BINDINGS[key][1]:
                    raise ValueError(f"Binding {key}: expected {BINDINGS[key][1]!r}, got {component_name!r}")
                seen.add(key)
            if len(children):
                entities.append(entry)
                visit(referred, current_location, child_indices, ancestors + [component_name])
            else:
                if binding is None:
                    raise ValueError(f"Unmapped STEP shape {key}: {component_name}")
                shape = shape_tool.GetShape_s(referred).Moved(current_location)
                box = Bnd_Box()
                BRepBndLib.AddOptimal_s(shape, box, False, False)
                if box.IsVoid():
                    raise ValueError(f"Empty STEP shape {key}")
                lo, hi = box.CornerMin(), box.CornerMax()
                entry["boundsMM"] = {
                    "minimum": [round(lo.X(), 6), round(lo.Y(), 6), round(lo.Z(), 6)],
                    "maximum": [round(hi.X(), 6), round(hi.Y(), 6), round(hi.Z(), 6)],
                }
                solids = TopExp_Explorer(shape, TopAbs_SOLID)
                solid_count = 0
                while solids.More():
                    solid_count += 1
                    solids.Next()
                entry["solidCount"] = solid_count
                entities.append(entry)

    roots = Sequence_TDF_Label()
    shape_tool.GetFreeShapes(roots)
    for index, root in enumerate(roots):
        visit(root, TopLoc_Location(), [index], [name(root)])
    if seen != BINDINGS.keys():
        raise ValueError(f"Missing expected STEP bindings: {BINDINGS.keys() - seen}")
    table = next(entry for entry in entities if entry["path"] == "0/3/0")
    nose = next(entry for entry in entities if entry["path"] == "0/2/0/1")
    if abs(table["boundsMM"]["maximum"][0] - 15.865) > 0.01:
        raise ValueError("Table reference check failed; check source revision and unit conversion")
    if abs(nose["boundsMM"]["minimum"][2] - 112.26) > 0.01:
        raise ValueError("Spindle nut reference check failed; check source revision and unit conversion")
    return {
        "sourceSHA256": digest(path.read_bytes()),
        "inputLengthUnit": "cm",
        "reportedLengthUnit": "mm",
        "pathConvention": "Zero-based free-shape/occurrence indices; longest ancestor binding wins. Paths are valid only for this source hash.",
        "componentBindings": [{"path": key, "componentID": value[0], "expectedName": value[1]} for key, value in BINDINGS.items()],
        "shapeCount": sum(entry["kind"] == "shape" for entry in entities),
        "assembledSolidCount": sum(entry.get("solidCount", 0) for entry in entities),
        "entities": entities,
    }


def make_manifest(machine: dict, output_files: dict[str, bytes]) -> dict:
    nodes = {}

    def collect(parts):
        for part in parts:
            nodes[part["id"]] = part
            collect(part.get("parts", []))

    collect(machine["kinematics"]["default"]["parts"])
    if machine["kinematics"]["default"]["units"] != {"angle": "degrees", "length": "mm"}:
        raise ValueError("Unexpected Fusion machine definition units")
    control = machine["controller"]["default"]["parts"]

    def component(identifier, role, parent=None, entities=(), axis=None, enclosure=False):
        value = {"id": identifier, "role": role, "modelEntities": list(entities)}
        if parent is not None:
            value["parentID"] = parent
        if axis is not None:
            value["axis"] = axis
        if enclosure:
            value["isEnclosure"] = True
        return value

    def axis(identifier, offset):
        source = nodes[identifier.upper()]
        return {
            "coordinate": identifier,
            "direction": vec(*source["direction"]),
            "modelMinimum": source["min"],
            "modelMaximum": source["max"],
            "modelHome": source["home"],
            "controllerScale": 1,
            "controllerOffset": offset,
        }

    def frame(identifier, component_id, source_id):
        source = nodes[source_id]["attach_frame"]
        return {"id": identifier, "componentID": component_id, "origin": vec(*source["point"]),
                "xDirection": vec(*source["x_direction"]), "zDirection": vec(*source["z_direction"])}

    def evidence(topic, status, sources, detail):
        return {"topic": topic, "status": status, "sourceIDs": sources, "detail": detail}

    def finding(identifier, severity, summary, detail):
        return {"id": identifier, "severity": severity, "summary": summary, "detail": detail}

    def check(identifier, title, scope, detail, sources, action=None):
        result = {"id": identifier, "title": title, "scope": scope,
                  "status": "pending" if action else "passed", "detail": detail, "sourceIDs": sources}
        if action:
            result["action"] = action
        return result

    profile = {
        "name": "Desktop CNC",
        "travel": vec(86.5, 241.5, 78.5),
        "machineEnvelope": {"x": [-86.0, -0.5], "y": [-241.5, -0.5], "z": [-78.5, -0.5]},
        "homePosition": vec(-86, -0.5, -0.5),
        "maxRate": vec(*(control[axis]["max_normal_speed"] for axis in ("X", "Y", "Z"))),
        "acceleration": vec(500, 500, 500),
        "junctionDeviation": 0.02,
        "arcTolerance": 0.002,
        "spindleRPM": [1500, 8000],
        "spindleRampIntermediateRPM": 5000,
        "estimatedSpindlePower": 150,
        "colletName": "ER-11",
        "maxShankDiameter": 8,
        "maxToolLength": 75,
        "colletSeatDepth": 22.9,
        "toolChangeMoves": ["$H", "G53 G0 Z-1", "G53 G0 Y-58", "G53 G0 X-1", "G53 G0 Z-60"],
        "maxLineLength": 79,
        "plannerBlocks": 16,
        "powerOnDistanceModeIsIncremental": True,
        "edgeFinderTipDiameter": 5.08,
        "probeFeed": 20,
        "probeSpindleRPM": 1500,
        "tSlotCount": 2,
        "tSlotNut": "Fixture-selected T-nuts: 12 × 3 mm cavity, 6.13 mm opening",
        "physicalEnvelope": vec(89, 242, 79),
    }
    roles = {"machine.step": "geometry", "source.mch": "fusionDefinition"}
    return {
        "schemaVersion": 1,
        "id": "desktop-cnc",
        "revision": 2,
        "name": "Desktop CNC",
        "manufacturer": machine["general"]["vendor"],
        "units": "mm",
        "process": "milling",
        "controller": "grbl",
        "verification": "digital",
        "postProcessorID": "coastline.grbl.desktop.v1",
        "profile": profile,
        "assets": [{"path": name, "role": roles.get(name, "reference"), "sha256": digest(data)} for name, data in output_files.items()],
        "components": [
            component("base", "static", entities=["0/0"]),
            component("x", "linearAxis", axis=axis("x", 0)),
            component("table", "table", "x", ["0/3"]),
            component("y", "linearAxis", entities=["0/1"], axis=axis("y", 69)),
            component("z", "linearAxis", "y", ["0/2"], axis("z", 79.9)),
            component("head", "head", "z", ["0/2/0"]),
            component("cover", "static", entities=["0/4"], enclosure=True),
        ],
        "frames": [frame("table", "table", "table"), frame("tool", "head", "head"),
                   {"id": "table-surface", "componentID": "table", "origin": vec(15.865, -343, 79.04),
                    "xDirection": vec(0, 1, 0), "zDirection": vec(1, 0, 0)},
                   {"id": "view", "componentID": "base", "origin": vec(0, 0, 0),
                    "xDirection": vec(0, 1, 0), "zDirection": vec(1, 0, 0)}],
        "referenceStock": {"id": "orientation-block", "name": "Orientation check block", "frameID": "table-surface",
                           "minimum": vec(0, 0, 0), "size": vec(203.2, 37, 50.8)},
        "mountingInterfaces": [{
            "id": "table-slots", "frameID": "table", "kind": "tSlots",
            "slots": [{"id": f"slot-{index + 1}", "origin": vec(0, -46.42, round(z - 79.04, 3)),
                       "direction": vec(0, 1, 0), "length": 305,
                       "openingWidth": 6.13, "cavityWidth": 12, "cavityDepth": 3, "lipThickness": 2}
                      for index, z in enumerate((78.759, 118.764))],
        }],
        "sources": [
            {"id": "fusion-definition", "title": "Supplied Desktop CNC Machine.mch", "path": "source.mch"},
            {"id": "shared-readme", "title": "Original machine export notes, 2026-11-06", "path": "source-README.md"},
            {"id": "step-audit", "title": "Complete STEP occurrence and dimensional audit", "path": "geometry-index.json"},
            {"id": "fusion-audit", "title": "Read-only Fusion model inspection, 2026-11-06", "path": "fusion-audit.json"},
            {"id": "geometry-tests", "title": "Exact CAD seating, mounting and selected contact checks", "path": "geometry-validation.json"},
            {"id": "geometry-resolution", "title": "Seating and mounting engineering decisions", "path": "geometry-resolution.md"},
            {"id": "controller-review", "title": "Manufacturer controller and tooling evidence; native adapter contract", "path": "controller-evidence.md"},
            {"id": "package-policy", "title": "Digital capability and commissioning scope", "path": "README.md"},
        ],
        "evidence": [
            evidence("kinematics", "source", ["fusion-definition", "geometry-tests"], "X table moves in world −X; Y carriage carries Z head. Component inheritance and mapped home positions are checked. Selected Z and upper-Y CAD contacts corroborate the authored bounds; this is not an exhaustive travel/collision check."),
            evidence("controllerMapping", "inferred", ["shared-readme", "fusion-definition"], "q=(MPosX,MPosY+69,MPosZ+79.9) matches the supplied controller and CAD home anchors. Its algebra is validated digitally; physical switch trip, pull-off and datum offsets remain to be measured."),
            evidence("modelGeometry", "measured", ["step-audit", "geometry-tests"], "CAD only: OpenCascade converts source centimetres to millimetres. All 52 exported solids agree with the inspected Fusion body bounds to within 0.000003 mm."),
            evidence("geometryCoverage", "verified", ["step-audit", "fusion-audit"], "The complete read-only export restores all nine Cover bodies. All 52 authored bodies are mapped, including the enclosure and chip guards. The simplified source still omits some hardware; full machining collision clearance is not certified."),
            evidence("stockPlacement", "verified", ["geometry-tests", "geometry-resolution"], "The physical seating frame is separate from machining axes. Local X follows the slots, local Z points away from the table. A 203.2 × 37 × 50.8 mm reference block sits on the measured CAD support plane with 0.000137 mm maximum error and fits its footprint. The historical Fusion setup issue is not claimed to have been reproduced."),
            evidence("mountingInterfaces", "measured", ["geometry-tests", "geometry-resolution"], "The table defines slot geometry, while each fixture defines its fasteners. The Bookend's custom M5 nut and key have zero CAD overlap in both slots. This is seated geometric fit, not thread strength, insertion-path or installed-hardware validation."),
            evidence("usableSpindle", "source", ["controller-review", "fusion-definition"], "Manufacturer manual usable range 1500–8000 RPM is applied to generated programs. Firmware parameters 1360–8500 RPM describe a different limit and remain in the original source."),
            evidence("controllerDefaults", "source", ["controller-review", "shared-readme"], "Pinned manufacturer firmware corroborates supplied travel, rates and reported spindle parameters. Installed controller settings have not been read."),
            evidence("spindlePower", "inferred", ["package-policy"], "150 W remains the existing Coastline planning estimate, not a manufacturer rating or measured cutting power."),
            evidence("toolLimits", "source", ["controller-review", "fusion-definition"], "ER11 8 mm shank acceptance and nominal 22.9 mm seating depth have distinct manufacturer references. The supplied 75 mm overall-length cap replaces the unsubstantiated legacy 76.2 mm cap. The imported 7 mm tool-diameter limit is preserved as source metadata; actual tool stickout remains a per-setup measurement."),
            evidence("nativePost", "verified", ["controller-review"], "Coastline explicitly selects coastline.grbl.desktop.v1. Generated text and local preflight regressions cover feed/arc modes, usable RPM, bounded comments and manual tooling. system://grbl.cps is preserved as Fusion provenance, not executed. No machine command was sent."),
        ],
        "checks": [
            check("complete-geometry", "Complete machine model", "geometry",
                  "All 52 authored solids are mapped, including nine recovered enclosure and chip-guard bodies. Exported body bounds match the saved Fusion model within 0.000003 mm. Intentional simplifications remain documented.",
                  ["step-audit", "fusion-audit", "geometry-tests"]),
            check("digital-motion", "Axis motion and home pose", "kinematics",
                  "X moves the table; Y carries Z and the spindle. Controller-to-model home conversion and nested motion are checked. Selected Z stop and upper-Y clearance tests corroborate the CAD ranges; physical calibration is a separate commissioning step.",
                  ["fusion-definition", "geometry-tests"]),
            check("stock-seating", "Stock sits on the X table", "setupPlacement",
                  "A dedicated seating frame removes the machining-axis/seating-axis ambiguity. The asymmetric 203.2 × 37 × 50.8 mm block lies on the measured table plane and inside its support footprint; its dimensions remain in their intended directions.",
                  ["geometry-tests", "geometry-resolution"]),
            check("slot-mounting", "Bookend mounting fits both T-slots", "setupPlacement",
                  "The machine interface is the 6.13 mm opening above a 12 × 3 mm cavity. The Bookend's custom M5 nut and 6 × 1.8 mm key fit the actual CAD slots. Fastener selection belongs to the fixture, so the table is not restricted to a generic M4 label.",
                  ["geometry-tests", "geometry-resolution"]),
            check("tool-dimensions", "Tool dimensions have distinct meanings", "tooling",
                  "Use an 8 mm maximum shank and the supplied conservative 75 mm overall-length planning cap. Nominal collet seating is 22.9 mm. Cutting diameter and measured exposed stickout are separate tool-assembly inputs; the source's 7 mm diameter value is retained without calling it a proved hardware limit.",
                  ["controller-review", "fusion-definition"]),
            check("usable-spindle", "Usable spindle speed applied", "tooling",
                  "Generated programs use the manufacturer-supported 1500–8000 RPM range. Firmware report limits of 1360–8500 RPM are retained as controller metadata, without treating them as usable cutting speeds.",
                  ["controller-review", "fusion-definition"]),
            check("native-post", "Coastline GRBL adapter checked", "controller",
                  "The profile names its actual native post adapter. Feed and arc-centre modes, bounded ASCII comments, RPM limits and generated-job preflight pass regression tests. Existing tool-length compensation is preserved consistently with touch-off. No Fusion CPS or physical controller is claimed tested.",
                  ["controller-review"]),
            check("manual-tooling", "Manual tool changes selected", "controller",
                  "One installed tool per program, with guided changes between programs. No M6 or tool preload is emitted. The imported preload flag and 15-second estimate are not automatic-tool-changer capabilities.",
                  ["controller-review", "fusion-definition"]),
            check("physical-calibration", "Calibrate the installed machine", "hardware",
                  "The digital model is usable now. The actual controller settings and the relationship between homed table/spindle datums and CAD have not been measured on this machine.",
                  ["fusion-definition", "geometry-tests", "controller-review"],
                  "Read the installed controller settings, then record the table and spindle reference measurements after homing, including switch pull-off. Compare signs, offsets and usable travel with this profile before activating it for physical control."),
        ],
        "findings": [
            finding("physical-calibration", "blocking", "Calibrate the installed machine before physical control",
                    "Digital geometry, placement and native post checks are available now. Read actual controller settings and measure homed table/spindle datums and pull-off to validate the controller-to-model offsets before enabling this profile on hardware."),
        ],
    }


PACKAGE_README = """# Desktop CNC — digital machine package, revision 2

This package supports digital machine inspection, nested axis motion and stock
placement on the X table. The checks in `manifest.json` record what was proved and
how. Physical controller calibration is separate and remains pending. Digital
status does not activate the profile for machine control or certify a machining
job, holding force, tool reach or a collision-free travel envelope.

## What changed

The read-only complete STEP export includes all 52 authored solids in 50 leaf
occurrences. The nine Cover solids, previously missing, are present and bound to
a separate stationary enclosure component. Hiding that enclosure in a preview is
only a display choice: it remains part of the machine definition. The simplified
source still excludes some bearings, fasteners, switches and other hardware.

The `table-surface` frame describes the actual support plane: local X follows
world Y along the slots, local Y follows world Z across them, and local Z is world
X away from the surface. It is distinct from the original `table` machining-axis
frame. The asymmetric reference block is 203.2 × 37 × 50.8 mm in that seating
frame. Its footprint and bottom plane are checked against analytic STEP faces.
This fixes Coastline's seating-frame ambiguity without claiming a historical
Fusion simulation fault was reproduced. The original `.mch` remains unchanged.

T-slot geometry is a machine interface; the fixture owns its nut and fastener
choice. The custom Bookend M5 nut/key envelopes fit both actual CAD slots. This
seated-fit check does not establish insertion clearance, torque, thread strength
or the installed hardware's dimensions.

Tool dimensions now have distinct meanings. ER11 accepts an 8 mm shank; the
conservative overall-length planning cap is the supplied 75 mm, replacing the
legacy unsubstantiated 76.2 mm value. Nominal collet seating is 22.9 mm. The source
7 mm tool-diameter limit remains in the original Fusion metadata; it is not a
proved cutting-diameter hardware limit. Actual tool stickout is a setup input.
The usable spindle range is 1500–8000 RPM; 1360–8500 are firmware parameters.
The 150 W cutting-power value remains an estimate, not a measured rating.

Coastline uses `coastline.grbl.desktop.v1`, its native Swift GRBL adapter. The
original `system://grbl.cps` reference is provenance only. Native post/preflight
tests check explicit feed/arc modes, bounded ASCII comments, usable RPM and
manual tool changes. Tool-length compensation is preserved consistently with
existing touch-off. No controller command was sent for these checks.

## Commissioning still required

The supplied home mapping is q=(Mx, My+69, Mz+79.9), with controller home
(-86,-0.5,-0.5). Digital checks validate its algebra, nested motion and selected
CAD contact boundaries. Actual switch trip, pull-off, settings and table/spindle
datum measurements are needed to establish that mapping on the installed machine.
The reference CAD pose q=0 is an authoring position; the preview starts at the
defined digital home, inside the configured operating ranges.

## Evidence and reproduction

- `machine.step`: complete source geometry, unchanged; centimetres in STEP,
  converted to millimetres by OpenCascade.
- `source.mch` and `source-README.md`: unchanged original exports/notes. Some
  original warnings describe the earlier incomplete package; the checks and
  resolution evidence here record the actual fixes.
- `geometry-index.json`: source-bound occurrence paths and dimensional audit.
- `fusion-audit.json`: read-only saved-model inspection, including all 52 bodies.
- `geometry-validation.json`: reproduced analytic seating, mounting, body-bounds
  and selected contact checks, generated against this package's actual frames.
- `geometry-resolution.md` and `controller-evidence.md`: engineering decisions,
  exact source references, test scope and limitations.

From the repository root, run `engine/.venv/bin/python
scripts/build-desktop-machine-package.py --source '/path/to/Desktop CNC Machine -
share' --output resources/machines/desktop-cnc` as one shell command. Add `--check`
to compare without writing. `--geometry` defaults to the pinned complete export
in `resources/machine-profile-sources`; source hashes and occurrence names are
checked before packaging. Exact CAD tests run during every generation/check.
Changed source exports require a reviewed mapping and a new package revision.

The `view` frame changes viewport presentation only. Its world-Y right and
world-X up axes display this horizontal-spindle machine upright without changing
controller coordinates, machining frames or toolpaths.
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path("resources/machines/desktop-cnc"))
    parser.add_argument("--fusion-audit", type=Path,
                        default=Path(__file__).resolve().parents[1] / "docs/machine-profile-fusion-audit.json")
    parser.add_argument("--geometry", type=Path,
                        default=ROOT / "resources/machine-profile-sources/desktop-cnc-full.step")
    parser.add_argument("--check", action="store_true", help="Compare generated bytes with package, without writing")
    args = parser.parse_args()
    inputs = {}
    for name, expected in INPUTS.items():
        data = (args.source / name).read_bytes()
        if digest(data) != expected:
            raise ValueError(f"Source fingerprint changed: {name}. Review bindings and create a new profile revision.")
        inputs[name] = data
    full_geometry = args.geometry.read_bytes()
    if digest(full_geometry) != FULL_GEOMETRY_SHA256:
        raise ValueError("Complete geometry fingerprint changed; review occurrence bindings and issue a new profile revision")
    geometry_index = inspect_step(args.geometry)
    fusion_audit_data = args.fusion_audit.read_bytes()
    fusion_audit = json.loads(fusion_audit_data)
    fusion_body_count = sum(len(entry["bodies"]) for entry in fusion_audit["bodies"])
    cover_body_count = sum(len(entry["bodies"]) for entry in fusion_audit["bodies"] if entry["path"].startswith("Cover:1"))
    if (fusion_audit["document"] != "CNC simplified v31" or fusion_audit["isModified"]
            or fusion_body_count != 52 or cover_body_count != 9
            or fusion_body_count != geometry_index["assembledSolidCount"]):
        raise ValueError("Fusion audit no longer matches the reviewed source and STEP coverage")
    # The checks are results of exact CAD operations against the generated frames,
    # not unconditional claims copied from an old report.
    machine = json.loads(inputs["Desktop CNC Machine.mch"])
    definition = make_manifest(machine, {})
    frames = {frame["id"]: frame for frame in definition["frames"]}
    spec = importlib.util.spec_from_file_location("desktop_geometry_audit", ROOT / "scripts/audit-desktop-machine-geometry.py")
    audit_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit_module)
    geometry_report = audit_module.audit(args.geometry, frames["table-surface"], args.fusion_audit, frames["tool"])
    if (geometry_report["assembledSolidCount"] != 52 or geometry_report["coverSolidCount"] != 9
            or geometry_report["geometrySHA256"] != FULL_GEOMETRY_SHA256):
        raise ValueError("Exact CAD validation no longer matches the complete source model")
    files = {
        "machine.step": full_geometry,
        "source.mch": inputs["Desktop CNC Machine.mch"],
        "source-README.md": inputs["README.md"],
        "geometry-index.json": encoded(geometry_index),
        "fusion-audit.json": fusion_audit_data,
        "geometry-validation.json": encoded(geometry_report),
        "geometry-resolution.md": (ROOT / "docs/MACHINE_PROFILE_GEOMETRY_RESOLUTION.md").read_bytes(),
        "controller-evidence.md": (ROOT / "docs/machine-profile-controller-evidence.md").read_bytes(),
        "README.md": PACKAGE_README.encode(),
    }
    files["manifest.json"] = encoded(make_manifest(machine, files))
    if args.check:
        mismatches = [name for name, data in files.items() if not (args.output / name).is_file() or (args.output / name).read_bytes() != data]
        if mismatches:
            raise ValueError("Package differs from reproducible output: " + ", ".join(mismatches))
        print(f"Package matches all {len(files)} generated files; {geometry_index['shapeCount']} STEP shapes mapped.")
    else:
        args.output.mkdir(parents=True, exist_ok=True)
        for name, data in files.items():
            (args.output / name).write_bytes(data)
        print(f"Wrote digital package revision 2: {args.output}; {geometry_index['shapeCount']} STEP occurrences / {geometry_index['assembledSolidCount']} solids mapped. Physical calibration remains pending.")


if __name__ == "__main__":
    main()
