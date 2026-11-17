"""The gumball: placing the part in the stock and library fixtures on the bed. An arrow per axis
and a ring per axis; dragging moves the target in snaps, never past where it still makes sense.
Clicking a handle without dragging types the move. Port of Model/Gumball.swift and
Model/GumballTyping.swift."""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from ...viewport.mesh_builder import MeshBuilder
from ...viewport.scene import SceneColor
from .geometry import translation

AXES = [("gumball.x", np.array([1.0, 0, 0]), (1.0, 0.07, 0.05, 1.0)),
        ("gumball.y", np.array([0, 1.0, 0]), (0.03, 0.58, 0.12, 1.0)),
        ("gumball.z", np.array([0, 0, 1.0]), (0.0, 0.24, 1.0, 1.0))]
RING_IDS = ["gumball.ring.x", "gumball.ring.y", "gumball.ring.z"]
RING_SHARE = 0.62
HOT = (1.0, 0.78, 0.0, 1.0)
PROMPT_TITLES = {"gumball.x": "Up / down", "gumball.y": "Along Y", "gumball.z": "Toward the spindle",
                 "gumball.ring.x": "Turn about X", "gumball.ring.y": "Turn about Y", "gumball.ring.z": "Turn about Z"}


def ring_basis(k: int):
    """Two unit vectors spanning ring k's plane, right-handed with its axis."""
    if k == 0:
        return np.array([0, 1.0, 0]), np.array([0, 0, 1.0]), np.array([1.0, 0, 0])
    if k == 1:
        return np.array([0, 0, 1.0]), np.array([1.0, 0, 0]), np.array([0, 1.0, 0])
    return np.array([1.0, 0, 0]), np.array([0, 1.0, 0]), np.array([0, 0, 1.0])


@dataclass
class GumballDrag:
    axis: str  # an arrow, a ring, or "gumball.fixturePlane"
    dir: np.ndarray
    origin: np.ndarray
    t0: float
    start: object  # Setup
    target: tuple  # ("part",) or ("libraryFixture", component id)
    down_at: tuple = (0.0, 0.0)
    moved: bool = False
    from_handle: bool = False
    fixture_start: object | None = None


@dataclass
class GumballPrompt:
    """A typed move waiting for its value."""

    axis: str
    target: tuple
    point: tuple

    @property
    def is_ring(self) -> bool:
        return self.axis.startswith("gumball.ring")

    @property
    def title(self) -> str:
        return PROMPT_TITLES.get(self.axis, "Move")

    @property
    def unit(self) -> str:
        return "°" if self.is_ring else "mm"


def _segment_distance(p, a, b) -> float:
    ab = (b[0] - a[0], b[1] - a[1])
    ap = (p[0] - a[0], p[1] - a[1])
    l2 = max(ab[0] ** 2 + ab[1] ** 2, 1e-9)
    t = min(max((ap[0] * ab[0] + ap[1] * ab[1]) / l2, 0), 1)
    return math.hypot(p[0] - (a[0] + ab[0] * t), p[1] - (a[1] + ab[1] * t))


