"""Fixture CAD for the workspace: loading assemblies through the engine (cached by file hash),
fitting owned fixtures to the stock automatically, the measured table, and the job's own copies
of tools and stock. Port of Model/VettedFixtures.swift and Model/JobResources.swift."""

from __future__ import annotations

import copy
import hashlib
import json

import numpy as np

from ... import paths
from ...core import codable
from ...core.engine.client import EngineError
from ...core.inventory.snapshot import JobResourceSnapshot
from ...core.inventory.vetted_fixtures import VettedFixtureLibrary
from ...core.plan.fixture_assembly import FixtureAssemblyState
from ...core.plan.fixture_mechanism import FixtureMechanism, PlacementError, Table
from ...core.plan.library_fixture_geometry import LibraryFixtureGeometry
from ...core.codable import Range
from ..tasks import Work, spawn


class VettedFixturesMixin:
    def prepared_fixture(self, fixture):
        return VettedFixtureLibrary.prepared(fixture, paths.REPO_ROOT / "resources")

    def load_fixture_geometry(self, fixture):
        """A task: the fixture's solids (an assembly's parts by its definition), cached by file hash."""
        if fixture.model_path is None:
            raise EngineError("Fixture", "Choose the assembly's STEP model to place this fixture.")
        url = self.fixture_model_path(fixture.model_path)
        signature = self.fixture_model_signature(url)
        state = fixture.planning.assembly_state if fixture.planning is not None and fixture.planning.assembly_state is not None else FixtureAssemblyState()
        if fixture.assembly is not None:
            fixture.assembly.validate(state)
        cached = self.library_fixture_geometries.get(fixture.id)
        if self.library_fixture_geometry_signatures.get(fixture.id) == signature and cached is not None and cached.assembly_definition == fixture.assembly:
            return cached, signature
        engine = yield from self.live_engine()
        mesh = yield Work(lambda: engine.import_part(url))
        if fixture.assembly is not None:
            definition = fixture.assembly
            definition.validate(state)
            parts = yield Work(lambda: engine.fixture_assembly(mesh.part_id, definition))
            geometry = yield Work(lambda: LibraryFixtureGeometry.from_parts(parts, definition), lane="geometry")
        else:
            solids = yield Work(lambda: engine.fixture_solids(mesh.part_id))
            ok = solids and all(len(s.indices) and len(s.indices) % 3 == 0 and np.isfinite(s.vertices).all()
                                and len(s.normals) == len(s.vertices) and np.isfinite(s.normals).all()
                                and int(s.indices.max()) < len(s.vertices) for s in solids)
            if not ok:
                raise EngineError("Fixture", "The assembly has no usable closed solids.")
            geometry = yield Work(lambda: LibraryFixtureGeometry.from_solids(solids), lane="geometry")
        if self.fixture_model_signature(url) != signature:
            raise EngineError("Fixture", "The CAD file changed while loading. Try again.")
        self.library_fixture_geometries[fixture.id] = geometry
        self.library_fixture_geometry_signatures[fixture.id] = signature
        return geometry, signature

    @property
    def bookend_mount_table(self) -> Table | None:
        if self.planning_geometry is not None:
            return self.planning_geometry.bookend_mount_table(self.travel_centre_y)
        model = self.machine_model
        if model is None:
            return None
        t = self.table_geometry
        if len(model.t_slot_z) != 2 or t.minimum_y is None or t.maximum_y is None or not t.minimum_y < t.maximum_y:
            return None
        return Table(t.top_x, list(model.t_slot_z), Range(t.minimum_y, t.maximum_y), t.north_z, self.travel_centre_y)

    @staticmethod
    def fixture_state_key(fixture) -> str:
        try:
            data = codable.encode(fixture, pretty=False, sort_keys=True)
        except Exception:  # noqa: BLE001
            data = fixture.id.encode()
        return hashlib.sha256(data).hexdigest()

    def job_fixture_inventory(self, inventory):
        if not self.automatic_workholding:
            return inventory.for_fixture_setup(self.setup)
        fitted = {f.id: f for f in self.automatic_fixtures(inventory)[0]}
        result = copy.copy(inventory)
        result.fixtures = [fitted.get(f.id, f) for f in inventory.fixtures]
        return result

    @property
    def automatic_workholding(self) -> bool:
        """No fixture chosen by hand: every owned fixture with a reviewed mechanism is fitted to
        the stock, and the plan picks between them for each cut."""
        return (self.setup.plan_from_fixture_library or self.setup.holding is None) and self.setup.selected_fixture_ids is None

    def automatic_fixtures(self, inventory, stock_size=None) -> tuple[list, dict]:
        """Owned fixtures fitted to this job's stock, and why each other one isn't."""
        stock = self.stock
        if stock is None:
            return [], {}
        loaded = self.machineLoaded and not self.is_switching_planning_machine
        table = self.bookend_mount_table
        if table is None:
            if not loaded and not self.is_switching_planning_machine:
                spawn(self.load_machine())
            why = f"{self.planning_machine_title} has no measured T-slots for this fixture." if loaded else "Loading the machine…"
            return [], {f.id: why for f in inventory.fixtures}
        size = stock_size if stock_size is not None else self.setup.stock_size(stock)
        fitted, why = [], {}
        for f in inventory.fixtures:
            if f.quantity <= 0:
                continue
            issues = f.assembly.planning_issues if f.assembly is not None else []
            if issues:
                why[f.id] = " ".join(issues)
                continue
            try:
                x = FixtureMechanism.automatic(f, table, size)
                if x is not None:
                    fitted.append(x)
                else:
                    why[f.id] = "No model in the library." if f.model_path is None else "Not set up to fit itself yet. Place it by hand."
            except Exception as e:  # noqa: BLE001
                why[f.id] = str(e)
        return fitted, why

    @property
    def automatic_preview_fixtures(self) -> list:
        return self.automatic_fixtures(self.inventory)[0]

    def mechanism_for(self, fixture, stock=None):
        if not FixtureMechanism.has(fixture.assembly):
            return None
        size = stock if stock is not None else self.placement_stock_size
        if size is None:
            raise PlacementError("Choose the stock block for this job first.")
        if self.is_switching_planning_machine:
            raise PlacementError(f"Loading {self.planning_machine_title}…")
        table = self.bookend_mount_table
        if table is None:
            raise PlacementError("This job still uses an older machine definition without table mounting data. Apply your machine profile below."
                                 if self.planning_machine_reference.is_legacy else
                                 f"{self.planning_machine_title} does not provide the measured table this fixture needs.")
        return FixtureMechanism.make(fixture, table, size)

    def use_automatic_workholding(self) -> None:
        s = self.setup.copy()
        s.selected_fixture_ids = None
        s.fixture_assemblies = None
        self.setup = s
        self.clear_toolpath_results()
        self.layout_scene()

    def remove_job_fixture(self, id: str) -> None:
        if self.setup.selected_fixture_ids is None:
            return
        s = self.setup.copy()
        s.selected_fixture_ids = [x for x in s.selected_fixture_ids if x != id]
        if s.fixture_assemblies is not None:
            s.fixture_assemblies = [f for f in s.fixture_assemblies if f.id != id]
        self.setup = s
        self.clear_toolpath_results()

    # ---- job resources (JobResources.swift)

    @property
    def saved_resource_snapshot(self) -> JobResourceSnapshot:
        snap = copy.deepcopy(self.job_resources) if self.job_resources is not None else JobResourceSnapshot()
        snap.stock = self.stock
        ids = {o.tool_id for o in self.operations if o.tool_id is not None}
        snap.capture_tools(ids, [t for t in (self.tool_lookup(i) for i in ids) if t is not None])
        return snap

    def capture_job_tools(self) -> None:
        if self.job_resources is None:
            self.job_resources = JobResourceSnapshot()
        ids = {o.tool_id for o in self.operations if o.tool_id is not None}
        self.job_resources.capture_tools(ids, [t for t in (self.tool_lookup(i) for i in ids) if t is not None])

    def planning_inventory(self, inventory):
        base = self.job_resources.planning_inventory(inventory) if self.job_resources is not None else inventory
        return self.job_fixture_inventory(base)

    def job_tool(self, id):
        if self.job_resources is not None:
            t = next((t for t in self.job_resources.tools if t.id == id), None)
            if t is not None:
                return t
        return self.tool_lookup(id)

    def update_job_resources(self) -> None:
        """Explicitly refreshes the job's copies; routine library edits leave the job intact."""
        if not self.can_change_planning_machine:
            return
        inventory = self.inventory
        ids = {o.tool_id for o in self.operations if o.tool_id is not None}
        nxt = copy.deepcopy(self.job_resources) if self.job_resources is not None else JobResourceSnapshot()
        for i, t in enumerate(nxt.tools):
            current = next((x for x in inventory.tools if x.id == t.id), None)
            if current is not None:
                nxt.tools[i] = current
        nxt.capture_tools(ids, inventory.tools)
        if self.stock_id is not None:
            item = next((s for s in inventory.stock if s.id == self.stock_id), None)
            if item is not None:
                nxt.stock = inventory.resolved_stock(item)
        if nxt == self.saved_resource_snapshot:
            self.status = "Job resources are up to date"
            return
        self.job_resources = nxt
        self.clear_toolpath_results()
        self.op_cache = {}
        self.op_cache_order = []
        self.tool_change_spot_cache = None
        self.reference_plan = None
        self.plan_candidates, self.plan_options, self.chosen_plan, self.recommended_plan = [], [], None, None
        if nxt.stock is not None:
            self.stock_edited(nxt.stock)
        self.note_project_change()
        self.save_session()
        self.status = "Job resources updated. Regenerate toolpaths."
        self.touch()
