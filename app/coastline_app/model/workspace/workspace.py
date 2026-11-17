"""The workspace: every mixin (one per Swift file of the app model) composed onto WorkspaceCore.
QML reads state through slots that depend on `revision`; long work runs as tasks (tasks.py)."""

from __future__ import annotations

from PySide6.QtCore import QObject, QTimer, Slot

from ..machine_profiles import MachineProfileLibrary
from ..tasks import spawn
from .analysis import AnalysisMixin
from .appearance import AppearanceMixin
from .collision_check import CollisionCheckMixin
from .core import WorkspaceCore
from .ui import WorkspaceUI
from .cut_face import CutFaceMixin
from .fixture_placement import FixturePlacementMixin
from .generation import BackgroundGenerationMixin
from .guided_export import GeneratedProgramsMixin, GuidedExportMixin
from .gumball import GumballMixin
from .job_steps import JobStepsMixin
from .library_workholding import LibraryWorkholdingMixin
from .machining import MachiningMixin
from .planning_machine import PlanningMachineMixin
from .playback import PlaybackMixin
from .project_document import ProjectDocumentMixin
from .reach import ReachMixin
from .scene_layout import SceneLayoutMixin
from .side_setups import SideSetupsMixin
from .smart_plan import SmartPlanMixin
from .stage_transition import StageTransitionMixin
from .stages import StagesMixin
from .state import StateMixin
from .tab_check import TabCheckMixin
from .tool_change import ToolChangeMixin
from .vetted_fixtures import VettedFixturesMixin


class _DragHandler:
    """The viewport hands left-button drags here first (the gumball and fixture placement)."""

    def __init__(self, ws) -> None:
        self.ws = ws

    def begin(self, x: float, y: float) -> bool:
        return self.ws.gumball_begin(x, y)

    def move(self, x: float, y: float) -> None:
        self.ws.gumball_move(x, y)

    def end(self) -> None:
        self.ws.gumball_end()


class Workspace(StateMixin, SmartPlanMixin, SideSetupsMixin, StageTransitionMixin, AnalysisMixin, CutFaceMixin, ReachMixin, TabCheckMixin,
                BackgroundGenerationMixin, MachiningMixin, PlaybackMixin, CollisionCheckMixin, ToolChangeMixin, GumballMixin,
                FixturePlacementMixin, SceneLayoutMixin, ProjectDocumentMixin, GuidedExportMixin, GeneratedProgramsMixin, JobStepsMixin, PlanningMachineMixin,
                StagesMixin, AppearanceMixin, LibraryWorkholdingMixin, VettedFixturesMixin, WorkspaceUI):
    def __init__(self, inventory, journal, settings, mill, parent: QObject | None = None) -> None:
        self._touch_pending = False
        WorkspaceCore.__init__(self, inventory, journal, settings, mill, parent)
        self.init_state()
        self.machine_profiles = MachineProfileLibrary(self)
        self.pending_seek = None
        self.jobs = None  # JobsModel (set by AppRoot)
        self.drag_handler = _DragHandler(self)
        # Navigation (set by AppRoot): the sidebar page, and a tool to show on the Tools page.
        self.navigate = lambda page: None
        self.navigate_to_tool = lambda tool_id: None
        self.page_hint = lambda: "workspace"
        self.last_snapshot = self.project_snapshot

    def touch(self) -> None:
        """Something the inspectors show changed: one revision bump per event-loop turn."""
        if getattr(self, "_touch_pending", False):
            return
        self._touch_pending = True

        def fire() -> None:
            self._touch_pending = False
            WorkspaceCore.touch(self)

        QTimer.singleShot(0, fire)

    def start(self) -> None:
        """The engine, the machine and the last session, in the background."""
        def run():
            try:
                engine = yield from self.live_engine()
                info = engine.ping()
                self.status = "Ready"
            except Exception as e:  # noqa: BLE001
                self.status = f"The geometry engine did not start. {e}"
                return
            yield from self.load_machine()
            yield from self.restore_session()
            self.touch()

        spawn(run(), "workspace start")

    def open_path_task(self, path):
        """A task: opens a job (.coastline) or imports a part (launch argument, drops)."""
        from pathlib import Path
        if Path(path).suffix.lower() == ".coastline":
            yield from self.open_project(Path(path))
        else:
            yield from self.import_part(Path(path))

    # ---------------------------------------------------------------- the 3D view

    @Slot(QObject)
    def attachViewport(self, view) -> None:
        self.renderer.attach(view)
        view.drag_handler = self.drag_handler

    @Slot(QObject)
    def detachViewport(self, view) -> None:
        self.renderer.detach(view)
        view.drag_handler = None
