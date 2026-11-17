"""The toolpath viewer: drawing the paths, playback, the tool in the spindle and the material
removal simulation. Port of Model/Playback.swift."""

from __future__ import annotations

import math
import os
import time
from dataclasses import dataclass, field

import numpy as np

from ...core.plan import edge_finding as EdgeFinding
from ...core.plan.setup_side import SetupSide
from ...core.post.toolpath import Role, ToolpathGeometry
from ...core.sim import surfaces as SimSurfaces
from ...core.sim.heightmap import Heightmap
from ...viewport.cutter import tool_meshes
from ...viewport.grid import grid_mesh, update_grid
from ...viewport.scene import SEGMENT_DTYPE, PathColor, SceneColor, SceneLines, SceneMesh
from ..tasks import Sleep, Work, spawn
from .geometry import translation

SCRIPTED = "COASTLINE_SCRIPT" in os.environ

COLOR_MODES = {"moveType": "Move type", "feed": "Feed rate", "depth": "Depth", "operation": "Operation", "tool": "Tool"}
COLOR_MODE_EXPLANATIONS = {
    "moveType": "Bright cutting, light gray leading in and out, dark gray going down into the material, gray dashed rapids through the air",
    "feed": "Dark slow to bright fast: where the feed drops (corners, ramps)",
    "depth": "Light near the face to dark at the deepest",
    "operation": "One gray per operation, as on the timeline bar",
    "tool": "One gray per tool",
}
PALETTE = [SceneColor.line(v) for v in (240, 170, 210, 120, 190, 145)]


def role_colour(role: Role):
    """Display colours per move role (rapids dashed)."""
    if role == Role.RAPID:
        return PathColor.rapid
    if role == Role.CUT:
        return PathColor.cut
    if role == Role.PLUNGE:
        return PathColor.plunge
    if role in (Role.RAMP, Role.LEAD):
        return PathColor.lead
    return SceneColor.line(150)


@dataclass
class InspectedMove:
    """What the inspector shows for a clicked toolpath segment."""

    entry: int
    operation: str
    role: str
    feed: float
    position: tuple
    time: float
    program: int
    line: int | None
    context: list = field(default_factory=list)


