"""Portable machine definitions used for digital inspection.

The definition's axis coordinate q is distinct from controller machine position M:
q = controllerScale * M + controllerOffset. CAD geometry and frame origins are
stored at q=0. Linear displacements are inherited through the component tree.
Reading a package does not promote its calibration or authorize physical motion.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path

import numpy as np

MAXIMUM_MANIFEST_BYTES = 1_048_576
MAXIMUM_ASSET_BYTES = 209_715_200
MAXIMUM_PACKAGE_BYTES = 524_288_000
# Match the Swift preview's arithmetic headroom, including squared Float lengths.
# This is a representation limit, not a physical machine travel limit.
MAXIMUM_COORDINATE_MAGNITUDE = math.sqrt(float(np.finfo(np.float32).max)) / 1024


def _coordinate(value, field: str) -> float:
    number = _number(value, field)
    if abs(number) > MAXIMUM_COORDINATE_MAGNITUDE:
        raise ValueError(f"Machine profile {field} exceeds the supported numeric range.")
    return number


def _coordinate_vector(value, field: str) -> np.ndarray:
    vector = _vector(value, field)
    if np.any(np.abs(vector) > MAXIMUM_COORDINATE_MAGNITUDE):
        raise ValueError(f"Machine profile {field} exceeds the supported numeric range.")
    return vector


def _number(value, field: str) -> float:
    try:
        finite = not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite:
        raise ValueError(f"Machine profile {field} must be a finite number.")
    return float(value)


def _reject_nonfinite_json(value):
    raise ValueError(f"Non-finite JSON number {value} is not supported.")


def _vector(value, field: str) -> np.ndarray:
    if not isinstance(value, dict) or set(value) != {"x", "y", "z"}:
        raise ValueError(f"Machine profile {field} must contain x, y and z.")
    return np.array([_number(value[a], field) for a in "xyz"], dtype=float)


def _unit_vector(value, field: str) -> np.ndarray:
    vector = _vector(value, field)
    with np.errstate(over="ignore", invalid="ignore"):
        length_squared = float(vector @ vector)
    if abs(length_squared - 1) >= 1e-6:
        raise ValueError(f"Machine profile {field} must be a unit direction.")
    return vector


def _identifier(value, field: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 256:
        raise ValueError(f"Machine profile {field} must be a non-empty identifier.")
    return value


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            size += len(block)
            if size > MAXIMUM_ASSET_BYTES:
                raise ValueError("Machine asset grew beyond its 200 MiB size limit.")
            digest.update(block)
    return digest.hexdigest()


def _asset_path(root: Path, relative: str, maximum_bytes=MAXIMUM_ASSET_BYTES) -> Path:
    if not isinstance(relative, str) or not relative or "\\" in relative or ":" in relative or any(ord(c) < 32 for c in relative):
        raise ValueError("Machine profile asset path must be relative to the package.")
    p = Path(relative)
    if p.is_absolute() or any(part in ("", ".", "..") for part in relative.split("/")):
        raise ValueError("Machine profile asset path must stay inside the package.")
    current = root
    for component in relative.split("/"):
        current = current / component
        if current.is_symlink():
            raise ValueError(f"Machine asset contains a symbolic link: {relative}")
    resolved = (root / p).resolve()
    if not resolved.is_relative_to(root.resolve()) or not resolved.is_file():
        raise ValueError(f"Machine profile asset is missing or outside its package: {relative}")
    if not 0 < resolved.stat().st_size <= maximum_bytes:
        raise ValueError(f"Machine package file is empty or exceeds its size limit: {relative}")
    return resolved


@dataclass(frozen=True)
class MachineDefinition:
    manifest_path: Path
    data: dict
    geometry_path: Path
    fingerprint: str

    @property
    def components(self) -> dict[str, dict]:
        return {component["id"]: component for component in self.data["components"]}

    @property
    def bindings(self) -> dict[str, str]:
        return {path: component["id"] for component in self.data["components"]
                for path in component.get("modelEntities", [])}

    def component_for_path(self, occurrence_path: str) -> str:
        """The most specific ancestor binding owns this occurrence's geometry."""
        pieces = occurrence_path.split("/")
        bindings = self.bindings
        for n in range(len(pieces), 0, -1):
            candidate = "/".join(pieces[:n])
            if candidate in bindings:
                return bindings[candidate]
        raise ValueError(f"Machine geometry occurrence {occurrence_path} has no component assignment.")

    def translations(self, machine_position: list[float] | tuple[float, ...] | None = None) -> dict[str, list[float]]:
        """World-space displacement from the CAD reference pose, for every node.

        None means the authored CAD reference q=0, which need not be an allowed
        controller pose. No clamping to travel limits is performed for inspection.
        """
        if machine_position is not None:
            if not isinstance(machine_position, (list, tuple)) or len(machine_position) != 3:
                raise ValueError("Machine position must contain X, Y and Z in millimetres.")
            machine_position = [_number(v, "machine position") for v in machine_position]
        nodes = self.components
        result: dict[str, list[float]] = {}

        def visit(node_id: str) -> np.ndarray:
            if node_id in result:
                return np.array(result[node_id])
            node = nodes[node_id]
            offset = visit(node["parentID"]) if node.get("parentID") else np.zeros(3)
            if machine_position is not None and node.get("axis") is not None:
                axis = node["axis"]
                q = machine_position["xyz".index(axis["coordinate"])] * axis["controllerScale"] + axis["controllerOffset"]
                if not math.isfinite(q):
                    raise ValueError("Machine motion exceeds the supported numeric range.")
                with np.errstate(over="ignore", invalid="ignore"):
                    offset = offset + _vector(axis["direction"], "axis direction") * q
                if not np.all(np.isfinite(offset)) or np.any(np.abs(offset) > 8 * MAXIMUM_COORDINATE_MAGNITUDE):
                    raise ValueError("Machine motion exceeds the supported numeric range.")
            result[node_id] = offset.tolist()
            return offset

        for node_id in nodes:
            visit(node_id)
        return result

    def frame_origin(self, frame_id: str, machine_position=None) -> list[float]:
        frame = next((f for f in self.data.get("frames", []) if f["id"] == frame_id), None)
        if frame is None:
            raise ValueError(f"Machine profile has no frame {frame_id}.")
        with np.errstate(over="ignore", invalid="ignore"):
            origin = (_vector(frame["origin"], "frame origin")
                      + np.array(self.translations(machine_position)[frame["componentID"]]))
        if not np.all(np.isfinite(origin)) or np.any(np.abs(origin) > 8 * MAXIMUM_COORDINATE_MAGNITUDE):
            raise ValueError("Machine frame exceeds the supported numeric range.")
        return origin.tolist()

    def metadata(self) -> dict:
        """No legacy horizontal-machine assumptions are added to profile metadata."""
        fields = ("schemaVersion", "id", "revision", "name", "manufacturer", "units", "process", "controller",
                  "verification", "components", "frames", "mountingInterfaces", "findings", "evidence")
        return {key: self.data[key] for key in fields if key in self.data}


