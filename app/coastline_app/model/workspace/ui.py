"""What the workspace screens call: one Qt slot per action, and read-outs as plain lists and maps.
QML re-reads them when `revision` changes. Port of the actions and read-outs in the SwiftUI
workspace views (WorkspaceView, StageViews, SetupInspector, MachiningInspector, PlaybackBar,
JobStrip, StepCard, ToolChangeCard, ViewModeBar, MachinabilitySection, PlanOptionsView,
JobPlanningGuide, LibraryWorkholdingSection, FixturePlacementInspector, JogPanel)."""

from __future__ import annotations

import dataclasses
import math
import re
import traceback
from pathlib import Path

import numpy as np
from PySide6.QtCore import QObject, QUrl, Slot

from ...core.feeds import OperationKind as K
from ...core.inventory.checks import InventoryChecks, Severity
from ...core.inventory.items import ToolKind
from ...core.plan.dfm import Category
from ...core.plan.operation import Operation, OperationPlanner
from ...core.plan.setup import Workholding
from ...core.plan.setup_side import SetupSide
from ...core.units import Length
from ..tasks import Work, spawn
from .core import WorkspaceCore
from .analysis import highlight_color
from .machining import duration_text

STAGE_SHORT = {"partStock": "Part", "stock": "Stock", "planning": "Plan", "setups": "Setups", "machining": "Paths", "review": "Review"}
STAGE_NEXT = {"partStock": "stock", "stock": "planning", "planning": "setups", "setups": "machining", "machining": "review"}
OP_SYMBOLS = {"facing": "square.3.layers.3d.top.filled", "adaptive": "scribble.variable", "contour": "circle.dashed", "floor": "square.dashed",
              "drill": "arrow.down.to.line", "bore": "circle.circle", "chamfer": "triangle", "parallel": "line.3.horizontal",
              "waterline": "water.waves", "steep_shallow": "mountain.2", "scallop": "circle.circle", "spiral": "hurricane", "radial": "asterisk",
              "rest": "pencil.tip", "engrave": "textformat", "thread": "screwdriver"}
STAGE_SYMBOLS = {"partStock": "cube.transparent", "stock": "shippingbox", "planning": "sparkles", "setups": "square.and.arrow.down.on.square",
                 "machining": "point.topleft.down.to.point.bottomright.curvepath", "review": "checklist"}
CATEGORY_NAMES = {Category.NOT_SUPPORTED: "notSupported", Category.MISSING_RESOURCE: "missingResource",
                  Category.MISSING_INFORMATION: "missingInformation", Category.SETUP_CHANGE: "setupChange", Category.OK: "ok"}
VIEWS = [("tool", "Tool"), ("toolIso", "Tool iso"), ("front", "Front"), ("top", "Top"), ("iso", "Iso")]
ADDABLE = [K.FACING, K.ADAPTIVE, K.CONTOUR, K.FLOOR, K.CHAMFER, K.DRILL, K.BORE, K.PARALLEL, K.WATERLINE, K.STEEP_SHALLOW,
           K.SCALLOP, K.REST, K.ENGRAVE, K.THREAD]


