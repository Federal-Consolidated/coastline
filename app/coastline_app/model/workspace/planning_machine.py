"""The job's machine: loading its model into the scene, selecting another, the legacy control
machine. Port of Model/PlanningMachine.swift and Model/MachineTable.swift."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass

import numpy as np
from PySide6.QtCore import Slot

from ... import paths
from ...core import codable
from ...core.machine.definition import MachineDefinitionError
from ...core.machine.package import MachineDefinitionPackage
from ...core.machine.planning_geometry import MachinePlanningGeometry
from ...core.machine.planning_reference import PlanningMachineReference
from ...viewport.scene import SceneMesh
from ..settings import AppSettings
from ..tasks import Sleep, Work, spawn

PREFERENCE = "planningMachineReference"
SCRIPTED = "COASTLINE_SCRIPT" in os.environ


@dataclass
class MachineTable:
    """The table plate: where fixtures stand and how far the stock face comes toward the spindle."""

    top_x: float = -31.12
    north_z: float = -2.4  # the spindle-side edge
    back_z: float = -67.12  # the edge toward you
    thickness: float = 14.72
    minimum_y: float | None = None
    maximum_y: float | None = None


class PlanningMachineMixin:
    @property
    def table_geometry(self) -> MachineTable:
        t = MachineTable()
        if self.machine_model is not None:
            t.top_x = self.machine_model.table_top_x
        g = self.planning_geometry
        if g is not None:
            t.top_x = g.model.table_top_x
            t.north_z = g.support_bounds.maximum.z
            t.back_z = g.support_bounds.minimum.z
            t.thickness = t.top_x - g.table_bounds.minimum.x
            t.minimum_y = g.table_bounds.minimum.y
            t.maximum_y = g.table_bounds.maximum.y
        return t

    @property
    def planning_machine_ready(self) -> bool:
        return self.machineLoaded and self.machine_model is not None and not self.is_switching_planning_machine and self.planning_machine_problem is None

    @property
    def can_change_planning_machine(self) -> bool:
        fp = self.fixture_placement
        return (not self.isBusy and not self.is_generating and not self.isPlanningJob and not self.isFindingPlans
                and not self.is_switching_planning_machine and not (fp is not None and fp.loading) and (self.jobs is None or self.jobs.run is None))

    @property
    def planning_machine_title(self) -> str:
        r = self.planning_machine_reference
        return r.display_name if r.is_legacy else f"{r.display_name} · r{r.reference.revision}"

    def require_planning_machine(self) -> None:
        if not self.planning_machine_ready:
            raise MachineDefinitionError(self.planning_machine_problem or "Wait for the job's machine to finish loading before planning.")
        g = self.planning_geometry
        if g is not None and not g.supports_vetted_fixture_mounting:
            raise MachineDefinitionError("The current vetted workholding library requires two T-slots about 40 mm apart. Add compatible workholding before generating CAM for this machine.")

    def load_machine(self):
        """A task: loads the machine assembly at start."""
        if self.machineLoaded or self.is_switching_planning_machine:
            return
        try:
            reference = yield from self.initial_planning_machine_reference()
            while self.is_switching_planning_machine:
                yield Sleep(0.025)
            if self.machineLoaded:
                return  # a project opened meanwhile owns its explicit assignment
            yield from self.restore_planning_machine(reference)
        except Exception as e:  # noqa: BLE001
            self.planning_machine_problem = str(e)
            self.errorMessage = f"Couldn't load the machine model: {e}"

    def initial_planning_machine_reference(self):
        if getattr(self, "planning_machine_initialized", False):
            return self.planning_machine_reference
        raw = AppSettings.value(PREFERENCE, None)
        if raw:
            try:
                return codable.from_json(PlanningMachineReference, json.loads(raw))
            except Exception:  # noqa: BLE001 — a stale preference falls back to the default
                pass
        yield from self.machine_profiles.reload()
        package = next((p for p in self.machine_profiles.packages if p.definition.id == "desktop-cnc"), None)
        if package is None:
            raise MachineDefinitionError("Install a machine profile to start planning.")
        return PlanningMachineReference.of(package.definition)

    @Slot(str)
    def usePlanningMachine(self, profile_key: str) -> None:
        from ..machine_profiles import key
        package = next((p for p in self.machine_profiles.packages if key(p) == profile_key), None)
        if package is None:
            return
        try:
            reference = PlanningMachineReference.of(package.definition)
        except Exception as e:  # noqa: BLE001
            self.errorMessage = str(e)
            return
        spawn(self.select_planning_machine(reference))

    def select_planning_machine(self, reference: PlanningMachineReference):
        if self.planning_machine_reference == reference and self.planning_machine_ready:
            return
        if not self.can_change_planning_machine:
            return
        fp = self.fixture_placement
        placement_id = fp.id if fp is not None else None
        if placement_id is not None:
            fp.loading = True
            fp.error = None
            self.fixture_placement_geometry = None
            self.layout_scene()
        try:
            yield from self.restore_planning_machine(reference)
            fp = self.fixture_placement
            if placement_id is not None and fp is not None and fp.id == placement_id:
                # A mounting pose belongs to its machine: fit against the new table, review again.
                pl = fp.fixture.planning
                if pl is not None:
                    pl.workspace_placed = False
                    pl.grip_definition_reviewed = False
                    if pl.assembly_state is not None:
                        pl.assembly_state.mounted = False
                yield from self.reload_placement_geometry(centre_unconfigured=True)
                if self.fixture_placement is not None and self.fixture_placement.id == placement_id:
                    self.focus_placement_context()
            if not SCRIPTED:
                AppSettings.set_value(PREFERENCE, json.dumps(codable.to_json(reference)))
            self.note_project_change()
            self.save_session()
            self.status = (f"{self.planning_machine_title} selected. Regenerate toolpaths for this machine." if self.fixture_placement is None
                           else f"{self.planning_machine_title} selected for this job. Review the workholding on its table.")
        except Exception as e:  # noqa: BLE001
            fp = self.fixture_placement
            if placement_id is not None and fp is not None and fp.id == placement_id:
                yield from self.reload_placement_geometry()
            self.errorMessage = str(e)
        self.touch()

    def restore_planning_machine(self, reference: PlanningMachineReference):
        """Prepares the complete replacement before touching the job. Never substitutes a newer
        revision or a default machine when a saved package is unavailable."""
        while self.is_switching_planning_machine:
            yield Sleep(0.025)
        if reference.is_legacy:
            # Jobs from before machine profiles get the installed Desktop CNC profile: the old
            # built-in model has no measured table or T-slots.
            yield from self.machine_profiles.reload()
            package = next((p for p in self.machine_profiles.packages if p.definition.id == "desktop-cnc"), None)
            if package is not None:
                reference = PlanningMachineReference.of(package.definition)
                if not SCRIPTED:
                    AppSettings.set_value(PREFERENCE, json.dumps(codable.to_json(reference)))
        if self.planning_machine_ready and self.planning_machine_reference == reference:
            return
        if self.is_generating or self.isPlanningJob or self.isFindingPlans:
            raise MachineDefinitionError("Finish the current planning task before changing the job's machine.")
        self.is_switching_planning_machine = True
        try:
            if reference.is_legacy:
                model = yield from self.load_control_machine_model()
                geometry = None
            else:
                yield from self.machine_profiles.reload()
                resolved = reference.resolve(self.machine_profiles.packages)
                if resolved is None:
                    raise MachineDefinitionError("The selected machine package is missing.")
                fresh = yield Work(lambda: MachineDefinitionPackage.load(resolved.root), lane="files")
                if fresh.definition != reference.definition:
                    raise MachineDefinitionError("The machine profile changed while loading. Restore its original package or select the revised profile explicitly.")
                engine = yield Work(self.connected_engine)
                parts = yield Work(lambda: engine.machine_profile_parts(fresh.manifest_path))
                geometry = yield Work(lambda: MachinePlanningGeometry(fresh.definition, parts), lane="files")
                model = geometry.model
            meshes, components, roles = [], {}, {}
            for index, part in enumerate(model.parts):
                id = f"machine.{part.group}.{part.role}.{index}"
                m = SceneMesh(id, part.mesh.vertices, part.mesh.normals, part.mesh.indices, (*self.display_color(part.role, part.color), 1.0))
                m.group = (None if part.group == "static" else part.group) if geometry is None else "profile." + part.group
                meshes.append(m)
                components[id] = part.group
                roles[id] = part.role
            # Invalidate before replacing the assignment: old results must never take the new
            # profile's identity in an autosave or background completion.
            self.clear_toolpath_results()
            for name in ("analysis_task", "tool_change_task", "flip_task", "sim_catch_up", "sim_precompute", "clearance_recheck", "machine_tree_task"):
                t = getattr(self, name, None)
                if t is not None:
                    t.cancel()
                setattr(self, name, None)
            self.tool_change_stop = None
            self.machine_tree = None
            self.machine_tree_key = None
            self.head_trees = None
            self.profile_collision_trees = None
            self.bed_tree = None
            self.collision_generation = getattr(self, "collision_generation", 0) + 1
            self.collisions = []
            self.collision_prefixes = {}
            self.op_cache = {}
            self.op_cache_order = []
            self.tool_change_spot_cache = None
            self.reference_plan = None
            self.travel_issue = None
            self.plan_candidates = []
            self.plan_options = []
            self.chosen_plan = None
            self.recommended_plan = None
            self.plan_estimate = {}
            self.plan_notes = []
            self.scene.remove_prefix("machine.")
            self.scene.group_transforms = {}
            self.planning_machine_reference = reference
            self.calibration = self.load_calibration(reference)
            self.planning_machine_initialized = True
            self.planning_geometry = geometry
            self.machine_model = model
            self.machine_scene_components = components
            self.machine_scene_roles = roles
            for m in meshes:
                self.scene.add(m)
            self.machineLoaded = True
            self.planning_machine_problem = (
                "The current vetted workholding library needs two compatible T-slots about 40 mm apart. Install compatible workholding before generating CAM for this machine."
                if geometry is not None and not geometry.supports_vetted_fixture_mounting else None)
            home = reference.profile.home_position
            self.set_machine_position([home.x, home.y, home.z] if home is not None else [0, 0, 0])
            self.apply_machine_display()
            self.layout_scene()
            if self.part is None:
                self.renderer.frame_all()
            else:
                self.focus_work()
            self.schedule_analysis()
            self.touch()
        finally:
            self.is_switching_planning_machine = False

    def load_control_machine_model(self):
        """Physical control and old G-code projects use their existing machine model."""
        if self.legacy_control_model is not None:
            return self.legacy_control_model
        engine = yield Work(self.connected_engine)
        model = yield Work(lambda: engine.machine_model(paths.REPO_ROOT / "resources" / "machine" / "machine.step"))
        self.legacy_control_model = model
        return model
