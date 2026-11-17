"""Placing a library fixture around the stock in the 3D view: pieces picked and moved with the
gumball, snapped to the stock's faces, bookends and mechanisms fitted by their solvers, grip
patches marked on the stock. Port of Model/FixtureWorkspacePlacement.swift."""

from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field

import numpy as np
from PySide6.QtGui import QGuiApplication
from PySide6.QtCore import Qt

from ...core import codable
from ...core.geometry import Vec3
from ...core.plan import fixture_edge_snap as FixtureEdgeSnap
from ...core.plan.fixture_mechanism import BookendSetup, FixtureMechanism, PlacementError
from ...core.plan.setup import Workholding
from ...core.plan.workholding_profile import Contact, ContactNormal, FixturePlanningProfile
from ...core.ids import new_id
from ...viewport.scene import SEGMENT_DTYPE, SceneColor, SceneLines, SceneMesh, box_mesh
from ..tasks import Cancelled, spawn
from .geometry import translation

PLACEMENT_MESH_PREFIX = "fixture.placement."


@dataclass
class FixturePlacementSession:
    fixture: object
    return_page: str
    return_stage: str
    camera: object
    selected_component: str | None = None
    picking_grip: bool = False
    error: str | None = None
    loading: bool = False
    snap_enabled: bool = True
    snap_locks: list = field(default_factory=list)
    id: str = field(default_factory=new_id)


def _option_held() -> bool:
    return bool(QGuiApplication.keyboardModifiers() & Qt.KeyboardModifier.AltModifier)


