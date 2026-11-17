"""Editing groups and exact assembly transforms for a fixture's CAD. Port of
Plan/LibraryFixtureGeometry.swift. Nearby closed solids stay together so screws and washers move
with their bookend; no mesh is stretched or scaled."""

from __future__ import annotations

import copy
import hashlib
import math
from dataclasses import dataclass, field

import numpy as np

from .. import codable
from ..geometry import Vec3, affine
from ..mesh import MeshData, merge
from . import fixture_edge_snap
from .fixture_assembly import AssemblyError, FixtureAssemblyState, JointKind, Role
from .setup import FACINGS, Setup


@dataclass
class GeometryComponent:
    id: str
    name: str
    role: Role
    solid_indices: list[int]
    mesh: MeshData
    snap_faces: list

    @property
    def centre(self) -> np.ndarray:
        return (self.mesh.bounds_min.array + self.mesh.bounds_max.array) / 2


def axis_angle(angle: float, axis) -> np.ndarray:
    """simd_double3x3(simd_quatd(angle:axis:)): a rotation about a (normalized) axis."""
    a = np.asarray(axis, float)
    n = float(np.linalg.norm(a))
    if n == 0:
        return np.identity(3)
    x, y, z = a / n
    c, s = math.cos(angle), math.sin(angle)
    C = 1 - c
    return np.array([[c + x * x * C, x * y * C - z * s, x * z * C + y * s],
                     [y * x * C + z * s, c + y * y * C, y * z * C - x * s],
                     [z * x * C - y * s, z * y * C + x * s, c + z * z * C]])


