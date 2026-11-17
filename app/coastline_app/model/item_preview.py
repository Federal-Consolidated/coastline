"""3D previews of inventory items in their inspectors: a tool as it is (flutes, tip, shank), a stock
blank in its material, a fixture's own model. Port of the item viewer (Views/Components/ItemViewer3D,
Inventory/FixtureModelPreview, Model/InventoryPreviewModels.swift), simplified: measuring tools and
accessories have no 3D model here."""

from __future__ import annotations

import numpy as np
from PySide6.QtCore import Property, QObject, Slot

from ..viewport.cutter import tool_meshes
from ..viewport.mesh_builder import MeshBuilder
from ..viewport.scene import Scene, SceneColor, SceneMesh, SurfaceMaterial, box_mesh
from .bindable import prop
from .tasks import Work, spawn


class ItemPreview(QObject):
    revision, revisionChanged = prop(int, "revision", 0)

    def __init__(self, inventory_model, workspace, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.inventory_model = inventory_model
        self.workspace = workspace
        self.scene = Scene(self)
        self.views: list = []
        self.key = ""
        self.message = ""
        self._fixture_meshes: dict[str, object] = {}

    @Property(QObject, constant=True)
    def viewScene(self):
        return self.scene

    @Slot(QObject)
    def attachViewport(self, view) -> None:
        if view not in self.views:
            self.views.append(view)
        self._frame()

    @Slot(QObject)
    def detachViewport(self, view) -> None:
        if view in self.views:
            self.views.remove(view)

    def _frame(self) -> None:
        for v in list(self.views):
            try:
                v.setView("iso")
                v.frame_all(False)
            except RuntimeError:
                self.views.remove(v)

    @Slot(str, str)
    def show(self, kind: str, id: str) -> None:
        """kind: "tools", "stock" or "fixtures"."""
        inv = self.inventory_model.inventory
        x = next((i for i in getattr(inv, kind, []) if i.id == id), None) if id else None
        key = f"{kind}:{id}:{hash(repr(x))}"
        if key == self.key:
            return
        self.key = key
        self.scene.clear()
        self.message = ""
        if x is None:
            self.revision += 1
            return
        if kind == "tools":
            for m in tool_meshes(x, "item"):
                # Tip at the origin, axis +Z; the preview stands it upright on screen.
                self.scene.add(m)
        elif kind == "stock":
            self._show_stock(x)
        elif kind == "fixtures":
            self._show_fixture(x)
        self._frame()
        self.revision += 1

    def _show_stock(self, s) -> None:
        from .workspace.core import linear_swatch
        c = linear_swatch(s.material) if s.material is not None else (0.6, 0.6, 0.62)
        if s.shape.value == "roundBar":
            b = MeshBuilder()
            b.cylinder(s.size_x / 2, -s.size_y / 2, s.size_y / 2, 64)
            m = b.mesh("item", (*c, 1.0))
        else:
            m = box_mesh("item", (-s.size_x / 2, -s.size_y / 2, -s.size_z / 2), (s.size_x / 2, s.size_y / 2, s.size_z / 2), (*c, 1.0))
        m.material = SurfaceMaterial(metallic=1 if s.material is not None and s.material.family.value in ("aluminium", "brass", "copper", "steel", "stainless", "titanium") else 0,
                                     roughness=0.35)
        self.scene.add(m)

    def _show_fixture(self, f) -> None:
        if f.model_path is None:
            self.message = "No 3D model yet: choose one below."
            return
        cached = self._fixture_meshes.get(f.model_path)
        if cached is not None:
            self.scene.add(SceneMesh("item", cached.vertices, cached.normals, cached.indices, SceneColor.part))
            return
        ws = self.workspace
        key = self.key
        self.message = "Loading the model…"

        def run():
            try:
                path = ws.fixture_model_path(f.model_path)
                mesh = yield Work(lambda: ws.connected_engine().import_part(path))
            except Exception as e:  # noqa: BLE001
                if self.key == key:
                    self.message = f"Couldn't read the model: {e}"
                    self.revision += 1
                return
            self._fixture_meshes[f.model_path] = mesh
            if self.key == key:
                self.message = ""
                self.scene.add(SceneMesh("item", mesh.vertices, mesh.normals, mesh.indices, SceneColor.part))
                self._frame()
                self.revision += 1

        spawn(run(), "fixture preview")

    @Slot(result=str)
    def note(self) -> str:
        return self.message
