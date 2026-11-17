"""Workholding from the fixture library in the workspace: the fixture shown, preparing each fixture
for the planner (its CAD placed, clearance field, occupied stock), saved plans' geometry, export
checks and the setup list. Port of Model/LibraryWorkholding.swift."""

from __future__ import annotations

import copy
import hashlib
from pathlib import Path

import numpy as np

from ... import paths
from ...core.engine.client import EngineError
from ...core.inventory.inventory import Inventory
from ...core.plan.fixture_mechanism import FixtureMechanism
from ...core.plan.library_workholding import Candidate, eligibility
from ...core.plan.setup import Workholding
from ...core.safety.collision import Body, Collision
from ...core.safety.fixture_clearance import FixtureField, box_triangles
from ...core.sim.dexel import DexelGrid
from ..tasks import Cancelled, Work, spawn


class LibraryWorkholdingMixin:
    @property
    def current_library_step(self):
        plan = self.library_workholding_plan
        if not self.setup.plan_from_fixture_library or plan is None:
            return None
        # A turned side the plan has no step for shows no step (and so no fixture).
        step = next((s for s in plan.steps if s.id == self.selected_library_step), None)
        if step is None:
            step = next((s for s in plan.steps if s.side == max(self.viewSide, 0)), None)
        if step is None and self.viewSide < 2 and plan.steps:
            step = plan.steps[0]
        return step

    @property
    def displayed_job_fixture(self):
        """The chosen assembly shown while designing a job (not an eligibility or approval)."""
        step = self.current_library_step
        if step is not None:
            return step.fixture
        stock = self.stock
        if not self.setup.plan_from_fixture_library or stock is None:
            return None
        size = self.display_stock_size
        if size is None:
            size = np.asarray(self.setup.stock_size(stock), float)
        snapshots = self.setup.fixture_assemblies or []
        if self.automatic_workholding:
            candidates = self.automatic_fixtures(self.inventory, size)[0]
        elif self.setup.selected_fixture_ids is not None:
            candidates = [f for id in self.setup.selected_fixture_ids for f in snapshots if f.id == id][:]
        else:
            candidates = snapshots
        for f in candidates:
            p = f.planning
            if p is not None and np.linalg.norm(np.array([p.stock_size.x, p.stock_size.y, p.stock_size.z]) - size) <= 0.1:
                return f
        return None

    def enable_library_planning(self) -> None:
        s = self.setup.selecting_holding(Workholding.CUSTOM)
        s.plan_from_fixture_library = True
        self.setup = s
        self.two_sided_chosen = False
        if self.analysis is not None:
            self.choose_sides(self.analysis)
        self.status = "Automatic setups from your fixture library. Find a CAM plan, then Generate to compare the actual cuts with your fixtures."

    @staticmethod
    def fixture_model_path(path: str) -> Path:
        p = Path(path)
        return p if p.is_absolute() else paths.REPO_ROOT / "resources" / path

    def library_origin(self, fixture, s) -> np.ndarray:
        t = self.table_geometry
        past = fixture.planning.face_past_table if fixture.planning is not None else 0.0
        return np.array([t.top_x + fixture.height + s[0] / 2, self.travel_centre_y, t.north_z + past])

    def library_machine_origin(self, fixture, stock) -> np.ndarray | None:
        """Machine coordinates of stock zero with zero stick-out (the planner adds each tool's)."""
        mm = self.machine_model
        if mm is None:
            return None
        o, tip = self.library_origin(fixture, stock), self.tip_at_model_pose(0)
        return np.array([mm.model_pose.x - tip[0] + o[0], mm.model_pose.y + o[1] - tip[1], mm.model_pose.z + o[2] - tip[2]])

    def prepare_library_fixtures(self, inventory, base, turned=(), use_job_snapshots: bool = True):
        """A task: each eligible fixture placed for the planner (clearance field, occupied stock)."""
        machine_reference = self.planning_machine_reference
        input_signature = self.generation_signature

        def check_current() -> None:
            if (self.planning_machine_reference != machine_reference or self.generation_signature != input_signature
                    or self.is_switching_planning_machine):
                raise Cancelled()

        base = np.asarray(base, float)
        self.library_fixture_fields = {}
        candidates, rejected = [], []
        if self.machine_model is None:
            yield from self.load_machine()
        machine_tree = yield from self.machine_collision_tree()
        if machine_tree is None:
            raise EngineError("Machine", "Load the machine geometry before planning library fixtures.")
        check_current()
        fixtures = self.job_fixture_inventory(inventory).fixtures if use_job_snapshots else inventory.fixtures
        pairs = [(f, base) for f in fixtures]
        if use_job_snapshots and self.automatic_workholding:
            sizes = []
            for t in turned:
                t = np.asarray(t, float)
                if np.linalg.norm(t - base) > 0.1 and not any(np.linalg.norm(x - t) < 0.1 for x in sizes):
                    sizes.append(t)
            for t in sizes:
                pairs += [(f, t) for f in self.automatic_fixtures(inventory, t)[0]]
        elif not use_job_snapshots:
            # Saved plans: each fixture snapshot holds the stock size it was fitted to.
            pairs = [(f, np.array([f.planning.stock_size.x, f.planning.stock_size.y, f.planning.stock_size.z]) if f.planning else base)
                     for f in fixtures]
        for fixture, s in pairs:
            if fixture.quantity <= 0:
                continue
            issues = eligibility(fixture, s)
            profile = fixture.planning
            if issues or profile is None or fixture.model_path is None:
                rejected.append(f"{fixture.name}: {' '.join(issues)}")
                continue
            try:
                geometry, signature = yield from self.load_fixture_geometry(fixture)
                check_current()
                geometry.validate(profile)
                if FixtureMechanism.has(fixture.assembly):
                    table = self.bookend_mount_table
                    mechanism = FixtureMechanism.make(fixture, table, s) if table is not None else None
                    if table is None or mechanism is None or abs(fixture.height - mechanism.height) >= 0.001:
                        raise EngineError("Fixture", f"{fixture.name} needs the machine's measured table, with the stock seated as fitted.")
                    problems = mechanism.planning_issues(profile)
                    if problems:
                        raise EngineError("Fixture", " ".join(problems))
                saved = profile.workspace_placed is True or bool(profile.component_placements)
                if not geometry.placements_match(profile) or (saved and profile.component_model_signature != signature):
                    raise EngineError("Fixture", "The CAD assembly changed. Place its pieces in the workspace again before planning.")
                self.library_fixture_geometries[fixture.id] = geometry
                self.library_fixture_geometry_signatures[fixture.id] = signature
                placed = geometry.work_mesh(profile)
                state_key = self.fixture_state_key(fixture)
                self.library_fixture_meshes[state_key] = placed
                origin, table, centre = self.library_origin(fixture, s), self.table_geometry, self.travel_centre_y
                machine_origin = self.library_machine_origin(fixture, s)
                if machine_origin is None:
                    raise EngineError("Machine", "The machine placement isn't available.")
                env = self.machine.machine_envelope
                region_min = (env.x.lower - machine_origin[0] - 24, env.y.lower - machine_origin[1] - 24)
                region_max = (env.x.upper - machine_origin[0] + 24, env.y.upper - machine_origin[1] + 24)
                built = yield Work(lambda: _build_candidate(fixture, placed, geometry, profile, s, origin, table, centre,
                                                            machine_tree, region_min, region_max), lane="geometry")
                check_current()
                field, fixture_triangles, collisions, occupied = built
                if collisions:
                    raise EngineError("Placement", "The fixture placement intersects the machine: " + ", ".join(f"{c.a} × {c.b}" for c in collisions))
                self.library_fixture_triangles[state_key] = fixture_triangles
                self.library_fixture_fields[state_key] = field
                candidates.append(Candidate(fixture, field, occupied, machine_origin, signature))
            except Cancelled:
                raise
            except Exception as e:  # noqa: BLE001
                rejected.append(f"{fixture.name}: couldn't load its CAD model ({e}).")
        if not candidates:
            raise EngineError("Workholding", "No eligible fixture for this stock. Open Fixtures and define an assembled stock size, datum, and reviewed grip patches.\n" + "\n".join(rejected))
        return candidates

    def reload_saved_library_geometry(self):
        """A task."""
        stock = self.stock
        if not self.setup.plan_from_fixture_library or stock is None:
            return
        plan = self.library_workholding_plan
        if plan is None:
            yield from self.reload_selected_fixture_preview()
            return
        signature, machine_reference = self.generation_signature, self.planning_machine_reference
        inv = Inventory()
        for step in plan.steps:
            if step.fixture not in inv.fixtures:
                inv.fixtures.append(step.fixture)
        try:
            yield from self.prepare_library_fixtures(inv, self.setup.stock_size(stock), use_job_snapshots=False)
            if self.generation_signature == signature and self.planning_machine_reference == machine_reference:
                self.layout_scene()
        except Cancelled:
            return
        except Exception as e:  # noqa: BLE001
            if self.generation_signature == signature and self.planning_machine_reference == machine_reference:
                self.errorMessage = f"Saved workholding geometry couldn't be rechecked: {e}"

    def reload_selected_fixture_preview(self):
        """A task: only the saved assembly mesh; full cut/fixture checks still run during CAM."""
        fixture = self.displayed_job_fixture
        if fixture is None or fixture.planning is None:
            return
        profile = fixture.planning
        key, signature, machine_reference = self.fixture_state_key(fixture), self.generation_signature, self.planning_machine_reference

        def is_current() -> bool:
            shown = self.displayed_job_fixture
            return (self.planning_machine_reference == machine_reference and self.generation_signature == signature
                    and not self.is_switching_planning_machine and self.fixture_placement is None
                    and (self.library_workholding_plan is None or self.current_library_step is None)
                    and shown is not None and self.fixture_state_key(shown) == key)

        try:
            if self.machine_model is None:
                yield from self.load_machine()
            if not is_current():
                return
            geometry, model_signature = yield from self.load_fixture_geometry(fixture)
            if not is_current():
                return
            geometry.validate(profile)
            if not geometry.placements_match(profile) or profile.component_model_signature != model_signature:
                raise EngineError("Fixture", "The saved fixture CAD changed. Review its placement again.")
            fitted = np.array([profile.stock_size.x, profile.stock_size.y, profile.stock_size.z])
            mechanism = self.mechanism_for(fixture, fitted)
            if mechanism is not None:
                mechanism.validate(profile)
            self.library_fixture_meshes[key] = geometry.work_mesh(profile)
            self.layout_scene()
        except Cancelled:
            return
        except Exception as e:  # noqa: BLE001
            if not is_current():
                return
            self.library_fixture_meshes.pop(key, None)
            self.library_fixture_triangles.pop(key, None)
            self.layout_scene()
            self.errorMessage = f"Saved workholding preview couldn't be loaded: {e}"

    @staticmethod
    def fixture_model_signature(path: Path) -> str:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()

    def validate_library_plan_for_export(self) -> None:
        if self.fixture_placement is not None:
            raise EngineError("Workholding", "Save or cancel fixture placement before exporting or running.")
        if not self.setup.plan_from_fixture_library:
            return
        plan = self.library_workholding_plan
        if plan is None or not plan.reviewed or not all(
                p.workholding_step is not None and any(s.id == p.workholding_step.id for s in plan.steps) for p in self.programs):
            raise EngineError("Workholding", "Review every proposed fixture setup before exporting or running.")
        for step in plan.steps:
            a = step.fixture.assembly
            if a is not None and a.planning_issues:
                raise EngineError("Workholding", " ".join(a.planning_issues))
            path, signature = step.fixture.model_path, step.model_signature
            if path is None or signature is None or self.fixture_model_signature(self.fixture_model_path(path)) != signature:
                raise EngineError("Workholding", f"The model for {step.fixture.name} is missing or changed. Generate and review the setup sequence again.")
            owned = self.fixture_lookup(step.fixture.id)
            if owned is None or owned.quantity <= 0:
                raise EngineError("Workholding", f"{step.fixture.name} is not currently marked as owned.")
            fitted = next((f for f in self.automatic_preview_fixtures if f.id == step.fixture.id), None) if self.automatic_workholding else None
            current = copy.deepcopy(fitted or next((f for f in self.setup.fixture_assemblies or [] if f.id == step.fixture.id), None) or owned)
            current.quantity = step.fixture.quantity
            if current != step.fixture:
                raise EngineError("Workholding", f"{step.fixture.name}'s library definition changed. Generate and review the setup sequence again.")

    def review_library_step(self, id: str, reviewed: bool) -> None:
        plan = self.library_workholding_plan
        step = next((s for s in plan.steps if s.id == id), None) if plan is not None else None
        if step is None:
            return
        step.reviewed = reviewed
        for p in self.programs:
            if p.workholding_step is not None and p.workholding_step.id == id:
                p.workholding_step.reviewed = reviewed
        self.note_project_change()
        self.touch()

    def move_library_step(self, id: str, delta: int) -> None:
        """Moves a setup earlier (−1) or later (+1); the guided job's order follows."""
        plan = self.library_workholding_plan
        if plan is None:
            return
        i = next((k for k, s in enumerate(plan.steps) if s.id == id), None)
        if i is None or not 0 <= i + delta < len(plan.steps):
            return
        plan.steps[i], plan.steps[i + delta] = plan.steps[i + delta], plan.steps[i]
        for k, s in enumerate(plan.steps):
            s.number = k + 1
        plan.reordered = True
        for p in self.programs:
            if p.workholding_step is not None:
                now = next((s for s in plan.steps if s.id == p.workholding_step.id), None)
                if now is not None:
                    p.workholding_step = now
        self.note_project_change()
        self.touch()

    @property
    def step_order_note(self) -> str | None:
        plan = self.library_workholding_plan
        if plan is None or plan.reordered is not True:
            return None
        return ("Your order. The cuts were planned for the side setups first, on the whole block, then side A and B: "
                "a setup done earlier meets more stock, one done later less.")

    def inspect_library_step(self, step) -> None:
        self.selected_library_step = step.id
        if self.viewSide != step.side:
            self.show_side_number(step.side)
        p = next((p for p in self.programs if p.workholding_step is not None and p.workholding_step.id == step.id), None)
        if p is not None:
            entry = next((e for e in self.timeline.entries if e.program == p.index), None)
            if entry is not None:
                self.seek(entry.t_start)
        self.layout_scene()
        self.focus_work()


