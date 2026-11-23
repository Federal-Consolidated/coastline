"""App state: navigation plus the workspace (machine, part, stock, setup, measuring).
Port of Model/AppModel.swift.

Scene frame: the machine assembly's own coordinates, which are the machine axes (X up, Y right,
Z toward the spindle). The work frame of `Setup` is placed into it with `work_to_model` (a pure
translation: the axes are the same)."""

from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass, field, replace
from pathlib import Path

import numpy as np
from PySide6.QtCore import Property, QObject, Signal, Slot

from ... import paths
from ...core import codable
from ...core.engine.client import EngineClient, EngineError
from ...core.geometry import Vec3
from ...core.machine.planning_reference import PlanningMachineReference
from ...core.machine.profile import MachineProfile
from ...core.plan.setup import Setup, SetupChecks, Workholding
from ...core.plan.stock_orientation import stock_options
from ...core.units import Length
from ...viewport.scene import (SceneColor, SceneLines, SceneMesh, axes_segments, box_mesh, box_segments, segments)
from ..bindable import prop
from ..settings import AppSettings
from ..tasks import Work, spawn
from .geometry import transform_points, translation, world_bounds

SCRIPTED = "COASTLINE_SCRIPT" in os.environ
NOMINAL_STICKOUT = 25.0  # nominal tool for placing the stock under the spindle in the 3D view
SESSION_KEY = "CoastlineSession"

MACHINE_DISPLAYS = {"full": "Whole machine", "open": "Without enclosure", "ghost": "Ghosted (see-through)",
                    "moving": "Moving parts only", "hidden": "Hidden"}

# Motion groups: the table (X) carries the work; the translator (Y) and spindle (Z, riding on Y) the tool.
ON_TABLE = {"part", "stock", "stock.edges", "simstock", "simstock.back", "stock.anim", "clearance", "toolpath", "workarea",
            "workarea.edges", "travel.trace", "undercuts", "measure", "section.plane", "section.edges", "deviation", "cutface",
            "cutface.edges", "prep.cut", "prep.cut.edges", "prep.next", "simstock.walls", "simstock.loose"}


def group_for_id(id: str) -> str | None:
    if id.startswith("machine.x."):
        return "x"
    if id.startswith("machine.y."):
        return "y"
    if id.startswith("machine.z.") or id == "tool" or id.startswith("tool."):
        return "z"
    if id.startswith("fixture.") or id.startswith("tabs"):
        return "x"
    return "x" if id in ON_TABLE else None


@dataclass
class PartInfo:
    """What the inspector shows about the imported part."""

    path: Path
    file_name: str
    kind: str
    exact: bool
    face_count: int
    triangle_count: int
    size: Vec3
    bounds_min: np.ndarray
    bounds_max: np.ndarray
    part_id: str
    warnings: list[str]


@dataclass
class MeasurePoint:
    world: np.ndarray
    info: object | None = None  # FaceInfo


class ViewportLink:
    """The workspace's handle on the 3D view the page shows (created by QML). Camera moves made
    while no view is attached apply when one is."""

    def __init__(self, scene) -> None:
        self.scene = scene
        self.view = None
        self._pending = []
        self.animations_enabled = not SCRIPTED or "COASTLINE_ANIMATE" in os.environ

    def attach(self, view) -> None:
        from ...viewport.item import MACHINE_TO_DISPLAY
        self.view = view
        view.world_to_display = MACHINE_TO_DISPLAY
        view.animations_enabled = self.animations_enabled
        # The camera outlives the view (pages come and go); it starts at Iso like the Mac app's.
        if getattr(self, "_camera", None) is not None:
            view.camera = self._camera
        else:
            view.camera.set_view("iso")
        for fn in self._pending:
            fn(view)
        self._pending = []

    def detach(self, view) -> None:
        if self.view is view:
            self._camera = view.camera.copy()
            self.view = None

    def _do(self, fn) -> None:
        if self.view is not None:
            try:
                fn(self.view)
                return
            except RuntimeError:  # the page closed and took the item with it
                self.view = None
        self._pending.append(fn)

    def move_camera(self, change, animated: bool = True) -> None:
        self._do(lambda v: v.move_camera(change, animated))

    def frame(self, lo, hi, animated: bool = False) -> None:
        self._do(lambda v: v.frame_world(lo, hi, animated))

    def frame_all(self, animated: bool = False) -> None:
        self._do(lambda v: v.frame_all(animated))

    def set_pivot(self, world) -> None:
        self._do(lambda v: v.set_pivot(world))

    @property
    def camera(self):
        return self.view.camera if self.view is not None else None

    def ray(self, x: float, y: float):
        return self.view.ray(x, y) if self.view is not None else None


