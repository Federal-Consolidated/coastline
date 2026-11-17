"""A Coastline job saved as a `.coastline` file (JSON): the part file, the stock, the setup, the
operations and tuning, and the generated programs and toolpaths when they were made. Undo and redo
are snapshots of the same. Port of Model/ProjectDocument.swift and Model/SavedResults.swift.

Toolpath blobs: the Mac app writes them LZFSE-compressed; this app writes them raw (the Mac app
reads raw data too) and reads LZFSE when the `liblzfse` module is installed, otherwise such saved
toolpaths are generated again."""

from __future__ import annotations

import base64
import copy
import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from ...core import codable
from ...core.engine.cam import PlannedOperation
from ...core.inventory.snapshot import JobResourceSnapshot
from ...core.machine.planning_reference import PlanningMachineReference
from ...core.plan.holding_tabs import HoldingTabs, PlacedTab
from ...core.plan.setup import Setup
from ...core.plan.tuning import Tuning
from ...core.post.toolpath import OperationToolpath, moves_from_array, moves_to_array
from ..settings import AppSettings

SCRIPTED = "COASTLINE_SCRIPT" in os.environ
SETUP_FIELD_NAMES = {
    "facing": "the part's orientation", "spin": "the part's orientation", "stockAxes": "the stock's orientation",
    "topAllowance": "the part's height in the stock", "partOffsetX": "the part's placement", "partOffsetY": "the part's placement",
    "partScale": "the part's scale", "flipped": "the flip", "holding": "the holding", "customFixture": "the custom fixture",
}


def _unlzfse(data: bytes) -> bytes | None:
    """LZFSE data decompressed; raw data as it is; None when it can't be read here."""
    if not data[:3] == b"bvx":
        return data
    try:
        import liblzfse  # type: ignore[import-not-found]
        return liblzfse.decompress(data)
    except Exception:  # noqa: BLE001
        return None


def camel_words(s: str) -> str:
    out = ""
    for c in s:
        if c.isupper() and out:
            out += " "
        out += c.lower()
    return out


# ---------------------------------------------------------------- saved results

def _path_to_json(p: OperationToolpath) -> dict:
    raw = moves_to_array(p.moves).astype("<f4").tobytes()
    d = {"operationID": p.operation_id, "moves": base64.b64encode(raw).decode(), "warnings": list(p.warnings), "notes": list(p.notes)}
    if p.min_stickout is not None:
        d["minStickout"] = p.min_stickout
    return d


