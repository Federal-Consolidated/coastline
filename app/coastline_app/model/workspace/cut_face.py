"""The stock face the current or next cut works on, tinted. Port of Model/CutFace.swift."""

from __future__ import annotations

import numpy as np

from ...viewport.scene import SceneColor, SceneLines, SurfaceMaterial, box_mesh, box_segments


class CutFaceMixin:
    def layout_cut_face(self) -> None:
        """Tints the face toward the spindle, so it's clear which way round the stock goes."""
        scene = self.scene
        stock, size = self.stock, self.display_stock_size
        if not self.show_cut_face or stock is None or size is None:
            self.cut_face_key = ""
            scene.remove("cutface")
            scene.remove("cutface.edges")
            return
        key = f"{self.viewSide}-False-{tuple(np.round(np.asarray(size, float), 9))}-{stock.id}"
        if self.cut_face_key == key:
            return
        self.cut_face_key = key
        o = np.asarray(self.work_origin(size), float)
        t = 0.06  # just proud of the surface
        lo = o + np.array([-size[0] / 2, -size[1] / 2, 0])
        hi = o + np.array([size[0] / 2, size[1] / 2, t])
        m = box_mesh("cutface", lo, hi, SceneColor.surface(0.95, 0.30))
        m.material = SurfaceMaterial(metallic=0, roughness=0.6, edges=0)
        scene.add(m)
        scene.add(SceneLines("cutface.edges", box_segments(lo, hi, SceneColor.highlight)))
