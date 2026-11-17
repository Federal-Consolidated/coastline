"""Finding and using plans (StrategyEngine), the stand-in vise to buy, plan coverage and the time
model's calibration. Port of Model/SmartPlan.swift."""

from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass

import numpy as np

from ...core import codable
from ...core.feeds import OperationKind as K
from ...core.geometry import Vec3
from ...core.inventory.items import Fixture, FixtureKind
from ...core.plan import strategy_engine as SE
from ...core.plan.fixture_mechanism import FixtureMechanism
from ...core.plan.library_workholding import eligibility
from ...core.plan.plan_coverage import PlanCoverage
from ...core.plan.setup_side import SetupSide
from ...core.plan.workholding_profile import Contact, ContactNormal, FixturePlanningProfile
from ...core.safety.fixture_clearance import FixtureField, box_triangles
from ...core.units import Length
from ..settings import AppSettings
from ..tasks import Sleep, Work


class StandInVise:
    """A plain stand-in for the vise to buy, drawn where it would hold the stock. Not a real
    fixture: no collision or clearance check uses it as one."""

    FLOOR, JAW_HEIGHT, JAW_DEPTH, JAW_WIDTH, FACE_PAST = 12.0, 18.0, 40.0, 12.0, 2.0

    @staticmethod
    def boxes(s, faced_before: float, jaw_front: float, t) -> list[tuple[str, np.ndarray, np.ndarray]]:
        V = StandInVise
        edge, bottom, w = -faced_before - V.FACE_PAST, -s[0] / 2, V.JAW_WIDTH
        front = min(jaw_front, edge)
        back = front - V.JAW_DEPTH
        table_top = bottom - V.FLOOR
        A = np.array
        return [("floor", A([table_top, -s[1] / 2 - w - 4, back - 6]), A([bottom, s[1] / 2 + w + 26, front])),
                ("fixedjaw", A([bottom, -s[1] / 2 - w, back]), A([bottom + V.JAW_HEIGHT, -s[1] / 2, front])),
                ("movingjaw", A([bottom, s[1] / 2, back]), A([bottom + V.JAW_HEIGHT, s[1] / 2 + w, front])),
                ("screw", A([bottom, s[1] / 2 + w + 8, back + 10]), A([bottom + 10, s[1] / 2 + w + 26, front - 10])),
                ("table", A([table_top - t.thickness, -200, edge - (t.north_z - t.back_z)]), A([table_top, 200, edge]))]

    @staticmethod
    def field(s, faced_before: float, jaw_front: float, t) -> FixtureField:
        tri = np.concatenate([box_triangles(lo, hi) for _, lo, hi in StandInVise.boxes(s, faced_before, jaw_front, t)])
        return FixtureField(tri, (-s[0] / 2 - 40, -s[1] / 2 - 80), (s[0] / 2 + 40, s[1] / 2 + 80))


@dataclass
class WorkholdingToBuy:
    id: str  # the setup's side ("+y")
    setup: int
    title: str
    detail: str


STAND_IN_PREFIX = "00000000-0000-4000-8000-0000000B"


def stand_in_id(side: int, clamping: int = 0) -> str:
    return f"{STAND_IN_PREFIX}{side:02d}{clamping:02d}"


def calibration_key(reference) -> str:
    if reference.is_legacy:
        return "strategyCalibration"
    try:
        return "strategyCalibration." + reference.fingerprint()
    except Exception:  # noqa: BLE001
        return "strategyCalibration.unavailable"


