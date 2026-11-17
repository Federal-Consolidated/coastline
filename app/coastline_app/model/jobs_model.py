"""Generated jobs run on the machine: each "Run on Machine…" writes the job's programs and steps to a
folder in the data folder's Jobs, listed on the Projects page and run from there: one step at a time,
with the program's toolpath and the cut check in a 3D preview. Port of Model/JobsModel.swift."""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PySide6.QtCore import QObject, Slot

from ..core.export.guided_job import air_cut
from ..core.post.toolpath import OperationToolpath, Role, ToolpathGeometry
from ..core.program import gcode_reader as GCodeReader
from ..core.program import stl_reader as STLReader
from ..core.program.program_job import ModelRole, ProgramJob, Purpose, StepKind
from ..core.safety.gcode_validator import time_estimate_seconds
from ..core.sim.dexel import CutCheck, ToolShape
from ..core.storage import application_support
from ..viewport.scene import SEGMENT_DTYPE, PathColor, Scene, SceneColor, SceneLines, SceneMesh, axes_segments, segments
from .bindable import prop
from .tasks import Sleep, Work, spawn

SCRIPTED = "COASTLINE_SCRIPT" in os.environ


@dataclass
class Entry:
    folder: Path
    job: ProgramJob

    @property
    def id(self) -> str:
        return str(self.folder)


@dataclass
class RunItem:
    setup: object
    step: object

    @property
    def id(self) -> str:
        return f"{self.setup.id}/{self.step.id}"


@dataclass
class Run:
    folder: Path
    choices: dict
    items: list[RunItem]
    simulated: bool = False
    index: int = -1  # -1: the requirements, before the first step
    done: set = field(default_factory=set)
    started: str | None = None
    started_air_cut: bool = False

    @property
    def current(self) -> RunItem | None:
        return self.items[self.index] if 0 <= self.index < len(self.items) else None


@dataclass
class CutSummary:
    program: str
    removed: float
    gouge: float
    rapid_hits: float


def user_folder() -> Path:
    return application_support() / "Jobs"


def program_segments(program) -> np.ndarray:
    """The program's moves as coloured line segments (arcs as short lines), in order."""
    a_list, b_list, cols = [], [], []
    prev = None
    for m in program.moves:
        start, prev = prev, m.position
        if start is None:
            continue
        c = (PathColor.rapid if m.role == Role.RAPID else PathColor.plunge if m.role == Role.PLUNGE
             else PathColor.lead if m.role in (Role.LEAD, Role.LINK) else PathColor.cut)
        a = start
        for q in ToolpathGeometry.points(m, start):
            a_list.append(a)
            b_list.append(q)
            cols.append(c)
            a = q
    seg = np.empty(len(a_list), SEGMENT_DTYPE)
    if a_list:
        seg["a"], seg["b"] = a_list, b_list
        seg["color_a"] = seg["color_b"] = np.asarray(cols, np.uint8)
    return seg


def mirrors(p) -> bool:
    """True when the axis mapping is a reflection."""
    m = np.zeros((3, 3))
    for i, (axis, sign) in enumerate(p.rows):
        m[i][axis] = sign
    return np.linalg.det(m) < 0


def cylinder(top, length: float, radius: float, sides: int = 24):
    """A closed cylinder hanging down (−Z) from `top`."""
    p, n, idx = [], [], []

    def vertex(v, nn):
        p.append(v)
        n.append(nn)
        return len(p) - 1

    top = np.asarray(top, float)
    bottom = top - np.array([0, 0, length])
    for k in range(sides):
        a0, a1 = k / sides * 2 * np.pi, (k + 1) / sides * 2 * np.pi
        d0, d1 = np.array([np.cos(a0), np.sin(a0), 0]), np.array([np.cos(a1), np.sin(a1), 0])
        i0, i1 = vertex(top + d0 * radius, d0), vertex(top + d1 * radius, d1)
        i2, i3 = vertex(bottom + d1 * radius, d1), vertex(bottom + d0 * radius, d0)
        idx += [i0, i3, i2, i0, i2, i1]
        down = np.array([0, 0, -1.0])
        c, e0, e1 = vertex(bottom, down), vertex(bottom + d0 * radius, down), vertex(bottom + d1 * radius, down)
        idx += [c, e1, e0]
    return np.array(p), np.array(n), np.array(idx, np.uint32)


