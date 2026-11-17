"""The job's steps in the order they happen at the machine (clampings, edge finding, programs,
measuring, turning over, freeing the part), grouped into chapters; moving between them; what to
do at each. Port of the model parts of Views/JobStrip.swift, Model/JobStepGuide.swift and
LibraryWorkholding.libraryJobSteps."""

from __future__ import annotations

from dataclasses import dataclass, field

from ...core.export import finishing_guide as FinishingGuide
from ...core.feeds import OperationKind as K
from ...core.plan import edge_finding as EdgeFinding
from ...core.plan.operation import ReferenceFeature
from ...core.plan.setup import Workholding
from ...core.plan.setup_side import SetupSide
from ...core.units import Length
from .machining import duration_text, edge_find_program
from .tab_check import THROUGH_MAX_EXCESS


@dataclass(frozen=True)
class JobChapter:
    id: str
    title: str
    side: int


@dataclass
class JobStep:
    id: str
    kind: str  # setup, program, flip, measure, finish
    number: int
    title: str
    detail: str
    symbol: str
    side: int
    stage: int = 0
    program: int | None = None
    minutes: float | None = None
    checkpoint: object | None = None
    chapter: JobChapter = field(default_factory=lambda: JobChapter("", "", 0))

    @property
    def hand_minutes(self) -> float:
        return {"setup": self.minutes if self.minutes is not None else 5, "flip": 4, "measure": 1.5, "finish": 10}.get(self.kind, 0)

    @property
    def duration(self) -> float:
        return max(self.minutes if self.minutes is not None else 1, 0.2) if self.kind == "program" else self.hand_minutes

    @property
    def phase(self) -> str:
        return "finish" if self.kind == "finish" else ("sideA" if self.side == 0 else "sideB")


def _short(name: str) -> str:
    return name.split(" · ")[0]


