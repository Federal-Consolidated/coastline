"""One generation in progress, rendered in the background like a video editor renders a timeline:
the operations of every side are jobs, several engine processes take them in machining order, and
each side's toolpaths appear as soon as the operations from its start are done. Port of
Model/BackgroundGeneration.swift."""

from __future__ import annotations

import copy
import dataclasses
import hashlib
import json
import math
import os
import time
from dataclasses import dataclass, field

import numpy as np

from ...core import codable
from ...core.engine import cam
from ...core.engine.client import EngineClient, EngineError
from ...core.plan.warning_triage import split as triage_split
from ...core.post.toolpath import Move, Role
from ...core.safety.fixture_clearance import FixtureClearance
from ...core.units import Length
from ..settings import AppSettings
from ..tasks import Cancelled, Sleep, Work, spawn
from . import toolpath_cache as disk

TIMING = "COASTLINE_TIMING" in os.environ


@dataclass
class StandInClamping:
    """One clamping of an end setup in the vise to buy."""

    faced_before: float
    jaw_front: float
    facing: float | None
    field: object  # FixtureField


@dataclass
class SidePlan:
    side: int
    setup: object
    planned: list
    material_top: float
    tab_spec: object | None
    tab_bottom: float
    transform: np.ndarray
    part_x: tuple[float, float] = (0.0, 0.0)
    part_y: tuple[float, float] = (0.0, 0.0)
    box_min: np.ndarray | None = None
    box_max: np.ndarray | None = None
    reach_x: object | None = None  # Range
    fields: list = field(default_factory=list)
    keep_y: tuple[float, float] | None = None
    clampings: list[StandInClamping] = field(default_factory=list)
    clamp_of: list[int] = field(default_factory=list)


class GenerationRun:
    def __init__(self, signature: str, machine) -> None:
        self.signature = signature
        self.machine = machine
        self.sides: list[SidePlan] = []
        self.box_min = np.zeros(3)
        self.box_max = np.zeros(3)
        self.jobs: list[tuple[int, int]] = []
        self.next = 0
        self.done: list[list] = []
        self.failed: list[tuple[int, int, str]] = []
        self.published: list[int] = []
        self.last_publish = 0.0
        self.publish_scheduled = False
        self.frame = None
        self.frame_ready = False

    @property
    def finished(self) -> int:
        return sum(1 for d in self.done for x in d if x is not None)

    @property
    def total(self) -> int:
        return len(self.jobs)

    def prefix(self, si: int) -> int:
        n = 0
        for x in self.done[si]:
            if x is None:
                break
            n += 1
        return n


# ---------------------------------------------------------------- helpers (no app state)

def safe_height(p) -> float:
    """The clearance height for an operation's rapids and lifts (work Z)."""
    return p.clearance if p.clearance is not None else 3.0


def checks_for_air(op) -> bool:
    """The passes checked against the stock left: not facing, engraving, or the reference features."""
    return op.kind.value not in ("facing", "engrave") and op.reference is None


def _describe(v) -> str:
    if isinstance(v, np.ndarray):
        return repr(v.tolist())
    if hasattr(v, "to_json"):
        try:
            return json.dumps(v.to_json(), sort_keys=True, default=str)
        except TypeError:
            pass
    try:
        return json.dumps(codable.to_json(v), sort_keys=True, default=str)
    except Exception:  # noqa: BLE001
        return repr(v)


def generation_key(part_id: str, p, transform, lo, hi, tabs, tab_bottom: float, machine) -> str:
    """Everything that shapes one operation's toolpath."""
    tab_text = _describe(tabs) if tabs is None or tabs.frame is None else _describe(dataclasses.replace(tabs, frame=None)) + tabs.frame.description
    parts = [part_id, _describe(machine), _describe(p.operation), _describe(p.tool), _describe(p.data), repr(p.z_min), repr(p.through),
             repr(p.z_top), repr(p.keep_out), repr(p.keep_out_below), repr(p.band), repr(p.frame_top), _describe(p.ref_tool),
             _describe(np.asarray(transform, float)), _describe(np.asarray(lo, float)), _describe(np.asarray(hi, float)), tab_text,
             repr(tab_bottom), repr(p.tile), repr(p.rest_from), repr(p.holes), repr(p.window)]
    if safe_height(p) != 3:
        parts.append(f"safe:{safe_height(p)}")
    return "|".join(parts)


