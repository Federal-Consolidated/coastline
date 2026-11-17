"""Starts the real window headless and runs the viewport renderer over a part and a
toolpath on Qt's null graphics backend (all renderer code runs; nothing reaches a GPU).
Real-GPU drawing is checked by scripts/bench_viewport.py, which needs a display.
Runs in a subprocess: Qt settings must be made before the application object exists."""

import os
import subprocess
import sys
import textwrap
from pathlib import Path

APP = Path(__file__).resolve().parent.parent

SCRIPT = textwrap.dedent("""
    import sys, faulthandler
    faulthandler.dump_traceback_later(60, exit=True)
    errors = []
    sys.excepthook = lambda *exc: errors.append(exc)  # PySide reports errors in overrides here
    import numpy as np
    from PySide6.QtCore import QTimer
    from coastline_app.application import create_app
    from coastline_app.viewport import PathColor, polyline_segments
    from coastline_app.viewport import item

    rendered = []
    original = item._Renderer.render
    def render(self, cb):
        original(self, cb)
        rendered.append(1)
    item._Renderer.render = render

    app = create_app(sys.argv[:1])
    scene = app.backend.scene
    scene.set_mesh("part", [[0, 0, 0], [10, 0, 0], [0, 10, 0]], [[0, 0, 1]] * 3, [0, 1, 2])
    scene.set_lines("path", polyline_segments(np.random.default_rng(1).random((2_500_001, 3)) * 10, PathColor.cut))
    scene.request_frame()
    def later():
        scene.set_visible_segments("path", 1_200_000)
        scene.remove("part")
    QTimer.singleShot(300, later)
    QTimer.singleShot(900, app.qt.quit)
    app.qt.exec()
    if errors:
        import traceback
        traceback.print_exception(*errors[0])
        sys.exit(1)
    print("frames", len(rendered))
    sys.exit(0 if len(rendered) >= 2 else 2)
""")


def test_window_and_viewport_render_headless():
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="rhi", QSG_RHI_BACKEND="null")
    result = subprocess.run([sys.executable, "-c", SCRIPT], cwd=APP, env=env, capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr


OPEN_PART = textwrap.dedent("""
    import os, sys, faulthandler
    faulthandler.dump_traceback_later(120, exit=True)
    from coastline_app import paths
    from coastline_app.application import create_app
    from coastline_app.model.tasks import spawn

    app = create_app(sys.argv[:1])
    ws = app.backend
    def run():
        yield from ws.import_part(paths.SAMPLES_DIR / "dfm_coupon.step")
        app.qt.quit()
    def fail(e):
        import traceback; traceback.print_exception(e); app.qt.exit(3)
    spawn(run(), "open", on_error=fail)
    code = app.qt.exec()
    app.root.shutdown()
    size = ws.part.size if ws.part is not None else None
    print(ws.status, ws.errorMessage, size)
    ok = code == 0 and "part" in ws.scene.meshes and size is not None and abs(size.x - 203.2) < 0.01
    os._exit(0 if ok else 4)
""")


def test_open_part_through_the_engine_worker():
    env = dict(os.environ, COASTLINE_SCRIPT="1", QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="rhi", QSG_RHI_BACKEND="null")
    result = subprocess.run([sys.executable, "-c", OPEN_PART], cwd=APP, env=env, capture_output=True, text=True, timeout=150)
    assert result.returncode == 0, result.stdout + result.stderr


PAGES = textwrap.dedent("""
    import sys, faulthandler
    faulthandler.dump_traceback_later(60, exit=True)
    errors = []
    sys.excepthook = lambda *exc: errors.append(exc)
    from PySide6.QtCore import QTimer
    from coastline_app.application import create_app
    from coastline_app.model.app_root import PAGES

    app = create_app(sys.argv[:1])
    warnings = []
    app.qml.warnings.connect(lambda ws: warnings.extend(w.toString() for w in ws))
    pages = list(PAGES)
    failed = []
    def step():
        # A page whose QML failed leaves the loader with no item (progress 0).
        # A fresh wrapper each time: Shiboken can drop old window wrappers when pages close.
        if not app.qml.rootObjects()[0].property("pageReady"):
            failed.append(app.root.page)
        if not pages:
            app.qt.quit()
            return
        app.root.page = pages.pop(0)
        QTimer.singleShot(250, step)
    QTimer.singleShot(200, step)
    app.qt.exec()
    for w in warnings:
        print("QML:", w)
    if errors:
        import traceback
        traceback.print_exception(*errors[0])
    print("not loaded:", failed)
    import os
    os._exit(1 if warnings or errors or failed else 0)  # skip teardown
""")


def test_every_page_loads_without_qml_errors(tmp_path):
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="rhi", QSG_RHI_BACKEND="null",
               COASTLINE_DATA_DIR=str(tmp_path))
    result = subprocess.run([sys.executable, "-c", PAGES], cwd=APP, env=env, capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
