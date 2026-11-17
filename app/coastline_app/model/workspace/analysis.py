"""Part analysis, machinability findings and their highlights, and watching the CAD file. Port of
Model/Analysis.swift."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
from PySide6.QtCore import QFileSystemWatcher

from ...core.engine.client import EngineClient
from ...core.storage import caches
from ...core.plan import dfm as DFM
from ...core.plan.dfm import Category
from ...core.plan.named_features import NamedFeature, recognise
from ...core.plan.part_analysis import PartAnalysis, analyse
from ...core.plan.plan_coverage import PlanCoverage, SetupRoom, Turn
from ...viewport.scene import SceneColor, SceneMesh
from ..tasks import Sleep, Work, spawn

HIGHLIGHT = {Category.NOT_SUPPORTED: (0.92, 0.12, 0.08, 1.0), Category.MISSING_RESOURCE: (0.98, 0.68, 0.08, 1.0),
             Category.SETUP_CHANGE: (0.22, 0.55, 1.0, 1.0), Category.MISSING_INFORMATION: (0.72, 0.72, 0.78, 1.0),
             Category.OK: (0.30, 0.80, 0.42, 1.0)}


def highlight_color(c) -> tuple[float, float, float, float]:
    """Red: can't be machined; amber: a tool or stock is missing; blue: a setup change; grey:
    information needed; green: fine."""
    return HIGHLIGHT[Category(c)]


def overlay(triangles) -> tuple[np.ndarray, np.ndarray]:
    """Triangles (9 floats each) with flat normals, lifted 0.03 mm off the surface along them so
    the overlay never z-fights the part."""
    t = np.asarray(triangles, np.float32).reshape(-1, 3, 3).copy()
    if not len(t):
        return np.zeros((0, 3), np.float32), np.zeros((0, 3), np.float32)
    c = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0])
    ln = np.linalg.norm(c, axis=1)
    n = np.where(ln[:, None] > 1e-12, c / np.maximum(ln, 1e-30)[:, None], np.array([0, 0, 1], np.float32)).astype(np.float32)
    t += n[:, None, :] * 0.03
    normals = np.repeat(n, 3, axis=0)
    return t.reshape(-1, 3), normals


def anchors(areas, access) -> list[np.ndarray]:
    """One point per place, on the surface: the triangle nearest the place's middle, lifted half a
    millimetre off it (work frame of the analysis)."""
    out = []
    for faces in areas:
        t = np.asarray(access.triangles_for_faces(faces), float).reshape(-1)
        if len(t) < 9:
            continue
        mid = t.reshape(-1, 3).mean(axis=0)
        tri = t[:len(t) // 9 * 9].reshape(-1, 3, 3)
        cross = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
        ln = np.linalg.norm(cross, axis=1)
        ok = ln > 1e-12
        if not ok.any():
            continue
        centres = tri.mean(axis=1)
        d = np.where(ok, np.linalg.norm(centres - mid, axis=1), np.inf)
        k = int(np.argmin(d))  # first of equals
        out.append(centres[k] + cross[k] / ln[k] * 0.5)
    return out


def same_transform(a, b) -> bool:
    a, b = np.asarray(a, float), np.asarray(b, float)
    return bool(np.all(np.linalg.norm(a[:, :3] - b[:, :3], axis=0) < 1e-9))


class NamedFeatureCache:
    """Named features per file content: recognition is slow on busy parts and the answer only
    changes with the file."""

    VERSION = 1

    @staticmethod
    def file(path: Path) -> Path | None:
        try:
            digest = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        except OSError:
            return None
        return caches() / "Features" / f"{digest}-v{NamedFeatureCache.VERSION}.json"

    @staticmethod
    def load(path: Path) -> list[NamedFeature] | None:
        f = NamedFeatureCache.file(path)
        try:
            return [NamedFeature(d["family"], d["label"], [int(k) for k in d["faces"]]) for d in json.loads(f.read_text())] if f else None
        except (OSError, ValueError, KeyError, TypeError):
            return None

    @staticmethod
    def save(features: list[NamedFeature], path: Path) -> None:
        f = NamedFeatureCache.file(path)
        if f is None:
            return
        try:
            f.parent.mkdir(parents=True, exist_ok=True)
            tmp = f.with_suffix(".tmp")
            tmp.write_text(json.dumps([{"faces": x.faces, "family": x.family, "label": x.label} for x in features]))
            tmp.replace(f)
        except OSError:
            pass


class AnalysisMixin:
    highlight_color = staticmethod(highlight_color)

    def schedule_analysis(self) -> None:
        """Re-runs the part analysis for the current orientation (debounced)."""
        if self.analysis_failed:
            self.analysis_failed = False  # checking again
        if self.analysis_task is not None:
            self.analysis_task.cancel()

        def run():
            yield Sleep(0.25)
            yield from self.run_analysis()

        self.analysis_task = spawn(run(), "analysis")

    def run_analysis(self):
        if self.part is None or not self.part.exact:
            self.analysis = None
            self.show_dfm_highlight()
            return
        self.recognise_features(self.part.path)
        try:
            engine = yield from self.live_engine()
            # After the engine is up: a restarted engine gave the part a new ID.
            part = self.part
            if part is None:
                return
            t = self.work_transform(part)
            a = yield Work(lambda: analyse(engine, part.part_id, t, access=True))
            if self.part is None or self.part.part_id != part.part_id:
                return  # another part was imported meanwhile: its own analysis follows
            # An exact part always comes back with access data: none means the check couldn't run.
            self.analysis_failed = a.access is None
            self.analysis_transform = t
            self.analysis = a
            self.show_undercuts()
            self.choose_sides(a)
        except Exception as e:  # noqa: BLE001
            from ..tasks import Cancelled
            if isinstance(e, Cancelled):
                raise
            self.analysis_failed = True
            self.errorMessage = f"Analysis failed: {e}"
        finally:
            self.touch()

    def recognise_features(self, path: Path) -> None:
        """Names the part's features in the background, on an engine of its own (slow on busy
        parts). Once per file; the findings take the names when they arrive."""
        if path == self.named_features_file:
            return
        self.named_features_file = path
        self.named_features = []
        if self.recognition_task is not None:
            self.recognition_task.cancel()
        if Path(path).suffix.lower() not in (".step", ".stp"):
            return

        def find():
            cached = NamedFeatureCache.load(path)
            if cached is not None:
                return cached
            try:
                engine = EngineClient()
            except Exception:  # noqa: BLE001
                return None
            try:
                found = recognise(engine, Path(path))
            except Exception:  # noqa: BLE001
                found = None
            finally:
                engine.shutdown()
            if found is not None:
                NamedFeatureCache.save(found, path)
            return found

        def run():
            found = yield Work(find, lane="recognise")
            if self.named_features_file == path and found is not None:
                self.named_features = found
                self.touch()

        self.recognition_task = spawn(run(), "recognise")

    def choose_sides(self, a) -> None:
        """Parts with shape on the back are machined from both sides; a flat back from one. A
        choice the user made is kept."""
        if self.two_sided_chosen:
            return
        findings = self.dfm_findings(self.inventory)
        want = self.back_has_shape(a) or (findings is not None and "-z" in PlanCoverage.propose(findings))
        if self.twoSided != want:
            self.twoSided = want
            self.status = "The back has shape (shown red): planned from both sides." if want else "The back is flat: planned from one side."

    @staticmethod
    def back_has_shape(a) -> bool:
        return a.undercut_area > 0.5

    def show_undercuts(self) -> None:
        """Faces that point away from the spindle, drawn red over the part."""
        try:
            scene = self.scene
            scene.remove("undercuts")
            self.undercut_overlay_shown = False
            a, part = self.analysis, self.part
            if not self.show_undercut_overlay or a is None or not len(a.undercut_triangles) or self.stock is None or part is None or self.viewSide == 1:
                return
            now = self.work_transform(part)
            part_mesh = scene.mesh("part")
            if part_mesh is None or not part_mesh.visible:
                return
            if self.analysis_transform is not None and not same_transform(now, self.analysis_transform):
                return
            t, normals = overlay(a.undercut_triangles)
            placed = np.asarray(part_mesh.transform, float) @ np.linalg.inv(np.asarray(self.analysis_transform if self.analysis_transform is not None else now, float))
            scene.add(SceneMesh("undercuts", t, normals, np.arange(len(t), dtype=np.uint32), SceneColor.surface(0.97, 0.8), placed))
            self.undercut_overlay_shown = True
        finally:
            # Every layout and analysis comes through here: the finding highlight follows the part too.
            self.show_dfm_highlight()

    # ---- machinability

    def current_access_analysis(self, part):
        a, then = self.analysis, self.analysis_transform
        if a is None or a.access is None or then is None:
            return None
        return a if same_transform(self.work_transform(part), then) else None

    @property
    def setup_room(self) -> SetupRoom | None:
        """The machine's room for the stock turned to each side. None for a profile without a model."""
        g, stock = self.planning_geometry, self.stock
        if g is None or stock is None:
            return None
        size, centre = self.setup.stock_size(stock), self.travel_centre_y
        key = f"{g.definition.id}#{g.definition.revision}|{tuple(np.round(np.asarray(size, float), 9))}|{centre}"
        if self.setup_room_cache is not None and self.setup_room_cache[0] == key:
            return self.setup_room_cache[1]
        enclosure = {c.id for c in g.definition.components if g.is_enclosure(c.id)}
        turns: dict[str, Turn] = {}
        for axis in ("z", "x", "y"):
            s = SetupRoom.size(size, "+" + axis)
            try:
                a = g.room_behind_table(s[0], s[1], centre)
                b = g.room_behind_table(s[0], s[1], centre, skip=enclosure)
            except Exception:  # noqa: BLE001
                continue
            turns["+" + axis] = Turn(a[0], b[0])
            turns["-" + axis] = turns["+" + axis]
        room = SetupRoom(g.support_bounds.size.z, turns)
        self.setup_room_cache = (key, room)
        return room

    def dfm_findings(self, inventory) -> list | None:
        """Machinability of the part as set up; None until the analysis for this orientation is
        in. Cached (the pins re-render with every camera move)."""
        part = self.part
        if part is None:
            return None
        room = self.setup_room
        key = (self.analysis_version, id(self.named_features), len(self.named_features), part.part_id, self.setup, self.stock,
               inventory, self.planning_machine_reference, self.twoSided, room)
        c = self.dfm_cache
        if c is not None:
            try:
                if c[0] == key:
                    return c[1]
            except (ValueError, TypeError):
                pass
        if part.exact:
            a = self.current_access_analysis(part)
            if a is None:
                return None
        else:
            a = PartAnalysis()
        import copy
        findings = DFM.assess(DFM.Input(a, self.setup, tuple(part.bounds_min), tuple(part.bounds_max), self.stock, inventory,
                                        self.machine, self.twoSided, self.named_features, room))
        pins = {}
        if a.access is not None:
            for f in findings:
                if f.category != Category.OK:
                    pins[f.id] = anchors(f.areas, a.access)
        self.dfm_cache = (copy.deepcopy(key), findings, pins)
        return findings

    def finding_pin_points(self, id: str) -> list[np.ndarray]:
        """The pins of a finding in world coordinates, where the part is drawn now."""
        if self.dfm_cache is None or self.analysis_transform is None:
            return []
        points = self.dfm_cache[2].get(id)
        part_mesh = self.scene.mesh("part")
        if not points or part_mesh is None or not part_mesh.visible:
            return []
        m = self.scene.group_transform(part_mesh.group) @ np.asarray(part_mesh.transform, float) @ np.linalg.inv(np.asarray(self.analysis_transform, float))
        return [(m @ np.array([*p, 1.0]))[:3] for p in points]

    @property
    def shows_findings_in_view(self) -> bool:
        return (self.show_findings_overlay and self.stage == "planning" and self.fixture_placement is None
                and not self.shows_machining_results and self.part is not None)

    def select_finding(self, f, frame: bool = True) -> None:
        """Picks a finding (None: none). Its faces light up on the part; the view frames them."""
        fid = f.id if f is not None else None
        if self.selected_finding_id != fid:
            self.selected_finding_id = fid
        self.dfm_highlight = (list(f.faces), f.category) if f is not None else None
        self.show_dfm_highlight()
        if frame and f is not None:
            self._frame_finding(f)
        self.touch()

    def sync_finding_selection(self, findings) -> None:
        """The findings were made again: the part's colours follow, the highlight follows its
        finding, and goes when the finding does or is solved."""
        faces: dict = {}
        for f in findings or []:
            if f.category != Category.OK:
                faces.setdefault(f.category, []).extend(f.faces)
        if faces != self.dfm_overlay_faces:
            self.dfm_overlay_faces = faces
            self.show_dfm_highlight()
        fid = self.selected_finding_id
        if fid is None:
            return
        f = next((x for x in findings or [] if x.id == fid), None)
        h = self.dfm_highlight
        if f is None or not (f.category != Category.OK or (h is not None and h[1] == Category.OK)):
            self.select_finding(None)
            return
        if h is None or h[0] != list(f.faces) or h[1] != f.category:
            self.select_finding(f, frame=False)

    def show_dfm_highlight(self) -> None:
        """Every problem's faces in its colour (Plan), and the selected finding's faces drawn over
        everything."""
        scene = self.scene
        scene.remove("dfm.highlight")
        for c in Category:
            scene.remove(f"dfm.cat.{int(c)}")
        a, then = self.analysis, self.analysis_transform
        part_mesh = scene.mesh("part")
        if self.stock_animating or a is None or a.access is None or then is None or part_mesh is None or not part_mesh.visible:
            return
        access = a.access
        transform = np.asarray(part_mesh.transform, float) @ np.linalg.inv(np.asarray(then, float))

        def add(id: str, faces, colour, on_top: bool) -> None:
            t, normals = overlay(access.triangles_for_faces(faces))
            if len(t) < 3:
                return
            m = SceneMesh(id, t, normals, np.arange(len(t), dtype=np.uint32), colour, transform)
            m.group = part_mesh.group  # on the table with the part
            m.depth_bias = 1  # as the undercuts: wins against the part face it lies on
            m.on_top = on_top
            scene.add(m)

        if self.shows_findings_in_view:
            for c, faces in self.dfm_overlay_faces.items():
                if faces:
                    r, g, b, _ = highlight_color(c)
                    add(f"dfm.cat.{int(c)}", faces, (r, g, b, 0.9), False)
        h = self.dfm_highlight
        if h is not None and h[0]:
            r, g, b, _ = highlight_color(h[1])
            add("dfm.highlight", h[0], (r, g, b, 0.55), True)

    def _frame_finding(self, f) -> None:
        a, then = self.analysis, self.analysis_transform
        part_mesh = self.scene.mesh("part")
        if a is None or a.access is None or then is None or part_mesh is None or not part_mesh.visible:
            return
        b = a.access.bounds_for_faces(f.faces)
        if b is None:
            return
        m = self.scene.group_transform(part_mesh.group) @ np.asarray(part_mesh.transform, float) @ np.linalg.inv(np.asarray(then, float))
        lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
        for i in range(8):
            c = np.array([b[0][0] if i & 1 == 0 else b[1][0], b[0][1] if i & 2 == 0 else b[1][1], b[0][2] if i & 4 == 0 else b[1][2], 1.0])
            w = (m @ c)[:3]
            lo, hi = np.minimum(lo, w), np.maximum(hi, w)
        # The view keeps its direction. Never a close-up of a small hole.
        c, half = (lo + hi) / 2, np.maximum((hi - lo) / 2 * 1.4, 15)
        self.renderer.frame(c - half, c + half, animated=True)

    def apply_dfm_remedy(self, r, library) -> None:
        """A finding's way forward. Only stock and navigation: nothing about a tool is changed here."""
        inventory = library.inventory
        if r.kind == "useStock":
            item = next((s for s in inventory.stock if s.id == r.id), None)
            if item is None:
                return
            self.use_stock(inventory.resolved_stock(item))
            self.use_stock_axes(list(r.axes or ()))
        elif r.kind in ("showTool", "buyTool"):
            self.navigate_to_tool(r.id)
        elif r.kind == "addCollet":
            self.navigate("accessories")
        elif r.kind == "addTool":
            t = r.tool
            if t is not None and not any(x.id == t.id for x in inventory.tools):
                library.update(lambda inv: inv.tools.append(t))  # a tool to buy (quantity 0)
            if t is not None:
                self.status = f"Added the {t.name} to your tools, to buy."
        elif r.kind == "reviewSetups":
            self.enter("setups")

    # ---- watching the CAD file

    def watch_part_file(self, path: Path) -> None:
        """Watches the imported file; a re-export shows a Reload banner."""
        if self.part_watcher is not None:
            self.part_watcher.deleteLater()
        self.part_changed_on_disk = False
        w = QFileSystemWatcher([str(path)])

        def changed(_):
            self.part_changed_on_disk = True
            self.touch()

        w.fileChanged.connect(changed)
        self.part_watcher = w

    def reload_part(self):
        """A task: re-imports the changed file, keeping the orientation, stock and operations."""
        if self.part is None:
            return
        path = self.part.path
        keep_setup, keep_ops, keep_stock = self.setup, list(self.operations), self.stock_id
        keep_sides = (self.twoSided, self.two_sided_chosen)
        yield from self.import_part(path)
        self.twoSided, self.two_sided_chosen = keep_sides
        self.setup = keep_setup
        self.stock_id = keep_stock
        self.operations = keep_ops
        self.part_changed_on_disk = False
        self.status = f"Reloaded {path.name}: orientation, stock and operations kept. Generate again."
