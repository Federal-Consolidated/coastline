"""The workspace's stored state (AppModel's stored properties) and what changing each one does
(Swift's didSet). Plain Python properties: QML sees changes through `revision` (touch())."""

from __future__ import annotations

import os

from ...core.plan.holding_tabs import HoldingTabs
from ...core.plan.tuning import Tuning
from ...core.post.timeline import ToolpathTimeline
from ..settings import AppSettings

SCRIPTED = "COASTLINE_SCRIPT" in os.environ


def didset(name: str, on_change=None, *, always: bool = False):
    """A property stored in `_<name>`; `on_change(self, old)` runs when the value changes (or on
    every assignment with always=True). Every change bumps the revision."""
    attr = "_" + name

    def get(self):
        return getattr(self, attr)

    def set_(self, value):
        old = getattr(self, attr, None)
        if not always and type(old) is type(value):
            try:
                if bool(old == value):
                    return
            except (ValueError, TypeError):  # arrays inside: treat as changed
                pass
        setattr(self, attr, value)
        if on_change is not None:
            on_change(self, old)
        self.touch()

    return property(get, set_)


def _operations_changed(self, old) -> None:
    self.capture_job_tools()
    self.clear_toolpath_results()
    self.note_project_change()
    self.layout_engraving_preview()


def _view_side_changed(self, old) -> None:
    if not self.switching_view:
        self.transition(old)


def _tabs_changed(self, old) -> None:
    if self._tabs.count % 2 == 1:  # tabs go in mirrored pairs (older projects may hold an odd count)
        self._tabs.count += 1
    self.clear_toolpath_results()
    self.note_project_change()


def _is_generating_changed(self, old) -> None:
    if old and not self._is_generating and self.sim_start is not None:
        self.precompute_checkpoints(self.sim_start)


def _show_cut_face_changed(self, old) -> None:
    if not SCRIPTED:
        AppSettings.set_value("showCutFace", self._show_cut_face)
    self.cut_face_key = ""
    self.layout_cut_face()


def _stage_changed(self, old) -> None:
    self.select_finding(None)


def _analysis_changed(self, old) -> None:
    self.analysis_version += 1


def _inspecting_changed(self, old) -> None:
    if not self._inspecting:
        self.inspected = None


def _simulate_changed(self, old) -> None:
    self.reset_simulation()
    self.update_playback()