def load_definition(manifest_path: str | Path) -> MachineDefinition:
    """Load a schema-v1 package and verify bindings, kinematics and asset identity.

    This validates the digital representation only. Source claims and the profile's
    declared verification state remain unchanged.
    """
    path = Path(manifest_path)
    if path.is_dir():
        root = path.resolve()
    elif path.name == "manifest.json":
        root = path.parent.resolve()
    else:
        raise ValueError("Select a machine package folder or its manifest.json.")
    path = _asset_path(root, "manifest.json", MAXIMUM_MANIFEST_BYTES)
    raw = path.read_bytes()
    if len(raw) > MAXIMUM_MANIFEST_BYTES:
        raise ValueError("Machine manifest grew beyond its 1 MiB size limit.")
    try:
        data = json.loads(raw, parse_constant=_reject_nonfinite_json)
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError(f"Machine manifest is not valid JSON: {exc}") from exc
    if not isinstance(data, dict) or type(data.get("schemaVersion")) is not int or data["schemaVersion"] != 1:
        raise ValueError("Unsupported machine profile schema; expected version 1.")
    for field in ("id", "name"):
        _identifier(data.get(field), field)
    if re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,79}", data["id"]) is None:
        raise ValueError("Machine ID must be a short lowercase package identifier.")
    if type(data.get("revision")) is not int or data["revision"] < 1:
        raise ValueError("Machine profile revision must be a positive integer.")
    if data.get("verification") not in ("draft", "digital", "hardware"):
        raise ValueError("Machine profile must declare its verification state.")
    if data.get("units") != "mm" or data.get("process") != "milling":
        raise ValueError("Machine preview supports millimetre milling profiles only.")
    if data.get("controller") != "grbl":
        raise ValueError("Unsupported machine controller; this version supports GRBL profiles.")
    components = data.get("components")
    if not isinstance(components, list) or not 1 <= len(components) <= 128:
        raise ValueError("Machine profile needs between 1 and 128 components.")
    nodes: dict[str, dict] = {}
    bindings: dict[str, str] = {}
    coordinates: dict[str, np.ndarray] = {}
    for component in components:
        if not isinstance(component, dict):
            raise ValueError("Machine component must be an object.")
        node_id = _identifier(component.get("id"), "component id")
        if node_id in nodes:
            raise ValueError(f"Duplicate machine component id: {node_id}")
        nodes[node_id] = component
        role = component.get("role")
        if role not in ("static", "linearAxis", "table", "head"):
            raise ValueError(f"Unsupported machine component role: {role}")
        paths = component.get("modelEntities", [])
        if not isinstance(paths, list):
            raise ValueError("Machine modelEntities must be occurrence paths.")
        for binding in paths:
            if not isinstance(binding, str) or re.fullmatch(r"(?:0|[1-9][0-9]*)(?:/(?:0|[1-9][0-9]*))*", binding) is None:
                raise ValueError("Machine model entity must be an indexed STEP occurrence path, such as 0/2/0.")
            if binding in bindings:
                raise ValueError(f"Duplicate machine geometry assignment: {binding}")
            bindings[binding] = node_id
        axis = component.get("axis")
        if role == "linearAxis":
            if not isinstance(axis, dict):
                raise ValueError(f"Machine axis {node_id} is missing its motion definition.")
            coordinate = axis.get("coordinate")
            if coordinate not in ("x", "y", "z") or coordinate in coordinates:
                raise ValueError("Machine axes must have unique X, Y and Z controller coordinates.")
            coordinates[coordinate] = _unit_vector(axis.get("direction"), "axis direction")
            lo = _coordinate(axis.get("modelMinimum"), "axis minimum")
            hi = _coordinate(axis.get("modelMaximum"), "axis maximum")
            home = _coordinate(axis.get("modelHome"), "axis home")
            if not lo < hi or not lo <= home <= hi:
                raise ValueError(f"Machine axis {node_id} has invalid limits or home.")
            if abs(abs(_number(axis.get("controllerScale"), "controller scale")) - 1) > 1e-6:
                raise ValueError("Machine controller scale must be +1 or -1 in millimetres.")
            _coordinate(axis.get("controllerOffset"), "controller offset")
        elif axis is not None:
            raise ValueError(f"Only linear-axis components can define motion: {node_id}")
    if set(coordinates) != {"x", "y", "z"}:
        raise ValueError("This version requires three linear X/Y/Z axes.")
    directions = np.stack(list(coordinates.values()))
    if np.any(np.abs(directions @ directions.T - np.eye(3)) >= 1e-6):
        raise ValueError("Machine X/Y/Z directions must be perpendicular.")
    for node_id in nodes:
        seen = {node_id}
        parent = nodes[node_id].get("parentID")
        while parent is not None:
            if not isinstance(parent, str) or parent not in nodes:
                raise ValueError(f"Machine component {node_id} has an unknown parent.")
            if parent in seen:
                raise ValueError("Machine component hierarchy contains a cycle.")
            seen.add(parent)
            parent = nodes[parent].get("parentID")
    tables = [c for c in components if c["role"] == "table"]
    heads = [c for c in components if c["role"] == "head"]
    if len(tables) != 1 or len(heads) != 1:
        raise ValueError("A supported machine needs one table and one head.")

    def ancestors(node_id):
        chain = set()
        while node_id:
            chain.add(node_id)
            node_id = nodes[node_id].get("parentID")
        return chain

    table_chain, head_chain = ancestors(tables[0]["id"]), ancestors(heads[0]["id"])
    for node_id, component in nodes.items():
        if component.get("axis") is not None and ((node_id in table_chain) == (node_id in head_chain)):
            raise ValueError(f"Machine axis {node_id} must move either the table or head; shared or disconnected motion is unsupported.")
    if not bindings:
        raise ValueError("Machine profile has no geometry assignments.")
    frame_ids = set()
    frames = data.get("frames", [])
    if not isinstance(frames, list):
        raise ValueError("Machine frames must be an array.")
    for frame in frames:
        if not isinstance(frame, dict):
            raise ValueError("Machine frame must be an object.")
        frame_id = _identifier(frame.get("id"), "frame id")
        if frame_id in frame_ids or frame.get("componentID") not in nodes:
            raise ValueError("Machine frames need unique IDs and existing components.")
        frame_ids.add(frame_id)
        _coordinate_vector(frame.get("origin"), "frame origin")
        x = _unit_vector(frame.get("xDirection"), "frame X direction")
        z = _unit_vector(frame.get("zDirection"), "frame Z direction")
        if abs(float(x @ z)) > 1e-6:
            raise ValueError("Machine frame X and Z directions must be perpendicular.")
    if not {tables[0]["id"], heads[0]["id"]} <= {frame["componentID"] for frame in frames}:
        raise ValueError("Machine needs reference frames on both the table and head.")
    mounts = data.get("mountingInterfaces", [])
    if not isinstance(mounts, list):
        raise ValueError("Machine mounting interfaces must be an array.")
    mount_ids = set()
    for mount in mounts:
        if not isinstance(mount, dict):
            raise ValueError("Machine mounting interface must be an object.")
        mount_id = _identifier(mount.get("id"), "mounting interface id")
        if mount_id in mount_ids or mount.get("frameID") not in frame_ids:
            raise ValueError("Machine mounting interfaces need unique IDs and existing frames.")
        mount_ids.add(mount_id)
        slots = mount.get("slots")
        if mount.get("kind") != "tSlots" or not isinstance(slots, list) or not 1 <= len(slots) <= 64:
            raise ValueError("Supported mounting interfaces require 1–64 T-slots.")
        slot_ids = set()
        for slot in slots:
            if not isinstance(slot, dict):
                raise ValueError("Machine mounting slot must be an object.")
            slot_id = _identifier(slot.get("id"), "slot id")
            if slot_id in slot_ids:
                raise ValueError("Machine mounting slots need unique IDs.")
            slot_ids.add(slot_id)
            _coordinate_vector(slot.get("origin"), "slot origin")
            _unit_vector(slot.get("direction"), "slot direction")
            dimensions = [_coordinate(slot.get(key), f"slot {key}") for key in
                          ("length", "openingWidth", "cavityWidth", "cavityDepth", "lipThickness")]
            if min(dimensions) <= 0 or slot["openingWidth"] >= slot["cavityWidth"]:
                raise ValueError("Machine slot dimensions must be positive and its cavity wider than the opening.")
    assets = data.get("assets")
    if not isinstance(assets, list) or not 1 <= len(assets) <= 32:
        raise ValueError("Machine profile needs between 1 and 32 assets.")
    geometry = []
    asset_paths = set()
    total_bytes = len(raw)
    for asset in assets:
        if not isinstance(asset, dict):
            raise ValueError("Machine asset must be an object.")
        if asset.get("role") not in ("geometry", "fusionDefinition", "fusionArchive", "reference"):
            raise ValueError("Machine profile has an unsupported asset role.")
        if asset.get("path") == "manifest.json":
            raise ValueError("The machine manifest cannot also be an asset.")
        asset_path = _asset_path(path.parent, asset.get("path"))
        total_bytes += asset_path.stat().st_size
        if total_bytes > MAXIMUM_PACKAGE_BYTES:
            raise ValueError("Machine package exceeds 500 MiB.")
        if asset_path in asset_paths:
            raise ValueError("Machine profile has duplicate asset paths.")
        asset_paths.add(asset_path)
        expected = asset.get("sha256", "")
        if not isinstance(expected, str) or re.fullmatch(r"[0-9a-fA-F]{64}", expected) is None or _sha256(asset_path) != expected.lower():
            raise ValueError(f"Machine asset SHA-256 does not match: {asset.get('path')}")
        if asset.get("role") == "geometry":
            if asset_path.suffix.lower() not in (".step", ".stp"):
                raise ValueError("Machine geometry must be a STEP assembly.")
            geometry.append(asset_path)
    if len(geometry) != 1:
        raise ValueError("Machine profile must declare exactly one STEP geometry asset.")
    definition = MachineDefinition(path, data, geometry[0], hashlib.sha256(raw).hexdigest())
    definition.translations([0, 0, 0])  # Also reject overflowed offsets on inherited chains.
    return definition