def ray_segment_distance(o, d, a, b) -> float:
    """Closest distance between a ray and a segment (sampled along the segment)."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    pts = a[None, :] + (b - a)[None, :] * (np.arange(9) / 8)[:, None]
    v = pts - o
    t = np.maximum(v @ d, 0)
    return float(np.min(np.linalg.norm(v - d[None, :] * t[:, None], axis=1)))


class PlaybackMixin:
    # ---------------------------------------------------------------- drawing

    def _path_colour(self, e, max_feed: float, depth: tuple[float, float]):
        if e.move.role == Role.RAPID:
            return PathColor.rapid
        mode = self.color_mode
        if mode == "moveType":
            return role_colour(e.move.role)
        if mode == "operation":
            return PALETTE[e.operation % len(PALETTE)]
        if mode == "tool":
            return PALETTE[e.program % len(PALETTE)]
        if mode == "feed":
            t = min(max(e.move.feed / max(max_feed, 1), 0), 1)
            return SceneColor.line(int(90 + 155 * t))
        span = max(depth[1] - depth[0], 1e-6)
        t = min(max((depth[1] - e.move.z) / span, 0), 1)
        return SceneColor.line(int(235 - 145 * t))

    def show_toolpaths(self) -> None:
        """Draws the whole timeline; playback hides segments past the playhead."""
        scene = self.scene
        scene.remove("toolpath")
        self.entry_segment_end = []
        stock = self.stock
        if stock is None or not self.timeline.entries:
            self.toolpath_segments = 0
            return
        size = self.display_stock_size
        origin = np.asarray(self.work_origin(size if size is not None else self.setup.stock_size(stock)), float)
        entries = self.timeline.entries
        max_feed = max((e.move.feed for e in entries), default=1)
        zs = [e.move.z for e in entries if e.move.role != Role.RAPID]
        depth = (min(zs, default=-1), max(zs, default=0))
        a_list, b_list, colours, ends = [], [], [], []
        for e in entries:
            c = self._path_colour(e, max_feed, depth)
            a = e.start
            for q in ToolpathGeometry.points(e.move, e.start, 0.15):
                a_list.append(a)
                b_list.append(q)
                colours.append(c)
                a = q
            ends.append(len(a_list))
        self.entry_segment_end = ends
        if not a_list:
            self.toolpath_segments = 0
            return
        seg = np.empty(len(a_list), SEGMENT_DTYPE)
        seg["a"] = np.asarray(a_list, float) + origin
        seg["b"] = np.asarray(b_list, float) + origin
        col = np.asarray(colours, np.uint8)
        seg["color_a"] = col
        seg["color_b"] = col
        lines = SceneLines("toolpath", seg)
        lines.xray = 0.35 if self.realistic else 0.0
        lines.visible = self.pathsVisible
        scene.add(lines)
        self.toolpath_segments = lines.count
        self.update_playback()

    # ---------------------------------------------------------------- playback

    def toggle_play(self) -> None:
        """Play plays one step: the program at the playhead to its end (at its end, the next
        one). A new tool's program starts with its tool change."""
        if self.is_playing:
            self.pause()
            return
        if self.tool_change_stop is not None:
            return  # the tool-change panel is up
        entries = self.timeline.entries
        if not entries:
            return
        if self.playhead >= self.timeline.duration - 1e-6:
            self.quiet_seek(0)
        i = self.timeline.index(self.playhead)
        program = entries[i].program

        def end_of(p: int) -> float:
            last = next((e for e in reversed(entries) if e.program == p), None)
            return last.t_end if last is not None else self.timeline.duration

        if self.playhead >= end_of(program) - 1e-6:
            n = next((k for k in range(i, len(entries)) if entries[k].program != program), None)
            if n is not None:
                i, program = n, entries[n].program
                self.quiet_seek(entries[n].t_start)
        stop = end_of(program)
        first = next((k for k, e in enumerate(entries) if e.program == program), None)
        if (first is not None and self.playhead <= entries[first].t_start + 1e-6 and first not in self.tool_changes_done
                and self.tool_change(first) is not None):
            self.begin_tool_change(first, True, stop)
            return
        self.play_until(stop)

    def play_until(self, end: float | None) -> None:
        """Plays from the playhead to `end` (None: the side's end), stopping at a tool change."""
        stop_at = min(end if end is not None else self.timeline.duration, self.timeline.duration)
        changes = [(k, self.timeline.entries[k].t_start) for k in self.tool_change_entries if k not in self.tool_changes_done]
        self.is_playing = True
        self.scene.remove("deviation")
        if self.play_timer is not None:
            self.play_timer.cancel()

        def run():
            last = time.monotonic()
            while self.is_playing:
                yield Sleep(1 / 60)
                now = time.monotonic()
                dt, last = now - last, now
                t = min(self.playhead + dt * self.play_speed, stop_at)
                c = next((c for c in changes if self.playhead + 1e-9 < c[1] <= t and c[1] < stop_at - 1e-9), None)
                if c is not None:
                    self.begin_tool_change(c[0], True, stop_at)
                    return
                self.advance_spin(dt)
                self.quiet_seek(t)
                if t >= stop_at - 1e-9:
                    self.pause()
                    return

        self.play_timer = spawn(run(), "play")
        self.touch()

    def quiet_seek(self, t: float) -> None:
        """A seek by playback or a tool change, not by you (keeps the tool changes done there)."""
        self.internal_seek = True
        try:
            self.seek(t)
        finally:
            self.internal_seek = False

    def pause(self) -> None:
        self.is_playing = False
        if self.play_timer is not None:
            self.play_timer.cancel()
            self.play_timer = None
        self.touch()

    def seek(self, t: float) -> None:
        if not self.internal_seek:
            if self.tool_change_stop is not None:
                if self.tool_change_task is not None:
                    self.tool_change_task.cancel()
                self.tool_change_stop = None
            self.tool_changes_done = set()
        target = min(max(t, 0), self.timeline.duration)
        if target < self.playhead - 1e-9:
            self.rewind_simulation(self.timeline.index(target))
        self.playhead = target
        self.update_playback()
        self.touch()

    def step(self, delta: int) -> None:
        """Steps to the start of the next/previous move."""
        entries = self.timeline.entries
        if not entries:
            return
        i = self.timeline.index(self.playhead)
        j = min(max(i + delta, 0), len(entries) - 1)
        self.seek(entries[j].t_end if delta > 0 else entries[j].t_start)

    def jump_operation(self, delta: int) -> None:
        entries = self.timeline.entries
        if not entries:
            return
        current = entries[self.timeline.index(self.playhead)].operation
        e = next((e for e in entries if e.operation == current + delta), None)
        self.seek(e.t_start if e is not None else (self.timeline.duration if delta > 0 else 0))

    @property
    def operation_starts(self) -> list[tuple[float, int]]:
        out, last = [], -1
        for e in self.timeline.entries:
            if e.operation != last:
                out.append((e.t_start, e.operation))
                last = e.operation
        return out

    def update_playback(self) -> None:
        """Shows segments up to the playhead, moves the tool, and advances the simulation."""
        try:
            entries = self.timeline.entries
            if not entries or self.stock is None:
                self.scene.remove("tool")
                self.scene.remove("tool.shank")
                return
            i = self.timeline.index(self.playhead)
            done = self.playhead >= self.timeline.duration - 1e-9
            lines = self.scene.line_set("toolpath")
            if lines is not None and self.entry_segment_end:
                n = lines.count if done else (self.entry_segment_end[i - 1] if i > 0 else 0) + self._partial_segments(i)
                self.scene.set_visible_segments("toolpath", n)
            entry = entries[i]
            if self.setup.plan_from_fixture_library:
                prog = next((p for p in self.programs if p.index == entry.program), None)
                step = prog.workholding_step if prog is not None else None
                if step is not None and self.rendered_library_step != step.id:
                    self.rendered_library_step = step.id
                    self.selected_library_step = step.id
            if 0 <= entry.operation < len(self.planned_tools):
                tool = self.planned_tools[entry.operation]
                if self.current_tool is None or self.current_tool.id != tool.id:
                    self.current_tool = tool
                    self.tool_changed()
                self.ensure_tool_mesh(tool)
            q = self.machine_position_for_work(self.timeline.position(self.playhead))
            if q is not None:
                self.set_machine_position(q)
            if self.simulate:
                self.advance_simulation(i, self.playhead)
        finally:
            self.layout_cut_face()

    def _partial_segments(self, i: int) -> int:
        e = self.timeline.entries[i]
        ends = self.entry_segment_end
        n = ends[i] - ends[i - 1] if i > 0 else ends[i]
        f = (self.playhead - e.t_start) / max(e.t_end - e.t_start, 1e-9)
        return int(math.floor(n * min(max(f, 0), 1)))

    # ---------------------------------------------------------------- the tool

    def advance_spin(self, dt: float) -> None:
        """Turns the tool as the spindle would: slower while edge finding."""
        i = self.timeline.index(self.playhead)
        entries = self.timeline.entries
        probing = (entries[i].program if 0 <= i < len(entries) else 0) >= 2000
        self.tool_spin += dt * 2 * math.pi * (2 if probing else 4)

    def ensure_tool_mesh(self, tool) -> None:
        """Puts this tool in the collet (rebuilt only when the tool changes)."""
        if self.scene.mesh("tool") is None or self.tool_mesh_id != tool.id:
            self.scene.remove("tool")
            self.scene.remove("tool.shank")
            for m in tool_meshes(tool, "tool"):
                self.scene.add(m)
            self.tool_mesh_id = tool.id
        spin = np.eye(4)
        if self.is_playing:
            c, s = math.cos(self.tool_spin), math.sin(self.tool_spin)
            spin[:2, :2] = [[c, -s], [s, c]]
        m = translation(self.tip_at_model_pose()) @ spin
        for id in ("tool", "tool.shank"):
            mesh = self.scene.mesh(id)
            if mesh is not None:
                mesh.transform = m

    # ---------------------------------------------------------------- material removal

    def rewind_simulation(self, i: int) -> None:
        """Back to the latest saved state at or before entry i (or the fresh stock)."""
        if self.sim_catch_up is not None:
            self.sim_catch_up.cancel()
        if self.sim_index <= i:
            return
        cp = next((c for c in reversed(self.sim_checkpoints) if c[0] <= i), None)
        if cp is not None and self.scene.mesh("simstock") is not None:
            hm = cp[1].copy()
            hm.mark_all_dirty()
            self.heightmap = hm
            self.sim_index = cp[0]
        else:
            self.reset_simulation()

    def compute_side_a_final(self) -> None:
        """Simulates side A to the end in the background (side B starts from it)."""
        stock = self.stock
        r = next((r for r in self.side_results if r.side == 0), None)
        if not self.twoSided or stock is None or r is None:
            return
        key = sum(len(p.moves) for p in r.paths)
        running = self.side_a_final_task is not None and not self.side_a_final_task.finished
        if key == self.side_a_final_key and (self.side_a_final is not None or running):
            return
        self.side_a_final_key = key
        if self.side_a_final_task is not None:
            self.side_a_final_task.cancel()
        self.side_a_final = None
        size = self.setup.stock_size(stock)
        tools = [p.tool for p in r.planned]
        paths, programs, lines = list(r.paths), list(r.operation_program), list(r.operation_lines)
        machine, ref = self.machine, self.planning_machine_reference

        def sim():
            from ...core.post.timeline import ToolpathTimeline
            tl = ToolpathTimeline(paths, programs, lines, machine)
            hm = Heightmap((-size[0] / 2, -size[1] / 2, -size[2]), (size[0] / 2, size[1] / 2, 0), 250_000)
            for e in tl.entries:
                if 0 <= e.operation < len(tools):
                    hm.apply(e.move, e.start, tools[e.operation].diameter / 2, tools[e.operation].corner_radius)
            return hm

        def run():
            hm = yield Work(sim, lane="sim")
            if self.planning_machine_reference != ref:
                return
            self.side_a_final = hm
            if self.viewSide == 1:
                t = self.playhead
                self.reset_simulation()
                self.seek(t)

        self.side_a_final_task = spawn(run(), "side A final")

    def in_process_start(self, side: int):
        """The stock model's snapshot as this side's first step starts."""
        plan = self.library_workholding_plan
        if plan is not None:
            step = next((s for s in plan.steps if s.side == side), None)
            if step is not None and f"step:{step.id}" in self.in_process_snapshots:
                return self.in_process_snapshots[f"step:{step.id}"]
        return self.in_process_snapshots.get(f"side:{side}")

    def _back_surface(self, hm: Heightmap):
        """Side B's back: side A's surface turned over."""
        a = self.side_a_final
        if not self.twoSided or self.viewSide != 1 or a is None or a.cols != hm.cols or a.rows != hm.rows:
            return None
        thickness = hm.top - hm.bottom
        roll_y = self.setup_for(1).flip_axis == 1
        from .tab_check import _round_clamp
        r, c = np.arange(hm.rows), np.arange(hm.cols)
        y, x = hm.origin[1] + r * hm.cell, hm.origin[0] + c * hm.cell
        ra = r if roll_y else _round_clamp((-y - a.origin[1]) / a.cell, a.rows)
        ca = _round_clamp((-x - a.origin[0]) / a.cell, a.cols) if roll_y else c
        return (np.float32(hm.top) - np.float32(thickness) - a.heights[np.ix_(ra, ca)]).astype(np.float32).reshape(-1)

    def reset_simulation(self) -> None:
        if self.sim_catch_up is not None:
            self.sim_catch_up.cancel()
        if self.sim_precompute is not None:
            self.sim_precompute.cancel()
        scene = self.scene
        for id in ("simstock", "simstock.back", "simstock.walls", "simstock.loose"):
            scene.remove(id)
        self.loose_pieces = 0
        self.sim_back = None
        self.heightmap = None
        self.sim_index = 0
        self.sim_checkpoints = []
        self.sim_start = None
        stock = self.stock
        if not self.simulate or stock is None or not self.timeline.entries:
            m = scene.mesh("stock")
            if m is not None:
                m.visible = True
            return
        size = self.display_stock_size
        if size is None:
            size = self.setup.stock_size(stock)
        hm = Heightmap((-size[0] / 2, -size[1] / 2, -size[2]), (size[0] / 2, size[1] / 2, 0), 250_000)
        origin = np.asarray(self.work_origin(size), float)
        c = np.asarray(self.linear_swatch(stock.material) if stock.material is not None else (0.5, 0.5, 0.5), float)
        back = self._back_surface(hm)
        from_model = False
        start = self.in_process_start(max(self.viewSide, 0))
        if start is not None:
            side = max(self.viewSide, 0)
            top = hm.heights.astype(np.float32).reshape(-1).copy()
            bottom = np.full(top.shape, np.float32(hm.bottom))
            k, sign = start.tool_axis(side)
            a, flip = self.setup.stock_size(stock), self.setup_for(1).flip_axis
            for r in range(hm.rows):
                for cc in range(hm.cols):
                    x, y = hm.origin[0] + cc * hm.cell, hm.origin[1] + r * hm.cell
                    pa = SetupSide.to_a((x, y, 0), side, a, flip)
                    spans = start.material_along(k, pa)
                    i = r * hm.cols + cc
                    if not spans:
                        top[i] = hm.bottom
                        continue
                    zs = [sign * (float(v) - pa[k]) for s in spans for v in s]
                    top[i] = min(max(zs), hm.top)
                    bottom[i] = max(min(zs), hm.bottom)
            hm.heights[:] = top.reshape(hm.rows, hm.cols)
            back = bottom
            from_model = True
        self.sim_back = back
        colour = (*(c * 0.85), 1.0)
        g = grid_mesh("simstock", hm.origin[0], hm.origin[1], hm.cell, hm.cols, hm.rows, hm.top, colour, translation(origin),
                      bottom=hm.bottom, bottom_face=back is None)
        scene.add(g)
        if back is not None:
            scene.add(grid_mesh("simstock.back", hm.origin[0], hm.origin[1], hm.cell, hm.cols, hm.rows, hm.bottom, colour,
                                translation(origin), facing_down=True))
            hm.mark_all_dirty()
        if from_model:
            hm.mark_all_dirty()
        self.heightmap = hm
        if from_model:
            self._refresh_sim_mesh()
        m = scene.mesh("stock")
        if m is not None:
            m.visible = False
        self.apply_surfaces()
        self.apply_stock_display()
        self.sim_start = hm.copy()
        self.precompute_checkpoints(self.sim_start)

    def precompute_checkpoints(self, start: Heightmap) -> None:
        """Runs the whole side's material removal off the UI thread once and keeps the state at
        the start of every operation (and every 1/50 of the moves)."""
        entries = list(self.timeline.entries)
        tools = list(self.planned_tools)
        if not entries or self.is_generating:
            return
        states = min(150, max(150_000_000 // max(start.heights.size * 4, 1), 20))
        every = max(len(entries) // states, 100)
        tick = self.timeline.duration
        ref = self.planning_machine_reference
        if self.sim_precompute is not None:
            self.sim_precompute.cancel()

        def slice_(hm, k, last_op):
            found = []
            stop = min(k + max(every * 4, 20_000), len(entries))
            while k < stop:
                e = entries[k]
                if e.operation != last_op or (k > 0 and k % every == 0):
                    last_op = e.operation
                    if k > 0:
                        found.append((k, hm.copy()))
                tool = tools[e.operation] if 0 <= e.operation < len(tools) else None
                if tool is not None and e.operation != 0 and not EdgeFinding.is_edge_finder(tool):
                    hm.apply(e.move, e.start, tool.diameter / 2, tool.corner_radius)
                k += 1
            return hm, k, found, last_op

        def run():
            hm, k, last_op = start.copy(), 0, -1
            while k < len(entries):
                hm, k, found, last_op = yield Work(lambda: slice_(hm, k, last_op), lane="sim")
                if self.timeline.duration != tick or self.planning_machine_reference != ref:
                    return
                for cp in found:
                    if not any(c[0] == cp[0] for c in self.sim_checkpoints):
                        at = next((j for j, c in enumerate(self.sim_checkpoints) if c[0] > cp[0]), len(self.sim_checkpoints))
                        self.sim_checkpoints.insert(at, cp)

        self.sim_precompute = spawn(run(), "checkpoints")

    def advance_simulation(self, i: int, t: float) -> None:
        """Applies moves up to entry i, ~25 ms at a time: a long jump finishes over the next frames."""
        if self.sim_catch_up is not None:
            self.sim_catch_up.cancel()
            self.sim_catch_up = None
        hm = self.heightmap
        if hm is None:
            return
        entries = self.timeline.entries
        every = max(len(entries) // 40, 200)
        deadline = time.monotonic() + (1e9 if SCRIPTED else 0.5 if self.is_playing else 0.025)
        cp = next((c for c in reversed(self.sim_checkpoints) if c[0] <= i), None)
        if cp is not None and cp[0] > self.sim_index + every // 4:
            hm = cp[1].copy()
            hm.mark_all_dirty()
            self.sim_index = cp[0]
        n = 0
        tools = self.planned_tools
        while self.sim_index < i:
            e = entries[self.sim_index]
            tool = tools[e.operation] if 0 <= e.operation < len(tools) else None
            if tool is not None and e.operation != 0 and not EdgeFinding.is_edge_finder(tool):
                hm.apply(e.move, e.start, tool.diameter / 2, tool.corner_radius)
            self.sim_index += 1
            if self.sim_index % every == 0 and not any(c[0] == self.sim_index for c in self.sim_checkpoints):
                at = next((j for j, c in enumerate(self.sim_checkpoints) if c[0] > self.sim_index), len(self.sim_checkpoints))
                self.sim_checkpoints.insert(at, (self.sim_index, hm.copy()))
            n += 1
            if n % 64 == 0 and time.monotonic() > deadline:
                break
        self.heightmap = hm
        self._refresh_sim_mesh()
        if self.sim_index < i:
            def later():
                yield Sleep(0.008)
                self.advance_simulation(i, t)
            self.sim_catch_up = spawn(later(), "sim catch-up")

    def _refresh_sim_mesh(self) -> None:
        hm = self.heightmap
        mesh = self.scene.mesh("simstock")
        if hm is None or mesh is None:
            return
        dirty = hm.take_dirty()
        if dirty is None:
            return
        c0, r0, c1, r1 = dirty
        back = self.sim_back
        heights = hm.heights
        if back is not None:
            bm = self.scene.mesh("simstock.back")
            if bm is not None:
                update_grid(bm, back, heights, back, hm.cols, hm.rows, hm.cell, c0, r0, c1, r1, True, hm.bottom)
        update_grid(mesh, heights, heights, back, hm.cols, hm.rows, hm.cell, c0, r0, c1, r1, False, hm.bottom)
        self.schedule_sim_surfaces()

    def schedule_sim_surfaces(self) -> None:
        """The walls around holes cut through and the loose pieces: at most every 0.2 s while playing."""
        if self.sim_back is None:
            return
        wait = 0.2 - (time.monotonic() - self.sim_surfaces_at)
        if not self.is_playing or wait <= 0:
            self.rebuild_sim_surfaces()
        elif not self.sim_surfaces_pending:
            self.sim_surfaces_pending = True

            def later():
                yield Sleep(wait)
                self.sim_surfaces_pending = False
                self.rebuild_sim_surfaces()

            spawn(later(), "sim surfaces")

    def rebuild_sim_surfaces(self) -> None:
        self.sim_surfaces_at = time.monotonic()
        scene = self.scene
        scene.remove("simstock.walls")
        scene.remove("simstock.loose")
        hm, back, sim = self.heightmap, self.sim_back, scene.mesh("simstock")
        if hm is None or back is None or sim is None:
            if self.loose_pieces != 0:
                self.loose_pieces = 0
                self.touch()
            return
        h = hm.heights.reshape(-1)
        cols, rows = hm.cols, hm.rows
        x0, y0, cell = hm.origin[0], hm.origin[1], hm.cell
        open_mask = h <= back + 0.005
        p, n = SimSurfaces.walls(cols, rows, x0, y0, cell, h, back, hm.bottom, open_mask)
        if len(p):
            m = SceneMesh("simstock.walls", p, n, np.arange(len(p), dtype=np.uint32), sim.color, sim.transform)
            m.material = sim.material
            m.visible = sim.visible
            m.xray_through = True
            scene.add(m)
        edge = np.zeros((rows, cols), bool)
        edge[0, :] = edge[-1, :] = edge[:, 0] = edge[:, -1] = True
        mask, pieces = SimSurfaces.loose(cols, rows, h, back, hm.bottom, np.zeros(len(h), bool), edge.reshape(-1))
        if self.loose_pieces != pieces:
            self.loose_pieces = pieces
            self.touch()
        if pieces > 0:
            p, n = SimSurfaces.overlay(cols, rows, x0, y0, cell, h, mask)
            if len(p):
                m = SceneMesh("simstock.loose", p, n, np.arange(len(p), dtype=np.uint32), SceneColor.danger_surface, sim.transform)
                m.depth_bias = 1
                m.visible = sim.visible
                scene.add(m)

    # ---------------------------------------------------------------- inspection

    def inspect_at(self, x: float, y: float) -> None:
        """Finds the toolpath move nearest to a click and shows its details and G-code line."""
        stock = self.stock
        entries = self.timeline.entries
        if stock is None or not entries:
            return
        ray = self.renderer.ray(x, y)
        if ray is None:
            return
        size = self.display_stock_size
        origin = np.asarray(self.work_origin(size if size is not None else self.setup.stock_size(stock)), float)
        o, d = np.asarray(ray[0], float) - origin, np.asarray(ray[1], float)
        d = d / max(np.linalg.norm(d), 1e-12)
        starts = np.array([e.start for e in entries], float)
        ends = np.array([e.move.position for e in entries], float)
        f = (np.arange(9) / 8)[None, :, None]
        pts = starts[:, None, :] + (ends - starts)[:, None, :] * f
        v = pts - o
        tt = np.maximum(v @ d, 0)
        dist = np.linalg.norm(v - tt[..., None] * d, axis=2).min(axis=1)
        k = int(np.argmin(dist))
        cam = self.renderer.camera
        h = cam.distance * math.tan(cam.field_of_view / 2) if cam is not None else 100.0
        if not dist[k] < h * 0.03:
            self.inspected = None
            self.touch()
            return
        e = entries[k]
        context = []
        line = e.gcode_line
        if line is not None and 0 <= e.program < len(self.programs):
            lines = self.programs[e.program].gcode.split("\n")
            for n in range(max(line - 3, 1), min(line + 3, len(lines)) + 1):
                context.append((n, lines[n - 1]))
        op = self.timeline_titles[e.operation] if 0 <= e.operation < len(self.timeline_titles) else "Operation"
        self.inspected = InspectedMove(k, op, e.move.role.name.lower(), e.move.feed, e.move.position, e.t_end, e.program, line, context)
        self.seek(e.t_end)