class GumballMixin:
    @property
    def showing_stock_only(self) -> bool:
        """Stage 1 shows only the stock as bought and the part in it."""
        return self.fixture_placement is None and self.stage in ("partStock", "stock")

    def part_centre_world(self):
        part, m = self.part, self.scene.mesh("part")
        if part is None or m is None:
            return None
        c = (np.asarray(part.bounds_min, float) + np.asarray(part.bounds_max, float)) / 2
        w = self.scene.group_transform(m.group) @ np.asarray(m.transform, float) @ np.array([*c, 1.0])
        return w[:3]

    @property
    def gumball_length(self) -> float:
        cam = self.renderer.camera
        return max((cam.distance if cam is not None else 300) * 0.12, 6)

    @property
    def gumball_target(self):
        s = self.fixture_placement
        if s is not None:
            return None if s.picking_grip else ("libraryFixture", s.selected_component)
        if self.stage == "setups":
            return ("part",)
        return None

    def gumball_axes(self, t) -> list:
        if t[0] == "part":
            return AXES
        id = t[1]
        if self.placing_bookends:
            return [a for a in AXES if a[0] == "gumball.y"] if self.can_move_bookend_component(id) else []
        if self.placing_mechanism:
            k = self.mechanism_axis(id)
            return [AXES[k]] if k is not None else []
        return AXES

    def gumball_origin(self, t):
        return self.placement_gumball_origin(t[1]) if t[0] == "libraryFixture" else self.part_centre_world()

    def ring_axes(self, t) -> list[int]:
        if t[0] == "part":
            return [0, 1, 2]
        return [] if self.placing_bookends or self.placing_mechanism else [0, 1, 2]

    def layout_gumball(self) -> None:
        scene = self.scene
        for a in AXES:
            scene.remove(a[0])
        for id in RING_IDS:
            scene.remove(id)
        scene.remove("gumball.centre")
        target = self.gumball_target
        o = self.gumball_origin(target) if target is not None else None
        if o is None:
            return
        o = np.asarray(o, float)
        ln = self.gumball_length
        r = ln * 0.011
        drag = self.gumball_drag
        for id, d, colour in self.gumball_axes(target):
            b = MeshBuilder()
            b.cylinder(r, ln * 0.12, ln * 0.84, 20)
            b.cone(r * 3.6, ln * 0.84, 0, ln)
            rot = np.eye(4)
            if d[0] > 0.5:
                rot[:3, :3] = [[0, 0, 1], [0, 1, 0], [-1, 0, 0]]  # +Z → +X (a quarter turn about Y)
            elif d[1] > 0.5:
                rot[:3, :3] = [[1, 0, 0], [0, 0, 1], [0, -1, 0]]  # +Z → +Y (a quarter turn about −X)
            m = b.mesh(id, HOT if drag is not None and drag.axis == id else colour, translation(o) @ rot)
            m.on_top = True
            m.unlit = True
            scene.add(m)
        for k in self.ring_axes(target):
            id = RING_IDS[k]
            u, v, n = ring_basis(k)
            b = MeshBuilder()
            b.torus(ln * RING_SHARE, r * 1.2)
            basis = np.eye(4)
            basis[:3, 0], basis[:3, 1], basis[:3, 2] = u, v, n
            m = b.mesh(id, HOT if drag is not None and drag.axis == id else AXES[k][2], translation(o) @ basis)
            m.on_top = True
            m.unlit = True
            scene.add(m)
        c = MeshBuilder()
        c.ball_end(r * 2.6, -r * 2.6)
        m = c.mesh("gumball.centre", SceneColor.surface(0.9), translation(o))
        m.on_top = True
        m.unlit = True
        scene.add(m)

    # ---------------------------------------------------------------- dragging

    def _project(self, w):
        v = self.renderer.view
        return v.project(np.asarray(w, float)) if v is not None else None

    def _ray(self, x: float, y: float):
        return self.renderer.ray(x, y)

    def gumball_begin(self, x: float, y: float) -> bool:
        """Mouse down: an arrow or ring under the point, or on the bed a fixture itself. False:
        the camera gets the drag."""
        p = (x, y)
        if self.fixture_placement is not None and self.fixture_placement.picking_grip:
            return False
        target = self.gumball_target
        o = self.gumball_origin(target) if target is not None else None
        if o is not None:
            o = np.asarray(o, float)
            ln = self.gumball_length
            best = None
            for id, d, _ in self.gumball_axes(target):
                s0, s1 = self._project(o), self._project(o + d * ln)
                if s0 is None or s1 is None:
                    continue
                dist = _segment_distance(p, s0, s1)
                if dist < 9 and dist < (best[2] if best else math.inf):
                    best = (id, d, dist, None)
            for k in self.ring_axes(target):
                u, v, n = ring_basis(k)
                pts = [self._project(o + (u * math.cos(a) + v * math.sin(a)) * ln * RING_SHARE) for a in np.arange(73) / 72 * 2 * math.pi]
                pts = [q for q in pts if q is not None]
                dist = min((_segment_distance(p, a, b) for a, b in zip(pts, pts[1:])), default=math.inf)
                if dist < 8 and dist < (best[2] if best else math.inf):
                    best = (RING_IDS[k], n, dist, k)
            if best is not None:
                if best[3] is not None:
                    a0 = self._ring_angle(p, o, best[3])
                    if a0 is None:
                        return False
                    t0 = a0
                else:
                    t0 = self._axis_parameter(p, o, best[1])
                    if t0 is None:
                        return False
                self.pause()
                fs = self.fixture_placement.fixture.planning if self.fixture_placement is not None else None
                self.gumball_drag = GumballDrag(best[0], best[1].copy(), o, t0, self.setup, target, p, from_handle=True, fixture_start=fs)
                self.gumball_prompt = None
                self.layout_gumball()
                self.touch()
                return True
        if self.fixture_placement is not None:
            hit = self.pick_placement_component(x, y)
            if hit is None:
                return False
            id, point = hit
            self.pause()
            self.select_placement_component(id)
            fs = self.fixture_placement.fixture.planning
            if self.placing_bookends or self.placing_mechanism:
                axis = (1 if self.can_move_bookend_component(id) else None) if self.placing_bookends else self.mechanism_axis(id)
                if axis is None:
                    self.layout_gumball()
                    return True
                d = np.zeros(3)
                d[axis] = 1
                t = self._axis_parameter(p, np.asarray(point, float), d)
                if t is None:
                    self.layout_gumball()
                    return True
                self.gumball_drag = GumballDrag(["gumball.x", "gumball.y", "gumball.z"][axis], d, np.asarray(point, float), t, self.setup,
                                                ("libraryFixture", id), p, fixture_start=fs)
                self.layout_gumball()
                return True
            ray = self._ray(x, y)
            self.gumball_drag = GumballDrag("gumball.fixturePlane", np.asarray(ray[1], float), np.asarray(point, float), 0.0, self.setup,
                                            ("libraryFixture", id), p, fixture_start=fs)
            self.layout_gumball()
            return True
        return False

    def gumball_move(self, x: float, y: float) -> None:
        d = self.gumball_drag
        if d is None:
            return
        p = (x, y)
        if not d.moved and math.hypot(x - d.down_at[0], y - d.down_at[1]) > 3:
            d.moved = True
        if not d.moved:
            return
        if d.axis in RING_IDS:
            k = RING_IDS.index(d.axis)
            a = self._ring_angle(p, d.origin, k)
            if a is None:
                return
            turn = math.remainder(a - d.t0, 2 * math.pi)
            q = int(_round(turn / (math.pi / 2)))
            if d.target[0] == "libraryFixture":
                if d.fixture_start is None:
                    return
                self.rotate_placement(k, q, d.fixture_start, d.target[1], False)
            else:
                s = self.placement_limited(d.start.turned(k, q))
                if s != self.setup:
                    self.setup = s
            self.layout_gumball()
            return
        if d.axis == "gumball.fixturePlane" and d.target[0] == "libraryFixture" and d.fixture_start is not None:
            ray = self._ray(x, y)
            ro, rd = np.asarray(ray[0], float), np.asarray(ray[1], float)
            normal = d.dir / np.linalg.norm(d.dir)
            den = float(rd @ normal)
            if abs(den) <= 1e-6:
                return
            hit = ro + rd * (float((d.origin - ro) @ normal) / den)
            scale = self.placement_drag_scale
            delta = (hit - d.origin) * scale
            snapped = np.array([_round(v) for v in delta]) / scale
            self.move_placement(snapped, d.fixture_start, d.target[1], False, snap=True)
            return
        t = self._axis_parameter(p, d.origin, d.dir)
        if t is None:
            return
        if d.target[0] == "libraryFixture":
            if d.fixture_start is None:
                return
            scale = self.placement_drag_scale
            if self.placing_bookends and d.target[1] == "pressure-screw":
                scale = max(10, scale)
            delta = _round((t - d.t0) * scale) / scale
            axis = {"gumball.x": 0, "gumball.y": 1}.get(d.axis, 2)
            self.move_placement(d.dir * delta, d.fixture_start, d.target[1], False, snap=True, snap_axes=[axis])
        else:
            delta = _round((t - d.t0) * 2) / 2  # 0.5 mm snaps
            s = d.start.copy()
            if d.axis == "gumball.x":
                s.part_offset_x = d.start.part_offset_x + delta
            elif d.axis == "gumball.y":
                s.part_offset_y = d.start.part_offset_y + delta
            else:
                s.top_allowance = d.start.top_allowance - delta  # toward the spindle = closer to the face
            limited = self.placement_limited(s)
            if limited != self.setup:
                self.setup = limited
        self.layout_gumball()

    def gumball_end(self) -> None:
        d = self.gumball_drag
        was_library = d is not None and d.target[0] == "libraryFixture"
        if d is not None and not d.moved and d.from_handle:
            self.gumball_drag = None
            self.gumball_prompt = GumballPrompt(d.axis, d.target, d.down_at)
            self.layout_gumball()
            self.touch()
            return
        self.gumball_drag = None
        self.layout_gumball()
        if was_library:
            return
        w = self.placement_warning
        if w is not None:
            self.status = w
        self.touch()

    def apply_typed(self, v: float, prompt: GumballPrompt) -> None:
        """Applies a typed move or turn to what the gumball holds."""
        try:
            if not math.isfinite(v) or abs(v) <= 1e-9:
                return
            if prompt.target[0] == "libraryFixture":
                if abs(v) >= 100_000:
                    return
                if prompt.axis in RING_IDS:
                    self.rotate_placement(RING_IDS.index(prompt.axis), int(_round(v / 90)), None, prompt.target[1], False)
                else:
                    delta = np.array([v if prompt.axis == "gumball.x" else 0, v if prompt.axis == "gumball.y" else 0, v if prompt.axis == "gumball.z" else 0])
                    self.move_placement(delta, None, prompt.target[1], False)
                return
            if prompt.axis in RING_IDS:
                q = int(_round(v / 90))
                if q == 0:
                    self.status = "The part turns in quarter turns (90°)."
                    return
                self.setup = self.placement_limited(self.setup.turned(RING_IDS.index(prompt.axis), q))
                return
            s = self.setup.copy()
            if prompt.axis == "gumball.x":
                s.part_offset_x += v
            elif prompt.axis == "gumball.y":
                s.part_offset_y += v
            else:
                s.top_allowance -= v
            limited = self.placement_limited(s)
            if limited != s:
                self.status = "Moved as far as the part's frame allows."
            self.setup = limited
        finally:
            self.gumball_prompt = None
            self.layout_gumball()
            self.touch()

    # ---------------------------------------------------------------- limits and snaps

    def placement_range(self, s):
        if self.part is None or self.stock is None:
            return None
        return s.placement_limits(self.part.bounds_min, self.part.bounds_max, self.stock, 6.35)

    def placement_limited(self, s):
        r = self.placement_range(s)
        if r is None:
            return s
        s = s.copy()
        s.part_offset_x = min(max(s.part_offset_x, r[0].lower), r[0].upper)
        s.part_offset_y = min(max(s.part_offset_y, r[1].lower), r[1].upper)
        s.top_allowance = min(max(s.top_allowance, r[2].lower), r[2].upper)
        return s

    @property
    def placement_warning(self) -> str | None:
        r = self.placement_range(self.setup)
        if r is None:
            return None
        if self.setup.part_offset_x in (r[0].upper, r[0].lower):
            return "The part meets the stock boundary. Existing finished stock faces can be left uncut; check the selected workholding's grip and clearance."
        return None

    def snap_part(self, snap: str) -> None:
        """centre, face, back, top, bottom, left, right."""
        r = self.placement_range(self.setup)
        if r is None:
            return
        s = self.setup.copy()
        if snap == "centre":
            s.part_offset_x = s.part_offset_y = 0.0
        elif snap == "face":
            s.top_allowance = 0.0
        elif snap == "back":
            s.top_allowance = r[2].upper
        elif snap == "top":
            s.part_offset_x = r[0].upper
        elif snap == "bottom":
            s.part_offset_x = r[0].lower
        elif snap == "left":
            s.part_offset_y = r[1].lower
        elif snap == "right":
            s.part_offset_y = r[1].upper
        self.setup = self.placement_limited(s)

    # ---------------------------------------------------------------- geometry helpers

    def _ring_angle(self, p, o, k: int):
        ray = self._ray(p[0], p[1])
        if ray is None:
            return None
        ro, rd = np.asarray(ray[0], float), np.asarray(ray[1], float)
        u, v, n = ring_basis(k)
        den = float(rd @ n)
        if abs(den) <= 1e-4:
            return None
        h = ro + rd * (float((o - ro) @ n) / den) - o
        return math.atan2(float(h @ v), float(h @ u))

    def _axis_parameter(self, p, o, d):
        ray = self._ray(p[0], p[1])
        if ray is None:
            return None
        ro = np.asarray(ray[0], float)
        rd = np.asarray(ray[1], float)
        rd = rd / np.linalg.norm(rd)
        w = ro - o
        b = float(rd @ d)
        denom = 1 - b * b
        if denom <= 1e-6:
            return None
        return (float(w @ d) - float(w @ rd) * b) / denom


def _round(v: float) -> float:
    """Swift's .rounded(): half away from zero."""
    return math.floor(v + 0.5) if v >= 0 else -math.floor(-v + 0.5)
