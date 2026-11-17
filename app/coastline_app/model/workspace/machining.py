"""Toolpath generation: every side's operations planned and generated, then posted per tool and
checked. Port of Model/Machining.swift (with ThreadMillingSetup.swift)."""

from __future__ import annotations

import copy
import dataclasses
import itertools
import math
import os
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from ...core import feeds as FeedsEngine
from ...core.codable import Range
from ...core.engine import cam
from ...core.engine.cam import PlannedOperation
from ...core.engine.client import EngineError
from ...core.export import surface_probe as SurfaceProbe
from ...core.feeds import OperationKind as K
from ...core.inventory.checks import InventoryChecks, Issue, Severity
from ...core.inventory.items import ToolKind
from ...core.plan import edge_finding as EdgeFinding
from ...core.plan import library_workholding as LWP
from ...core.plan import reference_bores as ReferenceBores
from ...core.plan.operation import DEFAULT_MIN_POCKET, Operation, OperationPlanner, ReferenceFeature
from ...core.plan.setup import Workholding
from ...core.plan.setup_side import SetupSide
from ...core.plan.threads import ThreadMilling, ThreadSpec
from ...core.plan.tuning import HIDDEN_CUSP_FACTOR, Tuning
from ...core.plan.workholding_profile import LibraryWorkholdingStep
from ...core.post import grbl_post as GRBLPost
from ...core.post.timeline import ToolpathTimeline
from ...core.post.toolpath import OperationToolpath, Role
from ...core.safety.fixture_clearance import NUT_RADIUS, FixtureClearance
from ...core.safety.gcode_validator import Context, GCodeValidator, time_estimate_seconds
from ...core.sim.stock_model import StockModel
from ...core.units import Length
from ..settings import AppSettings
from ..tasks import Cancelled, Work
from .generation import GenerationRun, SidePlan, StandInClamping, checks_for_air, safe_height
from .side_setups import end_keep_out, setup_title
from .smart_plan import StandInVise
from .tab_check import THROUGH_OVERSHOOT, THROUGH_SKIN

TIMING = "COASTLINE_TIMING" in os.environ
MINIMUM_GRIP = 3.0  # the least stock the clamp jaws must hold when the face is stood out past them
REFERENCE_BORES_ID = "5EF0B0E5-0000-4000-8000-00000000000A"
REFERENCE_WINDOWS_ID = "5EF0B0E5-0000-4000-8000-00000000000B"


@dataclass
class ToolProgram:
    """One G-code program: consecutive operations that use the same tool."""

    index: int
    side: int
    tool: object
    operations: list
    rpm: float
    gcode: str
    report: object  # GCodeValidator Report
    seconds: float
    warnings: list[str] = field(default_factory=list)
    min_stickout: float | None = None
    clearance_hits: list = field(default_factory=list)
    title: str | None = None
    surface_probe: str | None = None
    workholding_step: object | None = None

    @property
    def id(self) -> str:
        return str(self.index)

    @property
    def ops_title(self) -> str:
        return self.title or ", ".join(o.title for o in self.operations)

    @property
    def file_name(self) -> str:
        tool = self.tool.name.replace("/", "-").replace('"', "in").replace("·", "-")
        side = "Side B " if self.side == 1 else (SetupSide.words(self.side).title() + " " if self.side >= 2 else "")
        return f"{self.index + 1:02d} {side}{' + '.join(o.title for o in self.operations)} - {tool}.nc"


@dataclass
class SideResult:
    side: int
    setup: object
    planned: list
    paths: list
    operation_program: list[int]
    operation_lines: list


class SetupOrderError(Exception):
    pass


