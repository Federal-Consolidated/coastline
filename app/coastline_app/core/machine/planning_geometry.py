"""Adapts authored CAD coordinates to the horizontal-spindle setup planner. Controller-relative
cutting axes define the workspace basis; CAD axis names and component IDs don't.
Port of Machine/MachinePlanningGeometry.swift."""

from __future__ import annotations

import copy
import math
from dataclasses import dataclass, replace

import numpy as np

from ..codable import Range
from ..geometry import Vec3, swift_round
from ..mesh import MeshData
from .definition import (MachineComponentRole, MachineCoordinate, MachineDefinition, MachineDefinitionError,
                         MachineValidationScope, MachineValidationStatus)


@dataclass
class Bounds:
    minimum: Vec3
    maximum: Vec3

    @property
    def size(self) -> Vec3:
        return self.maximum - self.minimum


def _dot(a: Vec3, b: Vec3) -> float:
    return a.x * b.x + a.y * b.y + a.z * b.z


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)


def _near(a: Vec3, b: Vec3) -> bool:
    return abs(a.x - b.x) < 0.000001 and abs(a.y - b.y) < 0.000001 and abs(a.z - b.z) < 0.000001


def _ancestors(cid: str, definition: MachineDefinition) -> set[str]:
    chain: set[str] = set()
    current = cid
    while current is not None and current not in chain:
        chain.add(current)
        comp = next((c for c in definition.components if c.id == current), None)
        current = comp.parent_id if comp is not None else None
    return chain


def _bounds(points: np.ndarray) -> Bounds:
    if len(points) == 0:
        raise MachineDefinitionError("The machine model does not contain the declared table surface.")
    return Bounds(Vec3.of(points.min(axis=0)), Vec3.of(points.max(axis=0)))


def _planar_regions(points: np.ndarray, indices: np.ndarray, eligible: np.ndarray) -> list[np.ndarray]:
    """Merge tessellation vertices at shared locations, then find connected coplanar triangle
    regions (a box of all vertices at one height would wrongly include separate fastener pads)."""
    if not eligible.any():
        return []
    tris = indices.reshape(-1, 3).astype(np.int64)
    ok = eligible[tris].all(axis=1)
    keys: dict[tuple[float, float, float], int] = {}
    positions: list[int] = []
    parents: list[int] = []

    def vertex(i: int) -> int:
        p = points[i]
        key = (swift_round(p[0] * 10_000), swift_round(p[1] * 10_000), swift_round(p[2] * 10_000))
        vid = keys.get(key)
        if vid is None:
            vid = len(parents)
            keys[key] = vid
            parents.append(vid)
            positions.append(i)
        return vid

    def root(i: int) -> int:
        while parents[i] != i:
            parents[i] = parents[parents[i]]
            i = parents[i]
        return i

    for a, b, c in tris[ok].tolist():
        pa, pb, pc = points[a], points[b], points[c]
        area = abs((pb[1] - pa[1]) * (pc[2] - pa[2]) - (pb[2] - pa[2]) * (pc[1] - pa[1]))
        if not area > 1e-9:
            continue
        ia, ib, ic = vertex(a), vertex(b), vertex(c)
        ra, rb, rc = root(ia), root(ib), root(ic)
        parents[rb] = ra
        parents[rc] = ra
    regions: dict[int, list[int]] = {}
    for k, i in enumerate(positions):
        regions.setdefault(root(k), []).append(i)
    return [points[ids] for ids in regions.values()]