def generation_workers() -> int:
    """How many engine processes generate at once (the main one and workers)."""
    try:
        n = int(os.environ.get("COASTLINE_WORKERS", ""))
        if n >= 1:
            return n
    except ValueError:
        pass
    engines = int(AppSettings.value("engines", 0) or 0)
    if engines > 0:
        return engines
    cores = os.cpu_count() or 4
    return 4 if cores >= 10 else 3 if cores >= 8 else 2


def lift_where(moves: list[Move], blocked, inside=lambda x: x, safe_z: float = 3, plunge_feed: float = 0.0) -> tuple[list[Move], float]:
    """The moves with every stretch where `blocked(point)` lifted out: the tool rises to safe_z,
    crosses, and comes back down. `inside` brings a rapid's X back where the tool may go."""
    if not moves:
        return moves, 0.0
    out: list[Move] = []
    skipped = 0.0
    prev = moves[0].position
    lifted = False
    for k, m in enumerate(moves):
        if k == 0 or m.role == Role.RAPID:
            qx = inside(m.x)
            if lifted:
                out.append(Move(Role.RAPID, x=qx, y=m.y, z=max(m.z, safe_z)))
                if m.z < safe_z:
                    out.append(Move(Role.RAPID, x=qx, y=m.y, z=m.z))
                lifted = False
            else:
                if qx != m.x:
                    m = m.copy()
                    m.x = qx
                out.append(m)
            prev = m.position
            continue
        pts = FixtureClearance.samples(prev, m, 0.5)
        if not lifted and not blocked(prev) and not any(blocked(q) for q in pts):
            out.append(m)
            prev = m.position
            continue
        last = prev
        for q in pts:
            if blocked(q):
                if not lifted:
                    out.append(Move(Role.RAPID, x=inside(last[0]), y=last[1], z=safe_z))
                    lifted = True
                skipped += math.dist(q, last)
            elif lifted:
                out.append(Move(Role.RAPID, x=q[0], y=q[1], z=safe_z))
                out.append(Move(Role.PLUNGE, x=q[0], y=q[1], z=q[2], feed=plunge_feed))
                lifted = False
            else:
                out.append(Move(m.role, x=q[0], y=q[1], z=q[2], feed=m.feed))
            last = q
        prev = m.position
    if lifted and out:
        l = out[-1]
        out.append(Move(Role.RAPID, x=inside(l.x), y=l.y, z=safe_z))
    return out, skipped


def lift_outside(moves: list[Move], x, safe_z: float = 3, plunge_feed: float = 0.0) -> tuple[list[Move], float]:
    """The moves with every stretch outside the X range `x` lifted out."""
    return lift_where(moves, lambda p: p[0] < x.lower or p[0] > x.upper, lambda v: min(max(v, x.lower), x.upper), safe_z, plunge_feed)


