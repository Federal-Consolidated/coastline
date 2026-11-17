"""Switching the side on screen, with the clamping animation. Port of Model/StageTransition.swift."""

from __future__ import annotations

import os
import time

import numpy as np

from ...viewport.scene import box_mesh
from ..tasks import Sleep, spawn

HIDE = ["part", "stock", "stock.edges", "simstock", "simstock.back", "simstock.walls", "simstock.loose", "toolpath", "tabs",
        "cutface", "cutface.edges", "undercuts", "clearance"]


def quat_from_matrix(m) -> np.ndarray:
    """(w, x, y, z) of a rotation matrix."""
    m = np.asarray(m, float)
    t = np.trace(m)
    if t > 0:
        s = np.sqrt(t + 1.0) * 2
        q = [0.25 * s, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s]
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = [(m[2, 1] - m[1, 2]) / s, 0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s]
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = [(m[0, 2] - m[2, 0]) / s, (m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s]
    else:
        s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = [(m[1, 0] - m[0, 1]) / s, (m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s]
    q = np.array(q)
    return q / np.linalg.norm(q)


def quat_matrix(q) -> np.ndarray:
    w, x, y, z = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def slerp(a, b, t: float) -> np.ndarray:
    a, b = np.asarray(a, float), np.asarray(b, float)
    d = float(np.dot(a, b))
    if d < 0:
        b, d = -b, -d
    if d > 0.9995:
        q = a + (b - a) * t
        return q / np.linalg.norm(q)
    th = np.arccos(min(d, 1.0))
    return (np.sin((1 - t) * th) * a + np.sin(t * th) * b) / np.sin(th)


def ease(t: float) -> float:
    return t * t * (3 - 2 * t)


def animations_on() -> bool:
    return "COASTLINE_SCRIPT" not in os.environ or "COASTLINE_ANIMATE" in os.environ


class StageTransitionMixin:
    def show_side_number(self, side: int) -> None:
        """Shows another side (0 = A, 1 = B, 2… the side setups) with the clamping animation."""
        old = self.viewSide
        if old == side:
            return
        # The step shown follows the side: a step of another side would bring its fixture along.
        plan = self.library_workholding_plan
        if plan is not None:
            step = next((s for s in plan.steps if s.id == self.selected_library_step), None)
            if step is not None and step.side != side:
                nxt = next((s for s in plan.steps if s.side == side), None)
                self.selected_library_step = nxt.id if nxt is not None else None
        self.switching_view = True
        self.viewSide = side
        self.switching_view = False
        self.transition(old)

    def transition(self, old: int) -> None:
        """Re-lays the scene for the new view the way it happens at the machine: the fixture
        releases, the stock lifts out and turns the way it goes next, the next setup's fixture
        comes in, then the stock goes in."""
        def finish():
            if self.result_for_side(self.viewSide) is None:
                self.layout_scene()
            else:
                self.show_side()

        to = self.stock_box_for_side(self.viewSide)
        if not animations_on() or to is None:
            if self.flip_task is not None:
                self.flip_task.cancel()
            self.scene.remove("stock.anim")
            self.stock_animating = False
            finish()
            return
        self.animate_clamping(self.stock_box_for_side(old), to, self.turn(old, self.viewSide), finish)

    def turn(self, old: int, new: int) -> np.ndarray:
        """The rotation (quaternion w, x, y, z) taking the stock as one side's setup holds it to how
        the other's holds it."""
        base = self.setup.part_rotation.T
        r = (self.setup_for(max(new, 0)).part_rotation @ base) @ (self.setup_for(max(old, 0)).part_rotation @ base).T
        return quat_from_matrix(r)

    def _run(self, duration: float, step):
        start = time.monotonic()
        while True:
            t = min((time.monotonic() - start) / duration, 1.0)
            step(t)
            if t >= 1:
                return
            yield Sleep(0.016)

    def animate_clamping(self, a, b, q, done) -> None:
        """The clamping sequence, with a stand-in box for the stock; the real stock, part and paths
        are hidden until it's in."""
        if self.flip_task is not None:
            self.flip_task.cancel()
        self.stock_animating = True
        scene = self.scene
        scene.remove("stock.anim")
        stock = self.stock
        colour = self.linear_swatch(stock.material) if stock is not None and stock.material is not None else (0.6, 0.6, 0.62)
        proxy = box_mesh("stock.anim", (-0.5, -0.5, -0.5), (0.5, 0.5, 0.5), (*colour, 1.0))
        src = scene.mesh("simstock") or scene.mesh("stock")
        if src is not None:
            proxy.material = src.material

        def hide_work():
            for id in HIDE:
                m, ln = scene.mesh(id), scene.line_set(id)
                if m is not None:
                    m.visible = False
                if ln is not None:
                    ln.visible = False

        # The box's own size at the end: the old one, turned (it never changes shape on the way).
        qi = quat_matrix(q).T
        end_local = np.abs(qi @ np.asarray(b[1], float))
        identity = np.array([1.0, 0, 0, 0])

        def place(centre, turn, size):
            m = np.eye(4)
            m[:3, :3] = quat_matrix(slerp(identity, q, turn)) @ np.diag(np.asarray(size, float))
            m[:3, 3] = centre
            proxy.transform = m

        lift = np.array([45.0, 0, 0])  # X is up

        def finish():
            scene.remove("stock.anim")
            self.stock_animating = False
            done()

        def fade(meshes, f):
            for m, w in meshes:
                c = m.color
                m.color = (c[0], c[1], c[2], w * f)

        def run():
            # 1. The fixture releases: it fades out, the stock still in it.
            hide_work()
            if a is not None:
                place(a[0], 0, a[1])
                scene.add(proxy)
            old = [(m, m.color[3]) for m in scene.meshes.values() if m.id.startswith("fixture.") and m.visible]
            yield from self._run(0.35, lambda t: fade(old, 1 - ease(t)))
            for m, _ in old:
                m.visible = False
            # 2. The stock lifts out.
            if a is not None:
                yield from self._run(0.45, lambda t: place(a[0] + lift * ease(t), 0, a[1]))
            # 3. The next setup's fixture comes in; the stock, in the air, turns over it.
            self.layout_scene()
            hide_work()
            new = [(m, m.color[3]) for m in scene.meshes.values() if m.id.startswith("fixture.") and m.visible]
            fade(new, 0)
            start = a[0] + lift if a is not None else np.asarray(b[0]) + lift + np.array([30.0, 0, 0])
            start_size = np.asarray(a[1] if a is not None else b[1], float)
            start_turn = 1.0 if a is None else 0.0
            park = np.asarray(b[0]) + lift
            if a is None:
                place(start, 1, end_local)
                scene.add(proxy)

            def step3(t):
                e = ease(t)
                for m, w in new:
                    c = m.color
                    m.color = (c[0], c[1], c[2], w * min(t * 1.6, 1))
                place(start + (park - start) * e, start_turn + (1 - start_turn) * e, start_size + (end_local - start_size) * e)

            yield from self._run(0.75, step3)
            for m, w in new:
                c = m.color
                m.color = (c[0], c[1], c[2], w)
            # 4. The stock goes down into the fixture.
            yield from self._run(0.5, lambda t: place(park + (np.asarray(b[0]) - park) * ease(t), 1, end_local))
            finish()

        self.flip_task = spawn(run(), "clamping")

    def stock_box_for_side(self, side: int):
        """The stock's box in the model for a side: (centre, size)."""
        stock = self.stock
        if stock is None:
            return None
        s = self.setup_for(side if side >= 2 else 0).stock_size(stock)
        o = self.work_to_model(s)
        return (np.asarray(o, float) - np.array([0, 0, s[2] / 2]), np.asarray(s, float))