class MachinePlanningGeometry:
    def __init__(self, definition: MachineDefinition, parts: list) -> None:
        from ..engine.client import MachineModel
        from ..post.grbl_post import ADAPTER_ID
        S, P = MachineValidationScope, MachineValidationStatus
        definition = copy.deepcopy(definition)  # a value, as in Swift: later edits by the caller don't reach it
        definition.validate()
        if not (definition.supports_digital_setup and definition.validation_status(S.TOOLING) is P.PASSED
                and definition.validation_status(S.CONTROLLER) is P.PASSED and definition.post_processor_id == ADAPTER_ID):
            raise MachineDefinitionError("This machine profile needs completed digital setup, tooling and controller checks before planning.")
        planning_issues = [c for c in definition.validation_checks if c.scope is not S.HARDWARE and c.status is not P.PASSED]
        other_blockers = [f for f in definition.blocking_findings
                          if not any(c.id == f.id and c.scope is S.HARDWARE and c.status is not P.PASSED for c in definition.validation_checks)]
        if planning_issues or other_blockers:
            raise MachineDefinitionError("Resolve this profile's planning findings before using it: "
                                         + "; ".join([c.title for c in planning_issues] + [f.summary for f in other_blockers]))
        table = next(c for c in definition.components if c.role is MachineComponentRole.TABLE)
        head = next(c for c in definition.components if c.role is MachineComponentRole.HEAD)
        table_chain = _ancestors(table.id, definition)
        basis: dict[MachineCoordinate, Vec3] = {}
        reference = [0.0, 0.0, 0.0]
        for c in definition.components:
            a = c.axis
            if a is None:
                continue
            sign = a.controller_scale * (-1 if c.id in table_chain else 1)
            basis[a.coordinate] = a.direction * sign
            reference[a.coordinate.index] = -a.controller_offset / a.controller_scale
        x, y, z = basis[MachineCoordinate.X], basis[MachineCoordinate.Y], basis[MachineCoordinate.Z]
        if not _dot(_cross(x, y), z) > 0.999999:
            raise MachineDefinitionError("This planner requires right-handed controller-relative X, Y and Z cutting axes.")
        self.basis_x, self.basis_y, self.basis_z = x, y, z

        def projected(p: Vec3) -> Vec3:
            return Vec3(_dot(p, x), _dot(p, y), _dot(p, z))

        seating_candidates = [f for f in definition.frames if f.component_id == table.id and _near(projected(f.z_direction), Vec3(1, 0, 0))]
        seating = None
        if definition.reference_stock is not None:
            seating = next((f for f in definition.frames if f.id == definition.reference_stock.frame_id and f.component_id == table.id), None)
        if seating is None and len(seating_candidates) == 1:
            seating = seating_candidates[0]
        if seating is None:
            raise MachineDefinitionError("The machine profile needs an explicit table seating frame before planning.")
        tool_frames = [f for f in definition.frames if f.component_id == head.id]
        tool = next((f for f in tool_frames if f.id == "tool"), None) or (tool_frames[0] if len(tool_frames) == 1 else None)
        if tool is None:
            raise MachineDefinitionError("The machine profile needs an unambiguous tool reference frame before planning.")
        if not (_near(projected(seating.z_direction), Vec3(1, 0, 0)) and _near(projected(tool.z_direction), Vec3(0, 0, 1))):
            raise MachineDefinitionError("This setup planner currently supports a horizontal spindle with the table normal along cutting X and the tool along cutting −Z. This profile can still be inspected digitally.")
        surface = projected(seating.origin)
        spans = [s.length for m in definition.mounting_interfaces
                 for f in [next((f for f in definition.frames if f.id == m.frame_id), None)]
                 if f is not None and table.id in _ancestors(f.component_id, definition) for s in m.slots]
        support_span = max(spans) if spans else 0.0
        if not parts:
            raise MachineDefinitionError("The machine profile has no workspace geometry.")
        ids = {c.id for c in definition.components}
        converted = []
        table_points: list[np.ndarray] = []
        support_points: list[np.ndarray] = []
        for part in parts:
            if part.group not in ids:
                raise MachineDefinitionError(f"Machine geometry references unknown component '{part.group}'.")
            mesh = part.mesh
            v, nrm, idx = np.asarray(mesh.vertices, np.float32).reshape(-1, 3), np.asarray(mesh.normals, np.float32).reshape(-1, 3), np.asarray(mesh.indices).reshape(-1)
            if (len(v) == 0 or len(nrm) != len(v) or len(idx) == 0 or len(idx) % 3 or (idx >= len(v)).any()
                    or not np.isfinite(v).all() or not np.isfinite(nrm).all()):
                raise MachineDefinitionError(f"Machine geometry for '{part.group}' is invalid.")
            vd, nd = v.astype(float), nrm.astype(float)
            # Same arithmetic order as the Swift dot products (no fused sums).
            pts = np.stack([vd[:, 0] * x.x + vd[:, 1] * x.y + vd[:, 2] * x.z,
                            vd[:, 0] * y.x + vd[:, 1] * y.y + vd[:, 2] * y.z,
                            vd[:, 0] * z.x + vd[:, 1] * z.y + vd[:, 2] * z.z], axis=1)
            nms = np.stack([nd[:, 0] * x.x + nd[:, 1] * x.y + nd[:, 2] * x.z,
                            nd[:, 0] * y.x + nd[:, 1] * y.y + nd[:, 2] * y.z,
                            nd[:, 0] * z.x + nd[:, 1] * z.y + nd[:, 2] * z.z], axis=1)
            positions = pts.astype(np.float32)
            if not np.isfinite(positions).all():
                raise MachineDefinitionError("Machine geometry exceeds the workspace coordinate range.")
            attached = table.id in _ancestors(part.group, definition)
            seated = (np.abs(pts[:, 0] - surface.x) <= 0.01) & (nms[:, 0] > 0.999) if attached else np.zeros(len(pts), bool)
            broad = []
            for region in _planar_regions(pts, idx, seated):
                try:
                    b = _bounds(region)
                except MachineDefinitionError:
                    continue
                if b.size.y + 0.01 >= support_span:
                    broad.append(region)
            if broad:
                table_points.append(pts)
                support_points.extend(broad)
            box = _bounds(pts)
            changed = replace(part, mesh=MeshData(positions, nms.astype(np.float32), mesh.indices, box.minimum, box.maximum,
                                                  mesh.exact, mesh.face_count, mesh.part_id, list(mesh.warnings)))
            converted.append(changed)
        table_box = _bounds(np.concatenate(table_points) if table_points else np.zeros((0, 3)))
        support_box = _bounds(np.concatenate(support_points) if support_points else np.zeros((0, 3)))
        if not (support_box.size.y > 0 and support_box.size.z > 0 and table_box.minimum.x < surface.x - 0.001):
            raise MachineDefinitionError("The declared seating frame does not match a usable table surface in the model.")
        # The authored frame is the datum; tessellation only verifies the plane and its extents.
        support_box = Bounds(support_box.minimum.replacing(0, surface.x), support_box.maximum.replacing(0, surface.x))
        slots: list[float] = []
        for m in definition.mounting_interfaces:
            frame = next((f for f in definition.frames if f.id == m.frame_id), None)
            if frame is None or table.id not in _ancestors(frame.component_id, definition):
                continue
            for s in m.slots:
                direction = projected(definition.world_direction(s.direction, frame.id))
                if not (abs(abs(direction.y) - 1) < 0.000001 and abs(direction.x) < 0.000001 and abs(direction.z) < 0.000001):
                    raise MachineDefinitionError("This fixture planner requires table T-slots parallel to cutting Y.")
                start = projected(definition.world_point(s.origin, frame.id))
                end = start + direction * s.length
                if not (abs(start.x - surface.x) < 0.01
                        and support_box.minimum.z - 0.01 <= start.z <= support_box.maximum.z + 0.01
                        and min(start.y, end.y) >= support_box.minimum.y - 0.01
                        and max(start.y, end.y) <= support_box.maximum.y + 0.01):
                    raise MachineDefinitionError("The table T-slot definition lies outside the model's support surface.")
                slots.append(start.z)
        if not slots:
            raise MachineDefinitionError("This fixture planner requires an authored T-slot interface on the table.")
        self.definition = definition
        self.table_component_id, self.head_component_id = table.id, head.id
        self.table_bounds, self.support_bounds = table_box, support_box
        self.model = MachineModel(converted, projected(tool.origin), surface.x, Vec3(*reference), sorted(slots))

    def world_to_planning(self, p: Vec3) -> Vec3:
        return Vec3(_dot(p, self.basis_x), _dot(p, self.basis_y), _dot(p, self.basis_z))

    def planning_to_world(self, p: Vec3) -> Vec3:
        return self.basis_x * p.x + self.basis_y * p.y + self.basis_z * p.z

    def component_translations(self, position: Vec3) -> dict[str, Vec3]:
        """Component groups stay distinct; callers alias stock/table and tool/head themselves."""
        return {c.id: self.world_to_planning(self.definition.world_translation(c.id, position)) for c in self.definition.components}

    def room_behind_table(self, height: float, width: float, centre_y: float, clearance: float = 1, limit: float = 1000,
                          skip: set[str] = frozenset()) -> tuple[float, str | None]:
        """How far stock may reach past the table's far edge before it meets any other part of the
        machine anywhere in the axes' travel (triangle bounds: on the safe side), and what stops it."""
        back = self.support_bounds.minimum.z
        lo = np.array([self.model.table_top_x - clearance, centre_y - width / 2 - clearance, back - limit])
        hi = np.array([self.model.table_top_x + height + clearance, centre_y + width / 2 + clearance, back])
        e = self.definition.profile.machine_envelope
        corners = [Vec3(px, py, pz) for px in (e.x.lower, e.x.upper) for py in (e.y.lower, e.y.upper) for pz in (e.z.lower, e.z.upper)]

        def relative(at: Vec3) -> dict[str, np.ndarray]:
            t = self.component_translations(at)
            table = t.get(self.table_component_id)
            if table is None:
                return {}
            return {k: np.array([v.x - table.x, v.y - table.y, v.z - table.z]) for k, v in t.items()}

        posed = relative(self.model.model_pose)
        sweep_lo: dict[str, np.ndarray] = {}
        sweep_hi: dict[str, np.ndarray] = {}
        for c in corners:
            for cid, r in relative(c).items():
                d = r - posed.get(cid, np.zeros(3))
                sweep_lo[cid] = np.minimum(sweep_lo.get(cid, d), d)
                sweep_hi[cid] = np.maximum(sweep_hi.get(cid, d), d)
        best: tuple[float, str | None] = (limit, None)
        for part in self.model.parts:
            if part.group == self.table_component_id or part.group in skip:
                continue
            a, b = sweep_lo.get(part.group, np.zeros(3)), sweep_hi.get(part.group, np.zeros(3))
            n = len(part.mesh.indices) // 3 * 3
            if n == 0:
                continue
            tri = part.mesh.vertices.astype(float)[part.mesh.indices[:n].astype(np.int64)].reshape(-1, 3, 3)
            tlo, thi = tri.min(axis=1) + a, tri.max(axis=1) + b
            hit = ((thi[:, 0] > lo[0]) & (tlo[:, 0] < hi[0]) & (thi[:, 1] > lo[1]) & (tlo[:, 1] < hi[1])
                   & (tlo[:, 2] < hi[2]) & (thi[:, 2] > lo[2]))
            if hit.any():
                room = float(np.maximum(back - thi[hit, 2], 0).min())
                if room < best[0]:
                    best = (room, part.group)
        return best

    def is_moving(self, component_id: str) -> bool:
        chain = _ancestors(component_id, self.definition)
        return any(c.id in chain and c.axis is not None for c in self.definition.components)

    def is_enclosure(self, component_id: str) -> bool:
        chain = _ancestors(component_id, self.definition)
        return any(c.id in chain and c.is_enclosure is True for c in self.definition.components)

    def moves_with_table(self, component_id: str) -> bool:
        axes = {c.id for c in self.definition.components if c.axis is not None}
        motion = _ancestors(component_id, self.definition) & axes
        table_motion = _ancestors(self.table_component_id, self.definition) & axes
        return bool(motion) and motion == table_motion

    @property
    def _table_mounting_interfaces(self) -> list:
        out = []
        for m in self.definition.mounting_interfaces:
            frame = next((f for f in self.definition.frames if f.id == m.frame_id), None)
            if frame is not None and self.table_component_id in _ancestors(frame.component_id, self.definition):
                out.append(m)
        return out

    @property
    def supports_vetted_fixture_mounting(self) -> bool:
        """Interface eligibility for the vetted clamp/Bookend family (not a placement proof)."""
        slots = [s for m in self._table_mounting_interfaces for s in m.slots]
        tolerance = 0.1
        minimum_slot_length = 11.0  # the T-nut's length along the slot
        if not (len(slots) == 2 and len(self.model.t_slot_z) == 2
                and abs((self.model.t_slot_z[1] - self.model.t_slot_z[0]) - 40.005) <= tolerance):
            return False
        return all(s.length >= minimum_slot_length and abs(s.opening_width - 6.13) <= tolerance
                   and abs(s.cavity_width - 12) <= tolerance and abs(s.cavity_depth - 3) <= tolerance
                   and abs(s.lip_thickness - 2) <= tolerance for s in slots)

    def bookend_mount_table(self, centre_y: float):
        """Measured mounting limits in the table model's workspace."""
        from ..plan.fixture_mechanism import Table
        if not (self.supports_vetted_fixture_mounting and math.isfinite(centre_y)):
            return None
        lower, upper = -math.inf, math.inf
        for m in self._table_mounting_interfaces:
            for s in m.slots:
                try:
                    origin = self.definition.world_point(s.origin, m.frame_id)
                    direction = self.definition.world_direction(s.direction, m.frame_id)
                except MachineDefinitionError:
                    return None
                a = self.world_to_planning(origin)
                b = self.world_to_planning(origin + direction * s.length)
                lower = max(lower, min(a.y, b.y))
                upper = min(upper, max(a.y, b.y))
        if not (math.isfinite(lower) and math.isfinite(upper) and lower < upper):
            return None
        return Table(self.model.table_top_x, list(self.model.t_slot_z), Range(lower, upper), self.support_bounds.maximum.z, centre_y)