class SmartPlanMixin:
    def find_plans(self, library):
        """A task: searches the plans the inventory allows and keeps three to choose from."""
        self.capture_job_tools()
        inventory = self.planning_inventory(library)
        if not self.planning_machine_ready:
            self.errorMessage = self.planning_machine_problem or "Load a machine before planning."
            return
        machine, machine_reference = self.machine, self.planning_machine_reference
        part, stock = self.part, self.stock
        if part is None or stock is None or stock.material is None:
            return
        material = stock.material
        if material.validation_issues:
            self.errorMessage = f"{material.name}: " + " ".join(material.validation_issues)
            return
        if self.setup.holding is None and any(not eligibility(f, self.setup.stock_size(stock)) for f in inventory.fixtures):
            self.enable_library_planning()
        self.isFindingPlans = True
        try:
            self.status = "Analysing the part…"
            try:
                engine = yield from self.live_engine()
                m = self.work_transform(part)
                if self.cached_features(part, m) is None:
                    from ...core.engine import cam
                    result = yield Work(lambda: cam.features(engine, part.part_id, m))
                    if not (self.planning_machine_ready and self.planning_machine_reference == machine_reference):
                        return
                    self.features = result
                    self.features_key = (part.part_id, m)
                if self.analysis is None:
                    from ...core.plan.part_analysis import analyse
                    result = yield Work(lambda: analyse(engine, part.part_id, m, access=True))
                    if not (self.planning_machine_ready and self.planning_machine_reference == machine_reference):
                        return
                    self.analysis_transform = m
                    self.analysis = result
            except Exception as e:  # noqa: BLE001
                if self.planning_machine_reference == machine_reference:
                    self.errorMessage = f"Couldn't analyse the part: {e}"
                return
            a = self.analysis
            if a is None:
                return
            self.choose_sides(a)  # one or two sides decides how deep each side cuts
            lo, hi = self.setup.rotated_part_bounds(part.bounds_min, part.bounds_max)
            lo, hi = np.asarray(lo), np.asarray(hi)
            f = self.features
            facts = SE.Facts(a, tuple(hi - lo), tuple(self.setup.stock_size(stock)), material, min(0.25, self.setup.top_allowance),
                             [h.diameter for h in f.holes] if f is not None else [],
                             any(z < -1e-6 for z in f.floor_levels) if f is not None else False)
            # Holes are drilled and bored: their own widths and the rings of counterbores around
            # them aren't pockets or floors the end mills must fit.
            holes = f.holes if f is not None else []
            rings = [(b.diameter - h.diameter) / 2 for h in holes for b in holes
                     if b.diameter > h.diameter + 0.01 and math.hypot(h.x - b.x, h.y - b.y) < 0.01]

            def is_hole(w) -> bool:
                return any(abs(h.diameter - w) < 0.06 for h in holes)

            facts.pocket_widths = [w for w in (f.pocket_widths if f is not None else []) if not is_hole(w)]
            fw, fd = (f.floor_widths, f.floor_depths) if f is not None else ([], [])
            keep = [k for k in range(len(fw)) if k < len(fd) and fd[k] > 1e-6
                    and not any(abs(r - fw[k]) < 0.06 for r in rings) and not is_hole(fw[k])]
            facts.floor_widths = [fw[k] for k in keep]
            facts.floor_depths = [fd[k] for k in keep if k < len(fd)]
            part_z = hi[2] - lo[2]
            z = self.split_z
            if z is not None:
                part_above = -z - self.setup.top_allowance
                facts.cut_depth = max(-z + 0.5, part_z - part_above + 1.0)
            else:
                facts.cut_depth = self.setup.top_allowance + part_z
            self.status = "Comparing plans…"
            cal = self.calibration
            all_, with_buy_all = yield Work(lambda: (SE.candidates(facts, inventory, cal, False, machine),
                                                     SE.candidates(facts, inventory, cal, True, machine)), lane="planner")
            if not (self.planning_machine_ready and self.planning_machine_reference == machine_reference):
                return
            self.plan_candidates = all_
            self.plan_options = SE.recommend(all_)
            with_buy = [c for c in with_buy_all if c.needs_tools]
            best_finish = min((c.finish for c in self.plan_options), default=math.inf)
            best_risk = min((c.risk for c in self.plan_options), default=math.inf)
            extra = [c for c in SE.recommend(with_buy) if not self.plan_options or c.finish < best_finish * 0.7 or c.risk < best_risk - 0.15]
            extra = sorted(extra, key=lambda c: (c.risk, 1 if c.name.startswith("Finest") else 0, c.minutes))[:3]
            for c in extra:
                n = len(c.needs_tools)
                c.name = f"{c.name}, with {'a tool' if n == 1 else f'{n} tools'} to buy"

            def rubs(c) -> bool:
                return any("its shank rubs" in r for r in c.reasons)

            if any(not rubs(c) for c in extra):
                self.plan_options = [c for c in self.plan_options if not rubs(c)]

            def unfinished(c) -> bool:
                return c.finish >= SE.UNMADE_HOLE_FINISH

            if any(not unfinished(c) for c in extra):
                self.plan_options = [c for c in self.plan_options if not unfinished(c)]
            if extra and (not self.plan_options or extra[0].risk < best_risk - 0.15):
                self.plan_options = extra + self.plan_options
                self.recommended_plan = extra[0].name
            else:
                self.plan_options = self.plan_options + extra
                safest = min((c.risk for c in self.plan_options), default=0)
                safe = [c for c in self.plan_options if c.risk <= safest + 1e-9]
                sig = self.current_plan_signature
                kept = next((c for c in SE.pool(safe, lambda c: c.minutes) if c.signature == sig), None) if sig else None
                pick = kept or SE.pick(safe, lambda c: c.minutes)
                self.recommended_plan = pick.name if pick is not None else None
            self.plan_candidates = self.plan_candidates + with_buy
            more = "" if not extra else f"; {len(extra)} would be better with a tool you don't have yet"
            self.status = ("No usable plan: add a flat end mill to your inventory." if not self.plan_options else
                           f"Compared {len(all_) + len(with_buy)} plans; {len(SE.pareto(all_))} are best at something{more}")
        finally:
            self.isFindingPlans = False
            self.touch()

    @property
    def current_plan_signature(self) -> str | None:
        if self.chosen_plan is None:
            return None
        out = []
        for op in self.operations:
            if op.kind in (K.THREAD, K.ENGRAVE):
                continue
            t = self.job_tool(op.tool_id) if op.tool_id is not None else None
            out.append(op.kind.value + ":" + (t.name if t is not None else "") + ("(pockets)" if op.pockets_only is True else ""))
        return " ".join(out)

    def apply_remedy(self, r, c) -> None:
        """A risk's fix applied to a plan (and that plan used)."""
        if not self.planning_machine_ready:
            self.errorMessage = self.planning_machine_problem or "Wait for the job's machine to finish loading."
            return
        import copy
        fixed = copy.copy(c)
        fixed.operations = SE.apply(r, c.operations)
        fixed.remedies = [x for x in c.remedies if x != r]
        fixed.reasons = c.reasons + [f"Changed: {r.title}."]
        if r.change[0] == "swap":
            t = self.tool_lookup(r.change[2])
            if t is not None and not any(x.id == t.id for x in fixed.tools):
                fixed.tools = fixed.tools + [t]
        fixed.risk = max(fixed.risk - 0.2, 0)
        for k, o in enumerate(self.plan_options):
            if o.id == c.id:
                self.plan_options[k] = fixed
        self.use_plan(fixed)
        self.status = f"{r.title}: done. Generate to see it."

    @property
    def planned_sides(self) -> list[str]:
        return ["+z", "-z"] if self.twoSided else ["+z"]

    @property
    def turned_side_names(self) -> list[str]:
        if self.part is None or self.stock is None:
            return []
        return [SetupSide.names[k] for k in self.side_setup_sides(self.part, self.stock)]

    @property
    def plan_coverage(self) -> PlanCoverage | None:
        findings = self.dfm_findings(self.inventory)
        if findings is None:
            return None
        proposed = PlanCoverage.propose(findings)
        sides = [s for s in ("+z", "-z", "+x", "-x", "+y", "-y") if s in proposed or (self.operations and s in self.planned_sides)]
        turned = (self.turned_side_names if not self.side_results else
                  [SetupSide.names[r.side] for r in self.side_results if r.side >= 2 and r.side < len(SetupSide.names)])
        stock = self.stock
        return PlanCoverage.assess(findings, sides, {o.tool_id for o in self.operations if o.enabled and o.tool_id is not None},
                                   set(self.planned_sides + turned), self.setup_room,
                                   tuple(self.setup.stock_size(stock)) if stock is not None else None)

    @property
    def coverage_gap_note(self) -> str | None:
        if not self.operations:
            return None
        c = self.plan_coverage
        n = c.open if c is not None else 0
        if n <= 0:
            return None
        return f"{n} feature{' is' if n == 1 else 's are'} not in the toolpaths."

    def coverage_workholding(self, side: int) -> tuple:
        """The workholding for a side's setup, else None and why each fixture can't hold it."""
        plan = self.library_workholding_plan
        step = next((s for s in plan.steps if s.side == side), None) if plan is not None else None
        if step is not None and not self.is_stand_in(step.fixture):
            return step.fixture, None
        stock = self.stock
        if not self.setup.plan_from_fixture_library or stock is None:
            return None, None
        library = self.inventory
        fitted, why = self.automatic_fixtures(library, self.setup_for(side).stock_size(stock))
        if fitted:
            return fitted[0], None
        reasons = [f"{f.name}: {why[f.id]}" for f in library.fixtures if f.quantity > 0 and FixtureMechanism.has(f.assembly) and f.id in why]
        return None, (" ".join(reasons) if reasons else None)

    def stand_in_fixture(self, side: int, clamping: int, s, faced_before: float, jaw_front: float, facing: float | None) -> Fixture:
        """The vise to buy as the fixture of one clamping of an end setup (quantity 0)."""
        V = StandInVise
        opening = int(math.ceil(s[1] + 1))
        if facing is not None:
            how = (("" if clamping == 0 else f"Slide the bar toward the spindle until its faced end stands {Length.mm(V.FACE_PAST)} mm past the table edge again. ")
                   + f"Grip the bar's long faces in the jaws at least {Length.mm(facing + 3)} mm behind its end, the end standing {Length.mm(V.FACE_PAST)} mm past the table edge and the rest out the back. This clamping faces {Length.mm(facing)} mm off the end.")
        else:
            how = f"Slide the bar toward the spindle until its faced end stands {Length.mm(V.FACE_PAST)} mm past the table edge, and grip it again with the jaws at the table edge. Touch off Z on the faced end."
        f = Fixture.make(f"Vise to buy (opens to {opening} mm)", FixtureKind.VISE, id=stand_in_id(side, clamping), quantity=0,
                         height=V.FLOOR, notes=how + " Bolt the vise to a T-slot with M4 hardware.")
        p = FixturePlanningProfile()
        p.stock_size = Vec3(float(s[0]), float(s[1]), float(s[2]))
        p.face_past_table = V.FACE_PAST + faced_before
        z = min(jaw_front, -faced_before - V.FACE_PAST) - V.JAW_DEPTH / 2
        p.contacts = [Contact(point=Vec3(0, -s[1] / 2, z), radius=6, normal=ContactNormal.Y),
                      Contact(point=Vec3(0, s[1] / 2, z), radius=6, normal=ContactNormal.Y)]
        f.planning = p
        return f

    @staticmethod
    def is_stand_in(f) -> bool:
        return f.id.startswith(STAND_IN_PREFIX)

    def stand_in_jaw_front(self, side: int) -> float:
        f = self.displayed_job_fixture
        if f is not None and self.is_stand_in(f) and f.planning is not None and f.planning.contacts:
            return f.planning.contacts[0].point.z + StandInVise.JAW_DEPTH / 2
        return -(self.end_piece_thickness(side) + 3)

    @property
    def stand_in_faced_before(self) -> float:
        f = self.displayed_job_fixture
        if f is None or not self.is_stand_in(f) or f.planning is None:
            return 0.0
        return max(f.planning.face_past_table - StandInVise.FACE_PAST, 0.0)

    @property
    def plan_waits_for_workholding(self) -> bool:
        plan = self.library_workholding_plan
        return plan is not None and any(self.is_stand_in(s.fixture) for s in plan.steps)

    def workholding_to_buy(self, side: int, number: int) -> WorkholdingToBuy | None:
        stock = self.stock
        if not self.setup.plan_from_fixture_library or stock is None or not 0 <= side < len(SetupSide.names) or self.bookend_mount_table is None:
            return None
        fixture, why = self.coverage_workholding(side)
        if fixture is not None:
            return None
        s = self.setup_for(side).stock_size(stock)
        opening = int(math.ceil(s[1] + 1))
        facing = f"side {'A' if side == 0 else 'B'} up" if side < 2 else f"its {SetupSide.words(side)} toward the spindle"
        return WorkholdingToBuy(SetupSide.names[side], number, f"A vise that opens to {opening} mm or more",
                                f"For setup {number}, the stock with {facing}. Its jaws hold the {Length.mm(s[1])} mm width with the face at the table edge and the rest out the back. Bolt it to a T-slot with M4 hardware."
                                + (f" Why yours don't: {why}" if why else ""))

    @property
    def shows_stand_in_vise(self) -> bool:
        if not self.setup.plan_from_fixture_library or self.fixture_placement is not None or self.showing_stock_only or self.stock is None:
            return False
        f = self.displayed_job_fixture
        if f is not None:
            return self.is_stand_in(f)
        return self.workholding_to_buy(max(self.viewSide, 0), 0) is not None

    @property
    def job_workholding_to_buy(self) -> list[WorkholdingToBuy]:
        c = self.plan_coverage
        if c is None:
            return []
        out = []
        for cut in c.setups:
            k = SetupSide.index(cut.side)
            if k is not None:
                w = self.workholding_to_buy(k, cut.number)
                if w is not None:
                    out.append(w)
        return out

    def select_coverage(self, cut) -> None:
        """Lights a setup's faces on the part, frames them and shows the stock as that setup mounts it."""
        from ...core.plan.dfm import Category, DFMFinding
        if cut is None:
            self.select_finding(None)
            return
        self.select_finding(DFMFinding(f"setup{cut.side}", Category.OK, f"Setup {cut.number}", "", faces=list(cut.faces)))
        side = SetupSide.index(cut.side)
        if side is None or self.part is None or self.stock is None:
            return
        plan = self.library_workholding_plan
        step = next((s for s in plan.steps if s.side == side), None) if plan is not None else None
        self.selected_library_step = step.id if step is not None else None
        if self.viewSide != side:
            self.show_side_number(side)
        else:
            self.layout_scene()
        self.focus_work()
        facing = f"side {'A' if side == 0 else 'B'} up" if side < 2 else f"its {SetupSide.words(side)} toward the spindle"
        title = self.setup_title(side, self.twoSided)
        note = next((n for n in self.plan_notes if n.startswith(title + ": ") and "left out" in n), None)
        dropped = ""
        if note is not None:
            rest = note[len(title) + 2:]
            dropped = " " + rest[:1].upper() + rest[1:]
        fixture, _ = self.coverage_workholding(side)
        fixture = fixture or self.displayed_job_fixture
        if fixture is not None:
            self.status = f"Setup {cut.number}: the stock with {facing}, in {fixture.name}.{dropped}"
        elif self.setup.plan_from_fixture_library:
            w = self.workholding_to_buy(side, cut.number)
            buy = f" To buy: {w.title[:1].lower()}{w.title[1:]}, on the Shopping List." if w is not None else ""
            self.status = f"Setup {cut.number}: the stock with {facing}. No fixture you own holds it this way.{buy}"

    @property
    def job_tools_to_buy(self) -> list:
        seen, out = set(), []
        for op in self.operations:
            if not op.enabled or op.tool_id is None:
                continue
            t = self.tool_lookup(op.tool_id)
            if t is not None and t.is_suggestion and t.id not in seen:
                seen.add(t.id)
                out.append(t)
        return out

    def use_plan(self, c) -> None:
        if not self.planning_machine_ready:
            self.errorMessage = self.planning_machine_problem or "Wait for the job's machine to finish loading."
            return
        from ...core.inventory.snapshot import JobResourceSnapshot
        if self.job_resources is None:
            self.job_resources = JobResourceSnapshot()
        for tool in c.tools:
            self.job_resources.tools = [t for t in self.job_resources.tools if t.id != tool.id] + [tool]
        # Threads and engraving are yours (no plan makes them): they stay, at the end.
        self.operations = list(c.operations) + [o for o in self.operations if o.kind in (K.THREAD, K.ENGRAVE)]
        self.plan_notes = list(c.reasons)
        self.plan_estimate = dict(c.minutes_by_op)
        self.chosen_plan = c.name
        self.touch()

    def use_plan_and_build(self, c, inventory):
        """A task: the plan, and its toolpaths start building at once."""
        if self.is_generating:
            self.cancel_generation_now()
            while self.is_generating:
                yield Sleep(0.1)
        self.use_plan(c)
        if self.chosen_plan != c.name:
            return
        yield from self.generate_or_apply(inventory)

    def learn_from_generation(self) -> None:
        """After generating: teach the time model what the simulation says each operation takes."""
        from ...core.safety.gcode_validator import time_estimate_seconds
        if not self.plan_estimate or not self.side_results:
            return
        simulated: dict[str, float] = {}
        for r in self.side_results:
            for k, path in enumerate(r.paths):
                if k < len(r.planned):
                    oid = r.planned[k].operation.id
                    simulated[oid] = simulated.get(oid, 0.0) + time_estimate_seconds([path], self.machine) / 60
        cal = SE.Calibration(dict(self.calibration.factor))
        for op in self.operations:
            est, sim = self.plan_estimate.get(op.id), simulated.get(op.id)
            if est is None or sim is None or not sim > 0:
                continue
            raw = est / self.calibration.factor.get(op.kind.value, 1.0)  # the estimate includes the current factor
            cal.learn(op.kind, raw, sim)
        self.calibration = cal
        AppSettings.set_value(calibration_key(self.planning_machine_reference), json.dumps(codable.to_json(cal)))

    @staticmethod
    def load_calibration(reference=None) -> SE.Calibration:
        from ...core.machine.planning_reference import PlanningMachineReference
        reference = reference or PlanningMachineReference.legacy()
        raw = AppSettings.value(calibration_key(reference), None)
        if raw:
            try:
                return codable.from_json(SE.Calibration, json.loads(raw))
            except Exception:  # noqa: BLE001
                pass
        return SE.Calibration()