def _build_candidate(fixture, placed, geometry, profile, s, origin, table, centre, machine_tree, region_min, region_max):
    """Off the UI thread: the fixture's triangles, its collision check with the machine, the stock it
    occupies and the clearance field (fixture plus the table plate)."""
    tri = placed.vertices.astype(float)[placed.indices.astype(np.int64)]
    fixture_triangles = tri.copy()
    bodies = [Body.from_triangles(fixture.name, tri + origin), Body("machine", machine_tree)]
    collisions = Collision.check(bodies, 0.2)
    cell = max(0.2, max(s[0], s[1]) / 400)
    occupied = DexelGrid((-s[0] / 2, -s[1] / 2), (s[0] / 2, s[1] / 2), cell)
    for index, solid in enumerate(geometry.solids):
        if index not in geometry.physical_solid_indices:
            continue
        t = geometry.solid_transform(index, profile)
        v = solid.vertices.astype(float) @ t[:3, :3].T + t[:3, 3]
        body = DexelGrid((-s[0] / 2, -s[1] / 2), (s[0] / 2, s[1] / 2), cell)
        body.fill(v.astype(np.float32), solid.indices)
        occupied.merge(body)
    lo = np.array([table.top_x - table.thickness, table.minimum_y if table.minimum_y is not None else centre - 200, table.back_z]) - origin
    hi = np.array([table.top_x, table.maximum_y if table.maximum_y is not None else centre + 200, table.north_z]) - origin
    triangles = np.concatenate([tri, box_triangles(lo, hi).reshape(-1, 3)])
    field = FixtureField(triangles, region_min, region_max)
    return field, fixture_triangles, collisions, occupied