class JobsModel(QObject):
    revision, revisionChanged = prop(int, "revision", 0)
    lastError, lastErrorChanged = prop(str, "lastError", "")

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.scene = Scene(self)
        self.scene.add(SceneLines("axes", axes_segments(10)))
        self.entries: list[Entry] = []
        self.selection: Path | None = None
        self.choices: dict[str, dict[str, str]] = {}
        self.preview_program: str | None = None
        self.programs: dict[str, object] = {}
        self.engine = None  # () -> EngineClient (blocking), set by the app
        self.machine_source = None  # task step returning a MachineModel
        self.meshes: dict[str, object] = {}
        self._shown_key = None
        self._placed_for = None
        self._placed_part = None
        self.cut_summary: CutSummary | None = None
        self.cut_checking = False
        self._cut_key = None
        self._cut_task = None
        self.show_cuts = True
        self.show_machine = True
        self.machine = None
        self._machine_loading = False
        self._machine_pose = None
        self._tool_shown = None
        self.run: Run | None = None
        self.animation: float | None = None
        self._animation_task = None
        self.view = None  # the preview's Viewport item, when a page shows it
        self.reload()

    def touch(self) -> None:
        self.revision = self.revision + 1

    @property
    def selected(self) -> Entry | None:
        return next((e for e in self.entries if e.folder == self.selection), None)

    def reload(self) -> None:
        out = []
        try:
            folders = sorted(p for p in user_folder().iterdir() if p.is_dir())
        except OSError:
            folders = []
        for f in folders:
            try:
                out.append(Entry(f, ProgramJob.load(f)))
            except Exception:  # noqa: BLE001 — an unreadable folder isn't listed
                pass
        self.entries = out
        if self.selected is None:
            self.selection = out[0].folder if out else None
        self.touch()

    def chosen(self, job) -> dict:
        return job.choices(self.choices.get(job.id, {}))

    def choose(self, job, option: str, value: str) -> None:
        self.choices.setdefault(job.id, {})[option] = value
        self.touch()

    # ---------------------------------------------------------------- programs

    def key(self, entry: Entry, id: str) -> str:
        return f"{entry.folder}|{id}"

    def cached(self, entry: Entry, id: str):
        return self.programs.get(self.key(entry, id))

    def load(self, entry: Entry, id: str):
        """A task step: reads a program off the UI thread."""
        k = self.key(entry, id)
        p = entry.job.program(id)
        if k in self.programs or p is None:
            return
        path = entry.folder / p.file
        program = yield Work(lambda: GCodeReader.read(path.read_text(encoding="utf-8") if path.exists() else ""), lane="jobs")
        self.programs[k] = program
        if self.preview_program == id:
            self.show(entry, id)
        self.touch()

    def _frame(self, lo, hi) -> None:
        if self.view is not None:
            try:
                self.view.frame_world(lo, hi, False)
            except RuntimeError:
                self.view = None

    def show(self, entry: Entry, id: str) -> None:
        """Puts a program's toolpath in the preview, framed."""
        self.preview_program = id
        self._place_models(entry, id)
        self._set_machine_tool(entry, id)
        if any(s.machine is not None for s in entry.job.setups):
            spawn(self.load_machine(), "job machine")
        self.show_cut_check(entry, id)
        k = self.key(entry, id)
        program = self.programs.get(k)
        if program is None or self._shown_key == k:
            self.touch()
            return
        self._shown_key = k
        self.scene.remove("toolpath")
        lines = SceneLines("toolpath", program_segments(program))
        lines.xray = 0.45
        self.scene.add(lines)
        lo = np.array([program.cut_min.x, program.cut_min.y, program.cut_min.z]) if program.cut_min is not None else None
        hi = np.array([program.cut_max.x, program.cut_max.y, program.cut_max.z]) if program.cut_max is not None else None
        mb = self._model_bounds()
        if mb is not None:
            lo = mb[0] if lo is None else np.minimum(lo, mb[0])
            hi = mb[1] if hi is None else np.maximum(hi, mb[1])
        if lo is not None:
            self._frame(lo - 2, hi + 2)
        self.touch()

    # ---------------------------------------------------------------- cut check

    def show_cut_check(self, entry: Entry, id: str) -> None:
        """What a cut program removes (light), gouges into the part (red), rapids through it (yellow)."""
        prog = entry.job.program(id)
        spec = entry.job.tool(prog.tool) if prog is not None else None
        if prog is None or prog.purpose != Purpose.CUT or spec is None:
            self._clear_cuts()
            return
        key = self.key(entry, id) + "|" + (self._placed_for or "") + ("" if self._placed_part is None else "|part")
        if self._cut_key == key:
            return
        self._clear_cuts()
        self._cut_key = key
        setup = entry.job.setup_running(id, self.chosen(entry.job))
        stickout = setup.machine.stickout if setup is not None and setup.machine is not None else 30
        part = self._placed_part
        self.cut_checking = True

        def check(read):
            r = CutCheck.run(read, ToolShape.from_spec(spec, stickout), part)
            if r is None:
                return None
            g = r.gouge.mesh() if r.gouge_volume > 0.01 and r.gouge is not None else None
            h = r.rapid_hits.mesh() if r.rapid_hit_volume > 0.01 and r.rapid_hits is not None else None
            return r.removed.mesh(), g, h, r.removed.volume, r.gouge_volume, r.rapid_hit_volume

        def run():
            yield from self.load(entry, id)
            read = self.cached(entry, id)
            if read is None:
                self.cut_checking = False
                return
            result = yield Work(lambda: check(read), lane="jobs")
            if self._cut_key != key:
                return
            self.cut_checking = False
            if result is None:
                self.touch()
                return
            for mid, mesh, colour in (("cut.removed", result[0], (0.9, 0.9, 0.9, 0.55)), ("cut.gouge", result[1], (1, 0.16, 0.14, 1)),
                                      ("cut.rapid", result[2], (1, 0.84, 0.04, 1))):
                if mesh is None or not len(mesh[2]):
                    continue
                m = SceneMesh(mid, mesh[0], mesh[1], mesh[2], colour)
                m.visible = self.show_cuts
                self.scene.add(m)
            self.cut_summary = CutSummary(id, result[3], result[4], result[5])
            self.touch()

        self._cut_task = spawn(run(), "cut check")

    def _clear_cuts(self) -> None:
        if self._cut_task is not None:
            self._cut_task.cancel()
        self._cut_task = None
        self._cut_key = None
        self.cut_summary = None
        self.cut_checking = False
        for id in ("cut.removed", "cut.gouge", "cut.rapid"):
            self.scene.remove(id)

    def set_show_cuts(self, on: bool) -> None:
        self.show_cuts = on
        for m in self.scene.meshes.values():
            if m.id.startswith("cut."):
                m.visible = on
        self.touch()

    # ---------------------------------------------------------------- machine

    def load_machine(self):
        """A task step: the machine model (the workspace's), see-through around the work."""
        if self.machine is not None or self._machine_loading or self.machine_source is None:
            return
        self._machine_loading = True
        try:
            model = yield from self.machine_source()
        finally:
            self._machine_loading = False
        if model is None:
            return
        self.machine = model
        from .workspace.core import WorkspaceCore
        for i, p in enumerate(model.parts):
            if p.role.startswith("enclosure"):
                continue
            c = WorkspaceCore.display_color(p.role, p.color)
            m = SceneMesh(f"machine.{p.group}.{p.role}.{i}", p.mesh.vertices, p.mesh.normals, p.mesh.indices, (*c, 0.28))
            m.group = "m." + p.group
            self.scene.add(m)
        e = self.selected
        if e is not None and self.preview_program is not None:
            self._tool_shown = None
            self._set_machine_tool(e, self.preview_program)
        self._place_machine()

    def _place_machine(self, tip=None) -> None:
        model = self.machine
        if model is None:
            return
        n, m = model.spindle_nose, model.model_pose
        pose = self._machine_pose
        c = np.zeros(3)
        if pose is not None:
            w = pose.work_zero
            c = np.array([n.x + w[0] - m.x, n.y + w[1] - m.y, n.z + w[2] - m.z - pose.stickout])
        shift = np.eye(4)
        shift[:3, 3] = -c
        for mesh in self.scene.meshes.values():
            if mesh.id.startswith("machine.") or mesh.id == "jobtool":
                mesh.transform = shift
                mesh.visible = self.show_machine and pose is not None
        if pose is None:
            return
        t = tip if tip is not None else (0, 0, 10)
        q = (t[0] + pose.work_zero[0], t[1] + pose.work_zero[1], t[2] + pose.work_zero[2])
        dx, dy, dz = q[0] - m.x, q[1] - m.y, q[2] - m.z

        def tr(x, y, z):
            a = np.eye(4)
            a[:3, 3] = (x, y, z)
            return a

        self.scene.group_transforms.update({"m.x": np.eye(4), "m.static": tr(dx, 0, 0), "m.y": tr(dx, dy, 0), "m.z": tr(dx, dy, dz)})
        self.scene._touch()

    def set_show_machine(self, on: bool) -> None:
        self.show_machine = on
        self._place_machine()
        self.touch()

    def _set_machine_tool(self, entry: Entry, id: str) -> None:
        model = self.machine
        if model is None:
            return
        setup = entry.job.setup_running(id, self.chosen(entry.job))
        prog = entry.job.program(id)
        tool = entry.job.tool(prog.tool) if prog is not None else None
        if setup is None or setup.machine is None or tool is None:
            self.scene.remove("jobtool")
            self._tool_shown = None
            return
        if self._tool_shown == (tool.diameter, setup.machine.stickout):
            return
        self._tool_shown = (tool.diameter, setup.machine.stickout)
        n = model.spindle_nose
        p, nn, i = cylinder((n.x, n.y, n.z), setup.machine.stickout, tool.diameter / 2)
        m = SceneMesh("jobtool", p, nn, i, (0.85, 0.85, 0.85, 1))
        m.group = "m.z"
        self.scene.add(m)
        self._place_machine()

    def _model_bounds(self):
        lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
        for m in self.scene.meshes.values():
            if not (m.visible and m.id.startswith("model.")) or not len(m.vertices):
                continue
            v = m.vertices.astype(float) @ np.asarray(m.transform, float)[:3, :3].T + np.asarray(m.transform, float)[:3, 3]
            lo, hi = np.minimum(lo, v.min(0)), np.maximum(hi, v.max(0))
        return (lo, hi) if lo[0] <= hi[0] else None

    # ---------------------------------------------------------------- models

    def load_models(self, entry: Entry):
        """A task: reads the job's 3D models once; `show` places them per setup."""
        for model in entry.job.models:
            k = f"{entry.folder}|{model.id}"
            if k in self.meshes:
                continue
            path = entry.folder / model.file
            try:
                if path.suffix.lower() == ".stl":
                    self.meshes[k] = yield Work(lambda: STLReader.read(path), lane="jobs")
                elif self.engine is not None:
                    engine = self.engine
                    self.meshes[k] = yield Work(lambda: engine().import_part(path))
            except Exception as e:  # noqa: BLE001
                self.lastError = f"Couldn't read {model.title}: {e}"
        if self.preview_program is not None:
            self._placed_for = None
            self._place_models(entry, self.preview_program)
            self.show_cut_check(entry, self.preview_program)
        self.touch()

    def show_step(self, entry: Entry, step) -> None:
        if step.program is None:
            return
        self.show(entry, step.program)
        spawn(self.load(entry, step.program), "load program")

    def _place_models(self, entry: Entry, program_id: str) -> None:
        setup = entry.job.setup_running(program_id, self.chosen(entry.job))
        key = f"{entry.folder}|{setup.id if setup is not None else '-'}"
        if self._placed_for == key:
            return
        self.scene.remove_prefix("model.")
        self._placed_for = key
        self._placed_part = None
        self._machine_pose = setup.machine if setup is not None else None
        self._place_machine()
        if setup is None:
            return
        for model in entry.job.models:
            placement = setup.placements.get(model.id)
            data = self.meshes.get(f"{entry.folder}|{model.id}")
            if placement is None or data is None:
                continue
            v = np.array([placement.apply(tuple(p)) for p in np.asarray(data.vertices, float)])
            n = np.array([placement.apply(tuple(p), normal=True) for p in np.asarray(data.normals, float)])
            idx = np.asarray(data.indices, np.uint32).reshape(-1, 3).copy()
            if mirrors(placement):
                idx[:, [1, 2]] = idx[:, [2, 1]]
            if model.role == ModelRole.PART:
                self._placed_part = (v.astype(np.float32), idx.reshape(-1))
            colour = SceneColor.dark if model.role == ModelRole.FIXTURE else SceneColor.surface(0.56, 0.6)
            self.scene.add(SceneMesh(f"model.{model.id}", v, n, idx.reshape(-1), colour))

    def minutes(self, program) -> float:
        return (time_estimate_seconds([OperationToolpath("x", program.moves)]) + program.dwell) / 60

    # ---------------------------------------------------------------- running a job

    def start_run(self, entry: Entry, simulated: bool = False) -> None:
        chosen = self.chosen(entry.job)
        items = [RunItem(setup, step) for setup, steps in entry.job.plan(chosen) for step in steps]
        self.run = Run(entry.folder, chosen, items, simulated)
        self.touch()

    def end_run(self) -> None:
        self.stop_animation()
        self.run = None
        self.touch()

    def next(self) -> None:
        self.stop_animation()
        r = self.run
        if r is None:
            return
        item = r.current
        if item is not None and item.step.kind != StepKind.RUN:
            r.done.add(item.id)
        r.index = min(r.index + 1, len(r.items))
        r.started = None
        self.show_current()
        self.touch()

    def back(self) -> None:
        self.stop_animation()
        r = self.run
        if r is None or r.index <= -1:
            return
        r.index -= 1
        r.started = None
        self.show_current()
        self.touch()

    def retry_current(self) -> None:
        r = self.run
        if r is None or r.current is None or r.current.step.kind != StepKind.RUN:
            return
        r.done.discard(r.current.id)
        r.started = None
        self.touch()

    def show_current(self) -> None:
        r = self.run
        entry = next((e for e in self.entries if r is not None and e.folder == r.folder), None)
        if entry is None or r.current is None:
            return
        self.show_step(entry, r.current.step)

    def run_current(self, mill, air: bool):
        """A task: runs the current step's program on the machine (as an air cut: spindle off, 10 mm up)."""
        r = self.run
        item = r.current if r is not None else None
        entry = next((e for e in self.entries if r is not None and e.folder == r.folder), None)
        program = entry.job.program(item.step.program) if entry is not None and item is not None else None
        if program is None:
            return
        if r.simulated and not mill.is_simulated:
            mill.message = "A machine is connected. Disconnect it to simulate." if mill.is_open else "Start the Simulated Mill first."
            return
        path = entry.folder / program.file

        def read():
            text = path.read_text(encoding="utf-8") if path.exists() else ""
            return (air_cut(text) if air else text).split("\n")

        lines = yield Work(read, lane="jobs")
        name = f"{r.index + 1}. {item.step.title}{' · air cut' if air else ''}"
        if mill.run_job(name, lines):
            r.started = name
            r.started_air_cut = air
            if r.simulated:
                self.animate(entry, program.id)
        self.touch()

    def animate(self, entry: Entry, id: str) -> None:
        """Draws the program's toolpath move by move with the tool at its tip (2–20 s)."""
        self.stop_animation()

        def run():
            yield from self.load(entry, id)
            program = self.cached(entry, id)
            if program is None or len(program.moves) <= 1:
                return
            self.show(entry, id)
            seg = program_segments(program)
            seconds = min(max(self.minutes(program) * 60 / 30, 2), 20)
            frames = int(seconds * 20)
            self.animation = 0.0
            for frame in range(1, frames + 1):
                yield Sleep(0.05)
                f = frame / frames
                self._draw_partial(seg, max(1, int(len(seg) * f)))
                self.animation = f
                self.touch()
            self._animation_task = None
            self._finish_animation()

        self._animation_task = spawn(run(), "job animation")

    def stop_animation(self) -> None:
        if self._animation_task is None and self.animation is None:
            return
        if self._animation_task is not None:
            self._animation_task.cancel()
        self._animation_task = None
        self._finish_animation()

    def _finish_animation(self) -> None:
        self.animation = None
        self.scene.remove("simtool")
        self._place_machine()
        r = self.run
        entry = next((e for e in self.entries if r is not None and e.folder == r.folder), None)
        if entry is not None and self.preview_program is not None:
            self._shown_key = None
            self.show(entry, self.preview_program)

    def _draw_partial(self, seg: np.ndarray, count: int) -> None:
        part = seg[:count]
        self.scene.remove("toolpath")
        lines = SceneLines("toolpath", part.copy())
        lines.xray = 0.45
        self.scene.add(lines)
        if not len(part):
            return
        tip = np.asarray(part[-1]["b"], float)
        self._place_machine(tip)
        r = 1.5
        pairs = [(tip, tip + (0, 0, 12)), (tip - (r, 0, 0), tip + (r, 0, 0)), (tip - (0, r, 0), tip + (0, r, 0))]
        self.scene.add(SceneLines("simtool", segments(pairs, PathColor.cut)))

    def status(self, mill):
        """The mill's status of the program this run started last."""
        r = self.run
        p = mill.snapshot.program
        if r is None or r.started is None or p is None or p.name != r.started:
            return None
        return p

    def program_finished(self, outcome) -> None:
        """A real run (not an air cut) that completed completes the step."""
        r = self.run
        if r is None or r.current is None or r.started_air_cut or getattr(outcome, "value", outcome) != "completed":
            return
        r.done.add(r.current.id)
        self.touch()

    def offers_air_cut(self, entry: Entry, program_id: str) -> bool:
        p = entry.job.program(program_id)
        read = self.cached(entry, program_id)
        return p is not None and p.purpose == Purpose.CUT and read is not None and read.relative_moves == 0

    def delete(self, entry: Entry) -> None:
        shutil.rmtree(entry.folder, ignore_errors=True)
        if self.selection == entry.folder:
            self.selection = None
        self.reload()


