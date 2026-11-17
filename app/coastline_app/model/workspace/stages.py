"""The guided workflow: six stages, each with a status and the reason for it, free to go back
and forth. Port of Model/Stages.swift."""

from __future__ import annotations

from dataclasses import dataclass

from PySide6.QtCore import Slot

WORKFLOW = ["partStock", "stock", "setups", "planning", "machining", "review"]
TITLES = {"partStock": "Part", "stock": "Stock", "planning": "Plan", "setups": "Setups", "machining": "Toolpaths", "review": "Review"}


@dataclass
class StageStatus:
    state: str  # done, todo, attention, blocked, notNeeded, later
    why: str


class StagesMixin:
    def generation_blocker(self) -> str | None:
        """Why Generate can't run yet (None: it can)."""
        if self.fixture_placement is not None:
            return "Save or cancel the fixture placement before generating the job."
        for st in ("partStock", "stock", "setups"):
            s = self.stage_status(st)
            if s.state == "blocked":
                return f"First: {TITLES[st]}, {s.why[:1].lower()}{s.why[1:]}"
        ops = [o for o in self.operations if o.enabled]
        if not ops:
            return "First: find the best plan (or a quick suggestion) above."
        if any(o.tool_id is None or self.job_tool(o.tool_id) is None for o in ops):
            return "First: choose a tool for every operation."
        return None

    def stage_status(self, stage: str) -> StageStatus:
        has_part, has_stock = self.part is not None, self.stock is not None
        S = StageStatus
        if stage == "partStock":
            if not has_part:
                return S("todo", "Import a part (STEP, IGES or Rhino).")
            return S("done", "Part loaded at its designed size. Next, choose material from your stock library.")
        if stage == "stock":
            if not has_part:
                return S("later", "Load a part first.")
            if not has_stock:
                return S("todo", "Choose the stock you have.")
            owned = self.stock_lookup(self.stock.id)
            if (owned.quantity if owned is not None else 0) <= 0:
                return S("attention", "This blank is not marked as owned. Confirm you have it before planning with your library.")
            current = next((o for o in self.stock_options() if o.axes == self.setup.stock_axes), None)
            if current is None or not current.workable:
                return S("blocked", "The part is larger than this stock as oriented: turn it, scale it (Fit), or choose other stock.")
            error = next((i for i in self.stock_containment_issues if i.severity.name == "ERROR"), None)
            if error is not None:
                return S("blocked", error.message)
            return S("done", "The part fits your stock. Next, choose the workholding in Setups.")
        if stage == "planning":
            if not (has_part and has_stock):
                return S("later", "Load a part and choose your stock first.")
            if self.isPlanningJob:
                return S("todo", "Comparing your tools, generating cuts and checking fixture clearance.")
            plan = self.library_workholding_plan
            if self.setup.plan_from_fixture_library and plan is not None and not plan.complete:
                return S("blocked", "No complete setup sequence. Resolve the workholding issues below.")
            if self.programs:
                gaps = self.coverage_gap_note
                if gaps:
                    return S("attention", f"{gaps} See Setups below.")
                if self.setup.plan_from_fixture_library and not (plan is not None and plan.reviewed):
                    return S("attention", "Job proposed. Review each setup below, then inspect the toolpaths.")
                return S("done", "Job proposed. Inspect the toolpaths next.")
            return S("todo", "See what the part needs, then build the toolpaths from your tools and workholding.")
        if stage == "setups":
            if not (has_part and has_stock):
                return S("later", "After the part and stock.")
            if self.automatic_workholding:
                fitted = [f.name for f in self.automatic_fixtures(self.inventory)[0]]
                if not fitted:
                    return S("todo", "None of your fixtures fits this stock by itself. Choose one to place by hand.")
                return S("done", f"Automatic: {', '.join(fitted)} fit{'s' if len(fitted) == 1 else ''} this stock. The plan picks for each cut.")
            if self.setup.plan_from_fixture_library or self.setup.holding is None:
                if not (self.setup.selected_fixture_ids or []):
                    return S("todo", "Choose the workholding for this stock, then continue to Plan.")
                return S("done", "Workholding chosen. Next, check the part and build the plan.")
            error = next((i for i in self.setup_issues if i.severity.name == "ERROR"), None)
            if error is not None:
                return S("blocked", error.message)
            return S("attention", f"{self.setup.custom_fixture.name}. Check its placement and notes. Custom fixture geometry is not included in collision checks.")
        if stage == "machining":
            if not (has_part and has_stock):
                return S("later", "After the setup.")
            if not self.operations:
                return S("todo", "Build the plan first.")
            if self.is_generating:
                return S("todo", "Generating in the background: look at and simulate what's ready while the rest is made.")
            n = self.failed_operation_count
            if n > 0:
                return S("blocked", f"{n} operation{'' if n == 1 else 's'} failed: Retry redoes only {'it' if n == 1 else 'them'}.")
            if not self.programs:
                k = sum(1 for o in self.operations if o.enabled)
                return S("todo", f"Next: generate the toolpaths for the {k} operations.")
            if not all(p.report.passed for p in self.programs):
                return S("blocked", "A program failed its safety check.")
            gaps = self.coverage_gap_note
            if gaps:
                return S("attention", f"Toolpaths ready. {gaps} See Plan.")
            if self.setup.plan_from_fixture_library:
                plan = self.library_workholding_plan
                return S("done" if plan is not None and plan.reviewed else "attention",
                         "Toolpaths ready. Review the proposed setups in Plan, then simulate and check the cuts here.")
            if self.setup.holding is not None and self.setup.holding.value == "custom":
                return S("attention", "Toolpaths ready. Review the simulation and check your custom fixture's clearance; its geometry is not modelled.")
            return S("done", "Toolpaths ready and safety-checked.")
        # review
        if not self.programs:
            return S("later", "After the toolpaths.")
        return S("todo", "Next: simulate the job, then run it from Control.")

    @Slot(str)
    def enterStage(self, stage: str) -> None:
        if self.can_visit(stage):
            self.enter(stage)

    def enter(self, stage: str) -> None:
        """Goes to a stage: the inspector shows it and the 3D view shows what it's about."""
        self.stage = stage
        if stage in ("partStock", "stock"):
            self.switching_view = True
            self.viewSide = 0
            self.switching_view = False
            self.layout_scene()
            self.focus_work()
        elif stage in ("planning", "setups"):
            self.show_side_number(0)
            self.layout_scene()
        else:
            # Back from a setup step: rebuild the side's paths and simulation.
            if self.side_results:
                if self.viewSide < 0:
                    self.viewSide = 0
                self.show_side()
            self.layout_scene()
        self.touch()

    def can_visit(self, stage: str) -> bool:
        if stage == "partStock":
            return True
        if stage == "stock":
            return self.part is not None
        if stage in ("planning", "setups"):
            return self.part is not None and self.stock is not None
        if stage == "machining":
            return bool(self.operations) or bool(self.programs)
        return bool(self.programs) and not self.is_generating

    @Slot(result="QVariantList")
    def stageRows(self) -> list[dict]:
        out = []
        for k, st in enumerate(WORKFLOW):
            s = self.stage_status(st)
            out.append({"id": st, "number": k + 1, "title": TITLES[st], "state": s.state, "why": s.why,
                        "canVisit": self.can_visit(st), "current": self.stage == st})
        return out
