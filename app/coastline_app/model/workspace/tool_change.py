"""A tool change in playback, as it happens at the machine: playback stops, the machine goes to the
tool-change position by a path that keeps clear, a panel asks you to change the tool, and the
machine goes back to the next cut. Port of Model/ToolChange.swift."""

from __future__ import annotations

import math
import os
import time
from dataclasses import dataclass

import numpy as np

from ...core.geometry import Vec3
from ...core.plan import edge_finding as EdgeFinding
from ...core.safety.collision import TriangleTree
from ...core.units import Length
from ..tasks import Sleep, spawn
from .collision_check import _mesh_triangles, bed_triangles

TOOL_CHANGE_ROOM = 15.0  # room kept around the spindle at the tool-change position, mm


@dataclass
class ToolChangeSpot:
    y: float
    z: float
    note: str | None = None


@dataclass
class ToolChangeStop:
    time: float  # where in the timeline the new tool's program starts
    entry: int
    from_tool: object | None
    to: object
    phase: str  # "moving", "waiting", "returning"
    resume: bool
    play_end: float | None
    note: str | None = None


class ToolChangeMixin:
    def tool_at_entry(self, i: int):
        op = self.timeline.entries[i].operation
        return self.planned_tools[op] if 0 <= op < len(self.planned_tools) else None

    @property
    def tool_change_entries(self) -> list[int]:
        """Timeline entries where the tool changes (the first entry of the new tool's program)."""
        out, last = [], None
        for i in range(len(self.timeline.entries)):
            t = self.tool_at_entry(i)
            if t is None:
                continue
            if last is not None and last.id != t.id:
                out.append(i)
            last = t
        return out

    def tool_change(self, i: int):
        """(from, to) for the tool change starting at entry i, or None."""
        if i not in self.tool_change_entries:
            return None
        to = self.tool_at_entry(i)
        if to is None:
            return None
        frm = next((t for t in (self.tool_at_entry(k) for k in range(i - 1, -1, -1)) if t is not None), None)
        return frm, to

    def begin_tool_change(self, i: int, resume: bool, play_end: float | None) -> None:
        change = self.tool_change(i)
        if change is None:
            return
        self.pause()
        t = self.timeline.entries[i].t_start
        self.quiet_seek(max(t - 1e-6, 0))
        path, note = self.tool_change_path(np.asarray(self.machine_position, float), change[0])
        self.tool_change_stop = ToolChangeStop(t, i, change[0], change[1], "moving", resume, play_end, note)
        self.touch()

        def arrived():
            s = self.tool_change_stop
            if s is None or s.entry != i:
                return
            s.phase = "waiting"
            self.status = f"Tool change: fit the {change[1].name}"
            self.touch()

        self.animate_machine(path, arrived)

    def confirm_tool_change(self) -> None:
        """"Tool Changed": the new tool goes in, the machine goes back to the next cut, and
        playback carries on (when it was playing)."""
        stop = self.tool_change_stop
        if stop is None or stop.phase != "waiting":
            return
        stop.phase = "returning"
        self.current_tool = stop.to
        self.ensure_tool_mesh(stop.to)
        start = self.timeline.entries[stop.entry].start
        target = self.machine_position_for_work(start, stop.to.stickout)
        mp = np.asarray(self.machine_position, float)
        target = mp if target is None else np.asarray(target, float)
        back = list(reversed(self.tool_change_path(target, stop.to)[0]))
        path = [mp, np.array([mp[0], mp[1], self.machine.machine_envelope.z.upper])] + back[1:]
        self.touch()

        def done():
            s = self.tool_change_stop
            if s is None or s.entry != stop.entry:
                return
            self.tool_change_stop = None
            self.tool_changes_done.add(stop.entry)
            self.quiet_seek(s.time + 1e-6)
            self.status = f"Tool changed: {s.to.name}"
            if s.resume:
                self.play_until(s.play_end)
            self.touch()

        self.animate_machine(path, done)

    def cancel_tool_change(self) -> None:
        if self.tool_change_stop is None:
            return
        if self.tool_change_task is not None:
            self.tool_change_task.cancel()
        self.tool_change_stop = None
        self.update_playback()
        self.touch()

    # ---------------------------------------------------------------- a path that keeps clear

    def _head_trees(self):
        if self.head_trees is not None:
            return self.head_trees
        mm = self.machine_model
        if mm is None:
            return None

        def tree(group):
            return TriangleTree(_mesh_triangles([p for p in mm.parts if p.group == group and not p.role.startswith("enclosure")]))

        self.head_trees = (tree("z"), tree("y"))
        return self.head_trees

    def bed_tree_built(self):
        """What's on the table now (fixtures, parallels, stock), at the table's modelled pose."""
        if self.bed_tree is not None and self.bed_tree[0] == self.collision_generation:
            return self.bed_tree[1]
        if not self.bed_bodies:
            return None
        t = TriangleTree(bed_triangles(self.bed_bodies))
        self.bed_tree = (self.collision_generation, t)
        return t

    def _tool_tree(self, tool):
        if tool is None or self.machine_model is None:
            return None
        tip = np.asarray(self.tip_at_model_pose(tool.stickout), float)
        r = max(tool.diameter, tool.shank_diameter) / 2
        tris = []
        n = 16
        for k in range(n):
            a, b = 2 * math.pi * k / n, 2 * math.pi * (k + 1) / n
            pa, pb = np.array([r * math.cos(a), r * math.sin(a), 0]), np.array([r * math.cos(b), r * math.sin(b), 0])
            lo, hi = tip, tip + np.array([0, 0, tool.stickout])
            tris += [lo + pa, lo + pb, hi + pb, lo + pa, hi + pb, hi + pa, lo, lo + pb, lo + pa]
        return TriangleTree(np.asarray(tris))

    def head_clear(self, q, tool, bed=None) -> bool:
        """Whether the spindle head, the translator and the tool keep clear of what's on the table
        at machine position q."""
        g, mm = self.planning_geometry, self.machine_model
        bed = bed if bed is not None else self.bed_tree_built()
        if g is not None and mm is not None and bed is not None:
            if self.profile_collision_trees is None:
                trees = {}
                groups: dict[str, list] = {}
                for p in mm.parts:
                    groups.setdefault(p.group, []).append(p)
                for id, parts in groups.items():
                    if g.moves_with_table(id):
                        continue
                    current, on_table = id, False
                    while current is not None:
                        comp = next((c for c in g.definition.components if c.id == current), None)
                        if comp is None:
                            break
                        if current == g.table_component_id:
                            on_table = True
                            break
                        current = comp.parent_id
                    if on_table:
                        continue
                    trees[id] = TriangleTree(_mesh_triangles(parts))
                self.profile_collision_trees = trees
            try:
                translations = g.component_translations(Vec3(q[0], q[1], q[2]))
            except Exception:  # noqa: BLE001
                return False
            table, head = translations.get(g.table_component_id), translations.get(g.head_component_id)
            if table is None or head is None:
                return False
            for id, tree in self.profile_collision_trees.items():
                t = translations.get(id)
                if t is None:
                    return False
                if tree.touches(bed, (table.x - t.x, table.y - t.y, table.z - t.z)):
                    return False
            tt = self._tool_tree(tool)
            if tt is not None and tt.touches(bed, (table.x - head.x, table.y - head.y, table.z - head.z)):
                return False
            return True
        trees = self._head_trees()
        if mm is None or trees is None or bed is None:
            return True
        m = np.array([mm.model_pose.x, mm.model_pose.y, mm.model_pose.z])
        q = np.asarray(q, float)
        to_head, to_translator = m - q, np.array([m[0] - q[0], m[1] - q[1], 0])
        if trees[0].touches(bed, to_head) or trees[1].touches(bed, to_translator):
            return False
        tt = self._tool_tree(tool)
        return not (tt is not None and tt.touches(bed, to_head))

    def leg_clear(self, a, b, tool) -> bool:
        a, b = np.asarray(a, float), np.asarray(b, float)
        n = max(math.ceil(np.linalg.norm(b - a) / 2), 1)
        return all(self.head_clear(a + (b - a) * k / n, tool) for k in range(1, n + 1))

    def roomy(self, q, tool, bed=None) -> bool:
        m = TOOL_CHANGE_ROOM
        q = np.asarray(q, float)
        return all(self.head_clear(q + np.array(d), tool, bed) for d in ((0, 0, 0), (m, 0, 0), (-m, 0, 0), (0, m, 0), (0, -m, 0), (0, 0, -m)))

    def tool_change_spot(self) -> ToolChangeSpot:
        """Where to change tools in this job: the table down (X) and the spindle forward to the
        maker's Z if it can, at the Y nearest theirs that keeps room in every clamping."""
        tools = [p.tool for p in self.programs] + [EdgeFinding.TOOL]
        longest = tools[0]
        for t in tools[1:]:
            if longest.stickout < t.stickout:
                longest = t
        key = f"{self.setup!r}|{self.stock_id or ''}|{[t.id for t in tools]}|{self.twoSided}"
        if self.tool_change_spot_cache is not None and self.tool_change_spot_cache[0] == key:
            return self.tool_change_spot_cache[1]
        env, tc = self.machine.machine_envelope, self.machine.tool_change_pose
        views = [0, 1] if self.twoSided else [0]
        saved = self.viewSide
        self.switching_view = True
        beds = []
        try:
            ys = [tc[1]]
            for k in range(1, 61):
                for y in (tc[1] + 4 * k, tc[1] - 4 * k):
                    if env.y.lower + 4 <= y <= env.y.upper - 4:
                        ys.append(y)
            for v in views:
                self._viewSide = v
                self._layout_scene()
                t = self.bed_tree_built()
                if t is not None:
                    beds.append(t)
        finally:
            self._viewSide = saved
            self._layout_scene()
            self.switching_view = False

        def forward(y, room, better):
            z = tc[2]
            while z <= env.z.upper + 1e-9 and z < better - 1e-9:
                q = (tc[0], y, z)
                if all(self.roomy(q, longest, b) if room else self.head_clear(q, longest, b) for b in beds):
                    return z
                z += 4
            return None

        best = None
        y0 = next((y for y in ys if all(self.roomy((tc[0], y, tc[2]), longest, b) for b in beds)), None)
        if y0 is not None:
            best = (y0, tc[2], True)
        else:
            for room in (True, False):
                if best is not None:
                    break
                for y in ys[:24]:
                    z = forward(y, room, best[1] if best is not None else math.inf)
                    if z is not None:
                        best = (y, z, room)
        spot = ToolChangeSpot(best[0] if best else tc[1], best[1] if best else tc[2])
        notes = []
        if abs(spot.y - tc[1]) >= 2:
            notes.append(f"It stops at Y{Length.mm(spot.y)} instead of the maker's Y{Length.mm(tc[1])}: there the spindle would be right beside the clamps or the stock, with no room for your hands and the wrenches.")
        if best is not None and best[1] > tc[2] + 1e-9:
            what = f"come within {Length.mm(TOOL_CHANGE_ROOM)} mm of" if best[2] else "touch"
            notes.append(f"The spindle comes forward to Z{Length.mm(best[1])}, {Length.mm(best[1] - tc[2])} mm less than the maker's Z{Length.mm(tc[2])}: further forward it would {what} what's on the table. The collet nut is still in front of the machine, in reach.")
        if best is not None and not best[2]:
            notes.append(f"There's less than {Length.mm(TOOL_CHANGE_ROOM)} mm around the spindle here: mind your fingers and the wrenches on the clamps.")
        if best is None:
            notes.append("No spot in the travel keeps the spindle clear of the clamps: check the clearance by hand before it comes forward.")
        spot.note = " ".join(notes) if notes else None
        self.tool_change_spot_cache = (key, spot)
        return spot

    def prepare_tool_change_spot(self) -> None:
        """Finds the spot just after the job appears."""
        def run():
            yield Sleep(0.4)
            if not self.is_playing and self.tool_change_stop is None and self.programs:
                self.tool_change_spot()

        spawn(run(), "tool change spot")

    def tool_change_path(self, p, tool) -> tuple[list[np.ndarray], str | None]:
        """From p to the job's tool-change spot, the way the machine can go without touching the
        clamps, parallels or stock."""
        env, tc = self.machine.machine_envelope, self.machine.tool_change_pose
        spot = self.tool_change_spot()
        p = np.asarray(p, float)
        back = np.array([p[0], p[1], env.z.upper])
        path = [p, back]
        note = spot.note
        orders = [[np.array([p[0], spot.y, back[2]]), np.array([tc[0], spot.y, back[2]])],
                  [np.array([tc[0], p[1], back[2]]), np.array([tc[0], spot.y, back[2]])]]
        clear = next((o for o in orders if self.leg_clear(back, o[0], tool) and self.leg_clear(o[0], o[1], tool)), None)
        if clear is None:
            note = (note + " " if note else "") + "Moving over to the tool-change position the head would touch what's on the table: check it by hand."
        path += clear or orders[0]
        top = np.array([tc[0], spot.y, back[2]])
        out = np.array([tc[0], spot.y, spot.z])
        while out[2] < back[2] - 1e-9 and not self.leg_clear(top, out, tool):
            out[2] = min(out[2] + 2, back[2])
        if not np.array_equal(out, top):
            path.append(out)
        clean = []
        for q in path:
            if not clean or np.linalg.norm(clean[-1] - q) > 1e-6:
                clean.append(q)
        return clean, note

    def animate_machine(self, path: list, done) -> None:
        """Moves the machine through machine positions at a pace a person can follow."""
        if self.tool_change_task is not None:
            self.tool_change_task.cancel()
        scripted = "COASTLINE_SCRIPT" in os.environ and "COASTLINE_ANIMATE" not in os.environ
        if scripted or len(path) <= 1:
            if path:
                self.set_machine_position(path[-1])
            done()
            return

        def run():
            for k in range(1, len(path)):
                a, b = np.asarray(path[k - 1], float), np.asarray(path[k], float)
                span = max(np.linalg.norm(b - a) / 60, 0.3)
                start = time.monotonic()
                while True:
                    t = min((time.monotonic() - start) / span, 1)
                    e = t * t * (3 - 2 * t)
                    self.set_machine_position(a + (b - a) * e)
                    if self.current_tool is not None:
                        self.ensure_tool_mesh(self.current_tool)
                    if t >= 1:
                        break
                    yield Sleep(0.016)
            done()

        self.tool_change_task = spawn(run(), "tool change")