def _snake(key: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", key).lower().replace("_i_d", "_id")


def _f(v) -> float:
    return float(v) if v is not None else 0.0


def _url_path(url) -> Path:
    s = url.toLocalFile() if isinstance(url, QUrl) else str(url)
    if "://" in s:
        s = QUrl(s).toLocalFile()
    return Path(s)


class WorkspaceUI(WorkspaceCore):
    def _spawn(self, gen, name: str) -> None:
        def failed(e):
            traceback.print_exception(e)
            self.errorMessage = str(e)
        spawn(gen, name, on_error=failed)

    # ---------------------------------------------------------------- basics

    @Slot()
    def dismissError(self) -> None:
        self.errorMessage = ""

    @Slot(result="QVariantMap")
    def header(self) -> dict:
        """The window's title, the toolbar's state."""
        part = self.part
        return {"title": part.file_name if part is not None else "Workspace", "hasPart": part is not None,
                "canUndo": self.can_undo, "canRedo": self.can_redo, "undoName": self.undo_name or "", "redoName": self.redo_name or "",
                "dirty": self.project_dirty, "projectName": self.project_path.name if self.project_path is not None else "",
                "placing": self.fixture_placement is not None, "partChanged": self.part_changed_on_disk,
                "machineLoaded": self.machineLoaded, "machineTitle": self.planning_machine_title,
                "canChangeMachine": self.can_change_planning_machine, "hasStock": self.stock is not None, "stage": self.stage, "isGenerating": self.is_generating,
                "isPlanning": self.isPlanningJob or self.isFindingPlans, "generationProgress": _f(self.generation_progress),
                "loosePieces": self.loose_pieces, "undercutLegend": self.undercut_overlay_shown and not self.timeline.entries,
                "manualEdgeFinding": self.manual_edge_finding_now and self.tool_change_stop is None,
                "showsResults": self.shows_machining_results, "hasTimeline": bool(self.timeline.entries) or (self.is_generating and bool(self.planned_programs)),
                "showStepCard": self.show_step_card, "showCutFace": self.show_cut_face, "showUndercuts": self.show_undercut_overlay,
                "showFindings": self.show_findings_overlay, "inspecting": self.inspecting, "jogOpen": self.jog_open,
                "recentProjects": [str(p) for p in self.recent_projects()]}

    @Slot(str, bool)
    def setFlag(self, name: str, on: bool) -> None:
        """Display toggles kept in plain Python state."""
        attr = {"showStepCard": "show_step_card", "showCutFace": "show_cut_face", "showUndercuts": "show_undercut_overlay",
                "showFindings": "show_findings_overlay", "inspecting": "inspecting", "jogOpen": "jog_open"}.get(name)
        if attr is None:
            return
        setattr(self, attr, on)
        if name == "jogOpen" and on:
            self.jog_to(self.machine_position)
        self.touch()

    @Slot(str)
    def importPart(self, url: str) -> None:
        self._spawn(self.import_part(_url_path(url)), "import")

    @Slot()
    def reloadPart(self) -> None:
        self._spawn(self.reload_part(), "reload part")

    @Slot()
    def undoAction(self) -> None:
        self._spawn(self.undo(), "undo")

    @Slot()
    def redoAction(self) -> None:
        self._spawn(self.redo(), "redo")

    @Slot(result=bool)
    def saveProject(self) -> bool:
        """Saves to the job's file; False when it has none yet (QML asks for one)."""
        if self.project_path is None:
            return False
        self.saveProjectAs(str(self.project_path))
        return True

    @Slot(str)
    def saveProjectAs(self, url: str) -> None:
        path = _url_path(url)
        if path.suffix != ".coastline":
            path = path.with_suffix(".coastline")
        try:
            self.save_project(path)
        except Exception as e:  # noqa: BLE001
            self.errorMessage = f"Couldn't save: {e}"
        self.touch()

    @Slot(result=str)
    def suggestedProjectName(self) -> str:
        return (self.part.path.stem if self.part is not None else "Job") + ".coastline"

    @Slot(str)
    def openProject(self, url: str) -> None:
        self._spawn(self.open_project(_url_path(url)), "open project")

    @Slot()
    def updateJobResources(self) -> None:
        self.update_job_resources()
        self.touch()

    @Slot(result="QVariantList")
    def machineChoices(self) -> list:
        from ..machine_profiles import key
        out = []
        for p in self.machine_profiles.packages:
            try:
                selected = self.planning_machine_reference.reference is not None and self.planning_machine_reference.reference.id == p.definition.id
            except AttributeError:
                selected = False
            out.append({"key": key(p), "title": p.definition.name, "selected": bool(selected)})
        return out

    @Slot()
    def loadMachineProfiles(self) -> None:
        self._spawn(self.machine_profiles.reload(), "machine profiles")

    # ---------------------------------------------------------------- views

    @Slot(result="QVariantList")
    def standardViews(self) -> list:
        return [{"id": i, "title": t} for i, t in VIEWS]

    @Slot(float, float, float)
    def lookFrom(self, x: float, y: float, z: float) -> None:
        self.look_from(np.array([x, y, z]))

    @Slot()
    def focusWork(self) -> None:
        self.focus_work()

    @Slot()
    def focusPlacementContext(self) -> None:
        self.focus_placement_context()

    @Slot()
    def fit(self) -> None:
        if self.fixture_placement is not None:
            self.focus_placement_context()
        else:
            self.focus_work()

    @Slot(float, float)
    def click(self, x: float, y: float) -> None:
        if self.fixture_placement is not None:
            self.handle_placement_click(x, y)
        elif self.inspecting:
            self.inspect_at(x, y)
        else:
            self.viewportClicked(x, y)
        self.touch()

    @Slot(result="QVariantMap")
    def measureInfo(self) -> dict:
        pts = []
        for p in self.measure_points:
            summary = getattr(p.info, "summary", None) if p.info is not None else None
            pts.append(summary or ("Measuring…" if self.part is not None and self.part.exact else "Point on render mesh"))
        d, delta = self.measured_distance, self.measured_delta
        return {"points": pts, "distance": Length.mm(d) if d is not None else "",
                "delta": f"ΔX {Length.mm(abs(delta[0]))}  ΔY {Length.mm(abs(delta[1]))}  ΔZ {Length.mm(abs(delta[2]))}" if delta is not None else ""}

    @Slot(result="QVariantMap")
    def inspectedInfo(self) -> dict:
        i = self.inspected
        if i is None:
            return {}
        return {"operation": i.operation, "role": i.role, "feed": int(i.feed), "time": duration_text(i.time) if i.time >= 60 else f"{i.time:.0f} s",
                "position": f"X{Length.mm(i.position[0])} Y{Length.mm(i.position[1])} Z{Length.mm(i.position[2])}",
                "line": i.line or 0, "context": [{"n": n, "text": t, "here": n == i.line} for n, t in i.context]}

    @Slot()
    def closeInspected(self) -> None:
        self.inspected = None
        self.touch()

    @Slot(result="QVariantMap")
    def gumballPromptInfo(self) -> dict:
        p = self.gumball_prompt
        if p is None:
            return {}
        return {"title": p.title, "unit": p.unit, "x": float(p.point[0]), "y": float(p.point[1])}

    @Slot(float)
    def applyTypedMove(self, value: float) -> None:
        if self.gumball_prompt is not None:
            self.apply_typed(value, self.gumball_prompt)

    @Slot()
    def closeTypedMove(self) -> None:
        self.gumball_prompt = None
        self.layout_gumball()
        self.touch()

    @Slot()
    def sweepTravelSlot(self) -> None:
        self.sweep_travel()

    @Slot(result="QVariantList")
    def findingPins(self) -> list:
        """FindingPinsOverlay: a numbered pin, in its colour, on every problem area in view."""
        view = self.renderer.view
        if view is None or not self.shows_findings_in_view:
            return []
        findings = self.dfm_findings(self.inventory) or []
        problems = [f for f in findings if f.category != Category.OK]
        w_, h_ = view.width(), view.height()
        out = []
        for n, f in enumerate(problems):
            r, g, b = highlight_color(f.category)[:3]
            for w in self.finding_pin_points(f.id):
                p = view.project(w)
                if p is not None and 8 < p[0] < w_ - 8 and 8 < p[1] < h_ - 8:
                    out.append({"id": f.id, "x": float(p[0]), "y": float(p[1]), "number": n + 1, "title": f.title, "summary": f.summary,
                                "color": f"#{int(r * 255):02x}{int(g * 255):02x}{int(b * 255):02x}",
                                "selected": f.id == self.selected_finding_id})
        return out

    @Slot(result="QVariantMap")
    def findingCard(self) -> dict:
        """FindingCard: the picked problem explained, with its ways forward."""
        if not self.shows_findings_in_view or self.selected_finding_id is None:
            return {}
        problems = [f for f in (self.dfm_findings(self.inventory) or []) if f.category != Category.OK]
        n = next((k for k, f in enumerate(problems) if f.id == self.selected_finding_id), None)
        if n is None:
            return {}
        f = problems[n]
        r, g, b = highlight_color(f.category)[:3]
        return {"id": f.id, "number": n + 1, "title": f.title, "category": f.category.title, "measure": f.measure or "", "summary": f.summary,
                "fix": f.fix or "", "details": list(f.details), "color": f"#{int(r * 255):02x}{int(g * 255):02x}{int(b * 255):02x}",
                "remedies": [{"index": k, "title": rm.title_in(self.inventory, self.stock_id)}
                             for k, rm in enumerate(f.remedies) if rm.kind != "setStickout" and rm not in f.remedies[:k]]}

    # ---------------------------------------------------------------- stages

    @Slot(result="QVariantList")
    def stages(self) -> list:
        from .stages import TITLES, WORKFLOW
        out = []
        for i, s in enumerate(WORKFLOW):
            st = self.stage_status(s)
            out.append({"id": s, "number": i + 1, "title": TITLES[s], "short": STAGE_SHORT[s], "symbol": STAGE_SYMBOLS[s], "state": st.state, "why": st.why,
                        "current": self.stage == s, "enabled": self.can_visit(s) and not self.isPlanningJob})
        return out

    @Slot(result="QVariantMap")
    def stageHeader(self) -> dict:
        from .stages import TITLES, WORKFLOW
        st = self.stage_status(self.stage)
        nxt = STAGE_NEXT.get(self.stage)
        can_next = (nxt is not None and self.can_visit(nxt) and st.state != "blocked" and not self.isPlanningJob
                    and not (self.stage == "planning" and not self.programs) and not (self.stage == "stock" and st.state != "done"))
        return {"number": WORKFLOW.index(self.stage) + 1, "title": TITLES[self.stage], "why": st.why, "next": nxt or "",
                "nextTitle": TITLES.get(nxt, "") if nxt else "", "canNext": can_next}

    # ---------------------------------------------------------------- part and stock

    @Slot(result="QVariantMap")
    def partInfo(self) -> dict:
        part = self.part
        if part is None:
            return {}
        k = self.setup.part_scale
        fit = self.scale_to_fit_stock
        return {"file": part.file_name, "kind": part.kind,
                "size": f"{Length.mm(part.size.x * k)} × {Length.mm(part.size.y * k)} × {Length.mm(part.size.z * k)} mm" + (" (scaled)" if abs(k - 1) > 1e-9 else ""),
                "scale": k * 100, "fitScale": fit * 100 if fit is not None else 0, "warnings": list(part.warnings),
                "faces": part.face_count, "exact": part.exact}

    @Slot(float)
    def setPartScale(self, percent: float) -> None:
        self.change_setup(lambda s: setattr(s, "part_scale", min(max(percent / 100, 0.05), 10)))

    @Slot(result="QVariantList")
    def stockChoices(self) -> list:
        inv = self.inventory
        out = []
        for s in inv.stock:
            m = s.material
            out.append({"id": s.id, "title": f"{m.name if m is not None else '?'} · {s.size_description}", "owned": not s.is_suggestion,
                        "selected": s.id == self.stock_id})
        out.sort(key=lambda d: (not d["owned"],))
        return out

    @Slot(result="QVariantList")
    def ownedStockSuggestions(self) -> list:
        """OwnedStockSuggestions: the best three owned blanks that fit the part."""
        out = []
        for i, c in enumerate(self.guided_stock_choices(self.inventory)[:3]):
            s = c.stock
            n = c.matching_fixtures
            out.append({"id": s.id, "title": f"{s.material.name if s.material is not None else 'Stock'} · {s.size_description}",
                        "detail": f"{n} workholding option matches this stock" if n > 0 else "Fits the part · choose workholding next",
                        "recommended": i == 0, "selected": s.id == self.stock_id})
        return out

    @Slot(str)
    def chooseStock(self, id: str) -> None:
        if not id:
            self.stock_id = None
            return
        inv = self.inventory
        item = next((s for s in inv.stock if s.id == id), None)
        if item is not None:
            self.use_guided_stock(item, inv)
        self.touch()

    @Slot(result="QVariantMap")
    def stockInfo(self) -> dict:
        stock = self.stock
        if stock is None:
            return {}
        raw = self.setup.raw_stock_size(stock)
        options = self.stock_options()
        cur = next((o for o in options if list(o.axes) == list(self.setup.stock_axes or [])), None)
        owned = self.stock_lookup(stock.id)
        fits_text = "The part fits inside the stock" if cur is not None and cur.workable else (f"Doesn't fit: {cur.reason}" if cur is not None and cur.reason else "Doesn't fit")
        return {"size": f"{Length.mm(raw[0])} × {Length.mm(raw[1])} × {Length.mm(raw[2])} mm as bought",
                "fits": bool(cur is not None and cur.workable), "fitsText": fits_text, "owned": owned is not None and owned.quantity > 0,
                "orientation": cur.summary if cur is not None else "How it sits",
                "orientations": [{"axes": list(o.axes), "summary": o.summary, "workable": o.workable,
                                  "selected": list(o.axes) == list(self.setup.stock_axes or [])} for o in options],
                "standardFits": [{"id": s.id, "title": f"{s.material.name if s.material else 'Stock'} · {s.size_description}"}
                                 for s in self.standard_stock_that_fits()] if (cur is None or not cur.workable) else [],
                "canPlan": self.stage_status("stock").state == "done"}

    @Slot("QVariantList")
    def useStockAxesSlot(self, axes) -> None:
        self.use_stock_axes([int(a) for a in axes])
        self.touch()

    @Slot(str)
    def useStandardStock(self, id: str) -> None:
        item = next((s for s in self.inventory.stock if s.id == id), None)
        if item is not None:
            self.use_stock(item)

    @Slot()
    def markStockOwned(self) -> None:
        if self.stock is not None:
            self.inventory_model.markStockOwned([self.stock.id])
        self.touch()

    @Slot(result="QVariantMap")
    def placement(self) -> dict:
        s = self.setup
        return {"x": s.part_offset_x, "y": s.part_offset_y, "z": s.top_allowance,
                "issues": [{"severity": i.severity.name.lower(), "message": i.message} for i in self.setup_issues]}

    @Slot(str, float)
    def setPlacement(self, field: str, value: float) -> None:
        s = self.setup.copy()
        setattr(s, {"x": "part_offset_x", "y": "part_offset_y", "z": "top_allowance"}[field], value)
        self.setup = self.placement_limited(s)

    @Slot(str)
    def snapPart(self, snap: str) -> None:
        self.snap_part(snap)

    @Slot(result="QVariantMap")
    def orientation(self) -> dict:
        from ...core.plan.setup import FACINGS
        return {"facing": self.setup.facing.value, "spin": self.setup.spin,
                "facings": [{"value": f.value, "title": "Part " + f.title} for f in FACINGS],
                "containment": [{"severity": i.severity.name.lower(), "message": i.message} for i in self.stock_containment_issues]}

    @Slot(str)
    def setFacing(self, value: str) -> None:
        from ...core.plan.setup import Facing
        self.change_setup(lambda s: setattr(s, "facing", Facing(value)))

    @Slot(int)
    def setSpin(self, quarter: int) -> None:
        self.change_setup(lambda s: setattr(s, "spin", int(quarter) % 4))

    # ---------------------------------------------------------------- sides and holding

    @Slot(result="QVariantMap")
    def sides(self) -> dict:
        a = self.analysis
        split = self.split_z
        excess = self.one_sided_through_excess
        t = self.tabs
        c = self.setup.custom_fixture
        return {"twoSided": self.twoSided, "backHasShape": bool(a is not None and self.back_has_shape(a)), "split": Length.mm(split) if split is not None else "",
                "holdWithTabs": self.holdWithTabs, "throughExcess": excess if excess is not None else -1, "tabsCount": t.count,
                "tabsWidth": t.width, "tabsHeight": t.height, "web": self.webThickness, "library": self.setup.plan_from_fixture_library,
                "custom": {"name": c.name, "height": c.height, "faceProtrusion": c.face_protrusion, "notes": c.notes},
                "cutsThrough": self.cuts_through_with_tabs}

    @Slot(bool)
    def setTwoSided(self, on: bool) -> None:
        self.twoSided = on
        self.two_sided_chosen = True

    @Slot(bool)
    def setHoldWithTabs(self, on: bool) -> None:
        self.holdWithTabs = on

    @Slot(str, float)
    def setTabs(self, field: str, value: float) -> None:
        import copy
        t = copy.deepcopy(self.tabs)
        if field == "count":
            t.count = int(min(max(round(value), 2), 8))
        elif field == "width":
            t.width = max(value, 0.1)
        else:
            t.height = max(value, 0.1)
        self.tabs = t

    @Slot()
    def suggestTabs(self) -> None:
        from ...core.plan.holding_tabs import HoldingTabs
        if self.part is None:
            return
        lo, hi = self.setup.rotated_part_bounds(self.part.bounds_min, self.part.bounds_max)
        self.tabs = HoldingTabs.suggested(self.stock.material if self.stock is not None else None, np.asarray(hi) - np.asarray(lo))

    @Slot(float)
    def setWebThickness(self, v: float) -> None:
        self.webThickness = max(v, 0.05)

    @Slot(str, "QVariant")
    def setCustomFixture(self, field: str, value) -> None:
        def change(s):
            c = s.custom_fixture
            if field == "name":
                c.name = str(value)
            elif field == "notes":
                c.notes = str(value)
            elif field == "height":
                c.height = max(float(value), 0)
            elif field == "faceProtrusion":
                c.face_protrusion = float(value)
        self.change_setup(change)

    # ---------------------------------------------------------------- machinability

    @Slot(result="QVariantMap")
    def machinability(self) -> dict:
        findings = self.dfm_findings(self.inventory)
        self.sync_finding_selection(findings)
        if findings is None:
            return {"ready": False, "failed": self.analysis_failed, "exact": self.part is not None and self.part.exact, "findings": []}
        out = []
        for f in sorted(findings, key=lambda f: int(f.category)):
            r, g, b = highlight_color(f.category)[:3]
            out.append({"id": f.id, "category": CATEGORY_NAMES[f.category], "title": f.title, "summary": f.summary, "details": list(f.details),
                        "color": f"#{int(r * 255):02x}{int(g * 255):02x}{int(b * 255):02x}", "symbol": f.category.symbol,
                        "stickout": [r.title_in(self.inventory, self.stock_id) for r in f.remedies if r.kind == "setStickout"],
                        "measure": f.measure or "", "fix": f.fix or "",
                        "selected": f.id == self.selected_finding_id, "sides": list(f.sides),
                        "remedies": [{"index": k, "title": r.title_in(self.inventory, self.stock_id)}
                                     for k, r in enumerate(f.remedies) if r.kind != "setStickout" and r not in f.remedies[:k]]})
        return {"ready": True, "failed": False, "exact": True, "findings": out,
                "problems": sum(1 for f in findings if f.category != Category.OK)}

    @Slot(result="QVariantMap")
    def findingsLegend(self) -> dict:
        """What the colours on the part mean, with counts (FindingsLegend)."""
        if self.stage != "planning" or self.fixture_placement is not None or self.shows_machining_results or self.part is None:
            return {"shown": False}
        findings = self.dfm_findings(self.inventory)
        if findings is None:
            return {"shown": False}
        from .analysis import highlight_color
        problems = [f for f in findings if f.category != Category.OK]
        counts = []
        for c in Category:
            n = sum(1 for f in problems if f.category == c)
            if c != Category.OK and n:
                r, g, b = highlight_color(c)[:3]
                counts.append({"text": f"{n} {c.title.lower()}", "color": f"#{int(r * 255):02x}{int(g * 255):02x}{int(b * 255):02x}"})
        return {"shown": True, "problems": len(problems), "counts": counts, "overlay": self.show_findings_overlay}

    @Slot()
    def retryAnalysisSlot(self) -> None:
        self.schedule_analysis()

    @Slot(str)
    def selectFinding(self, id: str) -> None:
        f = next((f for f in (self.dfm_findings(self.inventory) or []) if f.id == id), None) if id else None
        if f is not None and self.selected_finding_id == id:
            f = None  # clicking the selected one again deselects it
        self.select_finding(f)

    @Slot(str, int)
    def applyRemedy(self, finding_id: str, index: int) -> None:
        f = next((f for f in (self.dfm_findings(self.inventory) or []) if f.id == finding_id), None)
        if f is None or not 0 <= index < len(f.remedies):
            return
        self.apply_dfm_remedy(f.remedies[index], self.inventory_model)
        self.touch()

    # ---------------------------------------------------------------- plan

    @Slot(result="QVariantMap")
    def plan(self) -> dict:
        inv = self.inventory
        blocker = self.library_planning_blocker(inv)
        options = []
        for c in self.plan_options:
            options.append({"id": c.id, "name": c.name, "minutes": duration_text(c.minutes * 60), "risk": float(c.risk), "finish": float(c.finish),
                            "recommended": c.name == self.recommended_plan, "chosen": c.name == self.chosen_plan,
                            "tools": [t.name for t in c.tools], "toBuy": [t.name for t in c.needs_tools], "reasons": list(c.reasons),
                            "remedies": [{"index": k, "title": r.title} for k, r in enumerate(c.remedies)]})
        cov = self.plan_coverage
        setups = []
        if cov is not None:
            for s in cov.setups:
                setups.append({"side": s.side, "number": s.number, "title": f"Setup {s.number}", "faces": len(s.faces),
                               "words": SetupSide.words(SetupSide.index(s.side)) if SetupSide.index(s.side) is not None else s.side})
        return {"blocker": blocker or "", "finding": self.isFindingPlans, "planning": self.isPlanningJob, "options": options,
                "chosen": self.chosen_plan or "", "recommended": self.recommended_plan or "", "notes": list(self.plan_notes),
                "coverageGap": self.coverage_gap_note or "", "setups": setups,
                "toBuy": [{"title": w.title, "detail": w.detail} for w in self.job_workholding_to_buy],
                "toolsToBuy": [t.name for t in self.job_tools_to_buy], "hasPrograms": bool(self.programs)}

    @Slot(result="QVariantMap")
    def planInspector(self) -> dict:
        """JobPlanInspector: the job, what stops building, the alternatives, the setups."""
        from ...core.plan.dfm import side_words
        from ...core.plan.operation import OperationPlanner
        from ...core.plan.plan_coverage import PlanCoverage
        inv = self.inventory
        stock = self.stock
        # The workholding's name (workholdingName).
        if self.automatic_workholding:
            names = [f.name for f in self.automatic_fixtures(inv)[0]]
            holding = "Automatic: " + ", ".join(names) if names else "None fits; choose in Setups"
        elif self.setup.plan_from_fixture_library or self.setup.holding is None:
            sel = self.setup.selected_fixture_ids or []
            names = [f.name for f in (self.setup.fixture_assemblies or []) if f.id in sel]
            holding = ", ".join(names) if names else "Choose in Setups"
        else:
            holding = self.setup.custom_fixture.name if self.setup.holding == Workholding.CUSTOM else "Fixture library"
        blocker = self.library_planning_blocker(inv) or (self.generation_blocker() if self.operations else None)
        build_blocker = self.library_planning_blocker(inv)

        def risk_word(r):
            return "comfortable" if r < 0.2 else "some risk" if r < 0.45 else "risky"
        options = []
        for c in self.plan_options:
            parts = c.name.split(", ")
            options.append({"id": c.id, "name": c.name, "head": parts[0], "rest": ", ".join(parts[1:]),
                            "recommended": c.name == self.recommended_plan, "chosen": c.name == self.chosen_plan,
                            "time": "≈ " + duration_text(c.minutes * 60), "finish": "to size" if c.finish < 3 else f"~{round(c.finish)} µm cusps",
                            "risk": risk_word(c.risk), "riskLevel": 0 if c.risk < 0.2 else 1 if c.risk < 0.45 else 2,
                            "ops": " → ".join(getattr(o.kind, "title", str(o.kind)) for o in c.operations),
                            "needs": [f"Needs the {t.name}: not in your inventory" + (f", about {t.unit_cost:.0f}" if getattr(t, 'unit_cost', None) else "")
                                      + ". " + (t.notes or "").replace("Not in your inventory: Coastline suggests it. ", "") for t in c.needs_tools],
                            "remedies": [{"index": k, "title": r.title} for k, r in enumerate(c.remedies)],
                            "reasons": list(c.reasons)})
        cov = self.plan_coverage
        setups, unused, gaps = [], [], []
        if cov is not None:
            for cut in cov.setups:
                side = SetupSide.index(cut.side)
                fixture = self.coverage_workholding(side)[0] if side is not None else None
                buy = self.workholding_to_buy(side, cut.number) if side is not None and fixture is None else None
                held = (f"\nHeld in {fixture.name}." if fixture is not None else
                        f"\nNo fixture you own holds it this way. To buy: {buy.title[:1].lower() + buy.title[1:]}, on the Shopping List." if buy is not None else "")
                titles = list(cut.titles)
                lst = "The outside only." if not titles else ", ".join(titles[:3]) + (f" and {len(titles) - 3} more" if len(titles) > 3 else "")
                summary = lst + (("\n" + cut.note) if cut.note else "") + held + ("" if cut.toolpaths or fixture is None else "\nNo toolpaths from this side: see the plan's notes.")
                setups.append({"side": cut.side, "number": cut.number, "title": f"Setup {cut.number}: {side_words(cut.side)} toward the spindle",
                               "summary": summary, "toolpaths": bool(cut.toolpaths), "selected": self.selected_finding_id == f"setup{cut.side}",
                               "enabled": bool(cut.faces)})
            for u in cov.unused:
                w = side_words(u.side)
                unused.append({"title": w[:1].upper() + w[1:], "summary": u.why, "fits": bool(u.fits)})
            if self.operations:
                for g in cov.gaps:
                    gaps.append({"finding": g.finding, "title": g.title, "summary": g.text, "notSupported": g.category == Category.NOT_SUPPORTED,
                                 "selected": self.selected_finding_id == g.finding})
        return {"part": self.part.file_name if self.part is not None else "No part",
                "stock": f"{stock.material.name if stock is not None and stock.material is not None else 'Stock'} · {stock.size_description}" if stock is not None else "Choose stock",
                "workholding": holding, "usableTools": len(OperationPlanner.usable_tools(inv, machine=self.machine)),
                "blocker": blocker or "", "blockerSetups": bool(blocker) and ("Setups" in blocker or "workholding" in blocker.lower()),
                "buildBlocker": build_blocker or "", "buildBlockerSetups": bool(build_blocker) and "Setups" in build_blocker,
                "options": options, "chosen": self.chosen_plan or "", "candidates": len(self.plan_candidates),
                "hasCoverage": cov is not None, "setups": setups, "unused": unused, "gaps": gaps,
                "open": cov.open if cov is not None and self.operations else 0,
                "planning": self.isPlanningJob, "generating": self.is_generating, "finding": self.isFindingPlans,
                "hasPrograms": bool(self.programs), "status": self.status,
                "needsReview": bool(self.setup.plan_from_fixture_library and (self.library_workholding_plan is None or not self.library_workholding_plan.reviewed)),
                "error": self.errorMessage or "", "libraryPlan": bool(self.setup.plan_from_fixture_library and self.library_workholding_plan is not None)}

    @Slot(str)
    def selectCoverage(self, side: str) -> None:
        cov = self.plan_coverage
        cut = next((c for c in cov.setups if c.side == side), None) if cov is not None else None
        if cut is not None and self.selected_finding_id == f"setup{side}":
            cut = None
        self.select_coverage(cut)
        self.touch()

    @Slot()
    def proposeJob(self) -> None:
        self._spawn(self.propose_job(self.inventory_model), "propose job")

    @Slot()
    def findPlans(self) -> None:
        self._spawn(self.find_plans(self.inventory), "find plans")

    @Slot(str, bool)
    def usePlan(self, id: str, build: bool) -> None:
        c = next((c for c in self.plan_options if c.id == id), None)
        if c is None:
            return
        if build:
            self._spawn(self.use_plan_and_build(c, self.inventory), "use plan")
        else:
            self.use_plan(c)

    @Slot(str, int)
    def applyPlanRemedy(self, id: str, index: int) -> None:
        c = next((c for c in self.plan_options if c.id == id), None)
        if c is not None and 0 <= index < len(c.remedies):
            self.apply_remedy(c.remedies[index], c)

    @Slot(str)
    def selectCoverage(self, side: str) -> None:
        cov = self.plan_coverage
        cut = next((s for s in cov.setups if s.side == side), None) if cov is not None else None
        self.select_coverage(cut)
        self.touch()

    # ---------------------------------------------------------------- setups (library workholding)

    @Slot(result="QVariantMap")
    def setups(self) -> dict:
        plan = self.library_workholding_plan
        steps = []
        if plan is not None:
            cur = self.current_library_step
            for s in plan.steps:
                steps.append({"id": s.id, "number": s.number, "title": s.title, "side": s.side, "fixture": s.fixture.name,
                              "operations": list(s.operations), "reasons": list(s.reasons), "reviewed": s.reviewed,
                              "instructions": s.instructions, "current": cur is not None and cur.id == s.id,
                              "standIn": self.is_stand_in(s.fixture)})
        inv = self.inventory
        fixtures = []
        for f in inv.fixtures:
            if f.quantity <= 0:
                continue
            fixtures.append({"id": f.id, "name": f.name, "hasModel": f.model_path is not None})
        auto, why = (self.automatic_fixtures(inv) if self.stock is not None else ([], {}))
        return {"library": self.setup.plan_from_fixture_library, "automatic": self.automatic_workholding, "steps": steps,
                "complete": plan is not None and plan.complete, "reviewed": plan is not None and plan.reviewed,
                "issues": list(plan.issues) if plan is not None else [], "orderNote": self.step_order_note or "",
                "fixtures": fixtures, "fitted": [f.name for f in auto],
                "why": [{"name": next((f.name for f in inv.fixtures if f.id == k), k), "why": v} for k, v in why.items()],
                "selected": list(self.setup.selected_fixture_ids or []), "holding": self.setup.holding.value if self.setup.holding else ""}

    @Slot(result="QVariantMap")
    def workholdingChoice(self) -> dict:
        """WorkholdingChoiceSection: library fixtures as rows, or a manual method."""
        from ...core.inventory.items import FixtureKind as FK
        inv = self.inventory
        from_library = self.setup.plan_from_fixture_library or self.setup.holding is None
        accessories = {FK.T_SLOT_NUTS, FK.RISER, FK.SQUARING_STOP, FK.SQUARING_BOSS, FK.SOFT_JAWS}
        automatic = self.automatic_fixtures(inv) if self.automatic_workholding and self.stock is not None else None
        busy = self.isPlanningJob or self.is_generating
        rows = []
        for f in inv.fixtures:
            if f.quantity <= 0 or f.kind in accessories:
                continue
            current = next((a for a in (self.setup.fixture_assemblies or []) if a.id == f.id), f)
            fits = automatic is not None and any(a.id == f.id for a in automatic[0])
            selected = current.id in (self.setup.selected_fixture_ids or []) or fits
            needs_assembly = current.assembly is not None and not current.assembly.is_assembled
            if automatic is not None:
                detail = "Fits this stock" if fits else automatic[1].get(f.id, "Doesn't fit this stock")
            else:
                detail = ("No model in the library" if current.model_path is None else "Needs an assembled model" if needs_assembly
                          else "Selected for this job" if selected else "Preview on stock")
            rows.append({"id": current.id, "name": current.name, "detail": detail, "selected": selected,
                         "enabled": current.model_path is not None and not needs_assembly and self.stock is not None and not busy,
                         "hasModel": current.model_path is not None,
                         "help": "Add this fixture's model in the Fixtures library" if current.model_path is None else "Preview this workholding around the current stock"})
        return {"fromLibrary": from_library, "automatic": automatic is not None, "planFromLibrary": self.setup.plan_from_fixture_library,
                "rows": rows, "method": self.setup.custom_fixture.name if self.setup.holding == Workholding.CUSTOM else "Fixture library"}

    @Slot(str, result=str)
    def fixtureThumbnail(self, id: str) -> str:
        """The key of a fixture's picture for image://thumb; "" while it's drawn, "failed" if it can't be."""
        from ...ui import thumbnails
        f = next((f for f in self.inventory.fixtures if f.id == id), None)
        if f is None or f.model_path is None:
            return "failed"
        key = f"fixture-{abs(hash((f.model_path, repr(f.planning) if hasattr(f, 'planning') else '')))}"
        if thumbnails.has(key):
            return key
        pending = self.__dict__.setdefault("_thumbs_pending", {})
        if key in pending:
            return "failed" if pending[key] == "failed" else ""
        pending[key] = "loading"
        path = self.fixture_model_path(f.model_path)

        def run():
            try:
                mesh = yield Work(lambda: self.connected_engine().import_part(path))
                img = yield Work(lambda: thumbnails.render(mesh.vertices, mesh.indices), "thumbs")
                thumbnails.store(key, img)
                pending.pop(key, None)
            except Exception:  # noqa: BLE001
                pending[key] = "failed"
            self.touch()

        spawn(run(), "fixture thumbnail")
        return ""

    @Slot(result="QVariantMap")
    def jobShopping(self) -> dict:
        """ShoppingListPage's job sections: workholding and tools this job's plan needs."""
        part = self.part.file_name if self.part is not None else "this job"
        tools = []
        for t in self.job_tools_to_buy:
            tools.append({"id": t.id, "name": t.name, "cost": f"≈ {t.unit_cost:.0f}" if t.unit_cost else "",
                          "note": (t.notes or "").replace("Not in your inventory: Coastline suggests it. ", ""),
                          "specs": f"⌀{Length.mm(t.diameter)} mm · {Length.mm(t.flute_length)} mm flutes/reach · {Length.mm(t.shank_diameter)} mm shank · {t.vendor}"})
        total = sum(t.unit_cost or 0 for t in self.job_tools_to_buy)
        return {"part": part, "holding": [{"title": w.title, "detail": w.detail} for w in self.job_workholding_to_buy],
                "tools": tools, "total": int(round(total))}

    @Slot(str)
    def removeRecentProject(self, path: str) -> None:
        import json
        from ..settings import AppSettings
        from .project_document import _recent_list
        AppSettings.set_value("recentProjects", json.dumps([p for p in _recent_list() if p != path]))
        self.touch()

    @Slot(str)
    def revealPath(self, path: str) -> None:
        """Shows a file or folder in Finder (macOS) or Explorer (Windows)."""
        import subprocess
        import sys
        p = str(_url_path(path))
        if sys.platform == "darwin":
            subprocess.Popen(["open", "-R", p])
        elif sys.platform == "win32":
            subprocess.Popen(["explorer", "/select,", p])
        else:
            subprocess.Popen(["xdg-open", str(Path(p).parent)])

    @Slot(str, result="QVariantMap")
    def projectSummary(self, path: str) -> dict:
        """What's in a project file, read without opening it (ProjectSummary)."""
        import json
        from ...core.inventory.items import StockItem
        from ...core import codable as _c
        try:
            p = json.loads(Path(path).read_text())
        except Exception:  # noqa: BLE001
            return {"ok": False}
        try:
            programs = ((p.get("results") or {}).get("programs")) or []
            tools = []
            for t in (g["tool"]["name"] for g in programs):
                if t not in tools:
                    tools.append(t)
            stock = None
            if p.get("stock"):
                st = _c.from_json(StockItem, p["stock"])
                stock = " ".join(x for x in [st.material.name if st.material is not None else None, st.size_description] if x)
            setup = p.get("setup") or {}
            custom = setup.get("holding") == "custom"
            sides = ("Two sides (A and B)" + ("" if custom else ", held by tabs" if p.get("holdWithTabs") else ", full web")) if p.get("twoSided") else "One side"
            secs = sum(float(g.get("seconds", 0)) for g in programs)
            return {"ok": True, "part": Path(p["partPath"]).name if p.get("partPath") else "", "stock": stock or "",
                    "holding": (setup.get("customFixture") or {}).get("name", "Custom") if custom else "Fixture library",
                    "sides": sides, "operations": len(p.get("operations") or []), "programs": len(programs),
                    "machining": duration_text(secs), "tools": "\n".join(tools)}
        except Exception:  # noqa: BLE001
            return {"ok": False}

    @Slot(result="QVariantList")
    def stockContainmentIssues(self) -> list:
        return [{"severity": i.severity.name.lower(), "message": i.message} for i in self.stock_containment_issues] \
            if self.part is not None and self.stock is not None else []

    @Slot(str)
    def reviewLibraryStep(self, id: str) -> None:
        plan = self.library_workholding_plan
        s = next((s for s in plan.steps if s.id == id), None) if plan is not None else None
        if s is not None:
            self.review_library_step(s)
        self.touch()

    @Slot(str)
    def inspectLibraryStep(self, id: str) -> None:
        plan = self.library_workholding_plan
        s = next((s for s in plan.steps if s.id == id), None) if plan is not None else None
        if s is not None:
            self.inspect_library_step(s)
        self.touch()

    @Slot(str, int)
    def moveLibraryStep(self, id: str, delta: int) -> None:
        self.move_library_step(id, delta)
        self.touch()

    @Slot(str)
    def placeFixture(self, id: str) -> None:
        f = next((f for f in self.inventory.fixtures if f.id == id), None)
        if f is not None:
            self._spawn(self.begin_fixture_placement(f), "place fixture")

    @Slot()
    def useAutomaticWorkholding(self) -> None:
        self.use_automatic_workholding()
        self.touch()

    @Slot(str)
    def removeJobFixture(self, id: str) -> None:
        self.remove_job_fixture(id)
        self.touch()

    @Slot(bool)
    def setLibraryPlanning(self, on: bool) -> None:
        if on:
            self.enable_library_planning()
        else:
            def change(s):
                s.plan_from_fixture_library = False
                s.holding = Workholding.CUSTOM
            self.change_setup(change)
        self.touch()

    # ---------------------------------------------------------------- fixture placement

    @Slot(result="QVariantMap")
    def placementInfo(self) -> dict:
        s = self.fixture_placement
        if s is None:
            return {}
        g = self.fixture_placement_geometry
        p = s.fixture.planning
        comps = [{"id": c.id, "name": getattr(c, "name", c.id), "selected": c.id == s.selected_component} for c in (g.components if g is not None else [])]
        controls = []
        m = self.placement_mechanism if self.placing_mechanism else None
        if m is not None and p is not None:
            for c in m.controls:
                try:
                    v = m.value(p, c.id)
                except Exception:  # noqa: BLE001
                    v = 0.0
                controls.append({"id": c.id, "title": c.title, "component": c.component_id, "value": v, "pitch": c.pitch or 0})
        bookends = None
        solver = self.placement_bookend_solver if self.placing_bookends else None
        if solver is not None and p is not None:
            from ...core.plan.fixture_mechanism import BookendSetup
            st = p.assembly_state
            try:
                pressure = solver.value(p, BookendSetup.PRESSURE_EXTENSION)
            except Exception:  # noqa: BLE001
                pressure = 0.0
            bookends = {"pressure": pressure, "fixedLocked": st is not None and BookendSetup.FIXED in st.locked_components,
                        "clampLocked": st is not None and BookendSetup.CLAMP in st.locked_components}
        return {"name": s.fixture.name, "error": s.error or "", "loading": s.loading, "snap": s.snap_enabled, "pickingGrip": s.picking_grip,
                "components": comps, "selected": s.selected_component or "", "bookends": bookends, "controls": controls,
                "mechanism": self.placing_mechanism, "contacts": [{"id": c.id, "x": c.point.x, "y": c.point.y, "z": c.point.z, "radius": c.radius}
                                                                   for c in (p.contacts if p is not None else [])],
                "reviewed": bool(p is not None and p.grip_definition_reviewed), "snaps": [c.label for c in s.snap_locks]}

    @Slot(str, "QVariant")
    def placementAction(self, action: str, value=None) -> None:
        if action == "select":
            self.select_placement_component(str(value) or None)
        elif action == "snap":
            self.set_placement_snapping(bool(value))
        elif action == "snapToStock":
            self.snap_placement_to_stock()
        elif action == "centre":
            self.centre_placement_on_stock()
        elif action == "align":
            self.align_placement_pair()
        elif action == "seat":
            self.seat_placement_bookends()
        elif action == "pickGrip":
            if self.fixture_placement is not None:
                self.fixture_placement.picking_grip = bool(value)
        elif action == "removeContact":
            s = self.fixture_placement
            if s is not None and s.fixture.planning is not None:
                import copy
                p = copy.deepcopy(s.fixture.planning)
                p.contacts = [c for c in p.contacts if c.id != value]
                p.grip_definition_reviewed = False
                self.set_placement_profile(p)
        elif action == "reviewed":
            s = self.fixture_placement
            if s is not None and s.fixture.planning is not None:
                import copy
                p = copy.deepcopy(s.fixture.planning)
                p.grip_definition_reviewed = bool(value)
                self.set_placement_profile(p)
        elif action == "pressure":
            self.set_bookend_pressure(float(value))
        elif action == "lockFixed":
            from ...core.plan.fixture_mechanism import BookendSetup
            self.set_bookend_base_locked(BookendSetup.FIXED, bool(value))
        elif action == "lockClamp":
            from ...core.plan.fixture_mechanism import BookendSetup
            self.set_bookend_base_locked(BookendSetup.CLAMP, bool(value))
        elif action == "save":
            self.finish_fixture_placement(True, self.inventory_model)
        elif action == "cancel":
            self.finish_fixture_placement(False, self.inventory_model)
        self.layout_scene()
        self.touch()

    @Slot(str, float)
    def setPlacementJointSlot(self, joint: str, value: float) -> None:
        self.set_placement_joint(joint, value)
        self.layout_scene()

    @Slot(str, float, float, float)
    def movePlacementBy(self, _id: str, dx: float, dy: float, dz: float) -> None:
        self.move_placement((dx, dy, dz))
        self.layout_scene()

    @Slot(int, int)
    def rotatePlacementBy(self, axis: int, turns: int) -> None:
        self.rotate_placement(axis, turns)
        self.layout_scene()

    # ---------------------------------------------------------------- operations

    def _op_tools(self, op) -> list:
        inv = self.planning_inventory(self.inventory)
        if op.kind == K.THREAD:
            tools = [t for t in inv.tools if t.kind == ToolKind.THREAD_MILL and t.condition.value != "broken" and (t.quantity > 0 or t.is_suggestion)
                     and all(i.severity < Severity.ERROR for i in InventoryChecks.check_tool(t, self.inventory, self.machine))]
            return sorted(tools, key=lambda t: (0 if t.quantity > 0 else 1, t.diameter))
        usable = OperationPlanner.usable_tools(inv, machine=self.machine)

        def fits(t) -> bool:
            k = op.kind
            if k == K.DRILL:
                return t.kind in (ToolKind.DRILL, ToolKind.SPOT_DRILL)
            if k == K.CHAMFER:
                return t.kind in (ToolKind.CHAMFER_MILL, ToolKind.ENGRAVER)
            if k == K.ENGRAVE:
                return t.kind in (ToolKind.ENGRAVER, ToolKind.CHAMFER_MILL, ToolKind.FLAT_END_MILL, ToolKind.BALL_END_MILL) and t.diameter <= 3.2
            if k.is_3d:
                return t.kind in (ToolKind.BALL_END_MILL, ToolKind.BULL_NOSE_END_MILL, ToolKind.FLAT_END_MILL)
            return t.kind in (ToolKind.FLAT_END_MILL, ToolKind.BULL_NOSE_END_MILL)

        return [t for t in usable if fits(t)]

    @Slot(result="QVariantList")
    def operationRows(self) -> list:
        out = []
        stock = self.stock
        material = stock.material if stock is not None else None
        owned = {t.id: t.quantity > 0 for t in self.inventory.tools}
        for op in self.operations:
            tool = self.job_tool(op.tool_id) if op.tool_id is not None else None
            choices = self._op_tools(op)
            if tool is not None and not any(t.id == tool.id for t in choices):
                choices.append(tool)
            state = self.gen_state(op.id)
            data = {}
            if tool is not None and material is not None:
                try:
                    d = op.cutting_data(tool, material, self.machine)
                    data = {"rpm": int(d.rpm), "feed": int(d.feed), "plunge": int(d.plunge_feed), "chipLoad": f"{d.chip_load:.3f}",
                            "stepdown": Length.mm(d.stepdown) if d.stepdown > 0 else "", "stepover": Length.mm(d.stepover) if d.stepover > 0 else "",
                            "power": int(round(d.power)), "notes": list(d.notes)}
                except Exception:  # noqa: BLE001
                    data = {}
            path = self.toolpaths.get(op.id)
            out.append({"id": op.id, "kind": op.kind.value, "title": op.title, "explanation": getattr(op, "explanation", ""), "enabled": op.enabled,
                        "symbol": OP_SYMBOLS.get(op.kind.value, "circle"),
                        "toolId": op.tool_id or "", "toolName": tool.name if tool is not None else "",
                        "tools": [{"id": t.id, "name": t.name if owned.get(t.id, False) else f"{t.name} (not owned)"} for t in choices],
                        "state": state[0] if isinstance(state, tuple) else (state or ""), "failed": state[1] if isinstance(state, tuple) else "",
                        "is3d": op.kind.is_3d, "leaveRadial": op.leave_radial, "leaveAxial": op.leave_axial,
                        "stepdown": op.stepdown_override if op.stepdown_override is not None else -1, "faceDepth": op.face_depth,
                        "springPass": bool(op.spring_pass), "cusp": op.scallop * 1000, "angle": op.angle, "steepAngle": op.steep_angle,
                        "data": data, "warnings": list(path.warnings) if path is not None else [], "notes": list(path.notes) if path is not None else [],
                        "engraving": {"text": op.engraving.text, "side": op.engraving.side or 0, "probe": op.engraving.probe_surface is True,
                                      "depth": op.engraving.depth if op.engraving.depth is not None else 0.15} if op.engraving is not None else None,
                        "thread": op.thread.spec if op.thread is not None else ""})
        return out

    @Slot(result="QVariantList")
    def addableOperations(self) -> list:
        return [{"kind": k.value, "title": k.title} for k in ADDABLE]

    @Slot(str, str, "QVariant")
    def setOperationField(self, id: str, key: str, value) -> None:
        ops = list(self.operations)
        k = next((i for i, o in enumerate(ops) if o.id == id), None)
        if k is None:
            return
        op = ops[k]
        if key == "cusp":
            op = dataclasses.replace(op, scallop=max(float(value), 0.5) / 1000)
        elif key == "stepdown":
            v = float(value) if value not in (None, "") else -1
            op = dataclasses.replace(op, stepdown_override=v if v > 0 else None)
        elif key == "toolId":
            op = dataclasses.replace(op, tool_id=str(value) or None)
        elif key.startswith("engraving."):
            import copy
            from ...core.plan.engraving import Engraving
            e = copy.deepcopy(op.engraving) if op.engraving is not None else Engraving(text="")
            field = key.split(".", 1)[1]
            if field == "probe":
                e.probe_surface = True if value else None
            elif field == "text":
                e.text = str(value)
            elif field == "side":
                e.side = int(value)
            elif field == "depth":
                e.depth = float(value)
            op = dataclasses.replace(op, engraving=e)
        elif key == "thread":
            from ...core.plan.threads import ThreadMilling
            op = dataclasses.replace(op, thread=ThreadMilling(spec=str(value), depth=op.thread.depth if op.thread is not None else None))
        else:
            name = _snake(key)
            cur = getattr(op, name)
            if isinstance(cur, bool):
                value = bool(value)
            elif isinstance(cur, float):
                value = float(value)
            op = dataclasses.replace(op, **{name: value})
        ops[k] = op
        self.operations = ops

    @Slot(str)
    def addOperation(self, kind: str) -> None:
        k = K(kind)
        op = Operation(k)
        if k == K.THREAD:
            self.prepare_thread(op, self.planning_inventory(self.inventory))
        elif k == K.ENGRAVE:
            from ...core.plan.engraving import Engraving
            op.engraving = Engraving(text="Coastline")
        else:
            tools = self._op_tools(op)
            op.tool_id = tools[0].id if tools else None
        self.just_added_operation = op.id
        self.operations = list(self.operations) + [op]

    @Slot(str)
    def removeOperation(self, id: str) -> None:
        self.operations = [o for o in self.operations if o.id != id]

    @Slot(str, int)
    def moveOperation(self, id: str, delta: int) -> None:
        ops = list(self.operations)
        k = next((i for i, o in enumerate(ops) if o.id == id), None)
        if k is None or not 0 <= k + delta < len(ops):
            return
        ops[k], ops[k + delta] = ops[k + delta], ops[k]
        self.operations = ops

    @Slot()
    def suggestOperations(self) -> None:
        self._spawn(self.suggest_operations(self.planning_inventory(self.inventory)), "suggest operations")

    # ---------------------------------------------------------------- generating

    @property
    def tuning_changed_since_generating(self) -> bool:
        return bool(self.programs) and self.tuning != self.generated_tuning

    @Slot(result="QVariantMap")
    def generation(self) -> dict:
        failed = self.failed_operation_count
        title = (("Retry the Failed Operation" if failed == 1 else f"Retry the {failed} Failed Operations") if failed > 0
                 else "Apply & Regenerate" if self.tuning_changed_since_generating else "Generate Toolpaths")
        ms = [self.plan_estimate[o.id] for o in self.operations if o.enabled and o.id in self.plan_estimate]
        planned = sum(ms) if ms else None
        generated = sum(p.seconds for p in self.programs) / 60
        now = planned if not self.programs else generated
        blocker = self.generation_blocker()
        delta = ""
        if self.programs and now is not None and abs(now - generated) >= 1:
            delta = f"({'−' if now < generated else '+'}{duration_text(abs(now - generated) * 60)})"
        return {"delta": delta, "faster": bool(now is not None and now < generated), "hasPrograms": bool(self.programs),
                "chosen": self.chosen_plan or "Custom operations", "toolsToBuy": [t.name for t in self.job_tools_to_buy],
                "ready": self.part is not None and self.stock is not None,
                "generating": self.is_generating, "progress": _f(self.generation_progress), "title": title, "blocker": blocker or "",
                "expected": duration_text(now * 60) if now is not None else "", "status": self.status,
                "tuning": {"cusp": self.tuning.cusp * 1000, "pace": self.tuning.pace, "hiddenSide": self.tuning.hidden_side if self.tuning.hidden_side is not None else -1}}

    @Slot()
    def generate(self) -> None:
        if self.part is None or self.stock is None or self.is_generating:
            return
        blocker = self.generation_blocker()
        if blocker is not None:
            self.status = blocker
            self.errorMessage = blocker
            return
        if self.tuning_changed_since_generating:
            self.operations = self.tuning.apply(self.operations)
        self._spawn(self.generate_toolpaths(self.inventory), "generate")

    @Slot()
    def cancelGeneration(self) -> None:
        self.cancel_generation_now()

    @Slot(str, float)
    def setTuning(self, field: str, value: float) -> None:
        import copy
        t = copy.deepcopy(self.tuning)
        if field == "cusp":
            t.cusp = max(value, 0.5) / 1000
        elif field == "pace":
            t.pace = min(max(value, 0.5), 1.5)
        elif field == "hiddenSide":
            t.hidden_side = int(value) if value >= 0 else None
        self.tuning = t
        self.touch()

    # ---------------------------------------------------------------- results

    @Slot(result="QVariantMap")
    def results(self) -> dict:
        programs = []
        for p in self.programs:
            side = (SetupSide.words(p.side).capitalize() + " · ") if p.side >= 2 else (("A · " if p.side == 0 else "B · ") if self.twoSided else "")
            stick = ""
            if p.min_stickout is not None:
                spare = p.tool.stickout - p.min_stickout
                if spare >= 0:
                    stick = (f"Stick-out {Length.mm(p.tool.stickout)} mm; {Length.mm(math.ceil(max(p.min_stickout, p.tool.flute_length)))} mm is enough here. Shorter is stiffer: better finish, less chatter."
                             if spare > 4 else f"Collet nut clears the work by {Length.mm(spare + 1)} mm at the deepest point.")
            programs.append({"label": f"{side}{p.index + 1} · {p.tool.name.split(' · ')[0]}", "notes": len(p.report.issues) + len(p.warnings),
                             "opsLine": f"{', '.join(o.title for o in p.operations)} · {int(p.rpm)} RPM · {p.report.line_count} lines", "stickout": stick,
                             "index": p.index, "fileName": p.file_name, "title": p.ops_title, "tool": p.tool.name, "side": p.side,
                             "minutes": duration_text(p.seconds), "passed": p.report.passed,
                             "issues": [{"severity": i.severity.name.lower(), "message": i.message} for i in p.report.issues],
                             "warnings": list(p.warnings), "lines": p.report.line_count})
        total = sum(p.seconds for p in self.programs)
        backing = ""
        if self.twoSided and self.part is not None and self.stock is not None:
            b = self.setup_for(1)
            lo, hi = self.setup.rotated_part_bounds(self.part.bounds_min, self.part.bounds_max)
            ideal = (hi[2] - lo[2]) + 2 * self.setup.top_allowance + 1
            if b.top_allowance > 3:
                secs = sum(p.seconds for p in self.programs if p.side == 1 and any(o.kind.value == "facing" for o in p.operations))
                backing = (f"Side B first faces off {Length.mm(b.top_allowance - 0.5)} mm of backing (about {duration_text(secs)}). Stock about "
                           f"{Length.mm(math.ceil(ideal))} mm thick instead of {Length.mm(self.setup.stock_size(self.stock)[2])} mm would save most of that.")
        return {"toolChanges": max(len(self.programs) - 1, 0), "backing": backing,
                "failedCount": sum(1 for p in self.programs if not p.report.passed),
                "programs": programs, "total": duration_text(total) if self.programs else "", "travelIssue": self.travel_issue or "",
                "passed": all(p.report.passed for p in self.programs), "unowned": [t.name for t in self.unowned_job_tools],
                "waitsForWorkholding": self.plan_waits_for_workholding, "reviewed": (self.library_workholding_plan.reviewed
                                                                                     if self.library_workholding_plan is not None else True),
                "jobRunning": self.jobs is not None and self.jobs.run is not None}

    @Slot(str)
    def exportPrograms(self, url: str) -> None:
        try:
            paths = self.export_programs(_url_path(url))
            self.status = f"Exported {len(paths)} program{'s' if len(paths) != 1 else ''} to {_url_path(url).name}"
        except Exception as e:  # noqa: BLE001
            self.errorMessage = str(e)

    @Slot(result="QVariantList")
    def codeFiles(self) -> list:
        """The guided job's files for "Export Selected Code…"."""
        def run():
            from ...core.export.generated_job import code_files
            try:
                inp = yield from self.checked_guided_input(self.inventory.measuring)
                self._code_files = code_files(inp, self.machine)
            finally:
                self._code_files_pending = False
            self.touch()
        if getattr(self, "_code_files", None) is None:
            if not getattr(self, "_code_files_pending", False):
                self._code_files_pending = True
                self._spawn(run(), "code files")
            return []
        return [{"id": f.id, "title": f.title, "kind": f.kind.value, "detail": getattr(f, "detail", "")} for f in self._code_files]

    @Slot("QVariantList", str)
    def exportSelectedCode(self, ids, url: str) -> None:
        from ...core.export.generated_job import export
        files = getattr(self, "_code_files", None) or []
        try:
            written = export(files, {str(i) for i in ids}, _url_path(url))
            self.status = f"Exported {len(written)} file{'s' if len(written) != 1 else ''}"
        except Exception as e:  # noqa: BLE001
            self.errorMessage = str(e)
        self._code_files = None

    @Slot()
    def runOnMachine(self) -> None:
        self._spawn(self.prepare_generated_run(self.inventory.measuring), "run on machine")

    @Slot(result=str)
    def takeProjectsPick(self) -> str:
        """"job:<folder>" or "project:<path>" for the Projects page to select, once."""
        pick, self.projects_pick = self.projects_pick or "", None
        return pick

    @Slot()
    def openGuidedMode(self) -> None:
        self.open_guided_mode()

    # ---------------------------------------------------------------- playback and the job strip

    @Slot(result="QVariantMap")
    def playback(self) -> dict:
        tl = self.timeline
        span = self.chapter_span
        cur = self.current_step
        ch = self.open_chapter
        steps = self.job_steps
        chapters, seen = [], []
        for st in steps:
            if not seen or seen[-1] != st.chapter:
                seen.append(st.chapter)
        for c in seen:
            group = [s for s in steps if s.chapter == c]
            chapters.append({"first": group[0].id, "symbol": group[0].symbol, "count": len(group),
                             "id": c.id, "title": c.title, "side": c.side, "number": len(chapters) + 1, "open": ch is not None and c == ch,
                             "ready": self.chapter_ready(group), "progress": _f(self.chapter_progress(group)),
                             "minutes": duration_text(sum(s.duration for s in group) * 60)})
        step_rows = []
        for s in steps:
            if ch is not None and s.chapter != ch:
                continue
            sp = self.step_span(s)
            side_word = (SetupSide.words(s.side).capitalize() + " · ") if s.side >= 2 else (("A · " if s.side == 0 else "B · ") if self.twoSided else "")
            sub = (f"{side_word}≈ {duration_text(s.minutes * 60)}" if s.minutes is not None else
                   "being generated…" if s.kind == "program" else "Side B" if s.kind == "flip" else
                   ("Side A" if self.twoSided else "Setup") if s.kind == "setup" else "By hand")
            active = self.is_active(s)
            prog = None
            if sp is not None and active and s.kind == "program":
                prog = min(max((self.playhead - sp[0]) / max(sp[1] - sp[0], 1e-6), 0), 1)
            step_rows.append({"symbol": s.symbol, "subtitle": sub, "duration": float(s.duration), "byHand": s.kind != "program",
                              "progress": -1 if prog is None else float(prog),
                              "id": s.id, "kind": s.kind, "number": s.number, "title": s.title, "detail": s.detail, "side": s.side,
                              "active": self.is_active(s), "minutes": duration_text(s.duration * 60),
                              "start": sp[0] if sp else -1, "end": sp[1] if sp else -1})
        markers = [{"t": t, "op": o, "title": self.timeline_titles[o] if 0 <= o < len(self.timeline_titles) else ""} for t, o in self.operation_starts]
        def clock(x):
            t = int(round(x))
            return f"{t // 3600}:{t // 60 % 60:02d}:{t % 60:02d}" if t >= 3600 else f"{t // 60}:{t % 60:02d}"
        return {"clock": f"{clock(self.playhead)} / {clock(tl.duration)}", "openTitle": ch.title if ch is not None else "Timeline",
                "pathsVisible": self.pathsVisible, "workArea": self.showWorkArea, "inspecting": self.inspecting, "empty": not tl.entries,
                "generating": self.is_generating, "toolChange": self.tool_change_stop is not None,
                "readyCount": sum(1 for c in chapters if c["ready"]),
                "duration": tl.duration, "playhead": self.playhead, "playing": self.is_playing, "speed": self.play_speed,
                "spanStart": span[0] if span else 0.0, "spanEnd": span[1] if span else tl.duration, "chapters": chapters, "steps": step_rows,
                "current": cur.id if cur is not None else "", "colorMode": self.color_mode, "simulate": self.simulate,
                "markers": markers, "viewSide": self.viewSide, "twoSided": self.twoSided, "time": duration_text(self.playhead) if self.playhead >= 60 else f"{self.playhead:.0f} s",
                "total": duration_text(tl.duration) if tl.duration > 0 else ""}

    @Slot()
    def togglePlay(self) -> None:
        self.toggle_play()
        self.touch()

    @Slot(float)
    def seekTo(self, t: float) -> None:
        self.seek(t)

    @Slot(int)
    def stepBy(self, d: int) -> None:
        self.step(d)

    @Slot(int)
    def jumpOperation(self, d: int) -> None:
        self.jump_operation(d)

    @Slot(float)
    def setPlaySpeed(self, v: float) -> None:
        self.play_speed = v
        self.touch()

    @Slot(str)
    def setColorMode(self, mode: str) -> None:
        self.color_mode = mode

    @Slot(bool)
    def setSimulate(self, on: bool) -> None:
        self.simulate = on

    @Slot(str)
    def goToStep(self, id: str) -> None:
        s = next((s for s in self.job_steps if s.id == id), None)
        if s is not None:
            self.visit(s)

    @Slot(str)
    def openChapter(self, id: str) -> None:
        s = next((s for s in self.job_steps if s.chapter.id == id), None)
        if s is not None:
            self.visit(s)

    @Slot(int)
    def showSide(self, side: int) -> None:
        self.show_side_number(side)

    @Slot(result="QVariantMap")
    def stepCard(self) -> dict:
        s = self.current_step
        if s is None:
            return {}
        nxt, prev = self.step_after(s, 1), self.step_after(s, -1)
        return {"symbol": s.symbol, "chapterNumber": self.chapter_number(s.chapter),
                "id": s.id, "number": s.number, "count": len(self.job_steps), "title": s.title, "detail": s.detail, "kind": s.kind,
                "chapter": s.chapter.title, "instructions": self.instructions(s), "next": nxt.id if nxt else "", "prev": prev.id if prev else ""}

    @Slot(result="QVariantMap")
    def toolChangeCard(self) -> dict:
        s = self.tool_change_stop
        if s is None:
            return {}
        return {"phase": s.phase, "from": s.from_tool.name if s.from_tool is not None else "", "to": s.to.name,
                "stickout": Length.mm(s.to.stickout), "note": s.note or ""}

    @Slot()
    def confirmToolChange(self) -> None:
        self.confirm_tool_change()

    @Slot()
    def cancelToolChange(self) -> None:
        self.cancel_tool_change()

    # ---------------------------------------------------------------- jog the modelled machine

    def jog_to(self, q) -> None:
        self.pause()
        e = self.machine.machine_envelope
        c = np.array([min(max(q[0], e.x.lower), e.x.upper), min(max(q[1], e.y.lower), e.y.upper), min(max(q[2], e.z.lower), e.z.upper)])
        self.current_tool = self.jog_tool
        if self.jog_tool is not None:
            self.ensure_tool_mesh(self.jog_tool)
        else:
            self.scene.remove("tool")
            self.scene.remove("tool.shank")
        self.set_machine_position(c)
        self.touch()

    @Slot(result="QVariantMap")
    def jogInfo(self) -> dict:
        q = self.machine_position
        mm, stock = self.machine_model, self.stock
        work = None
        stick = self.jog_tool.stickout if self.jog_tool is not None else 0.0
        if mm is not None and stock is not None:
            m = mm.model_pose
            size = self.display_stock_size if self.display_stock_size is not None else self.setup.stock_size(stock)
            o, t = self.work_origin(size), self.tip_at_model_pose(stick)
            work = (q[0] - m.x + t[0] - o[0], q[1] - m.y - o[1] + t[1], q[2] - m.z - o[2] + t[2])
        places = [("Home", (-0.5, -0.5, -0.5)), ("Tool change", tuple(self.machine.tool_change_pose))]
        if stock is not None:
            s = self.display_stock_size if self.display_stock_size is not None else self.setup.stock_size(stock)
            for name, p in (("Work zero", (0, 0, 2)), ("Top left corner", (s[0] / 2, -s[1] / 2, 2)), ("Top right corner", (s[0] / 2, s[1] / 2, 2)),
                            ("Bottom left corner", (-s[0] / 2, -s[1] / 2, 2)), ("Bottom right corner", (-s[0] / 2, s[1] / 2, 2))):
                mq = self.machine_position_for_work(p, stick)
                if mq is not None:
                    places.append((name, tuple(mq)))
        return {"x": float(q[0]), "y": float(q[1]), "z": float(q[2]),
                "work": [float(v) for v in work] if work is not None else [], "tool": self.jog_tool.name if self.jog_tool is not None else "",
                "tools": [{"id": t.id, "name": t.name} for t in self.inventory.tools if t.quantity > 0],
                "places": [{"name": n, "q": [float(v) for v in p]} for n, p in places]}

    @Slot(int, float)
    def jogBy(self, axis: int, d: float) -> None:
        q = np.array(self.machine_position, float)
        q[axis] += d
        self.jog_to(q)

    @Slot("QVariantList")
    def jogToPlace(self, q) -> None:
        self.jog_to([float(v) for v in q])

    @Slot(str)
    def setJogTool(self, id: str) -> None:
        self.jog_tool = next((t for t in self.inventory.tools if t.id == id), None) if id else None
        self.jog_to(self.machine_position)

    # ---------------------------------------------------------------- journal

    def draft_journal_entry(self):
        from ...core.journal import JournalEntry, Measurement, ProgramRun
        part, stock = self.part, self.stock
        if part is None or stock is None or not self.programs:
            return None
        self.stock_snapshot = stock
        runs = []
        for p in self.programs:
            d = 0.0
            for r in self.side_results:
                for k, path in enumerate(r.paths):
                    if k < len(r.operation_program) and r.operation_program[k] == p.index:
                        last = None
                        for m in path.moves:
                            if last is not None and m.role.value != 0:
                                d += math.dist(last, m.position)
                            last = m.position
            runs.append(ProgramRun(title=p.title or ", ".join(o.title for o in p.operations), tool_id=p.tool.id, tool_name=p.tool.name,
                                   minutes=p.seconds / 60, distance=d))
        checks = [Measurement(what=c.what, expected=c.expected, tolerance=c.tolerance) for c in self.checkpoints()]
        e = JournalEntry(part_name=part.file_name, material_id=stock.material_id, stock_description=stock.size_description, programs=runs,
                         measurements=checks)
        e.material_snapshot = stock.material
        e.project_path = str(self.project_path) if self.project_path is not None else None
        e.stock_id = stock.id
        raw, used = self.setup.raw_stock_size(stock), self.setup.stock_size(stock)[1]
        left = max(raw[1], raw[2]) - used - 3
        e.remnant_length = math.floor(left * 2) / 2 if left >= 10 else None
        return e

    @Slot(result=bool)
    def recordJob(self) -> bool:
        """Adds the job as generated to the journal (the Journal page then edits it)."""
        e = self.draft_journal_entry()
        if e is None:
            return False
        self.journal.on_recorded = lambda message: setattr(self, "status", message)
        self.journal.begin_draft(e)
        return True
