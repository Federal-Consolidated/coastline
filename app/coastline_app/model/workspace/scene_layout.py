"""The parts of the scene layout that come and go with the job: the fixture on the table, the vise
to buy, the stock as the shown step starts, the engraving outline. Port of the layout parts of
Model/AppModel.swift, Model/EngravingPreview.swift and Model/ScaleToFit.swift."""

from __future__ import annotations

import math

import numpy as np

from ...core.plan.setup_side import SetupSide
from ...core.plan.stock_orientation import stock_options
from ...core.sim.stock_model import dexel_mesh
from ...viewport.scene import SceneColor, SceneLines, SceneMesh, box_mesh, segments
from ..tasks import spawn
from .collision_check import BedBody
from .fixture_placement import PLACEMENT_MESH_PREFIX
from .geometry import translation
from .smart_plan import StandInVise


class SceneLayoutMixin:
    PLACEMENT_MESH_PREFIX = PLACEMENT_MESH_PREFIX

    def layout_clamps(self, stock_size) -> None:
        """The fixture on the table (it moves with X): the job's library fixture, drawn where the
        stock sits in it."""
        if self.fixture_placement is not None:
            self.layout_fixture_placement(stock_size)
            return
        scene = self.scene
        used: set[str] = set()
        bodies: list[BedBody] = []
        try:
            if self.stock is not None:
                fixture = self.displayed_job_fixture
                if (self.setup.plan_from_fixture_library and not self.showing_stock_only and self.automatic_workholding
                        and (self.library_workholding_plan is None or self.current_library_step is None) and fixture is not None
                        and self.fixture_state_key(fixture) not in self.library_fixture_meshes
                        and self.automatic_preview_requested != self.fixture_state_key(fixture)):
                    self.automatic_preview_requested = self.fixture_state_key(fixture)
                    spawn(self.reload_selected_fixture_preview(), "fixture preview")
                if self.setup.plan_from_fixture_library and not self.showing_stock_only and fixture is not None:
                    mesh = self.library_fixture_meshes.get(self.fixture_state_key(fixture))
                    if mesh is not None:
                        id = f"fixture.library.{fixture.id}"
                        origin = np.asarray(self.work_to_model(stock_size), float)
                        m = SceneMesh(id, mesh.vertices, mesh.normals, mesh.indices, SceneColor.part, translation(origin))
                        m.group = "x"
                        scene.add(m)
                        used.add(id)
                        local = self.library_fixture_triangles.get(self.fixture_state_key(fixture))
                        if local is not None:
                            bodies.append(BedBody(fixture.name, id, triangles=np.asarray(local, float).reshape(-1, 3) + origin))
            if self.stock is not None and self.shows_stand_in_vise:
                used.update(self._layout_stand_in_vise(stock_size))
            for m in scene.meshes.values():
                if m.id.startswith("fixture.") and m.id not in used:
                    m.visible = False
            self.apply_fixture_display()
        finally:
            self.schedule_collision_check(bodies, stock_size)

    def _layout_stand_in_vise(self, s) -> list[str]:
        """The stand-in vise around the stock as shown, see-through orange: the same boxes the
        clearance check uses (the table's is drawn by the machine)."""
        o = np.asarray(self.work_to_model(s), float)
        ids = []
        for name, lo, hi in StandInVise.boxes(s, self.stand_in_faced_before, self.stand_in_jaw_front(self.viewSide), self.table_geometry):
            if name == "table":
                continue
            id = f"fixture.standin.{name}"
            from ...viewport.scene import SurfaceMaterial
            m = box_mesh(id, lo + o, hi + o, (0.95, 0.62, 0.25, 0.55))
            m.group = "x"
            m.material = SurfaceMaterial(metallic=0, roughness=0.05)  # drawn see-through (apply_fixture_display)
            self.scene.add(m)
            ids.append(id)
        return ids

    @property
    def shown_in_process_key(self) -> str | None:
        """The snapshot of the stock for the step (or side) shown: what is left when it starts."""
        if self.showing_stock_only or self.fixture_placement is not None or self.stock is None:
            return None
        step = self.current_library_step
        key = f"step:{step.id}" if step is not None else f"side:{max(self.viewSide, 0)}"
        return key if key in self.in_process_snapshots else None

    def side_from_a(self, side: int, a) -> np.ndarray:
        """Side A's frame into this side's work frame (side B's flip included)."""
        s = SetupSide.stock_size(a, side)
        r = SetupSide.rotation(side, self.setup_for(1).flip_axis)
        rot = np.eye(4)
        rot[:3, :3] = r
        return translation((0, 0, -s[2] / 2)) @ rot @ translation((0, 0, a[2] / 2))

    def layout_in_process_stock(self, stock_size, origin) -> None:
        """The stock as the shown setup step starts: what every cut before it left."""
        scene = self.scene
        key = self.shown_in_process_key
        model = self.in_process_snapshots.get(key) if key is not None else None
        stock = self.stock
        if self.shows_machining_results or model is None or stock is None:
            scene.remove("stock.inprocess")
            return
        mesh = self.in_process_meshes.get(key)
        if mesh is None:
            mesh = dexel_mesh(model.material(2), 2)
            self.in_process_meshes[key] = mesh
        p, n, i = mesh
        if not len(i):
            scene.remove("stock.inprocess")
            return
        t = translation(origin) @ self.side_from_a(max(self.viewSide, 0), self.setup.stock_size(stock))
        c = self.linear_swatch(stock.material) if stock.material is not None else (0.5, 0.5, 0.5)
        m = SceneMesh("stock.inprocess", p, n, i, (*c, 0.22), t)
        m.group = "x"
        scene.add(m)

    @property
    def display_stock_trim(self) -> tuple[float, float]:
        """What is gone from the shown stock before this clamping (mm off its front and back)."""
        if self.viewSide < 4 or self.showing_stock_only:
            return 0.0, 0.0
        front, back = self.stand_in_faced_before, 0.0
        plan, cur = self.library_workholding_plan, self.current_library_step
        if self.viewSide == 5 and plan is not None and cur is not None:
            mine = next((k for k, s in enumerate(plan.steps) if s.id == cur.id), None)
            if mine is not None and any(s.side == 4 for s in plan.steps[:mine]):
                back = self.end_piece_thickness(4)
        return front, back

    def layout_engraving_preview(self) -> None:
        """The engraving's outline on the part's face, while there's an engraving op."""
        scene = self.scene
        scene.remove("engrave.preview")
        size = self.display_stock_size
        if self.showing_stock_only or self.viewSide < 0 or size is None:
            return
        texts = [o.engraving for o in self.operations if o.kind.value == "engrave" and o.enabled and o.engraving is not None
                 and (o.engraving.side == self.viewSide or not self.twoSided)]
        if not texts:
            return
        o = np.asarray(self.work_origin(size), float)
        z = -self.setup_for(self.viewSide).top_allowance + 0.05
        pairs = []
        for e in texts:
            for loop in e.polylines(0.05):
                for a, b in zip(loop, loop[1:]):
                    pairs.append(((a[0], a[1], z), (b[0], b[1], z)))
        if pairs:
            scene.add(SceneLines("engrave.preview", segments(np.asarray(pairs) + o, SceneColor.highlight)))

    @property
    def scale_to_fit_stock(self) -> float | None:
        """The largest uniform scale at which the part fits the stock, when it doesn't fit now."""
        part, stock = self.part, self.stock
        if part is None or stock is None:
            return None
        unit = self.setup.copy()
        unit.part_scale = 1.0
        lo, hi = unit.rotated_part_bounds(part.bounds_min, part.bounds_max)
        size = np.asarray(hi, float) - np.asarray(lo, float)

        def fits(k: float) -> bool:
            return any(o.workable for o in stock_options(stock, size * k))

        if fits(self.setup.part_scale):
            return None
        a, b = 0.02, self.setup.part_scale
        if not fits(a):
            return None
        for _ in range(30):
            m = (a + b) / 2
            if fits(m):
                a = m
            else:
                b = m
        return math.floor(a * 200) / 200  # 0.5 % steps