class StateMixin:
    operations = didset("operations", _operations_changed)
    selected_library_step = didset("selected_library_step", lambda s, o: s.layout_scene())
    fixture_placement = didset("fixture_placement", lambda s, o: s.layout_scene(), always=True)
    twoSided = didset("twoSided", lambda s, o: (s.clear_toolpath_results(), s.keep_stock_workable(), s.layout_scene(), s.note_project_change()))
    viewSide = didset("viewSide", _view_side_changed)
    webThickness = didset("webThickness", lambda s, o: s.clear_toolpath_results())
    holdWithTabs = didset("holdWithTabs", lambda s, o: (s.clear_toolpath_results(), s.note_project_change()))
    tabs = didset("tabs", _tabs_changed)
    is_generating = didset("is_generating", _is_generating_changed)
    show_cut_face = didset("show_cut_face", _show_cut_face_changed)
    show_undercut_overlay = didset("show_undercut_overlay", lambda s, o: s.show_undercuts())
    stock_animating = didset("stock_animating", lambda s, o: s.show_dfm_highlight())
    stage = didset("stage", _stage_changed)
    analysis = didset("analysis", _analysis_changed, always=True)
    show_findings_overlay = didset("show_findings_overlay", lambda s, o: s.show_dfm_highlight())
    color_mode = didset("color_mode", lambda s, o: s.show_toolpaths())
    simulate = didset("simulate", _simulate_changed)
    inspecting = didset("inspecting", _inspecting_changed)

    def init_state(self) -> None:
        S = setattr  # plain attributes (object.__setattr__ is refused on QObject subclasses)
        # Stored without running the didSet side effects (as Swift's initial values).
        for name, value in {
            "_operations": [], "_selected_library_step": None, "_fixture_placement": None, "_twoSided": False, "_viewSide": 0,
            "_webThickness": 0.3, "_holdWithTabs": True, "_tabs": HoldingTabs(), "_is_generating": False,
            "_show_cut_face": bool(AppSettings.value("showCutFace", False)), "_show_undercut_overlay": False,
            "_stock_animating": False, "_stage": "partStock", "_analysis": None, "_show_findings_overlay": True,
            "_color_mode": "moveType", "_simulate": True, "_inspecting": False,
        }.items():
            S(self, name, value)
        self.inspector_tab = "setup"
        self.inspector_scroll_target = None
        self.isPlanningJob = False
        self.restored_development_session = False
        self.planning_machine_initialized = False
        self.profile_collision_trees = None
        # collisions
        self.collisions = []
        self.collision_prefixes = {}
        self.collision_generation = 0
        self.machine_tree = None
        self.machine_tree_key = None
        self.head_trees = None
        self.bed_bodies = []
        self.bed_tree = None
        self.machine_tree_task = None
        self.machine_tree_task_id = None
        # toolpath cache
        self.op_cache = {}
        self.op_cache_order = []
        self.cached_ops = 0
        self.clamp_field_cache = None
        self.clearance_recheck = None
        self.in_process_snapshots = {}
        self.in_process_meshes = {}
        self.gumball_prompt = None
        # project document
        self.project_path = None
        self.project_dirty = False
        self.undo_history = []
        self.redo_history = []
        self.jog_open = False
        self.jog_tool = None
        self.last_snapshot = None
        self.last_change_at = 0.0
        # plan
        self.plan_notes = []
        self.library_workholding_plan = None
        self.library_fixture_meshes = {}
        self.automatic_preview_requested = None
        self.library_fixture_triangles = {}
        self.library_fixture_fields = {}
        self.library_fixture_geometries = {}
        self.library_fixture_geometry_signatures = {}
        self.fixture_placement_geometry = None
        self.rendered_library_step = None
        self.plan_candidates = []
        self.plan_options = []
        self.chosen_plan = None
        self.recommended_plan = None
        self.plan_estimate = {}
        self.calibration = self.load_calibration()
        self.tuning = Tuning()
        self.generated_tuning = Tuning()
        self.batch_quantity = 1
        self.features = None
        self.features_key = None
        self.toolpaths = {}
        self.programs = []
        self.generation_progress = None
        self.cancel_generation = False
        self.op_gen_state = {}
        self.worker_engines = []
        self.travel_issue = None
        self.two_sided_chosen = False
        self.selected_step = None
        self.show_step_card = True
        self.projects_pick = None
        self.just_added_operation = None
        self.undercut_overlay_shown = False
        self.analysis_transform = None
        self.planned_programs = []
        self.planned_operation_count = {}
        self.isFindingPlans = False
        self.loose_pieces = 0
        self.reference_plan = None
        self.sim_surfaces_at = 0.0
        self.sim_surfaces_pending = False
        self.side_a_final_key = -1
        self.scene_labels = []
        self.measuring_tool_names = []
        self.tool_spin = 0.0
        self.pending_play = False
        self.tool_change_stop = None
        self.tool_change_task = None
        self.tool_changes_done = set()
        self.internal_seek = False
        self.gumball_drag = None
        self.switching_view = False
        self.placed_tabs = []
        self.placed_tab_z = None
        self.tool_change_spot_cache = None
        self.side_results = []
        # playback
        self.timeline = ToolpathTimeline()
        self.playhead = 0.0
        self.is_playing = False
        self.play_speed = 1.0
        self.inspected = None
        self.entry_segment_end = []
        self.heightmap = None
        self.sim_index = 0
        self.sim_checkpoints = []
        self.sim_catch_up = None
        self.sim_precompute = None
        self.sim_start = None
        self.side_a_final = None
        self.timeline_titles = []
        self.side_a_final_task = None
        self.sim_back = None
        self.play_timer = None
        self.operation_program = []
        self.operation_lines = []
        self.planned_tools = []
        self.tool_mesh_id = None
        # analysis
        self.analysis_failed = False
        self.selected_finding_id = None
        self.dfm_highlight = None
        self.dfm_overlay_faces = {}
        self.analysis_version = 0
        self.dfm_cache = None
        self.setup_room_cache = None
        self.named_features = []
        self.named_features_file = None
        self.recognition_task = None
        self.tool_to_show = None
        self.part_changed_on_disk = False
        self.analysis_task = None
        self.part_watcher = None
        self.flip_task = None
        self.cut_face_key = ""