# ---------------------------------------------------------------- what the Projects page calls

from PySide6.QtCore import Property  # noqa: E402


class JobsUI(JobsModel):
    """Slots and read-outs for the Projects page (Views/Jobs/JobsPage, JobPreview, JobRunner)."""

    def __init__(self, mill=None, parent: QObject | None = None) -> None:
        self.mill = mill
        super().__init__(parent)
        self._last_outcome = None
        if mill is not None:
            mill.stateChanged.connect(self._watch_mill)

    @Property(QObject, constant=True)
    def viewScene(self):
        return self.scene

    @Slot(QObject)
    def attachViewport(self, view) -> None:
        from ..viewport.item import MACHINE_TO_DISPLAY
        self.view = view
        view.world_to_display = MACHINE_TO_DISPLAY
        if self.preview_program is not None and self.selected is not None:
            self._shown_key = None
            self.show(self.selected, self.preview_program)

    @Slot(QObject)
    def detachViewport(self, view) -> None:
        if self.view is view:
            self.view = None

    def _watch_mill(self) -> None:
        """The current program finished: a real run completes the step."""
        if self.run is None or self.mill is None:
            return
        st = self.status(self.mill)
        outcome = st.outcome if st is not None else None
        if outcome is not None and outcome.value != "running" and outcome != self._last_outcome:
            self.program_finished(outcome)
        self._last_outcome = outcome
        self.touch()

    @Slot()
    def reloadJobs(self) -> None:
        self.reload()

    @Slot(result="QVariantList")
    def entryRows(self) -> list:
        return [{"folder": str(e.folder), "title": e.job.title, "programs": len(e.job.programs), "selected": e.folder == self.selection}
                for e in self.entries]

    @Slot(str)
    def selectJob(self, folder: str) -> None:
        self.selection = Path(folder) if folder else None
        e = self.selected
        if e is not None:
            spawn(self.load_models(e), "job models")
        self.touch()

    @Slot(str)
    def deleteJob(self, folder: str) -> None:
        e = next((e for e in self.entries if str(e.folder) == folder), None)
        if e is not None:
            self.delete(e)

    @Slot(result="QVariantMap")
    def detail(self) -> dict:
        e = self.selected
        if e is None:
            return {}
        job = e.job
        chosen = self.chosen(job)
        options = [{"id": o.id, "title": o.title, "detail": o.detail or "", "value": chosen.get(o.id, ""),
                    "choices": [{"id": c.id, "title": c.title, "detail": c.detail or ""} for c in o.choices]}
                   for o in job.options if job.applies(o.when, chosen)]
        setups = []
        for setup, steps in job.plan(chosen):
            rows = []
            for st in steps:
                tool = job.tool(st.tool) if st.tool else None
                prog = job.program(st.program) if st.program else None
                rows.append({"id": st.id, "kind": st.kind.value, "title": st.title, "text": st.text or "", "items": list(st.items),
                             "caution": st.caution or "", "program": st.program or "", "programTitle": prog.title if prog else "",
                             "tool": f"{tool.name} in the {tool.collet} collet. {tool.fitting or ''}" if tool else ""})
            setups.append({"id": setup.id, "title": setup.title, "summary": setup.summary, "steps": rows})
        return {"folder": str(e.folder), "title": job.title, "summary": job.summary, "material": job.material or "",
                "machines": list(job.machines), "requirements": list(job.requirements), "options": options, "setups": setups,
                "tools": [{"name": t.name, "detail": f"Ø{t.diameter:.3f} mm · collet {t.collet}", "note": t.note or ""} for t in job.tools],
                "problems": job.problems(e.folder), "running": self.run is not None}

    @Slot(str, str)
    def chooseOption(self, option: str, value: str) -> None:
        e = self.selected
        if e is not None:
            self.choose(e.job, option, value)

    @Slot(str)
    def showProgram(self, id: str) -> None:
        e = self.selected
        if e is None:
            return
        self.show(e, id)
        spawn(self.load(e, id), "load program")

    @Slot(result="QVariantMap")
    def preview(self) -> dict:
        e, id = self.selected, self.preview_program
        if e is None or id is None:
            return {}
        p = e.job.program(id)
        read = self.cached(e, id)
        out = {"id": id, "title": p.title if p else id, "purpose": p.purpose.value if p else "", "changes": list(p.changes) if p else [],
               "loaded": read is not None, "checking": self.cut_checking, "showCuts": self.show_cuts, "showMachine": self.show_machine,
               "hasMachine": self.machine is not None}
        if read is not None:
            out.update({"moves": len(read.moves), "machineMoves": read.machine_moves, "minutes": max(1, round(self.minutes(read))),
                        "issues": [{"severity": i.severity.name.lower(), "message": i.message} for i in read.issues[:20]],
                        "probes": read.probes})
        c = self.cut_summary
        if c is not None and c.program == id:
            out["cut"] = {"removed": round(c.removed / 1000, 2), "gouge": round(c.gouge, 2), "rapidHits": round(c.rapid_hits, 2)}
        return out

    @Slot(bool)
    def setShowCuts(self, on: bool) -> None:
        self.set_show_cuts(on)

    @Slot(bool)
    def setShowMachine(self, on: bool) -> None:
        self.set_show_machine(on)

    # ---- the runner

    @Slot(bool)
    def startRun(self, simulated: bool) -> None:
        e = self.selected
        if e is None:
            return
        self.start_run(e, simulated)
        if simulated and self.mill is not None:
            self.mill.connectSimulator()

    @Slot()
    def endRun(self) -> None:
        self.end_run()

    @Slot()
    def nextStep(self) -> None:
        self.next()

    @Slot()
    def backStep(self) -> None:
        self.back()

    @Slot()
    def retryStep(self) -> None:
        self.retry_current()

    @Slot(bool)
    def runCurrent(self, air: bool) -> None:
        if self.mill is not None:
            spawn(self.run_current(self.mill, air), "run step")

    @Slot(result="QVariantMap")
    def runState(self) -> dict:
        r = self.run
        if r is None:
            return {}
        entry = next((e for e in self.entries if e.folder == r.folder), None)
        if entry is None:
            return {}
        out = {"title": entry.job.title, "index": r.index, "count": len(r.items), "simulated": r.simulated,
               "requirements": list(entry.job.requirements), "finished": r.index >= len(r.items),
               "steps": [{"id": it.id, "title": it.step.title, "setup": it.setup.title, "done": it.id in r.done, "current": k == r.index}
                         for k, it in enumerate(r.items)], "animation": self.animation if self.animation is not None else -1}
        item = r.current
        if item is not None:
            st = item.step
            tool = entry.job.tool(st.tool) if st.tool else None
            prog = entry.job.program(st.program) if st.program else None
            out["step"] = {"id": item.id, "kind": st.kind.value, "title": st.title, "setup": item.setup.title, "text": st.text or "",
                           "items": list(st.items), "caution": st.caution or "", "done": item.id in r.done,
                           "check": {"what": st.check.what, "expected": st.check.expected, "tolerance": st.check.tolerance} if st.check else None,
                           "tool": {"name": tool.name, "collet": tool.collet, "fitting": tool.fitting or "", "diameter": tool.diameter} if tool else None,
                           "program": {"id": prog.id, "title": prog.title, "purpose": prog.purpose.value,
                                       "airCut": self.offers_air_cut(entry, prog.id)} if prog else None}
            if prog is not None and self.cached(entry, prog.id) is None:
                spawn(self.load(entry, prog.id), "load program")
            m = self.mill
            if m is not None and prog is not None:
                snap = m.snapshot
                status = self.status(m)
                gate = None
                if snap.is_open:
                    path = entry.folder / prog.file
                    first = ""
                    try:
                        for line in path.read_text(encoding="utf-8").split("\n"):
                            t = line.strip()
                            if t and not t.startswith("("):
                                first = t.upper()
                                break
                    except OSError:
                        pass
                    refusal = snap.gates.home if first.startswith("$H") else snap.gates.run
                    gate = refusal.text if refusal is not None else None
                out["mill"] = {"open": snap.is_open, "simulated": m.is_simulated, "message": m.message, "gate": gate or "",
                               "status": None if status is None else {"outcome": status.outcome.value, "fraction": status.fraction,
                                                                     "done": status.done, "total": status.total, "failure": status.failure,
                                                                     "airCut": status.name.endswith("air cut")}}
        return out