class WorkspaceCore(QObject):
    """State and the basics; the extensions are mixins (see workspace.py)."""

    changed = Signal()  # anything an inspector shows changed (bumps `revision`)
    revision, revisionChanged = prop(int, "revision", 0)
    status, statusChanged = prop(str, "status", "Starting the geometry engine…")
    isBusy, isBusyChanged = prop(bool, "isBusy", False)
    errorMessage, errorMessageChanged = prop(str, "errorMessage", "")
    machineDisplay, machineDisplayChanged = prop(str, "machineDisplay", "full", on_set=lambda s, v: s.apply_machine_display())
    showChipGuards, showChipGuardsChanged = prop(bool, "showChipGuards", True, on_set=lambda s, v: s._remember("showChipGuards", v, s.apply_machine_display))
    perspective, perspectiveChanged = prop(bool, "perspective", False, on_set=lambda s, v: s.renderer.move_camera(lambda c: setattr(c, "orthographic", not v), animated=False))
    showWorkArea, showWorkAreaChanged = prop(bool, "showWorkArea", True, on_set=lambda s, v: s.layout_scene())
    realistic, realisticChanged = prop(bool, "realistic", True, on_set=lambda s, v: s._remember("realistic", v, s.apply_stock_display))
    stockDisplay, stockDisplayChanged = prop(str, "stockDisplay", "realistic", on_set=lambda s, v: s.apply_stock_display())
    isolateWork, isolateWorkChanged = prop(bool, "isolateWork", False, on_set=lambda s, v: s.apply_machine_display())
    pathsVisible, pathsVisibleChanged = prop(bool, "pathsVisible", True, on_set=lambda s, v: s._set_lines_visible("toolpath", v))
    sectionOn, sectionOnChanged = prop(bool, "sectionOn", False, on_set=lambda s, v: s.apply_section())
    sectionAxis, sectionAxisChanged = prop(str, "sectionAxis", "y", on_set=lambda s, v: s.apply_section())
    sectionOffset, sectionOffsetChanged = prop(float, "sectionOffset", 0.0, on_set=lambda s, v: s.apply_section())
    measuring, measuringChanged = prop(bool, "measuring", False, on_set=lambda s, v: None if v else s.clear_measurements())
    machineLoaded, machineLoadedChanged = prop(bool, "machineLoaded", False)

    @Property(QObject, constant=True)
    def viewScene(self):
        """The scene the 3D view draws (`scene` in Python)."""
        return self.scene

    def __init__(self, inventory, journal, settings: AppSettings, mill, parent: QObject | None = None) -> None:
        super().__init__(parent)
        from ...viewport import Scene
        self.inventory_model = inventory
        self.journal = journal
        self.settings = settings
        settings.unitsChanged.connect(self.touch)
        self.mill = mill
        self.scene = Scene(self)
        self.scene.group_for_id = group_for_id
        self.renderer = ViewportLink(self.scene)
        self.planning_machine_reference = PlanningMachineReference.legacy()
        self.control_machine = MachineProfile.standard()  # physical control stays on its commissioned machine
        self.planning_geometry = None
        self.planning_machine_problem: str | None = None
        self.is_switching_planning_machine = False
        self.machine_scene_components: dict[str, str] = {}
        self.machine_scene_roles: dict[str, str] = {}
        self.legacy_control_model = None
        self.machine_model = None
        self._engine: EngineClient | None = None
        self.part: PartInfo | None = None
        self.part_mesh_data = None
        self._setup = Setup()
        self._stock_id: str | None = None
        self.job_resources = None
        self.machine_position = np.zeros(3)
        self.current_tool = None
        self.toolpath_segments = 0
        self.measure_points: list[MeasurePoint] = []
        self.restoring_project = False
        self._loading_prefs = True
        self.showChipGuards = bool(AppSettings.value("showChipGuards", True))
        self.realistic = bool(AppSettings.value("realistic", True))
        self._loading_prefs = False
        self.scene.add(SceneLines("axes", axes_segments(20)))

    # ------------------------------------------------------------ basics

    def _remember(self, key: str, value, then) -> None:
        if not SCRIPTED and not getattr(self, "_loading_prefs", True):
            AppSettings.set_value(key, value)
        if not getattr(self, "_loading_prefs", True):
            then()

    def _set_lines_visible(self, id: str, on: bool) -> None:
        ln = self.scene.line_set(id)
        if ln is not None:
            ln.visible = on

    @staticmethod
    def linear_swatch(material) -> tuple[float, float, float]:
        return tuple(linear_swatch(material))

    def touch(self) -> None:
        """Something the inspectors show changed."""
        self.revision = self.revision + 1
        self.changed.emit()

    @property
    def machine(self) -> MachineProfile:
        return self.planning_machine_reference.profile

    @property
    def inventory(self):
        return self.inventory_model.inventory

    def stock_lookup(self, id):
        return next((s for s in self.inventory.stock if s.id == id), None)

    def tool_lookup(self, id):
        return next((t for t in self.inventory.tools if t.id == id), None)

    def fixture_lookup(self, id):
        return next((f for f in self.inventory.fixtures if f.id == id), None)

    # ------------------------------------------------------------ setup and stock (with Swift's didSet side effects)

    @property
    def setup(self) -> Setup:
        return self._setup

    @setup.setter
    def setup(self, value: Setup) -> None:
        if value == self._setup:
            return
        self._setup = value
        self.clear_toolpath_results()
        self.layout_scene()
        self.save_session()
        self.schedule_analysis()
        self.keep_stock_workable()
        self.note_project_change()
        self.touch()

    def change_setup(self, change) -> None:
        """Edits a copy of the setup and assigns it (so the side effects run once)."""
        s = self._setup.copy()
        change(s)
        self.setup = s

    @property
    def stock_id(self) -> str | None:
        return self._stock_id

    @stock_id.setter
    def stock_id(self, value: str | None) -> None:
        if value == self._stock_id:
            return
        self._stock_id = value
        snap = self.stock_snapshot
        if snap is None or snap.id != value:
            self.stock_snapshot = self.stock_lookup(value) if value is not None else None
        self.clear_toolpath_results()
        self.layout_scene()
        self.save_session()
        self.keep_stock_workable()
        self.note_project_change()
        self.touch()

    @property
    def stock(self):
        """Jobs keep their selected definitions even if the library is edited or removed."""
        if self._stock_id is None:
            return None
        snap = self.stock_snapshot
        return snap if snap is not None and snap.id == self._stock_id else self.stock_lookup(self._stock_id)

    @property
    def stock_snapshot(self):
        return self.job_resources.stock if self.job_resources is not None else None

    @stock_snapshot.setter
    def stock_snapshot(self, item) -> None:
        from ...core.inventory.snapshot import JobResourceSnapshot
        if self.job_resources is None:
            self.job_resources = JobResourceSnapshot()
        if item is not None:
            import copy
            item = copy.deepcopy(item)
            if item.material_snapshot is None:
                item.material_snapshot = item.material
        self.job_resources.stock = item

    # ------------------------------------------------------------ engine

    def connected_engine(self) -> EngineClient:
        """Blocking: call from work (yield Work(...))."""
        if self._engine is None:
            self._engine = EngineClient()
        return self._engine

    def live_engine(self):
        """A task step: the engine, restarted if it died, with the part imported into the new one."""
        e = self._engine
        if e is not None and e.is_running():
            return e
        restarted = e is not None
        self._engine = None
        engine = yield Work(self.connected_engine)
        if restarted and self.part is not None:
            mesh = yield Work(lambda: engine.import_part(self.part.path))
            self.part.part_id = mesh.part_id
            self.status = f"The geometry engine restarted; {self.part.file_name} was loaded into it again."
        return engine

    def shutdown(self) -> None:
        if self._engine is not None:
            self._engine.shutdown()
            self._engine = None

    # ------------------------------------------------------------ machine display

    def apply_machine_display(self) -> None:
        geometry = self.planning_geometry
        for m in self.scene.meshes.values():
            if not m.id.startswith("machine."):
                continue
            parts = m.id.split(".")
            group = self.machine_scene_components.get(m.id) or (parts[1] if len(parts) > 1 else "static")
            role = self.machine_scene_roles.get(m.id) or (parts[2] if len(parts) > 2 else "")
            moving = geometry.is_moving(group) if geometry is not None else group != "static"
            shell = geometry.is_enclosure(group) if geometry is not None else role.startswith("enclosure")
            if self.fixture_placement is not None:
                m.visible = moving and not shell and not role.endswith("guard")
                m.color = (*m.color[:3], 1.0)
                continue
            d = self.machineDisplay
            m.color = (*m.color[:3], (0.12 if shell else 0.24) if d == "ghost" else 1.0)
            m.visible = {"ghost": True, "full": True, "open": not shell, "moving": moving and not shell, "hidden": False}[d]
            if role.endswith("guard"):
                m.color = (*m.color[:3], 0.1 if d == "ghost" else 0.2)
                if not self.showChipGuards:
                    m.visible = False
            if self.isolateWork or self.showing_stock_only:
                m.visible = False
        self.apply_fixture_display()
        self.apply_surfaces()
        self.update_pivot()

    def update_pivot(self) -> None:
        """Orbit around the centre of the mill while it's shown, otherwise around the work."""
        shown = (self.machineDisplay != "hidden" and self.machineLoaded and not self.showing_stock_only
                 and not self.isolateWork and self.fixture_placement is None)
        los, his = [], []
        for m in self.scene.meshes.values():
            if m.visible and (m.id.startswith("machine.") if shown else m.id in ("part", "stock")):
                lo, hi = world_bounds(self.scene, m)
                los.append(lo)
                his.append(hi)
        self.renderer.set_pivot((np.min(los, 0) + np.max(his, 0)) / 2 if los else None)

    # ------------------------------------------------------------ layout

    def work_origin(self, stock_size) -> np.ndarray:
        return self.work_to_model(stock_size)

    def work_to_model(self, stock_size) -> np.ndarray:
        """Where the work origin (centre of the stock face toward the spindle) sits in the model,
        with the table at the model's pose: in the job's fixture, centred on the Y travel."""
        fp = self.fixture_placement
        if fp is not None and fp.fixture is not None:
            return self.library_origin(fp.fixture, stock_size)
        return self.custom_work_origin(stock_size)

    def custom_work_origin(self, s) -> np.ndarray:
        from .smart_plan import StandInVise
        fixture = self.displayed_job_fixture
        stand_in = fixture is None and self.shows_stand_in_vise
        table = self.table_geometry
        height = fixture.height if fixture is not None else StandInVise.FLOOR if stand_in else self.setup.custom_fixture.height
        past = ((fixture.planning.face_past_table if fixture is not None and fixture.planning is not None else 2.0) if fixture is not None
                else StandInVise.FACE_PAST if stand_in else self.setup.custom_fixture.face_protrusion)
        return np.array([table.top_x + height + s[0] / 2, self.travel_centre_y, table.north_z + past])

    def machine_origin(self, stickout: float, model_origin=None) -> np.ndarray | None:
        """Where work X0 Y0 Z0 is in machine coordinates for a tool sticking out `stickout`."""
        mm = self.machine_model
        if mm is None:
            return None
        if model_origin is None:
            stock = self.stock
            if stock is None:
                return None
            model_origin = self.custom_work_origin(self.setup.stock_size(stock))
        t, m, o = self.tip_at_model_pose(stickout), mm.model_pose, model_origin
        return np.array([m.x - t[0] + o[0], m.y + o[1] - t[1], m.z + o[2] - t[2]])

    @property
    def shows_machining_results(self) -> bool:
        return self.fixture_placement is None and self.stage in ("machining", "review")

    @property
    def display_stock_size(self) -> np.ndarray | None:
        if self.fixture_placement is not None:
            return self.placement_stock_size
        stock = self.stock
        if stock is None:
            return None
        if self.showing_stock_only:
            return np.asarray(self.setup.raw_stock_size(stock), float)  # stage 1: as bought
        return np.asarray(self.setup_for(self.viewSide if self.viewSide >= 2 else 0).stock_size(stock), float)

    @property
    def travel_centre_y(self) -> float:
        """Model y of the spindle axis when the gantry is in the middle of its Y travel."""
        mm = self.machine_model
        if mm is None:
            return 0.0
        e = self.machine.machine_envelope.y
        return mm.spindle_nose.y + ((e.lower + e.upper) / 2 - mm.model_pose.y)

    def layout_scene(self) -> None:
        """Re-places the part, stock and markers after any setup change."""
        if getattr(self, "_in_layout", False):
            return
        self._in_layout = True
        try:
            self._layout_scene()
        finally:
            self._in_layout = False

    def _layout_scene(self) -> None:
        scene = self.scene
        stock_size = self.display_stock_size
        if stock_size is None:
            stock_size = np.zeros(3)
        origin = self.work_to_model(stock_size)
        part_origin = origin.copy()
        mesh = scene.mesh("part")
        if mesh is not None:
            mesh.visible = True
        part = self.part
        if part is not None and mesh is not None:
            side = self.viewSide if (self.twoSided or self.viewSide >= 2) else 0
            t = translation(part_origin) @ self.setup_for(side).part_to_work(part.bounds_min, part.bounds_max)
            if self.stage == "partStock" and self.fixture_placement is None:
                # Inspect the CAD by itself: no stock, fixture or moving machine group.
                k = self.setup.part_scale
                centre = (part.bounds_min + part.bounds_max) / 2
                t = np.diag([k, k, k, 1.0])
                t[:3, 3] = -centre * k
                mesh.group = None
            else:
                mesh.group = "x"
            mesh.transform = t
        for id in ("toolpath", "simstock", "simstock.back", "simstock.walls", "simstock.loose", "tabs"):
            for item in (scene.line_set(id), scene.mesh(id)):
                if item is not None:
                    item.visible = True
        tp = scene.line_set("toolpath")
        if tp is not None:
            tp.visible = self.pathsVisible
        scene.remove("stock")
        scene.remove("stock.edges")
        stock = self.stock
        if stock is not None:
            front, back = self.display_stock_trim
            lo = np.array([-stock_size[0] / 2, -stock_size[1] / 2, -stock_size[2] + back]) + origin
            hi = np.array([stock_size[0] / 2, stock_size[1] / 2, -front]) + origin
            c = linear_swatch(stock.material)
            scene.add(box_mesh("stock", lo, hi, (*c, 0.22)))
            scene.add(SceneLines("stock.edges", box_segments(lo, hi, SceneColor.edge)))
        self.layout_clamps(stock_size)
        self.layout_in_process_stock(stock_size, origin)
        self.layout_tabs(part_origin)
        self.layout_work_area(stock_size, part_origin)
        if self.showing_stock_only or self.fixture_placement is not None:
            for id in ("workarea", "workarea.edges"):
                for item in (scene.mesh(id), scene.line_set(id)):
                    if item is not None:
                        item.visible = False
        self.cut_face_key = ""
        self.layout_cut_face()
        if self.showing_stock_only or not self.shows_machining_results:
            # The stock as bought, or a setup step: the plain stock, never a simulated one.
            for id in ("toolpath", "clearance"):
                ln = scene.line_set(id)
                if ln is not None:
                    ln.visible = False
            for id in ("simstock", "simstock.back", "simstock.walls", "simstock.loose", "tool", "tool.shank"):
                m = scene.mesh(id)
                if m is not None:
                    m.visible = False
            m = scene.mesh("stock")
            if m is not None:
                m.visible = True
        self.apply_machine_display()
        self.apply_stock_display()
        self.apply_section()
        self.refresh_measure_markers()
        self.show_undercuts()
        if not self.timeline.entries:
            self.park_machine()
        self.update_pivot()
        self.layout_gumball()
        self.layout_engraving_preview()

    def apply_fixture_display(self) -> None:
        """Fixtures follow the machine display: see-through when the machine is ghosted."""
        for m in self.scene.meshes.values():
            if not m.id.startswith("fixture."):
                continue
            clear = m.material.metallic == 0 and m.material.roughness <= 0.05  # insulators
            m.color = (*m.color[:3], 0.35 if clear else 0.5 if self.machineDisplay == "ghost" else 1.0)
            if self.fixture_placement is not None:
                m.visible = m.id.startswith(self.PLACEMENT_MESH_PREFIX)
            elif self.isolateWork or self.showing_stock_only:
                m.visible = False

    def layout_tabs(self, origin) -> None:
        """The holding tabs, as outlines over their Z range, on the side that cuts through."""
        self.scene.remove("tabs")
        r = self.tab_z
        if not (((self.twoSided and self.holdWithTabs) or self.cuts_through_with_tabs) and self.viewSide == self.tab_side
                and self.placed_tabs and r is not None):
            return
        bottom, top = r.lower, r.upper
        pairs = []
        for t in self.placed_tabs:
            c = t.corners
            if len(c) < 3:
                continue
            for k in range(len(c)):
                a, n = c[k], c[(k + 1) % len(c)]
                for z in (bottom, top):
                    pairs.append(((a[0], a[1], z), (n[0], n[1], z)))
                pairs.append(((a[0], a[1], bottom), (a[0], a[1], top)))
        if pairs:
            seg = segments(np.array(pairs) + np.asarray(origin, float), SceneColor.highlight)
            self.scene.add(SceneLines("tabs", seg))

    def tool_changed(self) -> None:
        """Another tool came into the spindle (playback): only the work area moves with it."""
        if self.showing_stock_only:
            self.layout_scene()
            return
        size = self.display_stock_size
        if size is None:
            size = np.zeros(3)
        self.layout_work_area(size, self.work_to_model(size))

    def layout_work_area(self, stock_size, origin) -> None:
        """Every point the tool tip can reach, in the table's frame (drawn on the table)."""
        self.scene.remove("workarea")
        self.scene.remove("workarea.edges")
        if self.machine_model is None or not self.showWorkArea:
            return
        lo, hi = self.reach_box()
        self.scene.add(box_mesh("workarea", lo, hi, SceneColor.surface(0.9, 0.06)))
        self.scene.add(SceneLines("workarea.edges", box_segments(lo, hi, SceneColor.line(170, 254))))

    # ------------------------------------------------------------ kinematics

    def tip_at_model_pose(self, stickout: float | None = None) -> np.ndarray:
        mm = self.machine_model
        if mm is None:
            return np.zeros(3)
        s = self.current_stickout if stickout is None else stickout
        return np.array([mm.spindle_nose.x, mm.spindle_nose.y, mm.spindle_nose.z - s])

    @property
    def current_stickout(self) -> float:
        return self.current_tool.stickout if self.current_tool is not None else NOMINAL_STICKOUT

    def reach_box(self) -> tuple[np.ndarray, np.ndarray]:
        """The reachable box of the tool tip in the table frame (table at the modelled pose)."""
        mm = self.machine_model
        if mm is None:
            return np.zeros(3), np.zeros(3)
        t, p, e = self.tip_at_model_pose(), mm.model_pose, self.machine.machine_envelope
        xs = [t[0] - (p.x - e.x.lower), t[0] - (p.x - e.x.upper)]
        ys = [t[1] + (e.y.lower - p.y), t[1] + (e.y.upper - p.y)]
        zs = [t[2] + (e.z.lower - p.z), t[2] + (e.z.upper - p.z)]
        return np.array([min(xs), min(ys), min(zs)]), np.array([max(xs), max(ys), max(zs)])

    def machine_mapper(self, stickout: float | None = None):
        """Work → machine coordinates for one tool (the work origin needs the whole placement)."""
        mm, stock = self.machine_model, self.stock
        if mm is None or stock is None:
            return None
        size = self.display_stock_size
        if size is None:
            size = self.setup.stock_size(stock)
        o = self.work_to_model(size)
        t = self.tip_at_model_pose(self.current_stickout if stickout is None else stickout)
        m = mm.model_pose

        def f(p):
            dx, dy, dz = t[0] - (o[0] + p[0]), o[1] + p[1] - t[1], o[2] + p[2] - t[2]
            return np.array([m.x - dx, m.y + dy, m.z + dz])
        return f

    def machine_position_for_work(self, p, stickout: float | None = None):
        f = self.machine_mapper(stickout)
        return f(p) if f is not None else None

    def set_machine_position(self, q) -> None:
        """Moves the machine's table, translator and spindle to machine coordinates."""
        mm = self.machine_model
        if mm is None:
            return
        q = np.asarray(q, float)
        geometry = self.planning_geometry
        if geometry is not None:
            try:
                translations = geometry.component_translations(Vec3(*q))
            except Exception as e:  # noqa: BLE001
                self.errorMessage = str(e)
                return
            transforms = {"profile." + id: translation((p.x, p.y, p.z)) for id, p in translations.items()}
            transforms["x"] = transforms["profile." + geometry.table_component_id]
            transforms["z"] = transforms["profile." + geometry.head_component_id]
            self.scene.group_transforms = transforms
            self.scene._touch()
            self.machine_position = q
            return
        m = mm.model_pose
        self.scene.group_transforms["x"] = translation((m.x - q[0], 0, 0))
        self.scene.group_transforms["y"] = translation((0, q[1] - m.y, 0))
        self.scene.group_transforms["z"] = translation((0, q[1] - m.y, q[2] - m.z))
        self.scene._touch()
        self.machine_position = q

    def park_machine(self) -> None:
        """Parks the tool 10 mm above the work origin (or at home if that's out of reach)."""
        if self.machine_model is None:
            return
        if self.current_tool is not None:
            self.ensure_tool_mesh(self.current_tool)
        env = self.machine.machine_envelope
        q = self.machine_position_for_work((0, 0, 10))
        if q is not None:
            self.set_machine_position([env.x.clamp(q[0]), env.y.clamp(q[1]), env.z.clamp(q[2])])
        else:
            home = self.machine.home_position or Vec3(env.x.lower, env.y.upper, env.z.upper)
            self.set_machine_position([home.x, home.y, home.z])

    def travel_problem(self, q) -> str | None:
        e = self.machine.machine_envelope
        out = []
        for name, v, r in (("X", q[0], e.x), ("Y", q[1], e.y), ("Z", q[2], e.z)):
            if v not in r:
                over = r.lower - v if v < r.lower else v - r.upper
                out.append(f"{name} by {Length.mm(over)} mm")
        return None if not out else "Beyond the machine's travel: " + ", ".join(out)

    # ------------------------------------------------------------ import

    @Slot(str)
    def openPart(self, url: str) -> None:
        from PySide6.QtCore import QUrl
        path = QUrl(url).toLocalFile() if "://" in str(url) else str(url)
        spawn(self.import_part(Path(path)), "import")

    def import_part(self, path: Path):
        self.isBusy = True
        self.status = f"Importing {path.name}…"
        self.errorMessage = ""
        try:
            new_part = self.part is None or Path(self.part.path).resolve() != Path(path).resolve()
            engine = yield from self.live_engine()
            mesh = yield Work(lambda: engine.import_part(path))
            # Another part: threads and engraving were for the last one's holes and faces.
            if self.part is not None and new_part:
                from ...core.feeds import OperationKind
                self.operations = [o for o in self.operations if o.kind not in (OperationKind.THREAD, OperationKind.ENGRAVE)]
            if not len(mesh.indices):
                raise EngineError("Empty", "The file has no surfaces to show.")
            self.scene.add(SceneMesh("part", mesh.vertices, mesh.normals, mesh.indices, SceneColor.part, pickable=True))
            self.analysis = None
            self.analysis_failed = False
            self.features = None
            self.features_key = None
            self.select_finding(None)
            self.part_mesh_data = (mesh.vertices, mesh.normals, mesh.indices)
            self.scene.remove_prefix("part.copy.")
            lo = np.array([mesh.bounds_min.x, mesh.bounds_min.y, mesh.bounds_min.z])
            hi = np.array([mesh.bounds_max.x, mesh.bounds_max.y, mesh.bounds_max.z])
            ext = Path(path).suffix[1:].upper()
            self.part = PartInfo(Path(path), Path(path).name, f"{ext} · exact NURBS" if mesh.exact else f"{ext} · render mesh",
                                 mesh.exact, mesh.face_count, mesh.triangle_count, mesh.size, lo, hi, mesh.part_id, list(mesh.warnings))
            s = self.setup.copy()
            if new_part and not self.restoring_project:
                # A new part starts a new proposal: not the old job's scale, offsets and operations.
                axes = s.stock_axes
                s = Setup().selecting_holding(Workholding.CUSTOM)
                s.stock_axes = axes
                s.plan_from_fixture_library = True
                self.operations = []
                self.holdWithTabs = False
            s.facing, s.spin = Setup.default_orientation(lo, hi)
            self.setup = s
            if new_part:
                self.enter("partStock")
            self.two_sided_chosen = False
            self.clear_measurements()
            self.keep_stock_workable()
            self.layout_scene()
            self.set_view("iso")
            self.focus_work()
            self.watch_part_file(Path(path))
            self.schedule_analysis()
            self.status = f"Imported {Path(path).name}"
            self.save_session()
            self.touch()
        except Exception as e:  # noqa: BLE001
            self.errorMessage = str(e)
            self.status = "Import failed"
        finally:
            self.isBusy = False

    @Slot(str)
    def setView(self, view: str) -> None:
        self.set_view(view)

    def set_view(self, view: str) -> None:
        """Standard views are engineering views: always orthographic, eased from the current view."""
        self.perspective = False

        def change(c):
            c.orthographic = True
            c.set_view(view)
        self.renderer.move_camera(change)

    def look_from(self, direction) -> None:
        self.perspective = False

        def change(c):
            c.orthographic = True
            c.look(direction)
        self.renderer.move_camera(change)

    @staticmethod
    def display_color(role: str, c) -> tuple[float, float, float]:
        """Machine parts in the monotone palette: each its own grey, the E-stop red (safety)."""
        if role == "estop":
            return tuple(c)
        if role == "pcb":
            return (0.022, 0.022, 0.022)
        if role == "guard":
            return (0.9, 0.9, 0.9)
        if role == "enclosure":
            return (0.42, 0.42, 0.42)
        g = SceneColor.luminance(c)
        return (g, g, g)

    @Slot()
    def focusWorkSlot(self) -> None:
        self.focus_work()

    def focus_work(self, fixtures: bool = True, machine_context: bool = False) -> None:
        """Frames the stock, part and clamps where the table currently is."""
        los, his = [], []
        geometry = self.planning_geometry
        for m in self.scene.meshes.values():
            ctx = False
            if machine_context:
                comp = self.machine_scene_components.get(m.id)
                if geometry is not None and comp is not None:
                    ctx = geometry.is_moving(comp) and not geometry.is_enclosure(comp)
                else:
                    ctx = m.id.startswith("machine.x.") or m.id.startswith("machine.z.")
            if (m.id in ("part", "stock") or (fixtures and m.id.startswith("fixture.")) or ctx) and m.visible:
                lo, hi = world_bounds(self.scene, m)
                los.append(lo)
                his.append(hi)
        if not los:
            return
        lo, hi = np.min(los, 0), np.max(his, 0)
        if not lo[0] < hi[0]:
            return
        c = (lo + hi) / 2
        half = np.maximum((hi - lo) / 2 * 1.3, 35)
        self.renderer.frame(c - half, c + half, animated=True)

    # ------------------------------------------------------------ stock choice

    @Slot(str)
    def useStockId(self, id: str) -> None:
        item = self.stock_lookup(id)
        if item is not None:
            self.use_stock(item)

    def use_stock(self, item) -> None:
        """Picks a sensible default orientation for the stock (thinnest toward the spindle)."""
        self.clear_toolpath_results()
        self.stock_snapshot = item
        s = self.setup.copy()
        s.stock_axes = self.best_stock_axes(item) or Setup.default_stock_axes(item)
        if self.part is not None:
            lo, hi = s.rotated_part_bounds(self.part.bounds_min, self.part.bounds_max)
            s.top_allowance = min(max(s.top_allowance, 0), max(s.stock_size(item)[2] - (hi[2] - lo[2]), 0))
        self.setup = s
        self.stock_id = item.id
        self.save_session()
        self.note_project_change()
        self.focus_work()
        self.touch()

    def stock_edited(self, item) -> None:
        """The stock in use was edited: keep how it sits if that still works, and plan again."""
        self.stock_snapshot = item
        if item.id != self.stock_id:
            self.use_stock(item)
            return
        keep = any(o.axes == self.setup.stock_axes and o.workable for o in self.stock_options(item))
        self.clear_toolpath_results()
        s = self.setup.copy()
        if not keep:
            s.stock_axes = self.best_stock_axes(item) or Setup.default_stock_axes(item)
        if s != self.setup:
            self.setup = s
        else:
            self.layout_scene()
            self.save_session()
            self.keep_stock_workable()
            self.note_project_change()
        self.focus_work()

    def standard_stock_that_fits(self, limit: int = 3) -> list:
        """Standard sizes to buy that hold the part, the least material first (same family first)."""
        stock = self.stock
        family = stock.material.family if stock is not None and stock.material is not None else None
        fits = [s for s in self.inventory.stock if s.is_suggestion and s.id != self.stock_id
                and any(o.workable for o in self.stock_options(s))]
        fits.sort(key=lambda s: (0 if s.material is not None and s.material.family == family else 1, s.volume))
        return fits[:limit]

    def stock_options(self, item=None) -> list:
        part, stock = self.part, item or self.stock
        if part is None or stock is None:
            return []
        lo, hi = self.setup.rotated_part_bounds(part.bounds_min, part.bounds_max)
        return stock_options(stock, np.asarray(hi) - np.asarray(lo), self.setup.stock_axes, self.settings.display_units)

    def best_stock_axes(self, item) -> list[int] | None:
        return next((o.axes for o in self.stock_options(item) if o.workable), None)

    def use_stock_axes(self, axes) -> None:
        self.change_setup(lambda s: setattr(s, "stock_axes", list(axes)))

    def keep_stock_workable(self) -> None:
        """When the part or sides change and the stock no longer fits as it sits, turn it."""
        stock, part = self.stock, self.part
        if stock is None or part is None:
            return
        lo, hi = self.setup.rotated_part_bounds(part.bounds_min, part.bounds_max)
        max_top = max(self.setup.stock_size(stock)[2] - (hi[2] - lo[2]), 0)
        if self.setup.top_allowance > max_top or self.setup.top_allowance < 0:
            self._setup.top_allowance = min(max(self._setup.top_allowance, 0), max_top)
        current = next((o for o in self.stock_options() if o.axes == self.setup.stock_axes), None)
        if current is None or current.workable:
            return
        best = self.best_stock_axes(stock)
        if best is None:
            return
        self.use_stock_axes(best)
        summary = next((o.summary for o in self.stock_options() if o.axes == best), "")
        self.status = f"The stock was turned so the part fits: {summary}."

    @property
    def setup_issues(self) -> list:
        return [] if self.stock is None else self.stock_containment_issues + self.collision_issues

    @property
    def stock_containment_issues(self) -> list:
        part, stock = self.part, self.stock
        if part is None or stock is None:
            return []
        return SetupChecks.check(self.setup, part.bounds_min, part.bounds_max, stock, self.machine)

    # ------------------------------------------------------------ section

    def apply_section(self) -> None:
        scene = self.scene
        scene.remove("section.plane")
        scene.remove("section.edges")
        if not self.sectionOn:
            scene.clip_plane = np.zeros(4)
            return
        stock = self.stock
        size = np.asarray(self.setup.stock_size(stock), float) if stock is not None else np.zeros(3)
        origin = self.work_to_model(size)
        centre = origin + np.array([0, 0, -size[2] / 2])
        part, mesh = self.part, scene.mesh("part")
        if part is not None and mesh is not None:
            c = (part.bounds_min + part.bounds_max) / 2
            centre = transform_points(mesh.transform, c)[0]
        n = {"x": np.array([1.0, 0, 0]), "y": np.array([0, 1.0, 0]), "z": np.array([0, 0, 1.0])}[self.sectionAxis]
        d = float(n @ centre) + self.sectionOffset
        scene.clip_plane = np.array([*n, d])
        # The cut plane itself, a hair on the kept side, so the section doesn't float in space.
        half = max(size[0], size[1], size[2], 40) * 0.75
        at = centre + n * (self.sectionOffset - 0.02)
        u, v = {"x": ((0, 1, 0), (0, 0, 1)), "y": ((1, 0, 0), (0, 0, 1)), "z": ((1, 0, 0), (0, 1, 0))}[self.sectionAxis]
        u, v = np.array(u, float), np.array(v, float)
        corners = np.array([at - u * half - v * half, at + u * half - v * half, at + u * half + v * half, at - u * half + v * half])
        scene.add(SceneMesh("section.plane", corners, np.tile(-n, (4, 1)), [0, 1, 2, 0, 2, 3], SceneColor.surface(0.9, 0.10)))
        scene.add(SceneLines("section.edges", segments([(corners[k], corners[(k + 1) % 4]) for k in range(4)], SceneColor.line(225))))

    # ------------------------------------------------------------ measuring

    @Slot(float, float)
    def viewportClicked(self, x: float, y: float) -> None:
        """A click in the viewport (no drag)."""
        if self.fixture_placement is not None:
            self.handle_placement_click(x, y)
            return
        if not self.measuring:
            return
        view = self.renderer.view
        if view is None:
            return
        hit = view.pick(x, y)
        if hit is None or hit[0] != "part":
            self.status = "Click on the part to measure"
            return
        if len(self.measure_points) >= 2:
            self.measure_points = []
        self.measure_points.append(MeasurePoint(np.asarray(hit[1], float)))
        index = len(self.measure_points) - 1
        self.refresh_measure_markers()
        self.touch()
        part = self.part
        if part is None or not part.exact:
            return
        local = hit[2]

        def info():
            try:
                engine = yield from self.live_engine()
                fi = yield Work(lambda: engine.face_info(part.part_id, Vec3(*map(float, local))))
                if index < len(self.measure_points):
                    self.measure_points[index].info = fi
                    self.touch()
            except Exception as e:  # noqa: BLE001
                self.status = f"Measuring failed: {e}"
        spawn(info())

    @property
    def measured_distance(self) -> float | None:
        if len(self.measure_points) != 2:
            return None
        return float(np.linalg.norm(self.measure_points[0].world - self.measure_points[1].world))

    @property
    def measured_delta(self):
        if len(self.measure_points) != 2:
            return None
        return self.measure_points[1].world - self.measure_points[0].world

    @Slot()
    def clearMeasurements(self) -> None:
        self.clear_measurements()

    def clear_measurements(self) -> None:
        self.measure_points = []
        self.refresh_measure_markers()
        self.touch()

    def refresh_measure_markers(self) -> None:
        self.scene.remove("measure")
        if not self.measure_points:
            return
        s = 1.5
        pairs = []
        for p in self.measure_points:
            w = p.world
            for axis in np.identity(3):
                pairs.append((w - axis * s, w + axis * s))
        if len(self.measure_points) == 2:
            pairs.append((self.measure_points[0].world, self.measure_points[1].world))
        self.scene.add(SceneLines("measure", segments(pairs, SceneColor.highlight)))

    # ------------------------------------------------------------ session (restored on next launch)

    def save_session(self) -> None:
        if SCRIPTED or getattr(self, "restoring_session", False):
            return
        stock = self.stock
        s = {"partPath": str(self.part.path) if self.part is not None else None, "setup": self.setup.to_json(),
             "stockID": self.stock_id, "machine": codable.to_json(self.planning_machine_reference),
             "stock": codable.to_json(stock) if stock is not None else None}
        AppSettings.set_value(SESSION_KEY, json.dumps({k: v for k, v in s.items() if v is not None}))

    @staticmethod
    def last_session_part() -> Path | None:
        raw = AppSettings.value(SESSION_KEY, None)
        if not raw:
            return None
        try:
            p = json.loads(raw).get("partPath")
        except ValueError:
            return None
        return Path(p) if p and Path(p).exists() else None

    def restore_session(self):
        """A task: restores the last part, stock and setup. Skipped during automation runs."""
        if SCRIPTED:
            return
        raw = AppSettings.value(SESSION_KEY, None)
        if not raw:
            return
        try:
            s = json.loads(raw)
            setup = Setup.from_json(s["setup"])
            machine = codable.from_json(PlanningMachineReference, s["machine"]) if s.get("machine") else PlanningMachineReference.legacy()
            stock = codable.from_json(_stock_type(), s["stock"]) if s.get("stock") else None
        except Exception:  # noqa: BLE001 — an unreadable session is just not restored
            return
        try:
            yield from self.restore_planning_machine(machine)
        except Exception as e:  # noqa: BLE001
            self.errorMessage = str(e)
            return
        self.restoring_session = True
        try:
            self.stock_snapshot = stock if stock is not None else (self.stock_lookup(s.get("stockID")) if s.get("stockID") else None)
            self.stock_id = s.get("stockID")
        finally:
            self.restoring_session = False
        path = s.get("partPath")
        if path and Path(path).exists():
            yield from self.import_part(Path(path))
        self.setup = setup
        yield from self.reload_saved_library_geometry()

    # ------------------------------------------------------------ results

    def clear_toolpath_results(self) -> None:
        """Generated results no longer match the inputs: drop them (paths, programs, simulation)."""
        from ...core.post.timeline import ToolpathTimeline
        self.pause()
        self.in_process_snapshots = {}
        self.in_process_meshes = {}
        if not self.is_generating:
            self.op_gen_state = {}
        self.programs = []
        self.library_workholding_plan = None
        self.selected_library_step = None
        self.side_results = []
        self.placed_tabs = []
        self.placed_tab_z = None
        self.scene.remove("tabs")
        self.timeline = ToolpathTimeline()
        self.inspected = None
        for id in ("toolpath", "tool", "tool.shank", "simstock", "simstock.back", "simstock.walls", "simstock.loose", "clearance"):
            self.scene.remove(id)
        self.loose_pieces = 0
        t = getattr(self, "side_a_final_task", None)
        if t is not None:
            t.cancel()
        self.side_a_final = None
        self.side_a_final_key = -1
        m = self.scene.mesh("stock")
        if m is not None:
            m.visible = True
        self.heightmap = None
        self.toolpath_segments = 0


def _stock_type():
    from ...core.inventory.items import StockItem
    return StockItem


def linear_swatch(material) -> tuple[float, float, float]:
    """The material's swatch in linear RGB for the viewport."""
    from .swatches import swatch
    c = swatch(material) if material is not None else (0.5, 0.5, 0.5)
    return tuple(float(v) ** 2.2 for v in c)