class FixturePlacementMixin:
    @property
    def placement_stock_size(self):
        return self.setup.raw_stock_size(self.stock) if self.stock is not None else None

    @property
    def placement_drag_scale(self) -> float:
        return 100.0 if _option_held() else 2.0

    def begin_fixture_placement(self, fixture):
        """A task: opens placement for a fixture around the stock."""
        if self.part is None or self.stock is None:
            self.errorMessage = "Load a part and choose stock, then place the fixture around it."
            return
        if self.is_generating or self.isPlanningJob or self.isFindingPlans:
            self.errorMessage = "Finish or cancel the current generation before placing a fixture."
            return
        if self.is_switching_planning_machine:
            self.errorMessage = "Wait for the selected machine to finish loading before placing a fixture."
            return
        self.pause()
        self.measuring = False
        self.inspecting = False
        self.gumball_prompt = None
        source = next((f for f in (self.setup.fixture_assemblies or []) if f.id == fixture.id), fixture)
        try:
            draft = copy.deepcopy(self.prepared_fixture(source))
        except Exception as e:  # noqa: BLE001
            self.errorMessage = str(e)
            return
        p = draft.planning if draft.planning is not None else FixturePlanningProfile()
        size = self.placement_stock_size
        if size is not None:
            nxt = Vec3(float(size[0]), float(size[1]), float(size[2]))
            if p.stock_size != nxt:
                if p.assembly_state is not None:
                    p.assembly_state.mounted = False
                p.grip_definition_reviewed = False
            p.stock_size = nxt
        p.enabled = True
        draft.planning = p
        cam = self.renderer.camera
        session = FixturePlacementSession(draft, self.page_hint(), self.stage, cam.copy() if cam is not None else None)
        self.scene.remove_prefix(PLACEMENT_MESH_PREFIX)
        self.fixture_placement_geometry = None
        self.fixture_placement = session
        self.navigate("workspace")
        self.show_side_number(0)
        if self.machine_model is None:
            yield from self.load_machine()
        yield from self.reload_placement_geometry(True)
        if self.fixture_placement is None or self.fixture_placement.id != session.id:
            return
        self.focus_placement_context()
        a = draft.assembly
        if a is not None and a.bookends is not None:
            self.status = "Slide a bookend along its T-slots, or select the side screw to release and advance it."
        elif FixtureMechanism.has(a):
            self.status = f"{draft.name} is fitted to the stock. Drag a clamp or screw to adjust it."
        else:
            self.status = f"Place {draft.name} around the stock. Pick a piece; drag arrows to move and rings to rotate."

    def reload_placement_geometry(self, centre_unconfigured: bool = False):
        """A task step: the fixture's model, fitted (bookends, mechanisms) or centred on the stock."""
        session = self.fixture_placement
        if session is None:
            return
        ref = self.planning_machine_reference
        self.fixture_placement_geometry = None
        self.scene.remove_prefix(PLACEMENT_MESH_PREFIX)
        self.scene.remove("placement.snap")
        session.snap_locks = []
        session.error = None
        session.loading = session.fixture.model_path is not None
        if session.fixture.model_path is None:
            self.layout_scene()
            return
        try:
            geometry, signature = yield from self.load_fixture_geometry(session.fixture)
            cur = self.fixture_placement
            if (cur is None or cur.id != session.id or self.planning_machine_reference != ref or self.is_switching_planning_machine
                    or cur.fixture.model_path != session.fixture.model_path):
                return
            draft = cur
            if draft.selected_component is not None and not any(c.id == draft.selected_component for c in geometry.components):
                draft.selected_component = None
            p = draft.fixture.planning if draft.fixture.planning is not None else FixturePlanningProfile()
            if (p.component_model_signature is not None and p.component_model_signature != signature) or not geometry.placements_match(p):
                p.component_placements = None
                p.grip_definition_reviewed = False
                p.workspace_placed = False
            p.component_model_signature = signature
            p.component_layout_id = geometry.layout_id
            a = draft.fixture.assembly
            if a is not None and a.bookends is not None:
                solver = self.bookend_solver(draft.fixture)
                needs = not (p.assembly_state is not None and p.assembly_state.mounted) or p.workspace_placed is not True
                if not needs:
                    try:
                        solver.validate(p)
                    except Exception:  # noqa: BLE001
                        needs = True
                if needs:
                    p = solver.seat(p)
                    p.assembly_state.locked_components = {BookendSetup.FIXED, BookendSetup.CLAMP}
                draft.fixture.height = 0.0
                if draft.selected_component is None:
                    draft.selected_component = BookendSetup.PRESSURE
            else:
                mechanism = self.mechanism_for(draft.fixture)
                if mechanism is not None:
                    needs = not (p.assembly_state is not None and p.assembly_state.mounted) or p.workspace_placed is not True
                    if not needs:
                        try:
                            mechanism.validate(p)
                        except Exception:  # noqa: BLE001
                            needs = True
                    if needs:
                        p = mechanism.seat(p)
                    draft.fixture.height = mechanism.height
                    if draft.selected_component is None and mechanism.controls:
                        draft.selected_component = mechanism.controls[0].component_id
                elif centre_unconfigured and not p.grip_definition_reviewed and p.workspace_placed is not True and self.placement_stock_size is not None:
                    size = self.placement_stock_size
                    lo, hi = geometry.bounds(p)
                    delta = np.array([0, 0, -size[2] / 2]) - (np.asarray(lo) + np.asarray(hi)) / 2
                    p = p.moved(Vec3(*map(float, delta)))
            p.workspace_placed = True
            draft.fixture.planning = p
            draft.error = None
            draft.loading = False
            self.fixture_placement_geometry = geometry
            self.fixture_placement = draft
        except Cancelled:
            raise
        except Exception as e:  # noqa: BLE001
            cur = self.fixture_placement
            if cur is None or cur.id != session.id or self.planning_machine_reference != ref:
                return
            cur.loading = False
            cur.error = str(e)
            self.touch()

    def update_placement_fixture(self, fixture) -> None:
        session = self.fixture_placement
        if session is None:
            return
        changed = fixture.model_path != session.fixture.model_path
        session.fixture = fixture
        if changed and session.fixture.planning is not None:
            session.fixture.planning.workspace_placed = False
        self.fixture_placement = session
        if changed:
            def run():
                yield from self.reload_placement_geometry(True)
                self.focus_placement_context()
            spawn(run(), "reload placement")

    def set_placement_profile(self, profile) -> None:
        session = self.fixture_placement
        if session is None or session.fixture.planning == profile:
            return
        nxt = profile
        if self.placing_bookends and session.fixture.planning is not None:
            prev = copy.deepcopy(session.fixture.planning)
            prev.grip_definition_reviewed = False
            comparison = copy.deepcopy(nxt)
            comparison.grip_definition_reviewed = False
            if prev != comparison:
                nxt.grip_definition_reviewed = False
        session.fixture.planning = nxt
        session.snap_locks = []
        self.fixture_placement = session

    def select_placement_component(self, id) -> None:
        session = self.fixture_placement
        if session is None:
            return
        session.selected_component = id
        session.snap_locks = []
        self.fixture_placement = session

    def set_placement_snapping(self, enabled: bool) -> None:
        session = self.fixture_placement
        if session is None:
            return
        session.snap_enabled = enabled
        session.snap_locks = []
        self.fixture_placement = session

    def move_placement(self, delta, start=None, component_id=None, use_selection: bool = True, snap: bool = False,
                       snap_axes=(0, 1, 2)) -> None:
        geometry, session = self.fixture_placement_geometry, self.fixture_placement
        if geometry is None or session is None:
            return
        profile = start if start is not None else session.fixture.planning
        delta = np.asarray(delta, float)
        if profile is None or not all(math.isfinite(v) and abs(v) < 100_000 for v in delta):
            return
        id = session.selected_component if use_selection else component_id
        a = session.fixture.assembly
        if a is not None and a.bookends is not None:
            if id is None:
                return
            try:
                solver = self.bookend_solver(session.fixture)
                if id == BookendSetup.PRESSURE:
                    nxt = solver.setting_pressure(profile, solver.value(profile, BookendSetup.PRESSURE_EXTENSION) - delta[1])
                else:
                    joint = BookendSetup.FIXED_SLIDE if id == BookendSetup.FIXED else BookendSetup.CLAMP_SLIDE
                    nxt = solver.sliding(profile, id, solver.value(profile, joint) + delta[1])
                self.set_placement_profile(nxt)
                self.fixture_placement.error = None
            except Exception as e:  # noqa: BLE001
                self.fixture_placement.error = str(e)
                self.touch()
            return
        if FixtureMechanism.has(a):
            if id is None:
                return
            try:
                mechanism = self.mechanism_for(session.fixture)
                control = next((c for c in mechanism.controls if c.component_id == id), None) if mechanism is not None else None
                comp = next((c for c in a.components if c.id == id), None)
                joint = comp.joint if comp is not None else None
                if control is None or joint is None:
                    return
                along = delta[0] * joint.axis.x + delta[1] * joint.axis.y + delta[2] * joint.axis.z
                self.set_placement_profile(mechanism.setting(profile, control.id, mechanism.value(profile, control.id) + along))
                self.fixture_placement.error = None
            except Exception as e:  # noqa: BLE001
                self.fixture_placement.error = str(e)
                self.touch()
            return
        moved = geometry.moved(profile, id, Vec3(*map(float, delta)))
        size = self.placement_stock_size
        if snap and session.snap_enabled and not _option_held() and size is not None:
            result = FixtureEdgeSnap.snap(moved, geometry, id, size, self._placement_snap_tolerance(), set(snap_axes), session.snap_locks)
            session.fixture.planning = result.profile
            session.snap_locks = result.constraints
        else:
            session.fixture.planning = moved
            session.snap_locks = []
        self.fixture_placement = session

    def _placement_snap_tolerance(self) -> np.ndarray:
        size = self.placement_stock_size
        if size is None:
            return np.zeros(3)
        group = self.scene.group_transform("x")
        origin = (group @ np.array([*self.work_to_model(size), 1.0]))[:3]
        start = self._project(origin)
        if start is None:
            return np.zeros(3)
        tol = np.zeros(3)
        for axis in range(3):
            unit = np.zeros(4)
            unit[axis] = 1
            v = (group @ unit)[:3]
            end = self._project(origin + v)
            if end is None:
                continue
            pixels = math.hypot(end[0] - start[0], end[1] - start[1])
            if pixels > 0.05:
                tol[axis] = min(8 / pixels, 20)
        return tol

    def snap_placement_to_stock(self) -> None:
        if self.placing_bookends or self.placing_mechanism:
            self.seat_placement_bookends()
            return
        session, geometry, size = self.fixture_placement, self.fixture_placement_geometry, self.placement_stock_size
        if session is None or session.fixture.planning is None or geometry is None or size is None:
            return
        result = FixtureEdgeSnap.snap(session.fixture.planning, geometry, session.selected_component, size, np.full(3, 3.0))
        session.fixture.planning = result.profile
        session.snap_locks = result.constraints
        self.fixture_placement = session
        self.status = ("Move the selected piece closer to a stock edge, then snap again." if not result.constraints
                       else "Snapped to " + ", ".join(c.label for c in result.constraints))

    def focus_placement_context(self) -> None:
        self.focus_work(machine_context=True)

    def rotate_placement(self, axis: int, turns: int, start=None, component_id=None, use_selection: bool = True) -> None:
        if self.placing_bookends or self.placing_mechanism:
            return
        geometry, session = self.fixture_placement_geometry, self.fixture_placement
        if geometry is None or session is None:
            return
        profile = start if start is not None else session.fixture.planning
        if profile is None:
            return
        id = session.selected_component if use_selection else component_id
        self.set_placement_profile(geometry.turned(profile, id, axis, int(math.fmod(turns, 4))))

    def centre_placement_on_stock(self) -> None:
        if self.placing_bookends or self.placing_mechanism:
            self.seat_placement_bookends()
            return
        geometry, s, size = self.fixture_placement_geometry, self.fixture_placement, self.placement_stock_size
        if geometry is None or s is None or s.fixture.planning is None or size is None:
            return
        p = s.fixture.planning
        lo, hi = geometry.bounds(p)
        delta = np.array([0, 0, -size[2] / 2]) - (np.asarray(lo) + np.asarray(hi)) / 2
        self.set_placement_profile(p.moved(Vec3(*map(float, delta))))
        self.focus_placement_context()

    def align_placement_pair(self) -> None:
        if self.placing_bookends or self.placing_mechanism:
            self.seat_placement_bookends()
            return
        geometry, s, size = self.fixture_placement_geometry, self.fixture_placement, self.placement_stock_size
        if geometry is None or s is None or s.fixture.planning is None or size is None:
            return
        self.set_placement_profile(geometry.aligned_pair(s.fixture.planning, size))
        self.focus_placement_context()
        self.status = "Pair aligned by its bounding faces. Adjust the actual gripping faces and hardware, then mark the stock's grip patches."

    def finish_fixture_placement(self, save: bool, library) -> None:
        session = self.fixture_placement
        if session is None:
            return
        if save:
            geometry, p = self.fixture_placement_geometry, session.fixture.planning
            if geometry is None or p is None or not geometry.placements_match(p):
                session.error = "Load the assembly model before saving its placement."
                self.touch()
                return
            try:
                sig = self.fixture_model_signature(self.fixture_model_path(session.fixture.model_path)) if session.fixture.model_path else None
            except Exception:  # noqa: BLE001
                sig = None
            if sig is None or sig != p.component_model_signature:
                session.error = "The CAD model changed while placing it. Reload the model before saving."
                self.touch()
                return
            owned = next((f for f in library.inventory.fixtures if f.id == session.fixture.id), None)
            if owned is None or owned.quantity <= 0:
                session.error = "This fixture was removed from the library."
                self.touch()
                return
            issues = list(p.definition_issues) + (list(session.fixture.assembly.planning_issues) if session.fixture.assembly is not None else [])
            if issues:
                session.error = " ".join(issues)
                self.touch()
                return
            a = session.fixture.assembly
            try:
                if a is not None and a.bookends is not None:
                    solver = self.bookend_solver(session.fixture)
                    solver.validate(p)
                    geometry.validate(p)
                    issues = solver.planning_issues(p)
                elif FixtureMechanism.has(a):
                    mechanism = self.mechanism_for(session.fixture)
                    if mechanism is None:
                        return
                    mechanism.validate(p)
                    geometry.validate(p)
                    issues = mechanism.planning_issues(p)
            except Exception as e:  # noqa: BLE001
                session.error = str(e)
                self.touch()
                return
            if issues:
                session.error = " ".join(issues)
                self.touch()
                return
            used = copy.deepcopy(session.fixture)
            used.quantity = owned.quantity
            saved = self.setup.selecting_holding(Workholding.CUSTOM)
            saved.plan_from_fixture_library = True
            saved.fixture_assemblies = [f for f in (saved.fixture_assemblies or []) if f.id != used.id] + [used]
            selected = list(saved.selected_fixture_ids or [])
            if used.id not in selected:
                selected.append(used.id)
            saved.selected_fixture_ids = selected
            self.setup = saved
            self.clear_toolpath_results()
            self.library_fixture_meshes[self.fixture_state_key(used)] = geometry.work_mesh(p)
        self.fixture_placement = None
        self.fixture_placement_geometry = None
        self.scene.remove_prefix("placement.grip.")
        self.scene.remove("placement.snap")
        self.gumball_drag = None
        self.gumball_prompt = None
        if save:
            self.enter("setups")
            self.navigate("workspace")
        else:
            self.enter(session.return_stage)
            self.navigate(session.return_page)
            if session.camera is not None:
                self.renderer.move_camera(lambda c: c.__dict__.update(session.camera.__dict__), animated=False)
        self.status = (f"{session.fixture.name} is selected for this job. Continue to Plan to check the part and build the cuts."
                       if save else "Workholding selection cancelled.")

    @property
    def placing_bookends(self) -> bool:
        s = self.fixture_placement
        return s is not None and s.fixture.assembly is not None and s.fixture.assembly.bookends is not None

    @property
    def placing_mechanism(self) -> bool:
        s = self.fixture_placement
        return not self.placing_bookends and s is not None and FixtureMechanism.has(s.fixture.assembly)

    @property
    def placement_mechanism(self):
        s = self.fixture_placement
        if s is None:
            return None
        try:
            return self.mechanism_for(s.fixture)
        except Exception:  # noqa: BLE001
            return None

    def mechanism_axis(self, id) -> int | None:
        """The axis a mechanism piece moves along (0 X, 1 Y, 2 Z), None when it doesn't move."""
        m = self.placement_mechanism
        if id is None or m is None or not any(c.component_id == id for c in m.controls):
            return None
        comp = next((c for c in self.fixture_placement.fixture.assembly.components if c.id == id), None)
        if comp is None or comp.joint is None:
            return None
        a = comp.joint.axis
        v = [abs(a.x), abs(a.y), abs(a.z)]
        return v.index(max(v))

    def set_placement_joint(self, joint: str, value: float) -> None:
        s = self.fixture_placement
        if s is None or s.fixture.planning is None:
            return
        try:
            m = self.mechanism_for(s.fixture)
            if m is None:
                return
            self.set_placement_profile(m.setting(s.fixture.planning, joint, value))
            self.fixture_placement.error = None
        except Exception as e:  # noqa: BLE001
            s.error = str(e)
            self.touch()

    def bookend_solver(self, fixture) -> BookendSetup:
        if fixture.assembly is None:
            raise PlacementError("Reload the Bookends model to restore its mounting definition.")
        stock = self.placement_stock_size
        if stock is None:
            raise PlacementError("Choose the stock block for this job first.")
        if self.is_switching_planning_machine:
            raise PlacementError(f"Loading {self.planning_machine_title}…")
        table = self.bookend_mount_table
        if table is None:
            msg = ("This job still uses an older machine definition without table mounting data. Apply your machine profile below."
                   if self.planning_machine_reference.is_legacy else f"{self.planning_machine_title} does not provide compatible table slots for these Bookends.")
            raise PlacementError(msg)
        return BookendSetup(fixture.assembly, table, stock)

    @property
    def placement_bookend_solver(self):
        s = self.fixture_placement
        if s is None:
            return None
        try:
            return self.bookend_solver(s.fixture)
        except Exception:  # noqa: BLE001
            return None

    def can_move_bookend_component(self, id) -> bool:
        s = self.fixture_placement
        st = s.fixture.planning.assembly_state if s is not None and s.fixture.planning is not None else None
        if id is None or st is None or not st.mounted:
            return False
        if id == BookendSetup.PRESSURE:
            return True
        return id in (BookendSetup.FIXED, BookendSetup.CLAMP) and id not in st.locked_components

    def seat_placement_bookends(self) -> None:
        s = self.fixture_placement
        if s is None or s.fixture.planning is None:
            return
        try:
            m = self.mechanism_for(s.fixture)
            if m is None:
                return
            s.fixture.planning = m.seat(s.fixture.planning)
            s.fixture.height = m.height
            s.error = None
            s.snap_locks = []
            self.fixture_placement = s
            self.status = f"{s.fixture.name} fitted to the stock. Review the grip before using this setup."
        except Exception as e:  # noqa: BLE001
            s.error = str(e)
            self.touch()

    def set_bookend_base_locked(self, id: str, locked: bool) -> None:
        s = self.fixture_placement
        p = copy.deepcopy(s.fixture.planning) if s is not None and s.fixture.planning is not None else None
        if id not in (BookendSetup.FIXED, BookendSetup.CLAMP) or p is None or p.assembly_state is None or not p.assembly_state.mounted:
            return
        if locked:
            p.assembly_state.locked_components.add(id)
        else:
            p.assembly_state.locked_components.discard(id)
            p.grip_definition_reviewed = False
        self.set_placement_profile(p)

    def set_bookend_pressure(self, value: float) -> None:
        s = self.fixture_placement
        if s is None or s.fixture.planning is None:
            return
        try:
            self.set_placement_profile(self.bookend_solver(s.fixture).setting_pressure(s.fixture.planning, value))
            self.fixture_placement.error = None
        except Exception as e:  # noqa: BLE001
            s.error = str(e)
            self.touch()

    def placement_gumball_origin(self, id):
        g, s, size = self.fixture_placement_geometry, self.fixture_placement, self.placement_stock_size
        if g is None or s is None or s.fixture.planning is None or size is None:
            return None
        lo, hi = g.bounds(s.fixture.planning, id)
        centre = (np.asarray(lo, float) + np.asarray(hi, float)) / 2
        if not math.isfinite(centre[0]):
            return None
        w = self.scene.group_transform("x") @ np.array([*(centre + np.asarray(self.work_to_model(size), float)), 1.0])
        return w[:3]

    def pick_placement_component(self, x: float, y: float):
        ray = self.renderer.ray(x, y)
        if ray is None:
            return None
        hit = self.scene.pick(ray[0], ray[1])
        if hit is None or not hit[0].startswith(PLACEMENT_MESH_PREFIX):
            return None
        id = hit[0][len(PLACEMENT_MESH_PREFIX):]
        g = self.fixture_placement_geometry
        if g is None or not any(c.id == id for c in g.components):
            return None
        return id, hit[1]

    def handle_placement_click(self, x: float, y: float) -> None:
        s = self.fixture_placement
        if s is None:
            return
        if s.picking_grip:
            self._pick_placement_grip(x, y)
            return
        hit = self.pick_placement_component(x, y)
        if hit is not None:
            self.select_placement_component(hit[0])

    def _pick_placement_grip(self, x: float, y: float) -> None:
        size, s = self.placement_stock_size, self.fixture_placement
        if size is None or s is None or s.fixture.planning is None:
            return
        p = copy.deepcopy(s.fixture.planning)
        ray = self.renderer.ray(x, y)
        if ray is None:
            return
        inv = np.linalg.inv(self.scene.group_transform("x"))
        ro = (inv @ np.array([*ray[0], 1.0]))[:3] - np.asarray(self.work_to_model(size), float)
        rd = (inv @ np.array([*ray[1], 0.0]))[:3]
        lo = np.array([-size[0] / 2, -size[1] / 2, -size[2]])
        hi = np.array([size[0] / 2, size[1] / 2, 0])
        near, far, face = -math.inf, math.inf, 2
        for axis in range(3):
            if abs(rd[axis]) < 1e-9:
                if ro[axis] < lo[axis] or ro[axis] > hi[axis]:
                    return
                continue
            a, b = (lo[axis] - ro[axis]) / rd[axis], (hi[axis] - ro[axis]) / rd[axis]
            enter, leave = min(a, b), max(a, b)
            if enter > near:
                near, face = enter, axis
            far = min(far, leave)
        if not (near >= 0 and near <= far):
            self.status = "Click a face of the stock to mark a grip patch."
            return
        q = ro + rd * near
        patch = Contact(point=Vec3(*map(float, q)), radius=1.0)
        patch.normal = [ContactNormal.X, ContactNormal.Y, ContactNormal.Z][face]
        p.contacts.append(patch)
        p.grip_definition_reviewed = False
        s.picking_grip = False
        self.set_placement_profile(p)
        self.status = "Grip patch added. Check its radius and location in the inspector."

    def layout_fixture_placement(self, stock_size) -> None:
        """Uses the same per-piece transforms that the library planning sends to CAM checks."""
        scene = self.scene
        for m in scene.meshes.values():
            if m.id.startswith("fixture."):
                m.visible = False
        scene.remove_prefix("placement.grip.")
        scene.remove("placement.snap")
        s, g = self.fixture_placement, self.fixture_placement_geometry
        if s is None or g is None or s.fixture.planning is None:
            return
        p = s.fixture.planning
        origin = translation(self.work_to_model(stock_size))
        for c in g.components:
            id = PLACEMENT_MESH_PREFIX + c.id
            if scene.mesh(id) is None:
                scene.add(SceneMesh(id, c.mesh.vertices, c.mesh.normals, c.mesh.indices, SceneColor.part, pickable=True))
            m = scene.mesh(id)
            m.group = "x"
            m.transform = origin @ np.asarray(g.transform(c, p), float)
            m.color = (0.2, 0.5, 0.95, 1.0) if c.id == s.selected_component else (0.65, 0.68, 0.72, 1.0)
            m.visible = True
        o = np.asarray(self.work_to_model(stock_size), float)
        for contact in p.contacts:
            centre = np.array([contact.point.x, contact.point.y, contact.point.z]) + o
            r = min(max(contact.radius, 0.3), 3)
            marker = box_mesh(f"placement.grip.{contact.id}", centre - r, centre + r, (0.1, 0.5, 1.0, 1.0))
            marker.group = "x"
            marker.on_top = True
            scene.add(marker)
        self._layout_placement_snap_guides(stock_size)

    def _layout_placement_snap_guides(self, s) -> None:
        self.scene.remove("placement.snap")
        locks = self.fixture_placement.snap_locks if self.fixture_placement is not None else []
        if not locks:
            return
        lo, hi = np.array([-s[0] / 2, -s[1] / 2, -s[2]]), np.array([s[0] / 2, s[1] / 2, 0])
        origin = np.asarray(self.work_to_model(s), float)
        pairs = []
        for lock in locks:
            axes = [a for a in range(3) if a != lock.axis]
            corners = []
            for a, b in ((False, False), (True, False), (True, True), (False, True)):
                q = lo.copy()
                q[lock.axis] = hi[lock.axis] if lock.upper else lo[lock.axis]
                q[axes[0]] = hi[axes[0]] if a else lo[axes[0]]
                q[axes[1]] = hi[axes[1]] if b else lo[axes[1]]
                corners.append(q + origin)
            for i in range(4):
                pairs.append((corners[i], corners[(i + 1) % 4]))
        seg = np.empty(len(pairs), SEGMENT_DTYPE)
        seg["a"] = [a for a, _ in pairs]
        seg["b"] = [b for _, b in pairs]
        seg["color_a"] = seg["color_b"] = (80, 170, 255, 255)
        lines = SceneLines("placement.snap", seg)
        lines.group = "x"
        lines.xray = 0.7
        self.scene.add(lines)