def depth_slices(p, part_bottom: float) -> list:
    """An adaptive roughing operation split into up to four depth slices, when it has four or more
    levels; anything else as it is."""
    if p.operation.kind != K.ADAPTIVE or not p.data.stepdown > 0.05:
        return [p]
    top = p.z_top
    bottom = max(p.z_min if p.z_min is not None else part_bottom, part_bottom)
    depth = top - bottom
    levels = math.ceil(depth / p.data.stepdown - 1e-9)
    if levels < 4:
        return [p]
    count = min(4, levels // 2)
    out = []
    for i in range(count):
        q = copy.copy(p)
        a, b = float(levels * i // count), float(levels * (i + 1) // count)
        q.z_top = top - depth * a / levels
        q.z_min = p.z_min if i == count - 1 else top - depth * b / levels
        q.frame_top = p.frame_top if p.frame_top is not None else p.z_top
        out.append(q)
    return out


def finish_strips(p, y: Range) -> list:
    """Raster-style 3D finishing in three strips across the stock's length, each its own job."""
    if p.operation.kind not in (K.STEEP_SHALLOW, K.PARALLEL, K.WATERLINE) or not y.upper - y.lower > 20:
        return [p]
    n = 3
    w = (y.upper - y.lower) / n
    out = []
    for i in range(n):
        q = copy.copy(p)
        q.tile = Range(-1e4 if i == 0 else y.lower + i * w - 0.05, 1e4 if i == n - 1 else y.lower + (i + 1) * w + 0.05)
        out.append(q)
    return out


def threads_last(planned: list) -> list:
    """Threads go into holes the other operations make: always after them (stable otherwise)."""
    return [p for p in planned if p.operation.kind != K.THREAD] + [p for p in planned if p.operation.kind == K.THREAD]


def setup_orders(sides: list[int], turn) -> list[list[int]]:
    """The setup orders worth comparing, the planner's own first. Side B stays last."""
    unique = []
    for s in sides:
        if s not in unique:
            unique.append(s)
    last = [1] if 1 in unique else []
    movable = [s for s in unique if s != 1]
    out = [movable + last]
    if len(movable) <= 3:
        for p in itertools.permutations(movable):
            if list(p) != movable:
                out.append(list(p) + last)
    elif movable:
        order, left = [movable[0]], movable[1:]
        while left:
            nxt = left[0]
            for c in left[1:]:
                if turn(order[-1], c) < turn(order[-1], nxt):
                    nxt = c
            order.append(nxt)
            left = [x for x in left if x != nxt]
        if order != movable:
            out.append(order + last)
    return out


def out_of_reach_strips(reach) -> list:
    """Keep-out strips for what lies beyond the X travel in a setup."""
    if reach is None:
        return []
    far = 1e4
    return [((-far, -far), (reach.x.lower, far)), ((reach.x.upper, -far), (far, far))]


def edge_find_program(side: int, stage: int) -> int:
    """The timeline's pseudo-program for the edge finding after a clamping."""
    return 2000 + (side + 1) * 100 + stage


def duration_text(s: float) -> str:
    m = int(math.floor(s / 60 + 0.5))
    return f"{max(m, 1)} min" if m < 60 else f"{m // 60} h {m % 60} min"


def follow_probed_face(text: str, lines: list, probing: list, blocked: str | None, machine):
    """An engraving program made to follow the probed face, with its probe program; or why it
    can't. Returns (text, lines, probe, note)."""
    if not probing:
        return text, lines, None, None
    if blocked is not None:
        return text, lines, None, blocked
    cuts = [m for _, moves in probing for m in moves if m.role == Role.CUT]
    face, spread = SurfaceProbe.flat_face([m.position for m in cuts], probing[0][0])
    pts = SurfaceProbe.points([(m.x, m.y) for m in cuts])
    if face is None or pts is None:
        return text, lines, None, (f"The engraving can't follow the probed face: the face under it isn't flat (its deepest cuts vary by {Length.mm(spread)} mm; "
                                   "the compensation would add that a second time). It follows the CAD.")
    new_text, moved = SurfaceProbe.follow(text, face)
    new_lines = [[(moved[l - 1] + 1 if l is not None and 0 <= l - 1 < len(moved) else l) for l in op] for op in lines]
    return new_text, new_lines, SurfaceProbe.program(pts, face, machine=machine), None


def _part_xy_box(transform, part) -> tuple[Range, Range]:
    lo, hi = np.full(2, np.inf), np.full(2, -np.inf)
    for i in range(8):
        c = np.array([part.bounds_min[0] if i & 1 == 0 else part.bounds_max[0], part.bounds_min[1] if i & 2 == 0 else part.bounds_max[1],
                      part.bounds_min[2] if i & 4 == 0 else part.bounds_max[2], 1.0])
        w = np.asarray(transform, float) @ c
        lo, hi = np.minimum(lo, w[:2]), np.maximum(hi, w[:2])
    return Range(float(lo[0]), float(hi[0])), Range(float(lo[1]), float(hi[1]))


class MachiningMixin:
    def work_transform(self, part) -> np.ndarray:
        return self.setup.part_to_work(part.bounds_min, part.bounds_max)

    def cached_features(self, part, m):
        """The holes and floors found before, when they were found for this part where it sits now."""
        f, key = self.features, self.features_key
        if f is None or key is None or key[0] != part.part_id:
            return None
        return f if np.allclose(np.asarray(key[1], float), np.asarray(m, float), atol=1e-9, rtol=0) else None

    def suggest_operations(self, inventory):
        """A task: asks the engine for holes and floors, then proposes operations from the inventory."""
        if not self.planning_machine_ready:
            self.errorMessage = self.planning_machine_problem or "Load a machine before planning."
            return
        ref = self.planning_machine_reference
        part, stock = self.part, self.stock
        if part is None or stock is None:
            return
        self.status = "Finding features…"
        try:
            engine = yield from self.live_engine()
            m = self.work_transform(part)
            f = self.cached_features(part, m)
            if f is None:
                f = yield Work(lambda: cam.features(engine, part.part_id, m))
                if not (self.planning_machine_ready and self.planning_machine_reference == ref):
                    return
                self.features, self.features_key = f, (part.part_id, m)
            if self.analysis is None:
                from ...core.plan.part_analysis import analyse
                try:
                    result = yield Work(lambda: analyse(engine, part.part_id, m, access=True))
                except Cancelled:
                    raise
                except Exception:  # noqa: BLE001
                    result = None
                if not (self.planning_machine_ready and self.planning_machine_reference == ref):
                    return
                if result is not None:
                    self.analysis_transform = m
                self.analysis = result
            if not (self.planning_machine_ready and self.planning_machine_reference == ref):
                return
            a = self.analysis
            p = OperationPlanner.propose(inventory, [h.diameter for h in f.holes], any(z < -1e-6 for z in f.floor_levels),
                                         (a.freeform_area if a is not None else 0) > 1, a.min_concave_radius if a is not None else None,
                                         min(0.25, self.setup.top_allowance), self.machine)
            self.operations = list(p.operations) + [o for o in self.operations if o.kind in (K.THREAD, K.ENGRAVE)]
            self.plan_notes = list(p.notes)
            self.status = f"{len(p.operations)} operations suggested"
        except Cancelled:
            raise
        except Exception as e:  # noqa: BLE001
            self.errorMessage = f"Couldn't analyse the part: {e}"

    def turn_angle(self, a: int, b: int) -> float:
        """The angle the stock turns between two sides' setups, degrees."""
        if a == b:
            return 0.0
        base = self.setup.part_rotation.T
        r = (self.setup_for(b).part_rotation @ base) @ (self.setup_for(a).part_rotation @ base).T
        c = min(max((r[0, 0] + r[1, 1] + r[2, 2] - 1) / 2, -1), 1)
        return math.degrees(math.acos(c))

    def setup_for(self, side: int):
        """The setup for a side (0 = A, 1 = B, the stock turned front-to-back, 2… the side setups)."""
        if side <= 0 or self.part is None or self.stock is None:
            return self.setup
        s = self.setup.for_side(side, self.part.bounds_min, self.part.bounds_max, self.stock)
        return s if s is not None else self.setup

    @property
    def split_z(self) -> float | None:
        """The split between the sides in side-A work Z: the parting level."""
        if not self.twoSided or self.part is None:
            return None
        if self.analysis is not None and self.analysis.parting_z is not None:
            return self.analysis.parting_z
        lo, hi = self.setup.rotated_part_bounds(self.part.bounds_min, self.part.bounds_max)
        return float(-self.setup.top_allowance - (hi[2] - lo[2]) / 2)

    def learned_feed_factor(self, tool, material) -> float:
        return self.journal.learning.factor(material.id, tool.kind)

    def prepare_thread(self, op, inventory) -> None:
        """A new thread milling operation: the thread the part's holes were most likely made for,
        and the thread mill that cuts it (yours first, else a suggestion to buy)."""
        holes = self.features.holes if self.features is not None else []
        spec = next((s for s in (ThreadSpec.likely(h.diameter) for h in holes) if s is not None), None) or ThreadSpec.named("M3")
        op.thread = ThreadMilling(spec=spec.name)
        mills = [t for t in inventory.tools if t.kind == ToolKind.THREAD_MILL and t.condition.value != "broken"
                 and (t.quantity > 0 or t.is_suggestion) and spec.can_be_cut(t)
                 and all(i.severity < Severity.ERROR for i in InventoryChecks.check_tool(t, inventory, self.machine))]
        best = None
        for t in mills:
            if best is None or (0 if t.quantity > 0 else 1, -t.flute_length) < (0 if best.quantity > 0 else 1, -best.flute_length):
                best = t
        op.tool_id = best.id if best is not None else None

    # ------------------------------------------------------------ generation

    def generate_toolpaths(self, library):
        """A task: generates toolpaths for each side, posts them per tool and checks them."""
        self.capture_job_tools()
        inventory = self.planning_inventory(library)
        if not self.planning_machine_ready:
            self.errorMessage = self.planning_machine_problem or "Load a machine before planning."
            return
        machine, machine_reference = self.machine, self.planning_machine_reference
        if self.fixture_placement is not None:
            self.errorMessage = "Save or cancel the fixture placement before generating."
            return
        if self.is_generating:
            return
        part, stock = self.part, self.stock
        material = stock.material if stock is not None else None
        if part is None or stock is None or material is None:
            self.errorMessage = "Choose a part and stock first."
            return
        if material.validation_issues:
            self.errorMessage = f"{material.name}: " + " ".join(material.validation_issues)
            return
        tools = {t.id: t for t in inventory.tools}
        for operation in self.operations:
            if not operation.enabled:
                continue
            tool = tools.get(operation.tool_id) if operation.tool_id is not None else None
            if tool is None:
                self.errorMessage = f"Choose a tool for {operation.title} before generating."
                return
            issues = [i for i in InventoryChecks.check_tool(tool, inventory, machine) if i.severity == Severity.ERROR]
            if issues:
                self.errorMessage = f"{tool.name}: " + " ".join(i.message for i in issues)
                return
        self.is_generating = True
        self.cancel_generation = False
        try:
            yield from self._generate(inventory, part, stock, material, machine, machine_reference)
        except Cancelled:
            self.status = "Generation cancelled"
        except EngineError as e:
            if e.type == "EngineExited" and self.cancel_generation:
                self.status = "Generation cancelled"
            elif e.type == "EngineExited":
                self.errorMessage = ("The geometry engine crashed while generating (a native library failed on this geometry). It restarts by itself: "
                                     "generate again. If it keeps happening, change the finishing strategy or cusp height.")
                self.status = "Generation failed: the engine crashed"
            else:
                self.errorMessage = f"Toolpath generation failed: {e.message}"
                self.status = "Generation failed"
        except Exception as e:  # noqa: BLE001
            import traceback
            traceback.print_exc()
            self.errorMessage = f"Toolpath generation failed: {e}"
            self.status = "Generation failed"
        finally:
            self.is_generating = False
            self.generation_progress = None
            self.touch()

    def _check_run(self, run) -> None:
        if self.generation_signature != run.signature or self.cancel_generation:
            raise Cancelled()

    def _generate(self, inventory, part, stock, material, machine, machine_reference):
        library_candidates = []
        input_signature = self.generation_signature
        if self.setup.plan_from_fixture_library:
            self.library_workholding_plan = None
            self.selected_library_step = None
            self.status = "Loading eligible fixture assemblies from your library…"
            size = self.setup.stock_size(stock)
            turned = [SetupSide.stock_size(size, s) for s in self.side_setup_sides(part, stock)]
            try:
                library_candidates = yield from self.prepare_library_fixtures(inventory, size, turned)
            except Cancelled:
                raise
            except Exception as e:  # noqa: BLE001
                self.errorMessage = str(e)
                return
            if self.generation_signature != input_signature:
                self.status = "Setup changed: generate again."
                return
        # Cut free on tabs (one side, a bar barely thicker than the part).
        e = self.one_sided_through_excess
        if e is not None and self.holdWithTabs and abs(self.setup.top_allowance - e) > 0.01:
            self.change_setup(lambda s: setattr(s, "top_allowance", e))
        # The split, holes and floors come from an analysis for this orientation.
        if self.analysis_task is not None and not self.analysis_task.finished:
            yield self.analysis_task
        if part.exact and (self.analysis_transform is None or not np.allclose(self.analysis_transform, self.work_transform(part))):
            yield from self.run_analysis()
        if not (self.planning_machine_ready and self.planning_machine_reference == machine_reference):
            return
        tools = {t.id: t for t in inventory.tools}
        base = []
        for op in self.operations:
            if not op.enabled or op.tool_id is None or op.tool_id not in tools:
                continue
            tool = tools[op.tool_id]
            data = op.cutting_data(tool, material, machine)
            f = self.learned_feed_factor(tool, material)
            if abs(f - 1) > 1e-6:
                mx = machine.max_feed_any_direction
                data.feed, data.plunge_feed, data.ramp_feed = min(data.feed * f, mx), min(data.plunge_feed * f, mx), min(data.ramp_feed * f, mx)
            base.append(PlannedOperation(op, tool, data))
        base = threads_last(base)
        # Rest finishing works where the largest earlier 3D finishing tool couldn't reach.
        for k, p in enumerate(base):
            if p.operation.kind == K.REST:
                ref = None
                for q in base[:k]:
                    if q.operation.kind.is_3d and q.tool.diameter > p.tool.diameter and (ref is None or ref.diameter < q.tool.diameter):
                        ref = q.tool
                p.ref_tool = ref
        if not base:
            self.errorMessage = "No enabled operations with a tool."
            return
        self.errorMessage = ""
        self.status = "Generating toolpaths…"
        box_lo, box_hi = self.setup.stock_box(stock)
        box_lo, box_hi = np.array(box_lo, float), np.array(box_hi, float)
        through = self.cuts_through_with_tabs
        if through:
            box_lo[2] -= 3
        started = time.monotonic()
        self.cached_ops = 0
        size_a = self.setup.stock_size(stock)
        keep_out = self.fixture_keep_out(library_candidates, size_a)
        keep_out_below = 0.5
        ends = self.end_pieces(part, stock)
        if ends is not None:
            note = (f"The stock past the part's ends ({Length.mm(ends[0])} and {Length.mm(ends[1])} mm) stays on through the long-face setups: "
                    "the fixture grips it and the bar sits on full-length faces. The end setups face it off.")
            if note not in self.plan_notes:
                self.plan_notes.append(note)
        run = GenerationRun(self.generation_signature, machine)
        self.reference_plan = None
        for side in range(2 if self.twoSided else 1):
            s = self.setup_for(side)
            planned = [copy.copy(p) for p in base if p.operation.kind != K.ENGRAVE
                       or ((p.operation.engraving.side if p.operation.engraving is not None else 0) or 0) == side]
            # Facing only removes the allowance that exists, never the finished CAD face.
            facing_left = max(s.top_allowance, 0)
            kept = []
            for p in planned:
                if p.operation.kind != K.FACING:
                    kept.append(p)
                    continue
                depth = min(max(p.operation.face_depth, 0), facing_left)
                if depth <= 1e-6:
                    continue
                facing_left -= depth
                p.operation = dataclasses.replace(p.operation, face_depth=depth)
                kept.append(p)
            planned = kept
            if self.twoSided and self.tuning.hidden_side == side:
                for p in planned:
                    if p.operation.kind.is_3d:
                        p.operation = dataclasses.replace(p.operation, scallop=min(p.operation.scallop * HIDDEN_CUSP_FACTOR, 0.03))
                        p.data = p.operation.cutting_data(p.tool, material, machine)
            material_top = 0.0
            tab_spec = None
            tab_bottom = 0.0
            split = self.split_z
            if split is not None:
                if self.setup.holding == Workholding.CUSTOM:
                    z = split if side == 0 else s.side_b_z(split, stock) - THROUGH_OVERSHOOT
                elif self.holdWithTabs or ends is not None:
                    z = split if side == 0 else s.side_b_z(split, stock) - THROUGH_OVERSHOOT
                    if side == 1 and ends is None:
                        r = self.tab_range(s, stock, split)
                        tab_spec = copy.deepcopy(self.tabs)
                        tab_spec.height = r.upper - r.lower
                        rough = max((p.tool.diameter for p in planned if p.operation.kind == K.ADAPTIVE), default=6.35)
                        tab_spec.reach = 1.6 * rough + 3.75
                        tab_bottom = r.lower
                else:
                    z = split + self.webThickness / 2 if side == 0 else s.side_b_z(split - self.webThickness / 2, stock)
                for p in planned:
                    p.z_min = z
            elif side == 0 and through:
                r = self.one_sided_tab_range(stock)
                skin = -size_a[2] + THROUGH_SKIN
                contour_tool = max((p.tool.diameter for p in planned if p.operation.kind == K.CONTOUR), default=3.175)
                tab_spec = copy.deepcopy(self.tabs)
                tab_spec.height = r.upper - r.lower
                tab_spec.reach = contour_tool + 2.5
                tab_spec.lift = True
                tab_spec.skin_top = skin
                tab_bottom = r.lower
                for p in planned:
                    if p.operation.kind == K.ADAPTIVE:
                        p.z_min = skin
                    elif p.operation.kind == K.CONTOUR:
                        p.z_min = r.lower
                        p.through = True
                    elif p.operation.kind.is_3d:
                        p.z_min = max(p.z_min if p.z_min is not None else -math.inf, r.upper)
            # Side B: the backing over the part comes off first, only around the part.
            if side == 1 and s.top_allowance > 1:
                material_top = -(s.top_allowance - 0.5)
                widest = max((p.tool.diameter for p in planned), default=6.35)
                nut_band = widest + 1 + NUT_RADIUS + 0.5
                for p in planned:
                    if p.operation.kind == K.FACING:
                        p.operation = dataclasses.replace(p.operation, kind=K.ADAPTIVE)
                        p.data = FeedsEngine.compute(p.tool, material, K.ADAPTIVE, machine)
                        p.z_min = material_top
                        p.band = nut_band
                    else:
                        p.z_top = material_top
                        p.frame_top = 0.0
                        if p.operation.kind == K.ADAPTIVE:
                            p.band = None
            self._rest_from(planned)
            reach = self.reach_in_setup(library_candidates, s.stock_size(stock))
            elo, ehi = s.rotated_part_bounds(part.bounds_min, part.bounds_max)
            length_y = (s.part_offset_y - (ehi[1] - elo[1]) / 2, s.part_offset_y + (ehi[1] - elo[1]) / 2)
            end_ko = [] if ends is None else end_keep_out(length_y, s.stock_size(stock))
            side_ko = keep_out + out_of_reach_strips(reach) + end_ko
            if side_ko:
                for p in planned:
                    if p.operation.kind == K.ADAPTIVE and p.operation.reference is None:
                        p.keep_out = list(side_ko)
                        p.keep_out_below = keep_out_below
            transform = s.part_to_work(part.bounds_min, part.bounds_max)
            plo, phi = s.rotated_part_bounds(part.bounds_min, part.bounds_max)
            part_bottom = -(s.top_allowance + (phi[2] - plo[2]))
            yr = Range(s.part_offset_y - (phi[1] - plo[1]) / 2 - 3, s.part_offset_y + (phi[1] - plo[1]) / 2 + 3)
            planned = [q for p in planned for d in depth_slices(p, part_bottom) for q in finish_strips(d, yr)]
            planned = self.add_reference_features(planned, side, material, stock)
            if side == 1 and tab_spec is not None and self.reference_plan is not None:
                window_tool = next((p.tool.diameter for p in planned if p.operation.reference == ReferenceFeature.WINDOWS), 0)
                tab_spec.avoid = [(c[0], c[1], max(ReferenceBores.WINDOW_DIAMETER, window_tool) / 2 + 0.75) for c in self.reference_plan.centres_b]
            px, py = _part_xy_box(transform, part)
            if reach is not None:
                planned = self.within_reach(planned, reach, s.stock_size(stock)[2], setup_title(side, self.twoSided))
            run.sides.append(SidePlan(side, s, planned, material_top, tab_spec, tab_bottom, transform, (px.lower, px.upper), (py.lower, py.upper),
                                      reach_x=reach.x if reach is not None else None,
                                      fields=self.fixture_fields(library_candidates, s.stock_size(stock)),
                                      keep_y=None if ends is None else (py.lower, py.upper)))
        # Setups from the other sides: they come first at the machine, on the whole block.
        if self.setup.plan_from_fixture_library:
            side_plans = self.side_setup_plans(base, part, stock)
            for side, s, sp_planned in side_plans:
                transform = s.part_to_work(part.bounds_min, part.bounds_max)
                px, py = _part_xy_box(transform, part)
                side_lo, side_hi = (np.array(v, float) for v in s.stock_box(stock))
                if side == 5 and any(x[0] == 4 for x in side_plans):
                    side_lo[2] += self.end_piece_thickness(4)
                planned = [copy.copy(p) for p in sp_planned]
                end_piece = self.end_piece_thickness(side)
                turned_size = s.stock_size(stock)
                owned = any(c.fixture.planning is not None and math.dist((c.fixture.planning.stock_size.x, c.fixture.planning.stock_size.y,
                                                                          c.fixture.planning.stock_size.z), tuple(turned_size)) < 0.1 for c in library_candidates)
                stand_in = not owned and end_piece > 0.5
                if not owned and not stand_in:
                    self.plan_notes.append(f"{setup_title(side, self.twoSided)}: no fixture you own holds the stock this way, so this setup is left out until you have a vise "
                                           f"that opens to {math.ceil(turned_size[1] + 1)} mm or more (on the Shopping List). Its features stay open until then.")
                    continue
                reach = self.stand_in_reach(turned_size, 0) if stand_in else self.reach_in_setup(library_candidates, turned_size)
                keeps_ends = ends is not None and side <= 3
                side_ko = (self.fixture_keep_out(library_candidates, turned_size) + out_of_reach_strips(reach)
                           + (end_keep_out((py.lower, py.upper), turned_size) if keeps_ends else []))
                if side_ko:
                    for p in planned:
                        if p.operation.kind == K.ADAPTIVE:
                            p.keep_out = list(p.keep_out) + side_ko
                            p.keep_out_below = min(p.keep_out_below, keep_out_below)
                side_top = -end_piece if end_piece > 0.5 else 0.0
                name = setup_title(side, self.twoSided)
                clampings, clamp_of = [], []
                if stand_in and reach is not None:
                    ops = []
                    done = 0.0
                    f = next((p for p in planned if p.operation.kind == K.FACING), None)
                    if f is not None:
                        most = max(1, -reach.z_floor(f.tool.stickout) - 1)
                        while done < end_piece - 1e-6:
                            c = min(most, end_piece - done)
                            p = copy.copy(f)
                            p.z_top, p.z_min = -done, -(done + c)
                            p.operation = dataclasses.replace(p.operation, face_depth=c)
                            if done > 0:
                                p.clearance = -done + 3
                            jaw = -done - c - 3
                            clamp_of.append(len(clampings))
                            clampings.append(StandInClamping(done, jaw, c, StandInVise.field(turned_size, done, jaw, self.table_geometry)))
                            ops.append(p)
                            done += c
                    features = [p for p in planned if p.operation.kind != K.FACING]
                    r = self.stand_in_reach(turned_size, end_piece) if features else None
                    if features and r is not None:
                        kept = self.within_reach(features, r, turned_size[2], name, -end_piece)
                        for p in kept:
                            p.clearance = -end_piece + 3
                        if kept:
                            jaw = -end_piece - StandInVise.FACE_PAST
                            clamp_of += [len(clampings)] * len(kept)
                            clampings.append(StandInClamping(end_piece, jaw, None, StandInVise.field(turned_size, end_piece, jaw, self.table_geometry)))
                            ops += kept
                    planned = ops
                elif reach is not None:
                    planned = self.within_reach(planned, reach, turned_size[2], name, side_top)
                if not planned:
                    continue
                run.sides.append(SidePlan(side, s, planned, side_top, None, 0.0, transform, (px.lower, px.upper), (py.lower, py.upper),
                                          side_lo, side_hi, reach.x if reach is not None else None,
                                          [] if stand_in else self.fixture_fields(library_candidates, turned_size),
                                          (py.lower, py.upper) if keeps_ends else None, clampings, clamp_of))
        run.jobs = [(si, k) for si, sp in enumerate(run.sides) for k in range(len(sp.planned))]
        run.done = [[None] * len(sp.planned) for sp in run.sides]
        run.published = [0] * len(run.sides)
        self.op_gen_state = {}
        for sp in run.sides:
            for p in sp.planned:
                self.set_gen_state(p.operation.id, sp.side, "queued")
        self.side_results = []
        self.programs = []
        planned_programs = []
        for sp in run.sides:
            for p in sp.planned:
                last = planned_programs[-1] if planned_programs else None
                if (last is not None and last[1] == sp.side and last[2].id == p.tool.id
                        and last[3][-1].reference != ReferenceFeature.WINDOWS and p.operation.reference != ReferenceFeature.WINDOWS):
                    last[3].append(p.operation)
                else:
                    planned_programs.append((len(planned_programs), sp.side, p.tool, [p.operation]))
        self.planned_programs = planned_programs
        self.selected_step = None
        self.planned_operation_count = {sp.side: len(sp.planned) for sp in run.sides}
        run.box_min, run.box_max = box_lo, box_hi
        self.touch()
        yield from self.run_in_background(run, part.path, part.part_id)
        if run.failed:
            self.publish_partial(run, force=True)
            names = []
            for si, k, _ in run.failed:
                sp = run.sides[si]
                prefix = SetupSide.words(sp.side) + " · " if sp.side >= 2 else (("A · " if sp.side == 0 else "B · ") if self.twoSided else "")
                names.append(prefix + sp.planned[k].operation.title)
            what = "One operation" if len(names) == 1 else f"{len(names)} operations"
            self.errorMessage = f"{what} failed ({', '.join(names)}): {run.failed[0][2]} The rest is ready to look at; Retry redoes only the failed ones."
            self.status = f"{run.finished} of {run.total} operations ready · {len(run.failed)} failed"
            return
        generated_clamping: dict[int, list[int]] = {}
        generated = []
        for si, sp in enumerate(run.sides):
            planned, paths, clamps = [], [], []
            for k in range(len(sp.planned)):
                ps = run.done[si][k] or []
                if not any(m.role in (Role.CUT, Role.RAMP, Role.PLUNGE) for p in ps for m in p.moves):
                    continue
                planned += [sp.planned[k]] * len(ps)
                if k < len(sp.clamp_of):
                    clamps += [sp.clamp_of[k]] * len(ps)
                paths += ps
            if sp.clampings:
                generated_clamping[sp.side] = clamps
            generated.append([sp.side, sp.setup, planned, paths, sp.material_top])
        generated = [g for g in generated if g[0] >= 2] + [g for g in generated if g[0] < 2]
        if self.setup.plan_from_fixture_library:
            ok = yield from self._plan_workholding(run, generated, generated_clamping, library_candidates, stock, machine)
            if not ok:
                return
        if self.part_mesh_data is not None:
            yield from self._air_check(run, generated, part, stock)
        self.status = "Posting and checking the programs…"
        all_programs, results = yield from self._post(run, generated, part, stock, material, machine, box_lo, box_hi)
        self._check_run(run)
        self.programs = all_programs
        self.side_results = results
        base_result = next((r for r in results if r.side == 0), results[0] if results else None)
        self.toolpaths = {}
        for p in (base_result.paths if base_result is not None else []):
            self.toolpaths.setdefault(p.operation_id, p)
        # The whole job against the real travel, each tool's own stick-out, in its clamping.
        lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
        env = machine.machine_envelope
        for r in results:
            for k, path in enumerate(r.paths):
                if k >= len(r.planned):
                    continue
                step = self.library_workholding_plan.step(f"{r.side}:{k}") if self.library_workholding_plan is not None else None
                origin = None
                if step is not None:
                    o = self.library_machine_origin(step.fixture, r.setup.stock_size(stock))
                    if o is not None:
                        origin = np.asarray(o, float) + np.array([0, 0, r.planned[k].tool.stickout])
                if origin is None:
                    origin = self.machine_origin(r.planned[k].tool.stickout)
                if origin is None:
                    continue
                outside, first = 0, None
                for m in path.moves:
                    q = origin + np.array(m.position)
                    if m.role != Role.RAPID:
                        lo, hi = np.minimum(lo, q), np.maximum(hi, q)
                    if not (q[0] in env.x and q[1] in env.y and q[2] in env.z):
                        outside += 1
                        if first is None:
                            first = q
                if outside > 0 and k < len(r.operation_program):
                    pi = next((i for i, p in enumerate(all_programs) if p.index == r.operation_program[k]), None)
                    if pi is not None:
                        all_programs[pi].report.issues.append(Issue(Severity.ERROR,
                            f"{outside} move{'' if outside == 1 else 's'} leave the machine's travel (first at machine X{first[0]:.2f} Y{first[1]:.2f} Z{first[2]:.2f})."))
        if self.setup.holding == Workholding.CUSTOM and not self.setup.plan_from_fixture_library:
            for p in all_programs:
                p.report.issues.append(Issue(Severity.WARNING, f"Custom fixture geometry is not included in collision checks. Verify clearance to {self.setup.custom_fixture.name}, its jaws and fasteners."))
        self.programs = all_programs
        yield from self.check_tabs()
        self._check_run(run)
        self.travel_issue = (self.travel_problem(lo) or self.travel_problem(hi)) if math.isfinite(lo[0]) else None
        ops = self.operations
        self.generated_tuning = Tuning(next((o.scallop for o in ops if o.kind.is_3d), self.tuning.cusp), ops[0].feed_scale if ops else 1.0,
                                       next((o.roughing for o in ops if o.kind == K.ADAPTIVE), None), self.tuning.hidden_side if self.twoSided else None)
        self.tuning = self.generated_tuning
        self.learn_from_generation()
        shown_before = any(n > 0 for n in run.published)
        keep_view, keep_time = self.viewSide, self.playhead
        self.switching_view = True
        self.viewSide = min(self.viewSide, len(results) - 1)
        self.switching_view = False
        self.compute_side_a_final()
        self.prepare_tool_change_spot()
        self.show_side(keep_time if shown_before and self.viewSide == keep_view else 0)
        if not shown_before:
            self.set_view("iso")
            self.focus_work()
        secs = sum(p.seconds for p in self.programs)
        reused = f" · {self.cached_ops} unchanged operation{'' if self.cached_ops == 1 else 's'} reused" if self.cached_ops > 0 else ""
        self.status = f"Toolpaths ready in {time.monotonic() - started:.1f} s · about {duration_text(secs)} of machining{reused}"

    @staticmethod
    def _rest_from(planned: list) -> None:
        """Each roughing tool works only what the larger ones before it left."""
        for k, p in enumerate(planned):
            if p.operation.kind == K.ADAPTIVE:
                p.rest_from = [(q.tool.diameter, q.operation.min_pocket if q.operation.min_pocket is not None else DEFAULT_MIN_POCKET,
                                q.operation.leave_radial) for q in planned[:k]
                               if q.operation.kind == K.ADAPTIVE and q.tool.diameter > p.tool.diameter + 1e-6]

    def _plan_workholding(self, run, generated, generated_clamping, candidates, stock, machine):
        """A task step: the library workholding plan for the generated cuts (the setup order that
        turns the stock least). False when there's no complete plan."""
        self.status = "Comparing generated cuts with library fixtures and remaining stock…"
        stand_in_sides = {sp.side for sp in run.sides if sp.clampings}
        cuts = [LWP.Cut(f"{g[0]}:{i}", g[0], p.operation, p.tool, path.moves)
                for g in generated if g[0] not in stand_in_sides for i, (p, path) in enumerate(zip(g[2], g[3]))]
        size, flip = self.setup.stock_size(stock), self.setup_for(1).flip_axis
        orders = setup_orders([g[0] for g in generated if g[0] not in stand_in_sides], self.turn_angle)
        turns = {(a, b): self.turn_angle(a, b) for a in orders[0] for b in orders[0]}

        def search():
            best, first = None, None
            for order in orders:
                ordered = [c for side in order for c in cuts if c.side == side]
                p = LWP.plan(ordered, candidates, size, machine, flip)
                if first is None:
                    first = p
                if not p.complete:
                    continue
                sides = [s.side for s in p.steps]
                turn = sum(turns.get((a, b), 0.0) for a, b in zip(sides, sides[1:]))
                if best is None or turn < best[1] - 1e-6:
                    best = (p, turn, order)
            if best is not None:
                return best[0], best[2]
            from ...core.plan.workholding_profile import LibraryWorkholdingPlan
            return first or LibraryWorkholdingPlan(), orders[0]

        plan, order = yield Work(search, lane="planner")
        self._check_run(run)
        if plan.complete:
            for g in generated:
                if g[0] not in stand_in_sides:
                    continue
                sp = next((x for x in run.sides if x.side == g[0]), None)
                if sp is None:
                    continue
                for c, clamping in enumerate(sp.clampings):
                    clamps = generated_clamping.get(g[0], [])
                    keys = [i for i in range(len(g[2])) if i < len(clamps) and clamps[i] == c]
                    if not keys:
                        continue
                    fixture = self.stand_in_fixture(g[0], c, g[1].stock_size(stock), clamping.faced_before, clamping.jaw_front, clamping.facing)
                    self.library_fixture_fields[self.fixture_state_key(fixture)] = clamping.field
                    plan.steps.append(LibraryWorkholdingStep(len(plan.steps) + 1, g[0], fixture, [f"{g[0]}:{i}" for i in keys],
                                                             [g[2][i].operation.title for i in keys],
                                                             ["Held in a vise you don't have yet (on the Shopping List): running waits until it is in your fixtures."]))

        def rank(side: int) -> int:
            return order.index(side) if side in order else len(order) + side

        generated.sort(key=lambda g: rank(g[0]))
        self.library_workholding_plan = plan
        self.selected_library_step = plan.steps[0].id if plan.steps else None
        if not plan.complete:
            self.programs = []
            self.planned_programs = []
            self.errorMessage = "No complete workholding sequence. " + "\n".join(plan.issues)
            self.status = "Workholding needs attention; no cutting program is ready to run."
            return False
        return True

    def _air_check(self, run, generated, part, stock):
        """A task step: every pass against the stock as the cuts before it leave it; passes lift
        over stretches where their cutter meets nothing."""
        self.status = "Checking each pass against the stock the cuts before it leave…"
        mesh = self.part_mesh_data
        t = self.setup.part_to_work(part.bounds_min, part.bounds_max)
        v = np.asarray(mesh[0], float).reshape(-1, 3)
        verts = (v @ np.asarray(t, float)[:3, :3].T + np.asarray(t, float)[:3, 3]).astype(np.float32)
        size, flip, indices = self.setup.stock_size(stock), self.setup_for(1).flip_axis, mesh[2]
        step_of_key = {}
        for s in (self.library_workholding_plan.steps if self.library_workholding_plan is not None else []):
            for key in s.cut_keys:
                step_of_key[key] = f"step:{s.id}"
        entries = [(g[0], list(g[2]), [copy.copy(p) for p in g[3]]) for g in generated]

        def check():
            model = StockModel(size, part_vertices=verts, indices=indices, flip_axis=flip)
            out, snapshots = [], {}
            for side, planned, paths in entries:
                for i in range(len(paths)):
                    if i >= len(planned):
                        continue
                    at = step_of_key.get(f"{side}:{i}", f"side:{side}")
                    if at not in snapshots:
                        snapshots[at] = model.copy()
                    if f"side:{side}" not in snapshots:
                        snapshots[f"side:{side}"] = model.copy()
                    op = planned[i]
                    if checks_for_air(op.operation):
                        roughing = op.operation.kind == K.ADAPTIVE
                        moves, skipped = model.lift_air(paths[i].moves, side, op.tool, step=1 if roughing else 0.5, safe_z=safe_height(op),
                                                        slice=op.data.stepdown if roughing else None, plunge_feed=op.data.plunge_feed)
                        paths[i].moves = moves
                        if skipped > 1:
                            paths[i].notes = list(paths[i].notes) + [f"{Length.mm(skipped)} mm of this pass met no stock (a cut before it had already taken it): lifted over."]
                    model.sweep(paths[i].moves, side, op.tool, op.data.stepdown)
                out.append(paths)
            return out, snapshots

        filtered, snapshots = yield Work(check, lane="sim")
        self._check_run(run)
        for gi, paths in enumerate(filtered):
            generated[gi][3] = paths
        self.in_process_snapshots = snapshots
        self.in_process_meshes = {}

    def _post(self, run, generated, part, stock, material, machine, box_lo, box_hi):
        """A task step: every program posted and checked, in order. Returns (programs, results)."""
        probe_blocked = "The engraving can't follow the probed face: that needs electrical probing, which this workholding doesn't have. It follows the CAD."
        plan = self.library_workholding_plan
        jobs = []  # per side: (side, setup, planned, paths, [(group, rpm, step, args)])
        for side, s, planned, paths, material_top in generated:
            groups = []
            for index, pair in enumerate(zip(planned, paths)):
                step = plan.step(f"{side}:{index}") if plan is not None else None
                if groups:
                    last_step, cuts = groups[-1]
                    last = cuts[-1]
                    if (last[0].tool.id == pair[0].tool.id and (last_step.id if last_step else None) == (step.id if step else None)
                            and last[0].operation.reference != ReferenceFeature.WINDOWS and pair[0].operation.reference != ReferenceFeature.WINDOWS):
                        cuts.append(pair)
                        continue
                groups.append((step, [pair]))
            name = setup_title(side, self.twoSided)
            side_lo, side_hi = (self.setup_for(side).stock_box(stock) if side >= 2 else (box_lo, box_hi))
            pending = []
            for step, group in groups:
                tool = group[0][0].tool
                rpm = max((g[0].data.rpm for g in group), default=machine.spindle_rpm.upper)
                top = material_top
                if step is not None and self.is_stand_in(step.fixture):
                    fp = step.fixture.planning.face_past_table if step.fixture.planning is not None else StandInVise.FACE_PAST
                    top = -max(fp - StandInVise.FACE_PAST, 0)
                pending.append(dict(group=group, rpm=rpm, step=step, tool=tool, top=top,
                                    names=[g[0].operation.title for g in group], paths=[g[1] for g in group],
                                    stand_in=step is not None and self.is_stand_in(step.fixture),
                                    facing_only=all(g[0].operation.kind == K.FACING for g in group),
                                    faced=sum(g[0].operation.face_depth for g in group),
                                    fixtures=self.library_fixture_fields.get(self.fixture_state_key(step.fixture)) if step is not None else None,
                                    setup_name=step.title if step is not None else name,
                                    probing=[((g[0].operation.engraving.depth if g[0].operation.engraving.depth is not None else 0.15), g[1].moves)
                                             for g in group if g[0].operation.kind == K.ENGRAVE and g[0].operation.engraving is not None
                                             and g[0].operation.engraving.probe_surface is True],
                                    bmin=np.asarray(side_lo, float), bmax=np.asarray(side_hi, float)))
            jobs.append((side, s, planned, paths, pending))
        file_name, stock_name = part.file_name, f"{material.name} {stock.size_description}"

        def post_one(d):
            header = GRBLPost.Header(file_name, d["setup_name"], d["tool"], d["names"], stock_name)
            text, lines = GRBLPost.program_with_line_map(header, d["rpm"], d["paths"], machine)
            text, lines, probe, note = follow_probed_face(text, lines, d["probing"], probe_blocked, machine)
            ctx = Context(tuple(d["bmin"]), tuple(d["bmax"]), d["tool"])
            ctx.material_top = d["top"] - d["faced"] if d["facing_only"] else d["top"]
            if d["stand_in"]:
                ctx.safe_z = min(d["top"], 0) + 1
            report = GCodeValidator(machine).validate(text, ctx)
            hits = []
            if d["fixtures"] is not None:
                hits = FixtureClearance.check([m for p in d["paths"] for m in p.moves], d["tool"], d["fixtures"])
                t = FixtureClearance.describe(hits)
                if t is not None:
                    report.issues.append(Issue(Severity.ERROR, t))
            if note is not None:
                report.issues.append(Issue(Severity.INFO, note))
            if probe is not None:
                report.issues.append(Issue(Severity.INFO, "The engraving follows the face as probed: a probing step comes first in the guided job (M111), "
                                                          "the program turns the sender's compensation on (M112) and off (M113)."))
            return text, lines, report, time_estimate_seconds(d["paths"], machine), hits, probe

        def post_all():
            return [[post_one(d) for d in pending] for *_, pending in jobs]

        posted = yield Work(post_all, lane="post")
        self._check_run(run)
        all_programs, results = [], []
        for (side, s, planned, paths, pending), outs in zip(jobs, posted):
            op_program, op_lines = [], []
            for d, (text, lines, report, seconds, hits, probe) in zip(pending, outs):
                index = len(all_programs)
                op_program += [index] * len(d["group"])
                op_lines += lines
                stickouts = [g[1].min_stickout for g in d["group"] if g[1].min_stickout is not None]
                all_programs.append(ToolProgram(index, side, d["tool"], [g[0].operation for g in d["group"]], d["rpm"], text, report, seconds,
                                                [w for g in d["group"] for w in g[1].warnings], max(stickouts) if stickouts else None, hits,
                                                surface_probe=probe, workholding_step=d["step"]))
            results.append(SideResult(side, s, planned, paths, op_program, op_lines))
        return all_programs, results

    def add_reference_features(self, planned: list, side: int, material, stock) -> list:
        """Two-sided jobs: side A bores two reference holes in the frame with its roughing tool;
        side B opens them from the back first, so the guided job can probe them."""
        if self.setup.plan_from_fixture_library or not self.twoSided or not AppSettings.value("referenceBores", True) or self.part is None:
            return planned
        part = self.part

        def flat(t) -> bool:
            return t.kind in (ToolKind.FLAT_END_MILL, ToolKind.BULL_NOSE_END_MILL)

        if side == 0:
            tool = None
            for p in planned:
                if flat(p.tool) and p.tool.diameter <= ReferenceBores.DIAMETER - 2.5 and (tool is None or tool.diameter < p.tool.diameter):
                    tool = p.tool
            if tool is None:
                return planned
            size = self.setup.stock_size(stock)
            t = self.setup.part_to_work(part.bounds_min, part.bounds_max)
            px, py = _part_xy_box(t, part)
            rough = max((p.tool.diameter for p in planned if p.operation.kind == K.ADAPTIVE), default=6.35)
            clear = max(1.6 * rough + 1, 1.6 * rough + 3.75 if self.holdWithTabs else 0) + 0.5
            plan = ReferenceBores.place(size, (px.lower, py.lower), (px.upper, py.upper), clear, (), None, tool.diameter, tool.stickout - 2)
            if plan is None:
                return planned
            plan.flip_axis = self.setup_for(1).flip_axis
            self.reference_plan = plan
            op = Operation(K.BORE, tool_id=tool.id)
            op.id = REFERENCE_BORES_ID
            op.reference = ReferenceFeature.BORES
            p = PlannedOperation(op, tool, FeedsEngine.compute(tool, material, K.BORE, self.machine))
            p.holes = [(c, ReferenceBores.DIAMETER, 0.0, -plan.depth_a) for c in plan.centres_a]
            out = list(planned)
            at = max((i for i, q in enumerate(out) if q.tool.id == tool.id), default=len(out) - 1) + 1
            out.insert(at, p)
            return out
        plan = self.reference_plan
        if plan is None:
            return planned

        def fits(t) -> bool:
            return flat(t) and t.diameter <= 8

        tools = [p.tool for p in planned]
        tool = tools[0] if tools and fits(tools[0]) else None
        if tool is None:
            for t in tools:
                if fits(t) and (tool is None or tool.diameter < t.diameter):
                    tool = t
        if tool is None:
            self.reference_plan = None
            return planned
        op = Operation(K.BORE, tool_id=tool.id)
        op.id = REFERENCE_WINDOWS_ID
        op.reference = ReferenceFeature.WINDOWS
        p = PlannedOperation(op, tool, FeedsEngine.compute(tool, material, K.BORE, self.machine))
        p.holes = [(c, ReferenceBores.WINDOW_DIAMETER, 0.0, -plan.window_depth) for c in plan.centres_b]
        return [p] + list(planned)

    def cancel_generation_now(self) -> None:
        """Cancel now, even in the middle of a long operation: the engines are stopped."""
        self.cancel_generation = True
        self.status = "Cancelling…"
        if self._engine is not None:
            self._engine.terminate()
        for e, _, _ in self.worker_engines:
            e.terminate()

    def result_for_side(self, side: int):
        return next((r for r in self.side_results if r.side == side), None)

    def show_side(self, time_: float | None = None) -> None:
        """Shows the chosen side's toolpaths, playback and simulation, the playhead at `time_`
        (None: the end)."""
        r = self.result_for_side(self.viewSide)
        if r is None:
            return
        if self.viewSide == 1 and self.side_a_final is None:
            self.compute_side_a_final()
        self.planned_tools = [p.tool for p in r.planned]
        self.current_tool = r.planned[0].tool if r.planned else None
        self.operation_program = list(r.operation_program)
        self.operation_lines = list(r.operation_lines)
        stock = self.stock
        size = self.display_stock_size
        if size is None:
            size = self.setup.stock_size(stock) if stock is not None else np.array([10.0, 10, 10])
        f = self.displayed_job_fixture
        protrusion = f.planning.face_past_table if f is not None and f.planning is not None else self.setup.custom_fixture.face_protrusion
        probe_tool = EdgeFinding.TOOL
        probe_moves = EdgeFinding.moves(size, min(1.5, max(protrusion - 0.5, 0.5)), probe_tool.diameter / 2)
        from ...core.ids import new_id
        probe = OperationToolpath(new_id(), probe_moves)
        if self.setup.plan_from_fixture_library:
            self.timeline_titles = [p.operation.title for p in r.planned]
            self.timeline = ToolpathTimeline(r.paths, r.operation_program, r.operation_lines, self.machine)
        else:
            self.planned_tools = [probe_tool] + self.planned_tools
            self.timeline_titles = ["Edge finding"] + [p.operation.title for p in r.planned]
            self.timeline = ToolpathTimeline([probe] + list(r.paths), [edge_find_program(self.viewSide, 0)] + list(r.operation_program),
                                             [[]] + list(r.operation_lines), self.machine)
        d = self.timeline.duration
        self.playhead = min(max(time_ if time_ is not None else d, 0), d)
        self.layout_scene()
        self.reset_simulation()
        self.show_toolpaths()
        self.update_playback()
        seek = self.pending_seek
        if seek is not None:
            self.pending_seek = None
            seek()
        if self.pending_play:
            self.pending_play = False
            self.toggle_play()
        self.touch()

    def export_programs(self, folder: Path) -> list[Path]:
        """Writes one .nc file per tool program into a folder."""
        self.require_planning_machine()
        self.validate_library_plan_for_export()
        if self.is_generating:
            raise RuntimeError("Wait for toolpath generation to finish.")
        if not self.programs:
            raise RuntimeError("Generate toolpaths first.")
        if not all(p.report.passed for p in self.programs):
            raise RuntimeError("Fix the safety errors before exporting.")
        out = []
        for p in self.programs:
            path = Path(folder) / p.file_name
            path.write_text(p.gcode, encoding="utf-8")
            out.append(path)
        return out
