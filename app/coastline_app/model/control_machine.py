"""The real machine assembly on the Machine Control page, with its own scene and camera: it follows
the controller's reported (homed) position. Opening Control never changes the workspace.
Port of Views/Control/ControlMachineView.swift (ControlMachineScene)."""

from __future__ import annotations

import math
import time

import numpy as np
from PySide6.QtCore import Property, QObject, Slot

from ..mill.session_types import MillLink
from ..viewport.scene import Scene
from .bindable import prop
from .tasks import spawn
from .workspace.appearance import machine_surface
from .workspace.core import WorkspaceCore
from .workspace.geometry import translation

DISPLAYS = {"open": "Open Assembly", "full": "Whole Machine", "moving": "Moving Parts"}


class ControlMachine(QObject):
    revision, revisionChanged = prop(int, "revision", 0)

    def __init__(self, mill, workspace, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.mill = mill
        self.workspace = workspace
        self.scene = Scene(self)
        self.view = None
        self.model = None
        self.problem = ""
        self.loading = False
        self.display = "open"
        self.position_source = "Reference pose"
        self.position_help = "The assembly's modelled position. Home the connected machine to show its reported position."
        mill.stateChanged.connect(self.synchronize)

    def touch(self) -> None:
        self.revision = self.revision + 1

    @Property(QObject, constant=True)
    def viewScene(self):
        return self.scene

    @Slot(QObject)
    def attachViewport(self, view) -> None:
        from ..viewport.item import MACHINE_TO_DISPLAY
        self.view = view
        view.world_to_display = MACHINE_TO_DISPLAY
        if self.model is None:
            self.load()
        else:
            self.frame()

    @Slot(QObject)
    def detachViewport(self, view) -> None:
        if self.view is view:
            self.view = None

    @Slot()
    def load(self) -> None:
        if self.model is not None or self.loading:
            return
        self.loading = True
        self.problem = ""
        self.touch()

        def run():
            try:
                assembly = yield from self.workspace.load_control_machine_model()
                for i, part in enumerate(assembly.parts):
                    from ..viewport.scene import SceneMesh
                    c = WorkspaceCore.display_color(part.role, part.color)
                    m = SceneMesh(f"machine.{part.group}.{part.role}.{i}", part.mesh.vertices, part.mesh.normals, part.mesh.indices, (*c, 1.0))
                    m.group = part.group
                    m.material = machine_surface(part.role)
                    self.scene.add(m)
                if not self.scene.meshes:
                    self.problem = "The machine assembly contained no displayable parts."
                    return
                self.model = assembly
                self._apply_display()
                self.synchronize()
                self.frame()
            except Exception as e:  # noqa: BLE001
                self.problem = str(e)
            finally:
                self.loading = False
                self.touch()

        spawn(run(), "control machine")

    @Slot()
    def synchronize(self) -> None:
        """Only homed controller positions are shown as current; otherwise the reference pose."""
        if self.model is None:
            return
        s = self.mill.snapshot
        st = s.status
        if s.link != MillLink.CONNECTED or not s.homed or s.needs_reset or st is None:
            self._reference_pose()
            return
        p, m = st.machine_position, self.model.model_pose
        dx, dy, dz = m.x - p.x, p.y - m.y, p.z - m.z
        if not all(math.isfinite(v) for v in (dx, dy, dz)):
            self._reference_pose()
            return
        g = self.scene.group_transforms
        g["x"] = translation((dx, 0, 0))
        g["y"] = translation((0, dy, 0))
        g["z"] = translation((0, dy, dz))
        self.scene._touch()
        fresh = s.silent_since is None and s.status_time is not None and time.time() - s.status_time <= 1
        simulated = s.port is not None and s.port.is_simulated
        source = ("Simulated position" if simulated else "Reported position") if fresh else "Last reported position"
        if source != self.position_source:
            self.position_source = source
            self.position_help = ("The assembly follows the machine coordinates reported by the controller." if fresh
                                  else "The controller's position report is out of date. This is its last reported position.")
            self.touch()

    def _reference_pose(self) -> None:
        if self.scene.group_transforms:
            self.scene.group_transforms = {}
            self.scene._touch()
        if self.position_source != "Reference pose":
            self.position_source = "Reference pose"
            self.position_help = "The assembly's modelled position. A valid, homed controller position is needed to show the machine's reported position."
            self.touch()

    def _apply_display(self) -> None:
        for m in self.scene.meshes.values():
            parts = m.id.split(".")
            role = parts[2] if len(parts) > 2 else ""
            shell = role.startswith("enclosure")
            m.visible = (not shell) if self.display == "open" else True if self.display == "full" else (m.group != "static" and not shell)
            c = m.color
            m.color = (c[0], c[1], c[2], 0.2 if role.endswith("guard") else 1.0)

    @Slot(str)
    def setDisplay(self, d: str) -> None:
        self.display = d
        self._apply_display()
        self.frame()
        self.touch()

    @Slot(str)
    def setView(self, name: str) -> None:
        if self.view is not None:
            self.view.setView(name)

    @Slot()
    def frame(self) -> None:
        if self.view is None:
            return
        b = self.scene.visible_bounds()
        if b is not None:
            self.view.set_pivot((np.asarray(b[0]) + np.asarray(b[1])) / 2)
        self.view.frame_all(False)

    @Slot(result="QVariantMap")
    def info(self) -> dict:
        return {"loading": self.loading, "problem": self.problem, "display": self.display, "source": self.position_source,
                "help": self.position_help, "displays": [{"value": k, "title": v} for k, v in DISPLAYS.items()]}