def finish_job(one: list, k: int, sp: SidePlan) -> list:
    """What every operation's result goes through: warnings the plan handles become notes, and the
    pass lifts over what it can't reach or would meet (travel, end pieces, fixtures)."""
    p = sp.planned[k]
    clipped = [copy.copy(x) for x in one]
    for c in clipped:
        c.warnings, notes = triage_split(c.warnings, k, sp.planned)
        c.notes = list(c.notes) + list(notes)
    if sp.reach_x is not None:
        skipped = 0.0
        for c in clipped:
            c.moves, s = lift_outside(c.moves, sp.reach_x, safe_height(p), p.data.plunge_feed)
            skipped += s
        if skipped > 1 and clipped:
            how = "higher" if sp.reach_x.lower > -1e3 else "lower"
            clipped[0].warnings = clipped[0].warnings + [f"{Length.mm(skipped)} mm of this pass lies beyond the machine's X travel with the stock held like this: left uncut here (another setup may reach it; to cut it from this side, stand the stock {how} in the fixture)."]
    if sp.keep_y is not None and p.operation.reference is None:
        lo, hi = sp.keep_y[0] - 0.05, sp.keep_y[1] + 0.05
        skipped = 0.0
        for c in clipped:
            c.moves, s = lift_where(c.moves, lambda q: not (lo <= q[1] <= hi), safe_z=safe_height(p), plunge_feed=p.data.plunge_feed)
            skipped += s
        if skipped > 1 and clipped:
            clipped[0].notes = clipped[0].notes + [f"{Length.mm(skipped)} mm of this pass is on the stock past the part's ends: left for the end setups, which face it off."]
    facing = p.operation.kind.value == "facing"
    if k < len(sp.clamp_of) and not facing:
        f = sp.clampings[sp.clamp_of[k]].field
        skipped = 0.0
        for c in clipped:
            c.moves, s = FixtureClearance.clip(c.moves, p.tool, f, safe_z=safe_height(p), plunge_feed=p.data.plunge_feed)
            skipped += s
        if skipped > 1 and clipped:
            clipped[0].warnings = clipped[0].warnings + [f"{Length.mm(skipped)} mm of this pass was lifted to keep the tool clear of the vise's jaws: what it skips stays uncut."]
    if sp.fields and not facing:
        skipped = 0.0
        for c in clipped:
            for f in sp.fields:
                c.moves, s = FixtureClearance.clip(c.moves, p.tool, f, safe_z=safe_height(p), plunge_feed=p.data.plunge_feed)
                skipped += s
        if skipped > 1 and clipped:
            what = "collet nut" if p.tool.stickout < 20 else "tool"
            clipped[0].warnings = clipped[0].warnings + [f"{Length.mm(skipped)} mm of this pass was lifted to keep the {what} clear of the fixture or the table: what it skipped stays uncut. To cut there, stand the stock higher in the fixture (parallels under it) or use a longer stick-out."]
    return clipped


# ---------------------------------------------------------------- the app side