def _path_from_json(d: dict) -> OperationToolpath:
    raw = _unlzfse(base64.b64decode(d["moves"]))
    if raw is None:
        raise ValueError("compressed toolpaths")
    rows = np.frombuffer(raw[: len(raw) // 32 * 32], "<f4").astype(float).reshape(-1, 8)
    t = OperationToolpath(d["operationID"], moves_from_array(rows), list(d.get("warnings") or []))
    t.notes = list(d.get("notes") or [])
    t.min_stickout = d.get("minStickout")
    return t


def _program_to_json(p) -> dict:
    d = {"index": p.index, "side": p.side, "tool": codable.to_json(p.tool), "operations": codable.to_json(p.operations), "rpm": p.rpm,
         "gcode": p.gcode, "report": codable.to_json(p.report), "seconds": p.seconds, "warnings": list(p.warnings),
         "clearanceHits": [h.to_json() for h in p.clearance_hits]}
    for k, v in (("minStickout", p.min_stickout), ("title", p.title), ("surfaceProbe", p.surface_probe)):
        if v is not None:
            d[k] = v
    if p.workholding_step is not None:
        d["workholdingStep"] = codable.to_json(p.workholding_step)
    return d


def _program_from_json(d: dict):
    from ...core.inventory.items import Tool
    from ...core.plan.operation import Operation
    from ...core.plan.workholding_profile import LibraryWorkholdingStep
    from ...core.safety.fixture_clearance import Hit
    from ...core.safety.gcode_validator import Report
    from .machining import ToolProgram
    return ToolProgram(int(d["index"]), int(d["side"]), codable.from_json(Tool, d["tool"]), codable.from_json(list[Operation], d["operations"]),
                       float(d["rpm"]), d["gcode"], codable.from_json(Report, d["report"]), float(d["seconds"]), list(d.get("warnings") or []),
                       d.get("minStickout"), [Hit.from_json(h) for h in d.get("clearanceHits") or []], d.get("title"), d.get("surfaceProbe"),
                       codable.from_json(LibraryWorkholdingStep, d["workholdingStep"]) if d.get("workholdingStep") else None)


def _side_to_json(r) -> dict:
    flat = np.array([(-1 if v is None else v) for op in r.operation_lines for v in op], "<i4")
    planned = []
    for p in r.planned:
        e = {"operation": codable.to_json(p.operation), "tool": codable.to_json(p.tool), "data": codable.to_json(p.data), "zTop": p.z_top}
        if p.z_min is not None:
            e["zMin"] = p.z_min
        if p.ref_tool is not None:
            e["refTool"] = codable.to_json(p.ref_tool)
        planned.append(e)
    return {"side": r.side, "setup": r.setup.to_json(), "planned": planned, "paths": [_path_to_json(p) for p in r.paths],
            "operationProgram": list(r.operation_program), "operationLines": base64.b64encode(flat.tobytes()).decode(),
            "lineCounts": [len(op) for op in r.operation_lines]}


def _side_from_json(d: dict):
    from ...core.feeds import CuttingData
    from ...core.inventory.items import Tool
    from ...core.plan.operation import Operation
    from .machining import SideResult
    raw = _unlzfse(base64.b64decode(d["operationLines"]))
    if raw is None:
        raise ValueError("compressed line maps")
    flat = np.frombuffer(raw[: len(raw) // 4 * 4], "<i4").tolist()
    lines, k = [], 0
    for n in d.get("lineCounts") or []:
        end = min(k + n, len(flat))
        lines.append([None if v < 0 else v for v in flat[k:end]])
        k = end
    planned = []
    for e in d.get("planned") or []:
        p = PlannedOperation(codable.from_json(Operation, e["operation"]), codable.from_json(Tool, e["tool"]),
                             codable.from_json(CuttingData, e["data"]), e.get("zMin"))
        p.z_top = float(e.get("zTop", 0))
        p.ref_tool = codable.from_json(Tool, e["refTool"]) if e.get("refTool") else None
        planned.append(p)
    return SideResult(int(d["side"]), Setup.from_json(d["setup"]), planned, [_path_from_json(p) for p in d.get("paths") or []],
                      list(d.get("operationProgram") or []), lines)


# ---------------------------------------------------------------- the project file

@dataclass
class ProjectFile:
    setup: Setup
    two_sided: bool
    two_sided_chosen: bool
    hold_with_tabs: bool
    tabs: HoldingTabs
    web_thickness: float
    operations: list
    tuning: Tuning
    version: int = 1
    part_path: str | None = None
    stock_id: str | None = None
    stock: object | None = None
    machine: PlanningMachineReference | None = None
    resources: JobResourceSnapshot | None = None
    results: dict | None = None  # SavedResults as JSON (decoded on restore)

    def key(self) -> str:
        """For comparing snapshots (undo)."""
        d = self.to_json()
        d.pop("results", None)
        return json.dumps(d, sort_keys=True, default=str)

    def to_json(self) -> dict:
        d = {"version": self.version, "setup": self.setup.to_json(), "twoSided": self.two_sided, "twoSidedChosen": self.two_sided_chosen,
             "holdWithTabs": self.hold_with_tabs, "tabs": codable.to_json(self.tabs), "webThickness": self.web_thickness,
             "operations": codable.to_json(self.operations), "tuning": codable.to_json(self.tuning)}
        if self.part_path is not None:
            d["partPath"] = self.part_path
        if self.stock_id is not None:
            d["stockID"] = self.stock_id
        if self.stock is not None:
            d["stock"] = codable.to_json(self.stock)
        if self.machine is not None:
            d["machine"] = self.machine.to_json()
        if self.resources is not None:
            d["resources"] = codable.to_json(self.resources)
        if self.results is not None:
            d["results"] = self.results
        return d

    @staticmethod
    def from_json(d: dict) -> "ProjectFile":
        from ...core.inventory.items import StockItem
        from ...core.plan.operation import Operation
        return ProjectFile(Setup.from_json(d["setup"]), bool(d.get("twoSided", False)), bool(d.get("twoSidedChosen", False)),
                           bool(d.get("holdWithTabs", True)), codable.from_json(HoldingTabs, d.get("tabs") or {}), float(d.get("webThickness", 0.3)),
                           codable.from_json(list[Operation], d.get("operations") or []), codable.from_json(Tuning, d.get("tuning") or {}),
                           int(d.get("version", 1)), d.get("partPath"), d.get("stockID"),
                           codable.from_json(StockItem, d["stock"]) if d.get("stock") else None,
                           PlanningMachineReference.from_json(d["machine"]) if d.get("machine") else None,
                           codable.from_json(JobResourceSnapshot, d["resources"]) if d.get("resources") else None,
                           d.get("results"))


def _recent_list() -> list[str]:
    raw = AppSettings.value("recentProjects", [])
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            raw = [raw]
    return [p for p in (raw or []) if isinstance(p, str)]


class ProjectDocumentMixin:
    @property
    def project_snapshot(self) -> ProjectFile:
        return ProjectFile(copy.deepcopy(self.setup), self.twoSided, self.two_sided_chosen, self.holdWithTabs, copy.deepcopy(self.tabs),
                           self.webThickness, copy.deepcopy(self.operations), copy.deepcopy(self.tuning),
                           part_path=str(self.part.path) if self.part is not None else None, stock_id=self.stock_id,
                           stock=copy.deepcopy(self.stock), machine=self.planning_machine_reference, resources=self.saved_resource_snapshot)

    def apply_project(self, p: ProjectFile):
        """A task step: puts a snapshot back (undo, redo, opening a file). The part is imported
        again only when it's a different file. Returns whether it worked."""
        self.restoring_project = True
        try:
            try:
                yield from self.restore_planning_machine(p.machine or PlanningMachineReference.legacy())
            except Exception as e:  # noqa: BLE001
                from ..tasks import Cancelled
                if isinstance(e, Cancelled):
                    raise
                self.errorMessage = f"Couldn't restore this job's machine: {e}"
                return False
            self.clear_toolpath_results()
            if p.part_path is not None and (self.part is None or p.part_path != str(self.part.path)) and Path(p.part_path).exists():
                yield from self.import_part(Path(p.part_path))
            if p.resources is not None:
                self.job_resources = copy.deepcopy(p.resources)
            else:
                tools = []
                for prog in (p.results or {}).get("programs") or []:
                    try:
                        from ...core.inventory.items import Tool
                        tools.append(codable.from_json(Tool, prog["tool"]))
                    except Exception:  # noqa: BLE001
                        pass
                self.job_resources = JobResourceSnapshot(stock=copy.deepcopy(p.stock), tools=tools)
            s = (p.resources.stock if p.resources is not None else None) or p.stock
            if s is not None:
                self.stock_snapshot = s
            if (p.resources is None or p.resources.stock is None) and p.stock is None and p.stock_id is not None:
                s = self.stock_lookup(p.stock_id)
                if s is not None:
                    self.stock_snapshot = s
            self.stock_id = p.stock_id
            self.setup = copy.deepcopy(p.setup)
            self.twoSided = p.two_sided
            self.two_sided_chosen = p.two_sided_chosen
            self.holdWithTabs = p.hold_with_tabs
            self.tabs = copy.deepcopy(p.tabs)
            self.webThickness = p.web_thickness
            self.operations = copy.deepcopy(p.operations)
            self.tuning = copy.deepcopy(p.tuning)
            if p.results is None:
                yield from self.reload_saved_library_geometry()
            return True
        finally:
            self.restoring_project = False
            self.last_snapshot = self.project_snapshot
            self.touch()

    # ---------------------------------------------------------------- undo

    def note_project_change(self) -> None:
        """Called when the job's properties change: changes within 0.6 s are one step."""
        if self.restoring_project or not hasattr(self, "undo_history"):
            return
        now = time.monotonic()
        snap = self.project_snapshot
        before = self.last_snapshot
        if now - self.last_change_at > 0.6 and before is not None and before.key() != snap.key():
            self.undo_history.append(before)
            if len(self.undo_history) > 100:
                self.undo_history.pop(0)
            self.redo_history = []
        self.last_change_at = now
        self.last_snapshot = snap
        self.project_dirty = True

    @property
    def can_undo(self) -> bool:
        return bool(self.undo_history)

    @property
    def can_redo(self) -> bool:
        return bool(self.redo_history)

    @property
    def undo_name(self) -> str | None:
        return self.describe_change(self.undo_history[-1], self.project_snapshot) if self.undo_history else None

    @property
    def redo_name(self) -> str | None:
        return self.describe_change(self.project_snapshot, self.redo_history[-1]) if self.redo_history else None

    @staticmethod
    def describe_change(a: ProjectFile, b: ProjectFile) -> str:
        """The fields that differ between two snapshots, named for people."""
        names: list[str] = []

        def add(n: str) -> None:
            if n not in names:
                names.append(n)

        ja, jb = a.to_json(), b.to_json()
        if ja.get("machine") != jb.get("machine"):
            add("the machine")
        if ja.get("resources") != jb.get("resources"):
            add("job resources")
        if a.part_path != b.part_path:
            add("the part")
        if a.stock_id != b.stock_id or ja.get("stock") != jb.get("stock"):
            add("the stock")
        if a.two_sided != b.two_sided or a.two_sided_chosen != b.two_sided_chosen:
            add("one or two sides")
        if a.hold_with_tabs != b.hold_with_tabs or ja["tabs"] != jb["tabs"] or a.web_thickness != b.web_thickness:
            add("the holding tabs")
        if ja["tuning"] != jb["tuning"]:
            add("quality ↔ time")
        oa, ob = ja["operations"], jb["operations"]
        if oa != ob:
            ids_a, ids_b = {o["id"] for o in oa}, {o["id"] for o in ob}
            new = next((o for o in b.operations if o.id not in ids_a), None)
            gone = next((o for o in a.operations if o.id not in ids_b), None)
            if len(ob) > len(oa) and new is not None:
                add(f"adding {new.kind.title}")
            elif len(ob) < len(oa) and gone is not None:
                add(f"removing {gone.kind.title}")
            else:
                k = next((i for i in range(min(len(oa), len(ob))) if oa[i] != ob[i]), None)
                if k is not None:
                    add(f"{b.operations[k].kind.title} settings" if oa[k]["id"] == ob[k]["id"] else "the operation order")
                else:
                    add("the operations")
        sa, sb = ja["setup"], jb["setup"]
        if sa != sb:
            for key in sorted(set(sa) | set(sb)):
                if sa.get(key) == sb.get(key):
                    continue
                add(SETUP_FIELD_NAMES.get(key) or camel_words(key))
        if not names:
            return "the last change"
        return f"{names[0]}, {names[1]} and more" if len(names) > 2 else " and ".join(names)

    def undo(self):
        """A task."""
        if not self.undo_history:
            return
        previous = self.undo_history.pop()
        current = self.project_snapshot
        ok = yield from self.apply_project(previous)
        if not ok:
            self.undo_history.append(previous)
            return
        self.redo_history.append(current)
        self.status = "Undone"

    def redo(self):
        """A task."""
        if not self.redo_history:
            return
        nxt = self.redo_history.pop()
        current = self.project_snapshot
        ok = yield from self.apply_project(nxt)
        if not ok:
            self.redo_history.append(nxt)
            return
        self.undo_history.append(current)
        self.status = "Redone"

    # ---------------------------------------------------------------- saved results

    @property
    def saved_results(self) -> dict | None:
        """The generated job as it stands, for saving (None while generating or with nothing made)."""
        if self.is_generating or not self.programs or not self.side_results:
            return None
        d = {"version": 1, "programs": [_program_to_json(p) for p in self.programs], "sides": [_side_to_json(r) for r in self.side_results],
             "placedTabs": codable.to_json(self.placed_tabs), "generatedTuning": codable.to_json(self.generated_tuning),
             "machine": self.planning_machine_reference.to_json(), "resources": codable.to_json(self.saved_resource_snapshot)}
        if self.placed_tab_z is not None:
            d["placedTabZ"] = [self.placed_tab_z.lower, self.placed_tab_z.upper]
        if self.travel_issue is not None:
            d["travelIssue"] = self.travel_issue
        if self.reference_plan is not None:
            d["referencePlan"] = codable.to_json(self.reference_plan)
        if self.library_workholding_plan is not None:
            d["libraryWorkholdingPlan"] = codable.to_json(self.library_workholding_plan)
        return d

    def restore_results(self, r: dict) -> bool:
        """Puts a saved job back: the programs checked as they were, at chapter 1, step 1."""
        from ...core.codable import Range
        from ...core.plan import reference_bores as ReferenceBores
        from ...core.plan.workholding_profile import LibraryWorkholdingPlan
        machine = PlanningMachineReference.from_json(r["machine"]) if r.get("machine") else PlanningMachineReference.legacy()
        if machine != self.planning_machine_reference:
            self.clear_toolpath_results()
            self.status = "Machine changed · Regenerate toolpaths"
            return False
        if r.get("resources") is not None:
            res = codable.from_json(JobResourceSnapshot, r["resources"])
            if codable.to_json(res) != codable.to_json(self.saved_resource_snapshot):
                self.clear_toolpath_results()
                self.status = "Job resources changed · Regenerate toolpaths"
                return False
        try:
            programs = [_program_from_json(p) for p in r.get("programs") or []]
            sides = [_side_from_json(s) for s in r.get("sides") or []]
        except Exception:  # noqa: BLE001 — e.g. LZFSE toolpaths without a decoder
            self.clear_toolpath_results()
            self.status = "The saved toolpaths can't be read here · Regenerate toolpaths"
            return False
        self.reference_plan = codable.from_json(ReferenceBores.Plan, r["referencePlan"]) if r.get("referencePlan") else None
        self.library_workholding_plan = codable.from_json(LibraryWorkholdingPlan, r["libraryWorkholdingPlan"]) if r.get("libraryWorkholdingPlan") else None
        plan = self.library_workholding_plan
        self.selected_library_step = plan.steps[0].id if plan is not None and plan.steps else None
        self.generated_tuning = codable.from_json(Tuning, r.get("generatedTuning") or {})
        self.tuning = copy.deepcopy(self.generated_tuning)
        self.programs = programs
        self.side_results = sides
        self.placed_tabs = codable.from_json(list[PlacedTab], r.get("placedTabs") or [])
        z = r.get("placedTabZ")
        self.placed_tab_z = Range(z[0], z[1]) if isinstance(z, list) and len(z) == 2 and z[0] <= z[1] else None
        self.travel_issue = r.get("travelIssue")
        self.planned_programs = []
        self.planned_operation_count = {s.side: len(s.planned) for s in sides}
        base = next((s for s in sides if s.side == 0), sides[0] if sides else None)
        self.toolpaths = {}
        for p in (base.paths if base is not None else []):
            self.toolpaths.setdefault(p.operation_id, p)
        self.switching_view = True
        self.viewSide = 0
        self.switching_view = False
        self.set_view("iso")
        self.focus_work()
        self.compute_side_a_final()
        self.prepare_tool_change_spot()
        self.show_side(0)
        steps = self.job_steps
        if steps:
            self.go_to_step(steps[0])
        from .machining import duration_text
        self.status = f"Toolpaths from the project · about {duration_text(sum(p.seconds for p in self.programs))} of machining"
        if self.setup.plan_from_fixture_library:
            from ..tasks import spawn
            spawn(self.reload_saved_library_geometry(), "library geometry")
        return True

    # ---------------------------------------------------------------- files

    def save_project(self, path: Path) -> None:
        f = self.project_snapshot
        f.results = self.saved_results
        text = codable.dumps(f.to_json(), pretty=True)
        tmp = Path(path).with_suffix(".coastline.tmp")
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(path)
        self.project_path = Path(path)
        self.project_dirty = False
        self.add_recent(Path(path))
        self.status = f"Saved {Path(path).name}"

    def open_project(self, path: Path):
        """A task."""
        path = Path(path)
        try:
            p = ProjectFile.from_json(json.loads(path.read_text(encoding="utf-8")))
        except Exception as e:  # noqa: BLE001
            self.errorMessage = f"Couldn't open {path.name}: {e}"
            return
        if p.part_path is not None and not Path(p.part_path).exists():
            beside = path.parent / Path(p.part_path).name
            if beside.exists():
                p.part_path = str(beside)
            else:
                self.errorMessage = f"The part file isn't there any more: {p.part_path}"
        ok = yield from self.apply_project(p)
        if not ok:
            return
        self.undo_history = []
        self.redo_history = []
        self.project_path = path
        self.project_dirty = False
        self.add_recent(path)
        self.adopt_missing_items(p)
        machine_ok = p.results is not None and (PlanningMachineReference.from_json(p.results["machine"]) if p.results.get("machine")
                                                else PlanningMachineReference.legacy()) == self.planning_machine_reference
        if p.results is not None and self.part is not None and machine_ok:
            self.enter("machining")
            self.restore_results(p.results)
        else:
            self.enter("partStock")
            self.status = f"Opened {path.name}" if p.results is None else f"Opened {path.name} · Regenerate toolpaths for this machine"

    def adopt_missing_items(self, p: ProjectFile) -> None:
        """What the project uses that this inventory hasn't got: its own copies of the tools and
        the bar join as Not owned."""
        from ...core.inventory.catalogs import StockCatalog, ToolCatalog
        from ...core.inventory.items import Tool
        tools = []
        sources = list(p.resources.tools if p.resources is not None else [])
        for prog in (p.results or {}).get("programs") or []:
            try:
                sources.append(codable.from_json(Tool, prog["tool"]))
            except Exception:  # noqa: BLE001
                pass
        for t in sources:
            if self.tool_lookup(t.id) is None and not any(x.id == t.id for x in tools):
                c = copy.deepcopy(t)
                c.quantity = 0
                c.source = ToolCatalog.SOURCE
                tools.append(c)
        stock = []
        if p.stock is not None and self.stock_lookup(p.stock.id) is None:
            c = copy.deepcopy(p.stock)
            c.quantity = 0
            c.supplier = StockCatalog.SOURCE
            stock.append(c)
        if tools or stock:
            def change(inv):
                inv.tools.extend(tools)
                inv.stock.extend(stock)
            self.inventory_model.update(change)

    @staticmethod
    def recent_projects() -> list[Path]:
        return [Path(p) for p in _recent_list() if Path(p).exists()]

    @staticmethod
    def add_recent(path: Path) -> None:
        if SCRIPTED:
            return
        items = [p for p in _recent_list() if p != str(path)]
        items.insert(0, str(path))
        AppSettings.set_value("recentProjects", json.dumps(items[:10]))
