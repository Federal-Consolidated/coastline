"""Exact STEP occurrence ownership for vetted, articulated fixture assemblies.

No spatial grouping: each closed solid retains its declared component and occurrence.
The caller applies mechanical state to these authored reference meshes.
"""
from __future__ import annotations

import hashlib
import math
import re
from pathlib import Path

import numpy as np
from OCP.BRepCheck import BRepCheck_Analyzer
from OCP.IFSelect import IFSelect_RetDone
from OCP.STEPCAFControl import STEPCAFControl_Reader
from OCP.TCollection import TCollection_ExtendedString
from OCP.TDF import TDF_Label
from OCP.TDocStd import TDocStd_Document
from OCP.TopAbs import TopAbs_FACE, TopAbs_SOLID
from OCP.TopExp import TopExp_Explorer
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS
from OCP.XCAFDoc import XCAFDoc_DocumentTool
from OCP.collections import Sequence_TDF_Label

from .cad_import import tessellate


def _validate_definition(definition):
    if not isinstance(definition, dict) or definition.get("schemaVersion") != 1:
        raise ValueError("Unsupported fixture assembly format.")
    if not isinstance(definition.get("id"), str) or not definition["id"].strip():
        raise ValueError("Fixture assembly needs an ID.")
    if type(definition.get("revision")) is not int or definition["revision"] < 1:
        raise ValueError("Fixture assembly needs a positive revision.")
    if type(definition.get("isAssembled", True)) is not bool:
        raise ValueError("Fixture assembly readiness must be explicit true or false.")
    digest = definition.get("modelSHA256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
        raise ValueError("Fixture assembly needs the exact CAD SHA-256.")
    components = definition.get("components")
    if not isinstance(components, list) or not 1 <= len(components) <= 256:
        raise ValueError("Fixture assembly must have 1–256 components.")
    ids, joints, bindings = {}, set(), {}
    for component in components:
        if not isinstance(component, dict):
            raise ValueError("Invalid fixture component.")
        cid = component.get("id")
        if not isinstance(cid, str) or not cid or cid in ids:
            raise ValueError("Fixture component IDs must be unique and nonempty.")
        if component.get("role") not in ("physical", "reference"):
            raise ValueError("Fixture components must declare physical or reference geometry.")
        ids[cid] = component
        paths = component.get("modelEntities")
        if not isinstance(paths, list):
            raise ValueError("Fixture components need exact CAD occurrence paths.")
        for path in paths:
            if not isinstance(path, str) or not re.fullmatch(r"[0-9]+(/[0-9]+)*", path) or path in bindings:
                raise ValueError("Fixture CAD bindings must be unique indexed leaf paths.")
            bindings[path] = cid
        joint = component.get("joint")
        if joint is not None:
            if not isinstance(joint, dict) or joint.get("kind") not in ("prismatic", "revolute", "screw"):
                raise ValueError("Unsupported fixture joint.")
            jid = joint.get("id")
            if not isinstance(jid, str) or not jid or jid in joints:
                raise ValueError("Fixture joint IDs must be unique and nonempty.")
            joints.add(jid)
            def vector(key):
                value = joint.get(key)
                if not isinstance(value, dict) or any(type(value.get(k)) not in (int, float) or not math.isfinite(value[k]) for k in ("x", "y", "z")):
                    raise ValueError("Fixture joint coordinates must be finite.")
                return np.array([value[k] for k in ("x", "y", "z")])
            if abs(np.linalg.norm(vector("axis")) - 1) > 1e-6 or np.any(np.abs(vector("origin")) > 1e6):
                raise ValueError("Fixture joint axis/origin are invalid.")
            for key in ("minimum", "maximum", "referenceValue"):
                if type(joint.get(key)) not in (int, float) or not math.isfinite(joint[key]) or abs(joint[key]) > 1e6:
                    raise ValueError("Fixture joint limits must be finite.")
            if not joint["minimum"] <= joint["referenceValue"] <= joint["maximum"]:
                raise ValueError("Fixture joint reference must be within its limits.")
            pitch = joint.get("pitch")
            if joint["kind"] == "screw":
                if type(pitch) not in (int, float) or not math.isfinite(pitch) or not 0.000001 <= pitch <= 1000:
                    raise ValueError("Fixture screw joint needs a positive pitch.")
            elif pitch is not None:
                raise ValueError("Only fixture screw joints may have a pitch.")
    if not any(c["role"] == "physical" and c["modelEntities"] for c in components):
        raise ValueError("Fixture assembly has no physical bodies.")
    for component in components:
        current, seen = component, set()
        while current is not None:
            if current["id"] in seen:
                raise ValueError("Fixture component hierarchy contains a cycle.")
            seen.add(current["id"])
            parent = current.get("parentID")
            if parent is not None and parent not in ids:
                raise ValueError("Fixture component has an unknown parent.")
            current = ids.get(parent)
        if not component["modelEntities"] and not any(c.get("parentID") == component["id"] for c in components):
            raise ValueError("Fixture component has no CAD bodies or children.")
    return bindings


def load_fixture_assembly(path: str | Path, definition: dict):
    """Return ({component_id, entity_path, solid_index, bounds, face_count}, Mesh) pairs."""
    bindings = _validate_definition(definition)
    path = Path(path)
    if path.suffix.lower() not in (".step", ".stp"):
        raise ValueError("Vetted fixture assemblies require their exact STEP asset.")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != definition["modelSHA256"].lower():
        raise ValueError("Fixture CAD SHA-256 does not match its mechanical definition.")
    doc = TDocStd_Document(TCollection_ExtendedString("fixture-assembly"))
    reader = STEPCAFControl_Reader()
    reader.SetNameMode(True)
    if reader.ReadFile(str(path)) != IFSelect_RetDone or not reader.Transfer(doc):
        raise ValueError("Could not read the vetted fixture STEP assembly.")
    shape_tool = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    seen, result = set(), []

    def face_count(shape):
        ex, count = TopExp_Explorer(shape, TopAbs_FACE), 0
        while ex.More():
            count += 1
            ex.Next()
        return count

    def visit(label, location, occurrence_path):
        children = Sequence_TDF_Label()
        shape_tool.GetComponents_s(label, children)
        if len(children):
            for index, occurrence in enumerate(children):
                reference = TDF_Label()
                if not shape_tool.GetReferredShape_s(occurrence, reference):
                    reference = occurrence
                visit(reference, location.Multiplied(shape_tool.GetLocation_s(occurrence)), f"{occurrence_path}/{index}")
            return
        if occurrence_path not in bindings:
            raise ValueError(f"Fixture CAD occurrence {occurrence_path} has no explicit component assignment.")
        seen.add(occurrence_path)
        shape = shape_tool.GetShape_s(label).Moved(location)
        if shape.IsNull():
            raise ValueError(f"Fixture CAD occurrence {occurrence_path} is empty.")
        explorer = TopExp_Explorer(shape, TopAbs_SOLID)
        solid_index, faces = 0, 0
        while explorer.More():
            solid = TopoDS.Solid(explorer.Current())
            if not BRepCheck_Analyzer(solid).IsValid():
                raise ValueError(f"Fixture CAD occurrence {occurrence_path} has an invalid solid.")
            mesh, _ = tessellate(solid, 0.01)
            if not len(mesh.indices) or not np.all(np.isfinite(mesh.vertices)) or not np.all(np.isfinite(mesh.normals)) or np.any(np.abs(mesh.vertices) > 1e6):
                raise ValueError("Fixture CAD contains invalid mesh geometry.")
            lo, hi = mesh.bounds
            count = face_count(solid)
            result.append((dict(component_id=bindings[occurrence_path], entity_path=occurrence_path,
                                solid_index=solid_index, bounds_min=lo, bounds_max=hi, face_count=count), mesh))
            faces += count
            solid_index += 1
            explorer.Next()
        if not solid_index or faces != face_count(shape):
            raise ValueError(f"Every surface of fixture occurrence {occurrence_path} must belong to a closed solid.")

    roots = Sequence_TDF_Label()
    shape_tool.GetFreeShapes(roots)
    for index, root in enumerate(roots):
        visit(root, shape_tool.GetLocation_s(root), str(index))
    if seen != set(bindings):
        raise ValueError("Fixture CAD assignments are missing or are not exact leaf occurrences: " + ", ".join(sorted(set(bindings) - seen)))
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError("Fixture CAD changed while loading.")
    return result
