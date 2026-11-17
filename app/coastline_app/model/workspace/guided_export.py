"""The guided job: measuring checkpoints, setup pictures, the builder's input with the safety gate,
and the one-click job proposal. Port of Model/GuidedExport.swift and Model/GuidedJobPlanning.swift
(the Finder project icon is Mac-only and isn't ported)."""

from __future__ import annotations

import copy
import os
import tempfile
import time
from pathlib import Path

import numpy as np

from ...core.export import guided_job as GuidedJob
from ...core.feeds import OperationKind as K
from ...core.plan import job_library_guide as JobLibraryGuide
from ...core.plan.library_workholding import eligibility
from ...core.plan.operation import OperationPlanner, ReferenceFeature
from ...core.plan.setup import CustomFixture, Workholding
from ...core.units import Length
from ..tasks import Sleep, Work
from .geometry import translation


class GuidedExportError(Exception):
    pass


class GuidedExportMixin:
    def checkpoints(self) -> list:
        """Measuring checkpoints: thickness after facing, the outline after the finishing contour,
        thread depth by hand, hole sizes after drilling or boring."""
        part, stock = self.part, self.stock
        if part is None or stock is None:
            return []
        out = []
        rlo, rhi = self.setup.rotated_part_bounds(part.bounds_min, part.bounds_max)
        size = self.setup.stock_size(stock)
        for p in self.programs:
            kinds = {o.kind for o in p.operations if o.reference is None}
            if K.FACING in kinds:
                face = next(o for o in p.operations if o.kind == K.FACING)
                out.append(GuidedJob.Checkpoint(p.index, "Stock thickness after facing", float(size[2] - face.face_depth), 0.05))
            if K.CONTOUR in kinds:
                out.append(GuidedJob.Checkpoint(p.index, "Part height (X)", float(rhi[0] - rlo[0]), 0.05))
                out.append(GuidedJob.Checkpoint(p.index, "Part width (Y)", float(rhi[1] - rlo[1]), 0.05))
        holes = self.features.holes if self.features is not None else []
        for p in self.programs:
            for op in p.operations:
                if op.kind != K.THREAD or op.thread is None or op.thread.thread is None:
                    continue
                spec = op.thread.thread
                hole = next((h for h in holes if spec.fits(h.diameter)), None)
                depth = op.thread.depth if op.thread.depth is not None else (hole.z_top - hole.z_bottom if hole is not None else 0)
                if depth > 0:
                    out.append(GuidedJob.Checkpoint(p.index, f"{spec.name} thread: how deep a screw turns in by hand", depth, max(spec.pitch, 0.5)))
        last = next((p for p in reversed(self.programs) if p.side == 0
                     and any(o.kind in (K.BORE, K.DRILL) and o.reference is None for o in p.operations)), None)
        if last is not None:
            sizes = []
            for h in holes:
                if not any(abs(s - h.diameter) < 0.01 for s in sizes):
                    sizes.append(h.diameter)
            for d in sorted(sizes):
                out.append(GuidedJob.Checkpoint(last.index, "Hole diameter" if len(sizes) == 1 else f"Hole Ø{Length.mm(d)}", d, 0.03))
        return out

    def setup_snapshot(self, side: int = 0):
        """A task step: a picture of the setup from the spindle side (PNG bytes, or None without
        a 3D view)."""
        view = self.renderer.view
        if view is None:
            return None
        saved_cam = view.camera.copy()
        saved_machine = self.machineDisplay
        saved_anim = getattr(view, "animations_enabled", True)
        view.animations_enabled = False
        self.machineDisplay = "ghost"
        self.set_view("toolIso")
        self.focus_work()
        part_mesh = self.scene.mesh("part")
        saved_part = None if part_mesh is None else np.array(part_mesh.transform, float)
        part, stock = self.part, self.stock
        if part is not None and stock is not None and part_mesh is not None:
            o = self.work_origin(self.setup.stock_size(stock))
            part_mesh.transform = translation(o) @ self.setup_for(side).part_to_work(part.bounds_min, part.bounds_max)
        path = Path(tempfile.gettempdir()) / f"coastline-setup-{os.getpid()}-{time.monotonic_ns()}.png"
        done = []
        try:
            view.snapshot(path, 1200, 800, lambda ok: done.append(ok))
            waited = 0.0
            while not done and waited < 5:
                yield Sleep(0.05)
                waited += 0.05
            return path.read_bytes() if done and done[0] and path.exists() else None
        finally:
            view.camera = saved_cam
            view.animations_enabled = saved_anim
            self.machineDisplay = saved_machine
            if saved_part is not None and part_mesh is not None:
                part_mesh.transform = saved_part
            try:
                path.unlink()
            except OSError:
                pass
            view.update()

    def guided_input(self, measuring: list):
        """A task step: the guided job builder's input (None before toolpaths)."""
        part, stock = self.part, self.stock
        material = stock.material if stock is not None else None
        if part is None or stock is None or material is None or not self.programs:
            return None
        image = yield from self.setup_snapshot()
        inp = GuidedJob.Input(part.file_name, material, stock, tuple(float(v) for v in self.setup.stock_size(stock)), "Setup 1",
                              self.guided_programs(), self.checkpoints(), list(measuring), image, face_allowance=self.setup.top_allowance)
        if self.setup.holding == Workholding.CUSTOM:
            plan = self.library_workholding_plan
            if plan is not None and plan.steps and self.setup.plan_from_fixture_library:
                first = plan.steps[0]
                custom = CustomFixture()
                custom.name = first.fixture.name
                custom.height = first.fixture.height
                custom.face_protrusion = first.fixture.planning.face_past_table if first.fixture.planning is not None else 0.0
                custom.notes = first.instructions
                inp.custom_holding = custom
            else:
                inp.custom_holding = self.setup.custom_fixture
        if self.cuts_through_with_tabs and self.placed_tabs:
            inp.tabs = copy.deepcopy(self.tabs)
            inp.tabs.count = len(self.placed_tabs)
        if self.twoSided:
            inp.tabs = copy.deepcopy(self.tabs) if self.holdWithTabs and self.placed_tabs else None
            if inp.tabs is not None:
                inp.tabs.count = len(self.placed_tabs)
            inp.flip_image = yield from self.setup_snapshot(1)
            inp.flip_axis = self.setup_for(1).flip_axis
        inp.probing = self.probing()
        spot, tc = self.tool_change_spot(), self.machine.tool_change_pose
        inp.tool_change_z = spot.z if spot.z > tc[2] + 1e-9 else None
        inp.tool_change_y = spot.y if abs(spot.y - tc[1]) > 1e-9 else None
        return inp

    def guided_programs(self) -> list:
        """The programs for the guided job, each with the face height its tool is touched off on."""
        faced: dict[int, float] = {}
        out = []
        plan = self.library_workholding_plan
        for p in self.programs:
            g = GuidedJob.Program(p.tool, p.gcode, [o.title for o in p.operations], p.seconds / 60, p.side)
            g.touch_z = -faced.get(p.side, 0.0)
            g.reference = next((o.reference for o in p.operations if o.reference is not None), None)
            g.surface_probe = p.surface_probe
            ws = p.workholding_step
            if ws is not None and plan is not None:
                ws = next((s for s in plan.steps if s.id == ws.id), ws)
            g.workholding = ws
            for o in p.operations:
                if o.kind == K.FACING:
                    faced[p.side] = faced.get(p.side, 0.0) + o.face_depth
            out.append(g)
        return out

    def probing(self):
        """How the job finds the stock: the edge finder, and the reference bores."""
        pr = GuidedJob.Probing()
        refs = {o.reference for p in self.programs for o in p.operations if o.reference is not None}
        pr.bores = self.reference_plan if ReferenceFeature.BORES in refs and ReferenceFeature.WINDOWS in refs else None
        return pr

    @property
    def unowned_job_tools(self) -> list:
        """The job's tools you don't have yet: on your list to buy, or only in the job."""
        seen, out = set(), []
        for p in self.programs:
            t = p.tool
            if t.id in seen:
                continue
            seen.add(t.id)
            owned = self.tool_lookup(t.id)
            if (owned.quantity <= 0) if owned is not None else t.is_suggestion:
                out.append(t)
        return out

    def checked_guided_input(self, measuring: list):
        """A task step: the same safety gate for full export, selected code and the native runner."""
        self.require_planning_machine()
        self.validate_library_plan_for_export()
        if self.is_generating:
            raise GuidedExportError("Wait for toolpath generation to finish.")
        if not self.programs:
            raise GuidedExportError("Generate toolpaths first.")
        if not all(p.report.passed for p in self.programs):
            raise GuidedExportError("Fix the safety errors before exporting.")
        missing = [t.name for t in self.unowned_job_tools]
        if missing:
            one = len(missing) == 1
            raise GuidedExportError(f"Buy {'this tool' if one else 'these tools'} first, then set {'it' if one else 'them'} as owned in Tools: {', '.join(missing)}.")
        inp = yield from self.guided_input(measuring)
        if inp is None:
            raise GuidedExportError("Generate toolpaths first.")
        return inp

    # ---------------------------------------------------------------- guided job planning

    def guided_stock_choices(self, inventory) -> list:
        if self.part is None:
            return []
        lo, hi = self.setup.rotated_part_bounds(self.part.bounds_min, self.part.bounds_max)
        return JobLibraryGuide.stock_choices(np.asarray(hi) - np.asarray(lo), inventory, self.setup.stock_axes)

    def guided_stock(self, inventory) -> list:
        return [c.stock for c in self.guided_stock_choices(inventory)]

    def matching_fixture_count(self, item, inventory) -> int:
        c = next((c for c in self.guided_stock_choices(inventory) if c.stock.id == item.id), None)
        return c.matching_fixtures if c is not None else 0

    def use_guided_stock(self, item, inventory) -> None:
        c = next((c for c in self.guided_stock_choices(inventory) if c.stock.id == item.id), None)
        self.use_stock(inventory.resolved_stock(item))
        if c is not None:
            self.use_stock_axes(c.axes)

    def library_planning_blocker(self, inventory) -> str | None:
        if not self.planning_machine_ready:
            return self.planning_machine_problem or "Load a machine before planning."
        stock = self.stock
        if self.part is None or stock is None:
            return "Load a part and choose stock first."
        owned = self.stock_lookup(stock.id)
        if (owned.quantity if owned is not None else 0) <= 0:
            return "Choose stock you have, or confirm this blank is in your library."
        if stock.material is None:
            return "Assign a material to this stock so cutting data can be planned."
        st = self.stage_status("stock")
        if st.state != "done":
            return st.why
        if not [t for t in OperationPlanner.usable_tools(inventory, machine=self.machine) if not t.is_suggestion]:
            if any(t.quantity > 0 for t in inventory.tools):
                return "None of your owned tools is ready. Check matching collets, tool condition and dimensions in the library."
            return "Add your cutting tools and their matching collets to the library before planning."
        if self.setup.plan_from_fixture_library or self.setup.holding is None:
            available = self.job_fixture_inventory(inventory)
            size = self.setup.stock_size(stock)
            if not any(not eligibility(f, size) for f in available.fixtures):
                return "Choose workholding in Setups first."
        return None

    def propose_job(self, library):
        """A task: compare owned tooling, choose a usable proposal, generate its cuts, assign
        library fixtures, then hand the physical setups to the operator."""
        inventory = library.inventory if hasattr(library, "inventory") else library
        if self.isPlanningJob or self.isFindingPlans or self.is_generating:
            return
        blocker = self.library_planning_blocker(inventory)
        if blocker is not None:
            self.errorMessage = blocker
            return
        self.isPlanningJob = True
        self.errorMessage = ""
        try:
            if self.setup.holding is None:
                self.enable_library_planning()
            part_id = self.part.part_id if self.part is not None else None
            stock_id, original, ref = self.stock_id, copy.deepcopy(self.setup), self.planning_machine_reference
            selected = self.chosen_plan
            self.plan_options = []
            self.plan_candidates = []
            yield from self.find_plans(inventory)
            if self.errorMessage:
                return
            if (self.part is None or self.part.part_id != part_id or self.stock_id != stock_id or self.setup != original
                    or self.planning_machine_reference != ref):
                self.status = "The part or setup changed while comparing plans. Build the proposal again."
                return
            opts = self.plan_options
            proposed = (next((c for c in opts if c.name == selected), None) or next((c for c in opts if c.name == self.recommended_plan), None)
                        or (min(opts, key=lambda c: (c.risk, c.minutes)) if opts else None))
            if proposed is None:
                self.errorMessage = "No plan fits this machine with your tools or ones to buy. Check the problems below."
                return
            self.use_plan(proposed)
            yield from self.generate_toolpaths(inventory)
            plan = self.library_workholding_plan
            if self.cancel_generation or not self.programs or (self.setup.plan_from_fixture_library and not (plan is not None and plan.complete)):
                return
            buy = len(self.job_tools_to_buy)
            gap = self.coverage_gap_note
            self.status = ("Job proposed." + (f" {gap}" if gap else "")
                           + ((" It uses a tool to buy." if buy == 1 else f" It uses {buy} tools to buy.") if buy > 0 else "")
                           + " Review each setup below, then inspect the toolpaths.")
        finally:
            self.isPlanningJob = False
            self.touch()