class LibraryFixtureGeometry:
    def __init__(self, solids: list[MeshData], components: list[GeometryComponent], layout_id: str,
                 assembly_definition=None, physical_solid_indices: set[int] | None = None) -> None:
        self.solids = solids
        self.components = components
        self.layout_id = layout_id
        self.assembly_definition = assembly_definition
        self.physical_solid_indices = physical_solid_indices if physical_solid_indices is not None else set(range(len(solids)))

    @staticmethod
    def from_solids(solids: list[MeshData], grouping_gap: float = 0.5) -> "LibraryFixtureGeometry":
        """Nearby solids grouped into editing pieces (not a connectivity analysis)."""
        gap = max(0.0, min(grouping_gap, 5.0)) if math.isfinite(grouping_gap) else 0.5
        lo = [s.bounds_min.array for s in solids]
        hi = [s.bounds_max.array for s in solids]
        parents = list(range(len(solids)))

        def root(i: int) -> int:
            while parents[i] != i:
                i = parents[i]
            return i

        for i in range(len(solids)):
            for j in range(i + 1, len(solids)):
                if all(lo[i][k] <= hi[j][k] + gap and lo[j][k] <= hi[i][k] + gap for k in range(3)):
                    parents[root(j)] = root(i)
        groups: dict[int, list[int]] = {}
        for i in range(len(solids)):
            groups.setdefault(root(i), []).append(i)

        def key(g: list[int]):
            low = np.min([lo[i] for i in g], axis=0)
            return (low[0], low[1], low[2], g[0])

        ordered = sorted(groups.values(), key=key)
        components = []
        for i, indices in enumerate(ordered):
            mesh = merge([solids[k] for k in indices], [np.identity(4)] * len(indices))
            components.append(GeometryComponent(f"piece-{i}", f"Piece {i + 1}", Role.PHYSICAL, indices, mesh,
                                                fixture_edge_snap.faces(mesh)))
        parts = []
        for c in components:
            m = c.mesh
            values = [m.bounds_min.x, m.bounds_min.y, m.bounds_min.z, m.bounds_max.x, m.bounds_max.y, m.bounds_max.z]
            parts.append(",".join("%.6f" % v for v in values) + f":{len(c.solid_indices)}:{len(m.indices)}")
        return LibraryFixtureGeometry(solids, components, "nearby-solids-v1|" + "|".join(parts))

    @staticmethod
    def from_parts(parts: list, definition) -> "LibraryFixtureGeometry":
        """Exact, versioned CAD ownership: validates the engine's parts against the definition."""
        definition.validate()
        seen = set()
        wanted = {p for c in definition.components for p in c.model_entities}
        for part in parts:
            component = next((c for c in definition.components if c.id == part.component_id), None)
            key = f"{part.entity_path}#{part.solid_index}"
            if component is None or part.entity_path not in component.model_entities or part.solid_index < 0 or key in seen:
                raise AssemblyError(["The CAD body identity does not match its fixture definition."])
            seen.add(key)
            m = part.mesh
            if not (m.exact and len(m.indices) and len(m.indices) % 3 == 0 and len(m.normals) == len(m.vertices)
                    and np.all(np.isfinite(m.vertices)) and np.all(np.isfinite(m.normals))
                    and int(m.indices.max()) < len(m.vertices)
                    and m.bounds_min.is_finite and m.bounds_max.is_finite):
                raise AssemblyError(["The fixture contains an invalid closed-solid mesh."])
        if {p.entity_path for p in parts} != wanted:
            raise AssemblyError(["The fixture's exact CAD occurrences are missing or changed."])
        for path in wanted:
            indices = sorted(p.solid_index for p in parts if p.entity_path == path)
            if indices != list(range(len(indices))):
                raise AssemblyError(["The fixture CAD occurrence has missing or inconsistent solid identities."])
        physical_ids = {c.id for c in definition.components if c.role is Role.PHYSICAL}
        components = []
        for c in definition.components:
            if c.role is not Role.PHYSICAL:
                continue
            indices = [i for i, p in enumerate(parts) if p.component_id == c.id]
            if not indices:
                continue
            mesh = merge([parts[i].mesh for i in indices], [np.identity(4)] * len(indices))
            components.append(GeometryComponent(c.id, c.name, c.role, indices, mesh, fixture_edge_snap.faces(mesh)))
        return LibraryFixtureGeometry([p.mesh for p in parts], components, LibraryFixtureGeometry.layout_id(definition),
                                      definition, {i for i, p in enumerate(parts) if p.component_id in physical_ids})

    @staticmethod
    def layout_id(definition) -> str:
        """Identifies the reviewed definition a saved placement was made with."""
        text = codable.dumps(codable.to_json(definition), sort_keys=True, escape_slashes=False)
        digest = hashlib.sha256(text.encode()).hexdigest()
        return f"vetted-assembly-v1|{definition.id}|{definition.revision}|{digest}"

    def validate(self, profile) -> None:
        definition = self.assembly_definition
        if definition is None:
            if not self.placements_match(profile):
                raise AssemblyError(["The assembly's saved piece layout changed."])
            return
        definition.validate(profile.assembly_state or FixtureAssemblyState())
        if not (all(math.isfinite(v) and abs(v) <= 1_000_000 for v in (profile.datum.x, profile.datum.y, profile.datum.z, profile.face_past_table))
                and 0 <= profile.spin < 4):
            raise AssemblyError(["The fixture pose must have finite, supported coordinates and orientation."])
        if profile.component_model_signature is not None and profile.component_model_signature.lower() != definition.model_sha256.lower():
            raise AssemblyError(["The saved fixture refers to a different CAD revision."])
        if profile.component_layout_id is not None and profile.component_layout_id != self.layout_id:
            raise AssemblyError(["The saved fixture assembly definition changed."])
        placements = profile.component_placements or []
        if len({p.id for p in placements}) != len(placements):
            raise AssemblyError(["Duplicate component positions in the fixture state."])
        for placement in placements:
            component = next((c for c in definition.components if c.id == placement.id), None)
            if (component is None or component.role is not Role.PHYSICAL or component.joint is not None
                    or not all(math.isfinite(v) and abs(v) <= 1_000_000 for v in (placement.offset.x, placement.offset.y, placement.offset.z))
                    or not 0 <= placement.spin < 4):
                raise AssemblyError(["Joint-controlled fixture components cannot also have free piece positions."])

    def placements_match(self, profile) -> bool:
        if self.assembly_definition is not None:
            try:
                self.validate(profile)
                return True
            except AssemblyError:
                return False
        pieces = profile.component_placements
        if not pieces:
            return True
        return profile.component_layout_id == self.layout_id and all(any(c.id == p.id for c in self.components) for p in pieces)

    def local_transform(self, component: GeometryComponent, profile) -> np.ndarray:
        if self.assembly_definition is not None:
            return self._assembly_transform(component.id, self.assembly_definition, profile)
        return self._free_transform(component.id, component.centre, profile)

    def _free_transform(self, component_id: str, centre, profile) -> np.ndarray:
        placement = next((p for p in profile.component_placements or [] if p.id == component_id), None)
        if placement is None:
            return np.identity(4)
        s = Setup()
        s.facing, s.spin = placement.facing, placement.spin
        r = s.part_rotation
        c = np.asarray(centre, float)
        return affine(r, c - r @ c + placement.offset.array)

    def _assembly_transform(self, component_id: str, definition, profile) -> np.ndarray:
        component = next((c for c in definition.components if c.id == component_id), None)
        if component is None:
            return np.identity(4)
        parent = (self._assembly_transform(component.parent_id, definition, profile) if component.parent_id is not None
                  else np.identity(4))
        geo = next((c for c in self.components if c.id == component_id), None)
        centre = geo.centre if geo is not None else np.zeros(3)
        free = self._free_transform(component_id, centre, profile)
        joint = component.joint
        if joint is None:
            return parent @ free
        state = profile.assembly_state or FixtureAssemblyState()
        delta = state.value(joint) - joint.reference_value
        axis, origin = joint.axis.array, joint.origin.array
        if joint.kind is JointKind.REVOLUTE:
            angle = delta
        elif joint.kind is JointKind.SCREW:
            angle = delta * 2 * math.pi / (joint.pitch if joint.pitch is not None else 1)
        else:
            angle = 0.0
        r = axis_angle(angle, axis)
        offset = origin - r @ origin + (np.zeros(3) if joint.kind is JointKind.REVOLUTE else axis * delta)
        return parent @ free @ affine(r, offset)

    def transform(self, component: GeometryComponent, profile) -> np.ndarray:
        return profile.model_to_work @ self.local_transform(component, profile)

    def solid_transform(self, index: int, profile) -> np.ndarray:
        component = next((c for c in self.components if index in c.solid_indices), None)
        return profile.model_to_work if component is None else self.transform(component, profile)

    def work_mesh(self, profile) -> MeshData:
        return merge([c.mesh for c in self.components], [self.transform(c, profile) for c in self.components])

    def bounds(self, profile, component_id: str | None = None) -> tuple[np.ndarray, np.ndarray]:
        lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
        for c in self.components:
            if component_id is not None and c.id != component_id:
                continue
            m, t = c.mesh, self.transform(c, profile)
            a, b = m.bounds_min.array, m.bounds_max.array
            corners = np.array([[b[0] if k & 1 else a[0], b[1] if k & 2 else a[1], b[2] if k & 4 else a[2], 1.0] for k in range(8)])
            q = (t @ corners.T).T[:, :3]
            lo, hi = np.minimum(lo, q.min(axis=0)), np.maximum(hi, q.max(axis=0))
        return lo, hi

    def _locked_joint(self, profile, component_id: str | None) -> bool:
        if component_id is None or self.assembly_definition is None:
            return False
        component = next((c for c in self.assembly_definition.components if c.id == component_id), None)
        if component is None:
            return False
        state = profile.assembly_state or FixtureAssemblyState()
        return component_id in state.locked_components or component.joint is not None

    def moved(self, profile, component_id: str | None, by) -> object:
        from ..geometry import Vec3
        from .workholding_profile import ComponentPlacement
        if self._locked_joint(profile, component_id):
            return profile
        delta = np.asarray(by, float)
        if component_id is None or not any(c.id == component_id for c in self.components):
            return profile.moved(Vec3.of(delta))
        if not np.all(np.isfinite(delta)):
            return profile
        p = copy.deepcopy(profile)
        piece = copy.deepcopy(next((q for q in profile.component_placements or [] if q.id == component_id), None)) or ComponentPlacement(component_id)
        local = profile.model_to_work[:3, :3].T @ delta
        piece.offset = Vec3(piece.offset.x + local[0], piece.offset.y + local[1], piece.offset.z + local[2])
        p.component_placements = [q for q in (p.component_placements or []) if q.id != component_id] + [piece]
        p.component_layout_id = self.layout_id
        p.grip_definition_reviewed = False
        return p

    def turned(self, profile, component_id: str | None, axis: int, quarter_turns: int) -> object:
        from ..geometry import Vec3
        from .workholding_profile import ComponentPlacement
        if self._locked_joint(profile, component_id):
            return profile
        if axis not in (0, 1, 2):
            return profile
        work_rotation = Setup().turned(axis, quarter_turns).part_rotation
        if component_id is None or not any(c.id == component_id for c in self.components):
            lo, hi = self.bounds(profile)
            c = (lo + hi) / 2
            if not math.isfinite(c[0]):
                return profile
            return profile.turned(axis, quarter_turns).moved(Vec3.of(c - work_rotation @ c))
        p = copy.deepcopy(profile)
        piece = copy.deepcopy(next((q for q in profile.component_placements or [] if q.id == component_id), None)) or ComponentPlacement(component_id)
        old = Setup()
        old.facing, old.spin = piece.facing, piece.spin
        base = profile.model_to_work[:3, :3]
        want = base.T @ work_rotation @ base @ old.part_rotation
        for face in FACINGS:
            for spin in range(4):
                test = Setup()
                test.facing, test.spin = face, spin
                if np.all(np.linalg.norm(test.part_rotation - want, axis=0) < 1e-7):
                    piece.facing, piece.spin = face, spin
                    p.component_placements = [q for q in (p.component_placements or []) if q.id != component_id] + [piece]
                    p.component_layout_id = self.layout_id
                    p.grip_definition_reviewed = False
                    return p
        return profile

    def aligned_pair(self, profile, stock) -> object:
        """A visible starting position only: aligns the two editing groups' bounding faces."""
        stock = np.asarray(stock, float)
        if len(self.components) != 2 or not all(math.isfinite(v) and v > 0 for v in stock):
            return profile
        ordered = sorted(self.components, key=lambda c: self.bounds(profile, c.id)[0][1])
        p = profile
        a = self.bounds(p, ordered[0].id)
        b = self.bounds(p, ordered[1].id)
        p = self.moved(p, ordered[0].id, np.array([0.0, -stock[1] / 2 - a[1][1], 0.0]))
        p = self.moved(p, ordered[1].id, np.array([0.0, stock[1] / 2 - b[0][1], 0.0]))
        return p