class BackgroundGenerationMixin:
    @property
    def generation_signature(self) -> str:
        """The job's shape that toolpaths depend on (a change while generating stops it)."""
        def h(v) -> str:
            try:
                return hashlib.sha1(json.dumps(codable.to_json(v), sort_keys=True, default=str).encode()).hexdigest()[:16]
            except Exception:  # noqa: BLE001
                return repr(v)
        try:
            profile = self.planning_machine_reference.fingerprint()
        except Exception:  # noqa: BLE001
            profile = repr(self.machine)
        return f"{profile}|{h(self.operations)}|{h(self.saved_resource_snapshot)}|{self.stock_id or ''}|{self.twoSided}|{h(self.setup)}"

    def gen_state(self, op_id: str):
        """("queued" | "running" | "ready" | ("failed", message)) for an operation, or None."""
        by_side = self.op_gen_state.get(op_id)
        if not by_side:
            return None
        states = [by_side[k] for k in sorted(by_side)]
        f = next((s for s in states if isinstance(s, tuple)), None)
        if f is not None:
            return f
        if "running" in states:
            return "running"
        if "queued" in states:
            return "queued"
        return "ready"

    @property
    def failed_operation_count(self) -> int:
        return sum(1 for v in self.op_gen_state.values() for s in v.values() if isinstance(s, tuple))

    def set_gen_state(self, id: str, side: int, s) -> None:
        self.op_gen_state.setdefault(id, {})[side] = s

    def _job_key(self, run: GenerationRun, si: int, k: int, main_part_id: str) -> str:
        sp = run.sides[si]
        return generation_key(main_part_id, sp.planned[k], sp.transform, sp.box_min if sp.box_min is not None else run.box_min,
                              sp.box_max if sp.box_max is not None else run.box_max, sp.tab_spec, sp.tab_bottom, run.machine)

    def _disk_key(self, run: GenerationRun, si: int, k: int, path) -> str:
        sp = run.sides[si]
        op = copy.copy(sp.planned[k])
        op.operation = dataclasses.replace(op.operation, id=disk.SAME_ID)
        return generation_key(disk.file_fingerprint(path), op, sp.transform, sp.box_min if sp.box_min is not None else run.box_min,
                              sp.box_max if sp.box_max is not None else run.box_max, sp.tab_spec, sp.tab_bottom, run.machine) + "|engine:" + disk.engine_fingerprint()

    def store_in_cache(self, key: str, value) -> None:
        self.op_cache[key] = value
        if key in self.op_cache_order:
            self.op_cache_order.remove(key)
        self.op_cache_order.append(key)
        while len(self.op_cache_order) > 48:  # 3D paths can be large
            self.op_cache.pop(self.op_cache_order.pop(0), None)

    def run_in_background(self, run: GenerationRun, path, fallback_id: str):
        """A task step: runs the jobs on the main engine and worker engines, then returns."""
        main = yield from self.live_engine()
        main_part_id = self.part.part_id if self.part is not None else fallback_id
        uncached = yield Work(lambda: sum(1 for si, k in run.jobs if self._job_key(run, si, k, main_part_id) not in self.op_cache
                                          and not disk.has(self._disk_key(run, si, k, path))), lane="cache")
        extra = max(min(generation_workers() - 1, uncached - 1), 0)
        tasks = [spawn(self._work(run, main, main_part_id, main_part_id, path, "engine"), "generate main")]
        for i in range(extra):
            def worker_loop(i=i):
                w = yield from self._worker(i, path)
                if w is None:
                    return
                yield from self._work(run, w[0], w[1], main_part_id, path, f"worker{i}")
            tasks.append(spawn(worker_loop(), f"generate worker {i}"))
        for t in tasks:
            yield t
        if self.generation_signature != run.signature or self.cancel_generation:
            raise Cancelled()

    def _worker(self, i: int, path):
        """A worker engine with the part loaded (kept between generations)."""
        if i < len(self.worker_engines):
            e, p, pid = self.worker_engines[i]
            if p == path and e.is_running():
                return e, pid
            e.terminate()

        def start():
            e = EngineClient()
            m = e.import_part(path)
            return e, m.part_id

        try:
            e, pid = yield Work(start, lane=f"worker{i}")
        except Cancelled:
            raise
        except Exception:  # noqa: BLE001 — the main engine carries on alone
            return None
        w = (e, path, pid)
        if i < len(self.worker_engines):
            self.worker_engines[i] = w
        else:
            self.worker_engines.append(w)
        return e, pid

    def _work(self, run: GenerationRun, engine, part_id: str, main_part_id: str, path, lane: str):
        """One engine's loop: takes the next job until there are none (or it's cancelled)."""
        while not self.cancel_generation and run.next < len(run.jobs):
            if self.generation_signature != run.signature:
                self.cancel_generation_now()
                self.status = "The job changed while generating: generate again (finished operations are kept)."
                return
            nsi, _ = run.jobs[run.next]
            if nsi > 0 and run.sides[nsi].tab_spec is not None and not run.frame_ready:
                yield from self.await_tab_frame(run, nsi)
                continue
            si, k = run.jobs[run.next]
            run.next += 1
            sp = run.sides[si]
            side, op_id = sp.side, sp.planned[k].operation.id
            self.set_gen_state(op_id, side, "running")
            self._update_generation_status(run)
            started = time.monotonic()
            key = self._job_key(run, si, k, main_part_id)
            try:
                hit = self.op_cache.get(key)
                if hit is not None:
                    one, placed = hit
                    self.cached_ops += 1
                else:
                    dkey = yield Work(lambda: self._disk_key(run, si, k, path), lane="cache")
                    hit = yield Work(lambda: disk.load(dkey), lane="cache")
                    if hit is not None:
                        one, placed = hit
                        self.store_in_cache(key, hit)
                        self.cached_ops += 1
                    else:
                        p = sp.planned[k]
                        lo = sp.box_min if sp.box_min is not None else run.box_min
                        hi = sp.box_max if sp.box_max is not None else run.box_max
                        one, placed = yield Work(lambda: cam.generate(engine, part_id, sp.transform, lo, hi, [p], safe_height(p), sp.tab_spec,
                                                                      sp.tab_bottom, run.machine), lane=lane)
                        self.store_in_cache(key, (one, placed))
                        value = (one, placed)
                        yield Work(lambda: disk.store(dkey, value), lane="cache")
                if self.cancel_generation or self.generation_signature != run.signature:
                    return
                run.done[si][k] = yield Work(lambda: finish_job(one, k, sp), lane="finish")
                if placed:
                    self.placed_tabs = placed
                    if sp.tab_spec is not None:
                        from ...core.codable import Range
                        self.placed_tab_z = Range(sp.tab_bottom, sp.tab_bottom + sp.tab_spec.height)
                if all(sp.planned[j].operation.id != op_id or run.done[si][j] is not None for j in range(len(sp.planned))):
                    self.set_gen_state(op_id, side, "ready")
                if TIMING:
                    print(f"timing op side {side} {sp.planned[k].operation.title} {time.monotonic() - started:.1f} s, {len(one[0].moves) if one else 0} moves")
                self._update_generation_status(run)
                try:
                    self.publish_partial(run)
                except Exception:  # noqa: BLE001 — showing partial results never fails the operation
                    import traceback
                    traceback.print_exc()
            except Cancelled:
                raise
            except Exception as e:  # noqa: BLE001
                if self.cancel_generation or self.generation_signature != run.signature:
                    return
                if isinstance(e, EngineError):
                    message = "The geometry engine crashed on this operation (a native library failed on this geometry)." if e.type == "EngineExited" else e.message
                else:
                    message = str(e)
                run.failed.append((si, k, message))
                self.set_gen_state(op_id, side, ("failed", message))
                self._update_generation_status(run)
                if not engine.is_running():
                    return  # this engine died: the others carry on

    def _update_generation_status(self, run: GenerationRun) -> None:
        running = sum(1 for v in self.op_gen_state.values() for s in v.values() if s == "running")
        failed = f" · {len(run.failed)} failed" if run.failed else ""
        self.status = f"Generating: {run.finished} of {run.total} ready · {running} at a time{failed}"
        self.generation_progress = run.finished / max(run.total, 1)
        self.touch()

    def publish_partial(self, run: GenerationRun, force: bool = False) -> None:
        """Shows each side's toolpaths from its start up to the first operation still being made.
        At most every 2.5 s (a side that completes shows at once)."""
        from .machining import SideResult
        if self.generation_signature != run.signature or self.cancel_generation:
            return
        if not any(run.prefix(si) > run.published[si] for si in range(len(run.sides))):
            return
        side_done = any(run.prefix(si) == len(run.sides[si].planned) and run.published[si] < run.prefix(si) for si in range(len(run.sides)))
        wait = 2.5 - (time.monotonic() - run.last_publish)
        if not force and not side_done and wait > 0:
            if not run.publish_scheduled:
                run.publish_scheduled = True

                def later():
                    yield Sleep(wait)
                    run.publish_scheduled = False
                    if self.is_generating and not self.cancel_generation:
                        self.publish_partial(run, force=True)

                spawn(later(), "publish")
            return
        run.last_publish = time.monotonic()
        results = []
        program = 0
        last_side = max((si for si in range(len(run.sides)) if run.prefix(si) > 0), default=0)
        for si in range(min(last_side + 1, len(run.sides))):
            sp = run.sides[si]
            n = run.prefix(si)
            run.published[si] = n
            planned = sp.planned[:n]
            paths = [p for j in range(n) for p in (run.done[si][j] or [])]
            op_program = []
            for k, p in enumerate(planned):
                if k > 0 and planned[k - 1].tool.id != p.tool.id:
                    program += 1
                op_program.append(program)
            if planned:
                program += 1
            results.append(SideResult(sp.side, sp.setup, planned, paths, op_program, [[] for _ in planned]))
        first = not self.side_results
        keep = self.playhead
        at_end = not self.timeline.entries or self.playhead >= self.timeline.duration - 1e-6
        self.side_results = results
        base = next((r for r in results if r.side == 0), results[0] if results else None)
        self.toolpaths = {}
        for p in (base.paths if base is not None else []):
            self.toolpaths.setdefault(p.operation_id, p)
        if self.viewSide >= 0 and not any(r.side == self.viewSide for r in results):
            self.viewSide = results[0].side if results else 0
        if first and self.viewSide < 0 and self.stage in ("machining", "review"):
            self.switching_view = True
            self.viewSide = 0
            self.switching_view = False
        if self.twoSided and results and len(results[0].planned) >= self.planned_operation_count.get(0, math.inf):
            self.compute_side_a_final()
        if first:
            if self.viewSide >= 0:
                self.show_side(0)
            self.focus_work()
        elif self.viewSide >= 0:
            self.show_side(max(keep - 1e-3, 0) if at_end else keep)
        self.touch()
