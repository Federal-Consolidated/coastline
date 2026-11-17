"""Renders a test scene with every drawing mode on the real GPU and writes a PNG.

    .venv/bin/python scripts/render_check.py out.png [--realistic] [--section]

Opens a small window for a moment (pipelines only fail at draw time, on the real backend)."""

from __future__ import annotations

import os
import sys
from pathlib import Path

os.environ.setdefault("QSG_RENDER_LOOP", "basic")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np  # noqa: E402
from PySide6.QtCore import QTimer, QUrl  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtQuick import QQuickView  # noqa: E402

from coastline_app.viewport import Scene  # noqa: E402
from coastline_app.viewport.item import MACHINE_TO_DISPLAY, Viewport  # noqa: E402
from coastline_app.viewport.scene import (PathColor, SurfaceMaterial, axes_segments, box_mesh, box_segments,  # noqa: E402
                                          polyline_segments)


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "render_check.png")
    app = QGuiApplication(sys.argv)
    view = QQuickView()
    view.setResizeMode(QQuickView.ResizeMode.SizeRootObjectToView)
    view.resize(900, 600)
    vp = Viewport()
    vp.setParentItem(view.contentItem())
    vp.setWidth(900)
    vp.setHeight(600)
    scene = Scene()
    vp.scene = scene
    vp.world_to_display = MACHINE_TO_DISPLAY
    vp.realistic = "--realistic" in sys.argv
    table = scene.add(box_mesh("machine.x.table", (-10, -80, -60), (0, 80, 60), (0.3, 0.3, 0.32, 1)))
    table.material = SurfaceMaterial.aluminium
    part = scene.add(box_mesh("part", (0, -20, -15), (20, 20, 15), (0.56, 0.56, 0.56, 1)))
    part.material = SurfaceMaterial(1, 0.3, 1, 1, (0, 1, 0))
    stock = scene.add(box_mesh("stock", (0, -30, -20), (25, 30, 20), (0.7, 0.75, 0.8, 0.25)))
    stock.xray_through = True
    handle = scene.add(box_mesh("gumball", (30, -2, -2), (34, 2, 2), (0.9, 0.2, 0.2, 1)))
    handle.on_top = True
    handle.unlit = True
    t = np.linspace(0, 4 * np.pi, 400)
    pts = np.stack([10 + 5 * np.sin(t * 3), 18 * np.cos(t), np.linspace(-12, 12, 400)], 1)
    path = scene.set_lines("toolpath", polyline_segments(pts, PathColor.cut))
    path.xray = 0.35
    scene.set_lines("box", box_segments((0, -30, -20), (25, 30, 20), PathColor.envelope))
    scene.set_lines("axes", axes_segments(20))
    if "--section" in sys.argv:
        scene.clip_plane = np.array([0, 0, 1, 0.0])
    vp.camera.set_view("iso")
    view.show()
    vp.frame_all()

    def grab() -> None:
        img = view.grabWindow()
        img.save(str(out))
        print(f"wrote {out} {img.width()}x{img.height()}", flush=True)
        os._exit(0)  # skip teardown: a lone test window has nothing to save

    QTimer.singleShot(1500, grab)
    app.exec()


if __name__ == "__main__":
    main()
