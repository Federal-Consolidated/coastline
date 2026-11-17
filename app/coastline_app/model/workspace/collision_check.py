"""The collision engine at work in the 3D view: after every layout the fixtures, the stock and the
machine are checked against each other in the background; what collides turns red, gets a marker,
and is listed with the issues. Port of Model/CollisionCheck.swift and Model/TravelSweep.swift."""

from __future__ import annotations

import math
import os
import time
from dataclasses import dataclass

import numpy as np

from ...core.geometry import Vec3
from ...core.inventory.checks import Issue, Severity
from ...core.safety.collision import Body, Collision, TriangleTree
from ...core.units import Length
from ...viewport.scene import SceneColor, SceneLines, segments
from ..tasks import Sleep, Work, spawn

MACHINE_BODY_NAME = "the machine (bed, frame)"


@dataclass
class BedBody:
    """One object on the bed: a fixture (its triangles) or a box (the stock)."""

    name: str
    mesh_prefix: str  # scene meshes of this body (tinted when it collides)
    box: tuple | None = None  # (lo, hi)
    triangles: np.ndarray | None = None


def bed_triangles(bodies: list[BedBody]) -> np.ndarray:
    parts = [Collision.box_triangles(b.box[0], b.box[1]) if b.box is not None else np.asarray(b.triangles, float).reshape(-1, 3)
             for b in bodies]
    return np.concatenate(parts) if parts else np.zeros((0, 3))


def collide(bodies: list[BedBody], machine: TriangleTree | None) -> list:
    out = [Body.box(b.name, b.box[0], b.box[1]) if b.box is not None else Body.from_triangles(b.name, b.triangles) for b in bodies]
    if machine is not None:
        out.append(Body(MACHINE_BODY_NAME, machine))
    # Contact by design is touching; up to 0.2 mm is a key in a T-slot or a modelling tolerance.
    return Collision.check(out, tolerance=0.2)


def _mesh_triangles(parts, offsets: dict | None = None) -> np.ndarray:
    out = []
    for p in parts:
        v = np.asarray(p.mesh.vertices, float).reshape(-1, 3)
        t = v[np.asarray(p.mesh.indices, np.int64).reshape(-1)]
        if offsets is not None:
            o = offsets.get(p.group)
            if o is not None:
                t = t + np.array([o.x, o.y, o.z])
        out.append(t)
    return np.concatenate(out) if out else np.zeros((0, 3))


