"""How the stock and the machine are drawn (realistic surfaces, see-through, edges only).
Port of Model/Appearance.swift."""

from __future__ import annotations

import numpy as np

from ...core.materials import MaterialFamily as F
from ...viewport.scene import SurfaceMaterial

STOCK_DISPLAYS = {"realistic": "Solid", "seeThrough": "See-through", "wireframe": "Edges only", "hidden": "Hidden"}
CHIP_GUARD = SurfaceMaterial(0, 0.05, edges=0.8)  # clear polycarbonate


def machine_surface(role: str) -> SurfaceMaterial:
    r = role[len("enclosure_"):] if role.startswith("enclosure_") else role
    return {"enclosure": SurfaceMaterial.paint, "mirror": SurfaceMaterial.mirror, "steel": SurfaceMaterial.chrome,
            "fastener": SurfaceMaterial.black_oxide, "motor": SurfaceMaterial(0.3, 0.5), "belt": SurfaceMaterial.rubber,
            "guard": CHIP_GUARD, "pcb": SurfaceMaterial.plastic, "estop": SurfaceMaterial.plastic}.get(r, SurfaceMaterial.aluminium)


def fixture_surface(id: str, color) -> SurfaceMaterial:
    """Fixture meshes keep their kit colours; the colour tells the material."""
    c = np.asarray(color[:3], float)
    if c[0] > 0.7 and c[1] > 0.7:
        return SurfaceMaterial(0, 0.55, edges=0.5)  # acetal
    if c[0] > 0.3 and c[1] < 0.2:
        return SurfaceMaterial(0, 0.6, edges=0.4)  # insulator
    if np.linalg.norm(c) < 0.15:
        return SurfaceMaterial.black_oxide  # screws
    return SurfaceMaterial(1, 0.28)  # aluminium


class AppearanceMixin:
    def apply_surfaces(self) -> None:
        """Surfaces for realistic shading, by what each mesh is. The flat view only uses colours."""
        stock = self.stock
        metal = True if stock is None else (stock.material is not None and stock.material.family in
                                            (F.ALUMINIUM, F.COPPER_ALLOY, F.STEEL, F.STAINLESS, F.TITANIUM))
        size = np.asarray(self.setup.stock_size(stock), float) if stock is not None else np.array([1.0, 2.0, 1.0])
        longest = max(range(3), key=lambda k: size[k])  # bar stock is extruded along its longest side
        axis = [0.0, 0.0, 0.0]
        axis[longest] = 1.0
        for m in self.scene.meshes.values():
            id = m.id
            if id.startswith("machine."):
                role = self.machine_scene_roles.get(id) or (id.split(".")[2] if len(id.split(".")) > 2 else "")
                mat = machine_surface(role)
            elif id.startswith("fixture."):
                mat = SurfaceMaterial(1, 0.18, 1, 1, (0, 1, 0)) if "parallel" in id else fixture_surface(id, m.color)
            elif id in ("stock", "simstock", "simstock.back", "simstock.walls"):
                mat = SurfaceMaterial(1, 0.3, 1, 1, tuple(axis)) if metal else SurfaceMaterial(0, 0.45, 0, 0.6)
            elif id == "part":
                mat = SurfaceMaterial(1, 0.16) if metal else SurfaceMaterial.plastic
            else:
                continue
            if m.material != mat:
                m.material = mat

    def apply_stock_display(self) -> None:
        scene = self.scene
        simulating = self.shows_machining_results and scene.mesh("simstock") is not None
        d = self.stockDisplay
        alpha = 0.22 if (self.fixture_placement is not None or self.showing_stock_only or d == "seeThrough"
                         or (not self.realistic and d == "realistic")) else 1.0
        m = scene.mesh("stock")
        if m is not None:
            m.visible = self.fixture_placement is not None or (self.stage != "partStock" and not simulating and d in ("realistic", "seeThrough"))
            m.color = (*m.color[:3], alpha)
            if self.fixture_placement is not None:
                m.color = (0.3, 0.6, 0.95, alpha)
        for id in ("simstock", "simstock.back", "simstock.walls", "simstock.loose"):
            s = scene.mesh(id)
            if s is None:
                continue
            s.visible = self.shows_machining_results and d not in ("hidden", "wireframe")
            if id != "simstock.loose":
                s.color = (*s.color[:3], 0.45 if d == "seeThrough" else 1.0)
            s.xray_through = id != "simstock.loose"  # x-ray toolpaths show through the stock only
        if m is not None:
            m.xray_through = True
        ip = scene.mesh("stock.inprocess")
        if ip is not None and m is not None:
            ip.visible = m.visible
            ip.color = (*ip.color[:3], m.color[3])
            ip.material = m.material
            ip.xray_through = True
            m.visible = False
        edges = scene.line_set("stock.edges")
        if edges is not None:
            edges.visible = ip is None and (self.fixture_placement is not None or (self.stage != "partStock" and d != "hidden"))
        tp = scene.line_set("toolpath")
        if tp is not None:
            tp.xray = 0.35 if self.realistic else 0.0