class JobStepsMixin:
    @property
    def library_job_steps(self) -> list[JobStep]:
        plan = self.library_workholding_plan
        if plan is None:
            return []
        out = []
        checks = self.checkpoints()
        for step in plan.steps:
            ch = JobChapter(f"library.{step.id}", step.title, step.side)
            out.append(JobStep(f"library.{step.id}", "setup", len(out) + 1, step.title,
                               f"Secure stock in {step.fixture.name}, verify grip and reset work zero.", "hand.raised", step.side, chapter=ch))
            for p in self.programs:
                if p.workholding_step is None or p.workholding_step.id != step.id:
                    continue
                out.append(JobStep(f"p{p.index}", "program", len(out) + 1, p.tool.name, p.ops_title, "wrench.and.screwdriver", step.side,
                                   program=p.index, minutes=p.seconds / 60, chapter=ch))
                for i, c in enumerate(checks):
                    if c.after_program == p.index:
                        out.append(JobStep(f"lc{p.index}.{i}", "measure", len(out) + 1, "Measure", c.what, "ruler", step.side,
                                           program=p.index, checkpoint=c, chapter=ch))
        if plan.steps:
            last = plan.steps[-1]
            out.append(JobStep("finish", "finish", len(out) + 1, "Finish", "Unclamp and deburr", "scissors", last.side,
                               chapter=JobChapter("library.finish", "Finish", last.side)))
        return out

    @property
    def job_steps(self) -> list[JobStep]:
        """The job as the user runs it, in the same order as the guided job."""
        plan = self.library_workholding_plan
        if self.setup.plan_from_fixture_library and plan is not None and plan.complete and self.programs:
            return self.library_job_steps
        if self.programs:
            progs = [(p.index, p.side, p.tool, p.operations, p.seconds) for p in self.programs]
        else:
            progs = [(i, side, tool, ops, None) for i, side, tool, ops in self.planned_programs]
        if not progs:
            return []
        out: list[JobStep] = []

        def add(kind, id, title, detail, symbol, side, stage=0, program=None, minutes=None):
            out.append(JobStep(id, kind, len(out) + 1, title, detail, symbol, side, stage, program, minutes))

        reach = self.probing() if self.stock is not None else None

        def edge_find(side: int, stage: int) -> None:
            k = min(side, 1)
            both = side < 0 or reach is None or (reach.lower_x_reachable[k] and reach.upper_x_reachable[k])
            edges = "lower, upper, left and right edge" if both else "one X edge (the other is out of reach: X0 from it and the stock's height), left and right edge"
            add("program", f"e{side}.{stage}", "Edge-find", f"edge finder: {edges} → X0 Y0 at the face's centre; then touch off each tool on the face (Z0)",
                "scope", side, stage, edge_find_program(side, stage))

        checks = self.checkpoints()

        def measures(index: int, side: int) -> None:
            for n, c in enumerate(checks):
                if c.after_program == index:
                    out.append(JobStep(f"c{index}.{n}", "measure", len(out) + 1, "Measure",
                                       f"{c.what}: {Length.mm(c.expected)} ± {Length.mm(c.tolerance)} mm", "ruler", side, 0, index, checkpoint=c))

        def program_step(p, side: int) -> None:
            index, _, tool, ops, secs = p
            add("program", f"p{index}", _short(tool.name), "Change tool, touch off · " + ", ".join(o.title for o in ops),
                "wrench.and.screwdriver", side, program=index, minutes=secs / 60 if secs is not None else None)

        turned = []
        for p in progs:
            if p[1] >= 2 and p[1] not in turned:
                turned.append(p[1])
        for side in turned:
            words = SetupSide.words(side)
            add("setup", f"turn{side}", f"Turn: {words} to the spindle",
                f"Turn the stock so its {words} faces the spindle · secure it in the fixture shown · find the X/Y centre · touch off", "rotate.3d", side)
            edge_find(side, 0)
            for p in progs:
                if p[1] == side:
                    program_step(p, side)
                    measures(p[0], side)
        if turned:
            add("setup", "setup", "Turn: front to the spindle",
                "Turn the stock back so its front faces the spindle · secure it in the fixture shown · find the X/Y centre · touch off", "rotate.3d", 0)
        elif self.setup.holding == Workholding.CUSTOM:
            add("setup", "setup", "Secure in your fixture & edge-find",
                f"{self.setup.custom_fixture.name} · check fixture clearance · find the X/Y centre · touch off", "square.and.arrow.down.on.square", 0)
        else:
            add("setup", "setup", "Secure the stock & edge-find", "Secure the stock · find the X/Y centre · touch off", "square.and.arrow.down.on.square", 0)
        edge_find(0, 0)
        for p in progs:
            if p[1] == 0:
                program_step(p, 0)
                measures(p[0], 0)
        if self.twoSided:
            custom = self.setup.holding == Workholding.CUSTOM
            add("flip", "flip", "Turn over & re-clamp",
                "Front-to-back about the vertical axis · secure in your fixture · edge-find and touch off again" if custom
                else "Front-to-back about the vertical axis · secure it again · edge-find and touch off again", "arrow.triangle.2.circlepath", 1)
            edge_find(1, 0)
            for p in progs:
                if p[1] != 1:
                    continue
                program_step(p, 1)
                measures(p[0], 1)
                if any(o.reference == ReferenceFeature.WINDOWS for o in p[3]):
                    add("setup", "bores", "Find the reference bores",
                        "The edge finder finds each bore's four walls · X0 Y0 from the two centres · checks their size, spacing and squareness",
                        "circle.circle", 1, program=p[0], minutes=15)
        on_tabs = ((self.twoSided and self.holdWithTabs) or self.cuts_through_with_tabs) and bool(self.placed_tabs)
        finish = (f"Cut the {len(self.placed_tabs)} tabs, file the stubs" if on_tabs else "Saw the web, file flush" if self.twoSided
                  else "Saw it off the bar, face the back" if self.part_on_bar_back > 0.05 else "Unclamp and deburr")
        add("finish", "finish", "Free the part" if on_tabs or self.twoSided else "Finish", finish, "scissors", 1 if self.twoSided else 0)
        ops_of = {}
        for p in progs:
            ops_of.setdefault(p[0], p[3])

        def stage_of_work(ops) -> tuple[int, str]:
            if not ops:
                return 0, "Roughing"
            o = ops[0]
            if o.kind == K.FACING:
                return 0, "Roughing"
            if o.kind == K.ADAPTIVE:
                return (1, "Pockets") if o.pockets_only is True else (0, "Roughing")
            if o.kind in (K.CONTOUR, K.FLOOR, K.CHAMFER):
                return 2, "Walls & floors"
            if o.kind in (K.BORE, K.DRILL, K.ENGRAVE):
                return 4, "Holes & details"
            return 3, "Finishing"

        def side_name(side: int) -> str:
            if side >= 2:
                return SetupSide.words(side).title() + " · "
            return ("A · " if side == 0 else "B · ") if (self.twoSided or turned) else ""

        last = None
        runs = 0
        for st in out:
            if st.kind == "finish":
                key, title = "finish", st.title
            elif st.kind == "measure":
                key, title = (last[0], last[1].title) if last is not None else ("measure", "Measure")
            elif st.kind in ("setup", "flip"):
                what = ("Turn over & edge-find" if st.kind == "flip" or st.side == 1
                        else "Turn & edge-find" if st.side >= 2 or (st.side == 0 and turned) else "Clamp & edge-find")
                key, title = f"s{st.side}.setup", side_name(st.side) + what
            elif st.program == edge_find_program(st.side, 0) or any(o.reference == ReferenceFeature.WINDOWS for o in ops_of.get(st.program, [])):
                key, title = f"s{st.side}.setup", side_name(st.side) + ("Turn over & edge-find" if st.side == 1 else "Clamp & edge-find")
            else:
                cat, name = stage_of_work(ops_of.get(st.program, []))
                key, title = f"s{st.side}.{cat}", side_name(st.side) + name
            if last is None or last[0] != key:
                runs += 1
                last = (key, JobChapter(f"{key}#{runs}", title, st.side))
            st.chapter = last[1]
        return out

    # ---------------------------------------------------------------- where we are

    @property
    def current_program(self) -> int | None:
        if not self.timeline.entries:
            return None
        return self.timeline.entries[self.timeline.index(self.playhead)].program

    def is_active(self, step: JobStep) -> bool:
        sel = self.selected_step
        if sel is not None and abs(self.playhead - sel[1]) < 1e-6:
            return step.id == sel[0]
        at_start = self.playhead <= 1e-6
        if step.kind == "program":
            return step.program == self.current_program
        if step.kind == "setup":
            if self.setup.plan_from_fixture_library:
                cur = self.current_library_step
                return step.id == f"library.{cur.id if cur is not None else ''}" and at_start
            return self.viewSide == 0 and at_start
        if step.kind == "flip":
            return self.viewSide == 1 and at_start
        if step.kind == "measure":
            return sel is not None and sel[0] == step.id and abs(self.playhead - sel[1]) < 1e-6
        return self.viewSide == step.side and self.playhead >= self.timeline.duration - 1e-6 and self.timeline.duration > 0

    @property
    def current_step(self) -> JobStep | None:
        steps = self.job_steps
        s = next((s for s in steps if self.is_active(s)), None)
        if s is not None:
            return s
        if self.selected_step is not None:
            s = next((s for s in steps if s.id == self.selected_step[0]), None)
            if s is not None:
                return s
        return steps[0] if steps else None

    @property
    def open_chapter(self) -> JobChapter | None:
        cur = self.current_step
        if cur is not None:
            return cur.chapter
        s = next((s for s in self.job_steps if s.side == self.viewSide), None)
        return s.chapter if s is not None else None

    def program_ready(self, p: int) -> bool:
        if not self.is_generating:
            return True
        planned = next((x for x in self.planned_programs if x[0] == p), None)
        if planned is None:
            return False
        r = next((r for r in self.side_results if r.side == planned[1]), None)
        done = sum(1 for q in r.operation_program if q == p) if r is not None else 0
        return done >= len(planned[3])

    def chapter_ready(self, group: list[JobStep]) -> bool:
        if not self.is_generating:
            return bool(self.programs) or bool(self.side_results)
        progs = [s.program for s in group if s.program is not None and s.program < 2000]
        if not progs:
            side = group[0].side if group else 0
            return any(r.side == side and r.planned for r in self.side_results)
        return all(self.program_ready(p) for p in progs)

    def chapter_progress(self, group: list[JobStep]) -> float | None:
        progs = [s.program for s in group if s.program is not None and s.program < 2000]
        if not progs:
            return None
        return sum(1 for p in progs if self.program_ready(p)) / len(progs)

    @property
    def chapter_span(self) -> tuple[float, float] | None:
        ch = self.open_chapter
        entries = self.timeline.entries
        if ch is None or not entries:
            return None
        progs = {s.program for s in self.job_steps if s.chapter == ch and s.program is not None}
        mine = [e for e in entries if e.program in progs]
        if not mine or not mine[-1].t_end > mine[0].t_start:
            return None
        return mine[0].t_start, mine[-1].t_end

    def chapter_number(self, ch: JobChapter) -> int:
        seen = []
        for st in self.job_steps:
            if not seen or seen[-1] != st.chapter:
                seen.append(st.chapter)
        return (seen.index(ch) if ch in seen else 0) + 1

    def step_span(self, step: JobStep) -> tuple[float, float] | None:
        if step.kind != "program" or step.program is None or step.side != self.viewSide:
            return None
        mine = [e for e in self.timeline.entries if e.program == step.program]
        return (mine[0].t_start, mine[-1].t_end) if mine else None

    @property
    def manual_edge_finding_now(self) -> bool:
        """The playhead is in edge finding with the edge finder (by hand at the machine)."""
        entries = self.timeline.entries
        if not self.shows_machining_results or not entries:
            return False
        e = entries[min(max(self.timeline.index(self.playhead), 0), len(entries) - 1)]
        return e.program >= 2000 and 0 <= e.operation < len(self.planned_tools) and self.planned_tools[e.operation].id == EdgeFinding.TOOL.id

    def step_after(self, s: JobStep, delta: int) -> JobStep | None:
        steps = self.job_steps
        i = next((k for k, x in enumerate(steps) if x.id == s.id), None)
        if i is None or not 0 <= i + delta < len(steps):
            return None
        return steps[i + delta]

    # ---------------------------------------------------------------- moving

    def go_to_step(self, step: JobStep) -> None:
        """Shows a step: switches side or clamping and jumps to its program."""
        self.pause()
        plan = self.library_workholding_plan
        if step.id.startswith("library.") and plan is not None:
            holding = next((s for s in plan.steps if f"library.{s.id}" == step.id), None)
            if holding is not None:
                self.inspect_library_step(holding)
                self.selected_step = (step.id, self.playhead)
                self.touch()
                return

        def seek_to():
            entries = self.timeline.entries
            if step.kind in ("setup", "flip"):
                self.seek(0)
            elif step.kind == "finish":
                self.seek(self.timeline.duration)
            elif step.kind == "measure":
                e = next((e for e in reversed(entries) if e.program == step.program), None)
                if e is not None:
                    self.seek(e.t_end)
            else:
                e = next((e for e in entries if e.program == step.program), None)
                if e is not None:
                    self.seek(e.t_start)
            self.selected_step = (step.id, self.playhead)
            self.touch()

        if step.side != self.viewSide:
            self.pending_seek = seek_to
            self.show_side_number(step.side)
        elif self.stock_animating:
            self.pending_seek = seek_to
        else:
            seek_to()

    def visit(self, step: JobStep) -> None:
        """Shows a step and frames it from the front, where you stand at the machine."""
        self.go_to_step(step)
        self.set_view("iso")
        self.focus_work()

    def instructions(self, step: JobStep) -> list[str]:
        """The step's instructions, short and in order."""
        stock = self.stock
        material = stock.material if stock is not None else None
        if step.kind == "program" and (step.program or 0) >= 2000:
            return ["**By hand, at the machine:** this animation only shows the order. The sender can't feel the stock here, so you jog.",
                    f"Edge finder in the collet, spinning at {int(self.machine.probe_spindle_rpm)} RPM.",
                    "In Machine Control, jog to the lower and upper edge (X), then the left and right edge (Y), until the finder kicks each time, and store it: the sender takes the centre as X0 Y0.",
                    "Then each tool is touched off on the face with a sheet of paper (Z0) before it cuts."]
        if step.kind == "program":
            p = next((p for p in self.programs if p.index == step.program), None)
            if p is None:
                return []
            out = [f"**{p.tool.name}**, {Length.mm(p.tool.stickout)} mm sticking out of the collet nut.",
                   f"{p.ops_title}, about {duration_text(p.seconds)}."]
            if p.min_stickout is not None and p.min_stickout > p.tool.stickout + 0.1:
                out.append(f"Needs at least {Length.mm(p.min_stickout)} mm stick-out to keep the collet nut clear.")
            out.append("The first time: run it as an air cut 10 mm above the work, spindle off.")
            if material is not None:
                out.append(material.lubricant)
            return out
        if step.kind == "setup":
            plan = self.library_workholding_plan
            if step.id.startswith("library.") and plan is not None:
                holding = next((s for s in plan.steps if f"library.{s.id}" == step.id), None)
                if holding is not None:
                    return [holding.instructions]
            if self.setup.holding == Workholding.CUSTOM:
                c = self.setup.custom_fixture
                return [x for x in (f"Hold the stock in **{c.name}**, secured independently of material removed by the toolpaths.", c.notes,
                                    "Custom fixture geometry is not included in collision checks. Check the jaws and fasteners, then edge-find and touch off the stock in Machine Control.") if x]
            return ["Secure the stock with its face toward the spindle, square to the spindle.",
                    "Edge-find and touch off the stock in Machine Control before the first cut."]
        if step.kind == "flip":
            if self.setup.holding == Workholding.CUSTOM:
                return ["Turn the stock front-to-back about the vertical axis and secure it in your custom fixture.",
                        "Check clearance again, then edge-find and touch off for side B."]
            return ["Vacuum the chips. Release the stock and turn it front-to-back about the vertical axis: the back now faces the spindle, left becomes right.",
                    "Secure it again, then edge-find and touch off for side B."]
        if step.kind == "measure":
            c = step.checkpoint
            if c is None:
                return []
            instrument = self.measuring_tool_names[0] if self.measuring_tool_names else "a caliper"
            return [f"With {instrument}: {c.what.lower()} should be **{Length.mm(c.expected)} mm**, between {Length.mm(c.expected - c.tolerance)} and {Length.mm(c.expected + c.tolerance)}.",
                    "Too big: the tool deflected or wore. Run the finishing program again (it only takes what's left) or add a spring pass.",
                    "Too small: check the tool's real diameter and stick-out, and the touch-off. Don't unclamp before it's right."]
        out = []
        if self.setup.plan_from_fixture_library:
            out.append("Stop the spindle, move the tool clear, release the final fixture and deburr the part.")
        elif ((self.twoSided and self.holdWithTabs) or self.cuts_through_with_tabs) and self.placed_tabs:
            out.append(f"Unclamp. The part hangs in the frame on {len(self.placed_tabs)} tabs: cut each close to the part with a jeweller's saw.")
        elif self.twoSided:
            out.append("Unclamp and saw through the thin web to free the part.")
        elif self.part_on_bar_back > 0.05:
            out.append(f"Unclamp. The part is still joined to the back of the bar ({Length.mm(self.part_on_bar_back)} mm of it): saw around it, then face or sand the back flat. "
                       f"(With Hold with tabs on, a bar up to {Length.mm(THROUGH_MAX_EXCESS)} mm thicker than the part is cut through instead.)")
        else:
            out.append("Unclamp and deburr.")
        return out + FinishingGuide.steps(material)