class CollisionCheckMixin:
    def machine_collision_tree(self):
        """A task step: the machine's fixed parts and the table, built once (the largest mesh)."""
        mm = self.machine_model
        if mm is None:
            return None
        reference = self.planning_machine_reference
        offsets = {}
        key = "legacy"
        g = self.planning_geometry
        if g is not None:
            p = self.machine_position
            try:
                translations = g.component_translations(Vec3(p[0], p[1], p[2]))
            except Exception:  # noqa: BLE001
                return None
            table = translations.get(g.table_component_id)
            if table is None:
                return None
            key = f"{reference.reference.id}:{reference.reference.revision}:{table.x},{table.y},{table.z}"
            parts = [q for q in mm.parts if not g.is_moving(q.group) or g.moves_with_table(q.group)]
            offsets = {id: Vec3(t.x - table.x, t.y - table.y, t.z - table.z) for id, t in translations.items()}
        else:
            parts = [q for q in mm.parts if q.group in ("static", "x")]
        if self.machine_tree_key == key:
            if self.machine_tree is not None:
                return self.machine_tree
            if self.machine_tree_task is not None and not self.machine_tree_task.finished:
                yield self.machine_tree_task
                return self.machine_tree
        if self.machine_tree_task is not None:
            self.machine_tree_task.cancel()
        self.machine_tree = None
        self.machine_tree_key = key
        token = object()
        self.machine_tree_task_id = token

        def build():
            tree = yield Work(lambda: TriangleTree(_mesh_triangles(parts, offsets)), lane="collision")
            if self.machine_tree_task_id is token and self.planning_machine_reference == reference:
                self.machine_tree = tree
            return tree

        self.machine_tree_task = spawn(build(), "machine tree")
        yield self.machine_tree_task
        return self.machine_tree

    def schedule_collision_check(self, bodies: list[BedBody], stock_size) -> None:
        self.collision_generation += 1
        generation = self.collision_generation
        if not bodies or self.stock is None or self.showing_stock_only or "COASTLINE_NO_COLLISIONS" in os.environ:
            if self.collisions:
                self.collisions = []
                self.touch()
            self.show_collisions()
            return
        o = np.asarray(self.work_origin(stock_size), float)
        s = stock_size
        all_ = list(bodies)
        if not self.setup.plan_from_fixture_library:
            all_.append(BedBody("the stock", "stock", box=((o[0] - s[0] / 2, o[1] - s[1] / 2, o[2] - s[2]), (o[0] + s[0] / 2, o[1] + s[1] / 2, o[2]))))
        self.bed_bodies = all_

        def run():
            yield Sleep(0.06)  # let a drag settle: only the latest layout is checked
            if generation != self.collision_generation:
                return
            machine = yield from self.machine_collision_tree()
            if generation != self.collision_generation:
                return
            found = yield Work(lambda: collide(all_, machine), lane="collision")
            if generation != self.collision_generation:
                return
            if found != self.collisions:
                self.collisions = found
                self.touch()
            self.collision_prefixes = {}
            for b in all_:
                self.collision_prefixes.setdefault(b.name, b.mesh_prefix)
            self.show_collisions()

        spawn(run(), "collision check")

    @property
    def collision_issues(self) -> list[Issue]:
        return [Issue(Severity.WARNING, f"{c.a[:1].upper() + c.a[1:]} runs into {c.b} by about {Length.mm(max(c.depth, 0.1))} mm.")
                for c in self.collisions]

    def show_collisions(self) -> None:
        """A marker where colliding things meet."""
        scene = self.scene
        scene.remove("collision")
        if not self.collisions:
            return
        pairs = []
        r = 3.0
        for c in self.collisions:
            p = np.asarray(c.point, float)
            for d in np.eye(3) * r:
                pairs.append((p - d, p + d))
            for k in range(24):
                a, b = k / 24 * 2 * math.pi, (k + 1) / 24 * 2 * math.pi
                pairs.append((p + np.array([0, math.cos(a), math.sin(a)]) * r, p + np.array([0, math.cos(b), math.sin(b)]) * r))
        scene.add(SceneLines("collision", segments(pairs, SceneColor.danger)))

    # ---------------------------------------------------------------- travel sweep

    def sweep_travel(self, duration: float = 9.0) -> None:
        """Drives the modelled machine through its whole travel with the bit in the collet; the
        tool tip's path, drawn on the table, is the real work volume."""
        mm = self.machine_model
        if not self.machineLoaded or mm is None:
            return
        pose = np.array([mm.model_pose.x, mm.model_pose.y, mm.model_pose.z])
        self.pause()
        if self.flip_task is not None:
            self.flip_task.cancel()
        self.stock_animating = False
        if self.current_tool is not None:
            self.ensure_tool_mesh(self.current_tool)
        e = self.machine.machine_envelope
        x0, x1, y0, y1, z0, z1 = e.x.lower, e.x.upper, e.y.lower, e.y.upper, e.z.lower, e.z.upper
        corners = np.array([(x0, y1, z1), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1),
                            (x0, y1, z0), (x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0),
                            (x0, y0, z0), (x0, y0, z1), (x1, y0, z1), (x1, y0, z0),
                            (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)], float)
        lengths = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(corners, axis=0), axis=1))])
        total = lengths[-1] or 1.0
        tip0 = np.asarray(self.tip_at_model_pose(), float)
        self.scene.remove("travel.trace")
        self.status = "Sweeping the machine's travel…"
        start = time.monotonic()

        def run():
            trace = []
            while True:
                t = min((time.monotonic() - start) / duration, 1)
                s = t * total
                k = int(np.searchsorted(lengths, s, side="right") - 1)
                if k >= len(corners) - 1:
                    q = corners[-1]
                else:
                    f = (s - lengths[k]) / max(lengths[k + 1] - lengths[k], 1e-9)
                    q = corners[k] + (corners[k + 1] - corners[k]) * f
                self.set_machine_position(q)
                trace.append(tip0 + (q - pose))
                if len(trace) > 1:
                    pts = np.asarray(trace)
                    self.scene.add(SceneLines("travel.trace", segments(np.stack([pts[:-1], pts[1:]], axis=1), SceneColor.line(175))))
                if t >= 1:
                    self.status = "Travel sweep done: the path is everywhere the tool tip can reach."
                    return
                yield Sleep(0.016)

        self.flip_task = spawn(run(), "travel sweep")