class GeneratedProgramsMixin:
    """Port of Model/GeneratedPrograms.swift: a generated job written to the Jobs folder and
    opened in the runner. Preparing it never connects or starts the machine."""

    def open_guided_mode(self) -> None:
        jobs = self.jobs
        if jobs is not None:
            folder = jobs.run.folder if jobs.run is not None else jobs.selection
            if folder is not None:
                self.projects_pick = f"job:{folder}"
        self.navigate("projects")

    def prepare_generated_run(self, measuring: list):
        """A task step: writes the job and starts its run. Raises with the reason when it can't."""
        import shutil
        import uuid
        from ...core.export.generated_job import write_native
        from ..jobs_model import user_folder
        if self.plan_waits_for_workholding:
            raise GuidedExportError("A setup is held in workholding you don't have yet (see the Shopping List). Add it to your fixtures, then generate again.")
        if not self.planning_machine_reference.is_legacy:
            raise GuidedExportError("This machine profile is ready for planning and workspace simulation. Commission its physical machine before running generated jobs through Machine Control.")
        jobs = self.jobs
        if jobs is None:
            raise GuidedExportError("The jobs list isn't available.")
        if jobs.run is not None:
            raise GuidedExportError("A guided job is already open. Return to Guided Mode and finish or end it first.")
        inp = yield from self.checked_guided_input(measuring)
        folder = user_folder() / f"generated-{str(uuid.uuid4()).upper()}"
        job = yield Work(lambda: write_native(inp, folder, self.machine), lane="post")
        problems = job.problems(folder)
        if problems:
            shutil.rmtree(folder, ignore_errors=True)
            raise GuidedExportError(" ".join(problems))
        jobs.reload()
        entry = next((e for e in jobs.entries if e.folder == folder), None)
        if entry is None:
            return
        jobs.selection = folder
        jobs.start_run(entry)
        self.open_guided_mode()
