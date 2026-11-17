"""The Machine page: a machine profile shown as an isolated digital model (no connection to any
controller), its axes moved by hand within their limits, and the profile's definition.
Port of Model/MachineProfilePreview.swift and the data of Views/MachineProfilesPage.swift."""

from __future__ import annotations

import numpy as np
from PySide6.QtCore import Property, QObject, Slot

from ..core.geometry import Vec3
from ..core.units import Length
from ..viewport.scene import PathColor, Scene, SceneColor, SceneLines, SceneMesh, box_mesh, segments
from .bindable import prop
from .tasks import Work, spawn
from .workspace.appearance import machine_surface
from .workspace.core import WorkspaceCore
from .workspace.geometry import translation

AXES = ("x", "y", "z")


def _v(v: Vec3) -> np.ndarray:
    return np.array([v.x, v.y, v.z], float)


class MachinePreview(QObject):
    revision, revisionChanged = prop(int, "revision", 0)

    def __init__(self, library, engine_source, workspace, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.library = library
        self.engine_source = engine_source  # blocking () -> EngineClient
        self.workspace = workspace
        self.scene = Scene(self)
        self.view = None
        self.definition = None
        self.problem = ""
        self.loading = False
        self.reference_pose = True
        self.position = np.zeros(3)
        self.show_interfaces = False
        self.show_reference_stock = True
        self.show_enclosure = False
        self.moving_only = False
        self._token = None
        library.selectedKeyChanged.connect(self.load_selected)
        library.revisionChanged.connect(self.load_selected)

    def touch(self) -> None:
        self.revision = self.revision + 1

    @Property(QObject, constant=True)
    def viewScene(self):
        return self.scene

    @Slot(QObject)
    def attachViewport(self, view) -> None:
        self.view = view
        view.world_to_display = self._display_transform()
        self.frame()

    @Slot(QObject)
    def detachViewport(self, view) -> None:
        if self.view is view:
            self.view = None

    def _display_transform(self) -> np.ndarray:
        """An authored "view" frame: X screen-right, Z up. Without it CAD Z is up."""
        d = self.definition
        f = next((f for f in d.frames if f.id == "view"), None) if d is not None else None
        m = np.eye(4)
        if f is not None:
            m[0, :3], m[1, :3], m[2, :3] = _v(f.x_direction), _v(f.y_direction), _v(f.z_direction)
        return m

    # ---------------------------------------------------------------- loading

    @Slot()
    def load_selected(self) -> None:
        package = self.library.selected
        if package is None:
            return
        if self.definition is not None and self.definition == package.definition and not self.problem:
            return
        token = object()
        self._token = token
        self.loading = True
        self.problem = ""
        self.scene.clear()
        self.definition = package.definition
        self.reference_pose = True
        self.touch()

        def run():
            try:
                engine = self.engine_source
                parts = yield Work(lambda: engine().machine_profile_parts(package.manifest_path))
                if self._token is not token:
                    return
                d = package.definition
                ids = {c.id for c in d.components}
                for i, part in enumerate(parts):
                    if part.group not in ids:
                        raise ValueError(f"Geometry refers to an unknown motion group: {part.group}.")
                    c = WorkspaceCore.display_color(part.role, part.color)
                    m = SceneMesh(f"profile.{i}", part.mesh.vertices, part.mesh.normals, part.mesh.indices, (*c, 0.2 if part.role.endswith("guard") else 1.0))
                    m.group = part.group
                    m.material = machine_surface(part.role)
                    self.scene.add(m)
                self._add_reference_stock(d)
                self._add_reference_lines(d)
                if self.view is not None:
                    self.view.world_to_display = self._display_transform()
                self.showHome()
                self._apply_visibility()
                self.frame()
            except Exception as e:  # noqa: BLE001
                if self._token is token:
                    self.problem = str(e)
            finally:
                if self._token is token:
                    self.loading = False
                self.touch()

        spawn(run(), "machine preview")

    def _add_reference_stock(self, d) -> None:
        s = d.reference_stock
        f = next((f for f in d.frames if f.id == s.frame_id), None) if s is not None else None
        if s is None or f is None:
            return
        t = np.eye(4)
        t[:3, 0], t[:3, 1], t[:3, 2], t[:3, 3] = _v(f.x_direction), _v(f.y_direction), _v(f.z_direction), _v(f.origin)
        lo = _v(s.minimum)
        m = box_mesh("reference.stock", lo, lo + _v(s.size), (0.34, 0.48, 0.62, 0.7), t)
        m.group = f.component_id
        self.scene.add(m)
        corners = [_v(c) for c in d.reference_stock_corners()]
        pairs = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        lines = SceneLines("reference.stock.edges", segments([(corners[a], corners[b]) for a, b in pairs], SceneColor.edge))
        lines.group = f.component_id
        self.scene.add(lines)

    def _add_reference_lines(self, d) -> None:
        for f in d.frames:
            if f.id == "view":
                continue
            o = _v(f.origin)
            seg = np.concatenate([segments([(o, o + _v(v) * 20)], c) for v, c in ((f.x_direction, PathColor.axis_x), (f.y_direction, PathColor.axis_y),
                                                                                    (f.z_direction, PathColor.axis_z))])
            lines = SceneLines(f"frame.{f.id}", seg)
            lines.group = f.component_id
            lines.xray = 0.3
            self.scene.add(lines)
        for mount in d.mounting_interfaces:
            f = next((f for f in d.frames if f.id == mount.frame_id), None)
            if f is None or not mount.slots:
                continue
            x, y, z, o = _v(f.x_direction), _v(f.y_direction), _v(f.z_direction), _v(f.origin)
            pairs = []
            for slot in mount.slots:
                p = o + x * slot.origin.x + y * slot.origin.y + z * slot.origin.z
                dd = x * slot.direction.x + y * slot.direction.y + z * slot.direction.z
                pairs.append((p, p + dd * slot.length))
            lines = SceneLines(f"mount.{mount.id}", segments(pairs, SceneColor.caution))
            lines.group = f.component_id
            lines.xray = 0.3
            self.scene.add(lines)

    def _apply_visibility(self) -> None:
        d = self.definition
        if d is None:
            return
        comps = {c.id: c for c in d.components}
        for m in self.scene.meshes.values():
            cid, moving = m.group, False
            while cid is not None and cid in comps:
                if comps[cid].axis is not None:
                    moving = True
                    break
                cid = comps[cid].parent_id
            enclosure = comps.get(m.group) is not None and comps[m.group].is_enclosure is True
            m.visible = ((not self.moving_only or moving) and (not enclosure or self.show_enclosure)
                         and (m.id != "reference.stock" or self.show_reference_stock))
        for ln in self.scene.lines.values():
            ln.visible = self.show_reference_stock if ln.id == "reference.stock.edges" else self.show_interfaces

    # ---------------------------------------------------------------- slots

    @Slot()
    def showReference(self) -> None:
        self.reference_pose = True
        self.scene.group_transforms = {}
        self.scene._touch()
        self.touch()

    @Slot()
    def showHome(self) -> None:
        if self.definition is None:
            return
        self.position = _v(self.definition.controller_home_position)
        self.reference_pose = False
        self._update_position()

    def _range(self, k: int):
        e = self.definition.profile.machine_envelope
        return (e.x, e.y, e.z)[k]

    @Slot(int, float)
    def setAxis(self, k: int, value: float) -> None:
        if self.definition is None or self.reference_pose:
            return
        r = self._range(k)
        self.position[k] = min(max(value, r.lower), r.upper)
        self._update_position()

    def _update_position(self) -> None:
        d = self.definition
        try:
            transforms = {}
            q = Vec3(*map(float, self.position))
            for c in d.components:
                transforms[c.id] = translation(_v(d.world_translation(c.id, q)))
            self.scene.group_transforms = transforms
            self.scene._touch()
        except Exception as e:  # noqa: BLE001
            self.problem = str(e)
        self.touch()

    @Slot()
    def frame(self) -> None:
        if self.view is None:
            return
        b = self.scene.visible_bounds()
        if b is not None:
            self.view.set_pivot((np.asarray(b[0]) + np.asarray(b[1])) / 2)
        self.view.frame_all(False)

    @Slot(str)
    def setView(self, name: str) -> None:
        if self.view is not None:
            self.view.setView(name)

    @Slot(str, bool)
    def setOption(self, name: str, on: bool) -> None:
        setattr(self, {"interfaces": "show_interfaces", "referenceStock": "show_reference_stock", "enclosure": "show_enclosure",
                       "movingOnly": "moving_only"}[name], on)
        self._apply_visibility()
        self.touch()

    @Slot(result="QVariantMap")
    def info(self) -> dict:
        d = self.definition
        out = {"loading": self.loading, "problem": self.problem, "referencePose": self.reference_pose,
               "interfaces": self.show_interfaces, "referenceStock": self.show_reference_stock, "enclosure": self.show_enclosure,
               "movingOnly": self.moving_only, "rows": self.library.rows(), "selected": self.library.selectedKey,
               "libraryError": self.library.error, "libraryMessage": self.library.message, "issues": self.library.issues()}
        if d is None:
            return out
        p = d.profile
        ws = self.workspace
        ref = ws.planning_machine_reference if ws is not None else None
        in_job = ref is not None and ref.definition is not None and ref.reference == d.reference
        out.update({
            "name": d.name, "revision": d.revision, "id": d.id, "manufacturer": d.manufacturer or "", "controller": d.controller.upper(),
            "inJob": bool(in_job), "key": self.library.selectedKey,
            "rpm": f"{p.spindle_rpm.lower:.0f}–{p.spindle_rpm.upper:.0f} RPM", "collet": p.collet_name,
            "shank": f"{Length.mm(p.max_shank_diameter)} mm", "toolLength": f"{Length.mm(p.max_tool_length)} mm",
            "axes": [{"name": AXES[k].upper(), "lower": self._range(k).lower, "upper": self._range(k).upper, "value": float(self.position[k])}
                     for k in range(3)],
            "frames": [{"id": f.id, "origin": f"{f.origin.x:.3f}, {f.origin.y:.3f}, {f.origin.z:.3f}", "component": f.component_id}
                       for f in d.frames if f.id != "view"],
            "mounts": [{"id": m.id, "slots": [{"id": s.id, "size": f"{Length.mm(s.length)} × {Length.mm(s.opening_width)} mm"} for s in m.slots]}
                       for m in d.mounting_interfaces],
            "components": [{"id": c.id, "parent": f"Moves with {c.parent_id}" if c.parent_id else "Machine root"} for c in d.components],
            "stock": f"{Length.mm(d.reference_stock.size.x)} × {Length.mm(d.reference_stock.size.y)} × {Length.mm(d.reference_stock.size.z)} mm" if d.reference_stock is not None else "",
        })
        return out

    @Slot()
    def useForJob(self) -> None:
        if self.workspace is not None and self.library.selectedKey:
            self.workspace.usePlanningMachine(self.library.selectedKey)
