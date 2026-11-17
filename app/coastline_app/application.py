"""Creates the Qt application and its main window. Used by the app, the benchmark and tests."""

from __future__ import annotations

import sys
from pathlib import Path

import os
from dataclasses import dataclass

from PySide6.QtCore import QObject, Qt, QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuickControls2 import QQuickStyle

from . import paths
from . import viewport  # noqa: F401 — registers the Viewport QML type
from .model.app_root import AppRoot


@dataclass
class App:
    qt: QGuiApplication
    backend: QObject  # the workspace
    root: AppRoot
    qml: QQmlApplicationEngine
    window: QObject  # the QML ApplicationWindow (a QQuickWindow)

    @property
    def viewport(self) -> viewport.Viewport:
        return self.window.findChild(QObject, "viewport")


def configure_qt() -> None:
    """Settings that must be made before the QGuiApplication exists."""
    # Draw on the UI thread. The viewport's renderer is Python code; with Qt Quick's
    # separate render thread, any UI-thread call that waits for that thread while holding
    # Python's GIL (window grabs, some resizes) deadlocks. Python runs one thread at a time
    # anyway, so the render thread gained nothing.
    os.environ.setdefault("QSG_RENDER_LOOP", "basic")
    # Fusion draws the same controls on Windows and macOS.
    QQuickStyle.setStyle("Fusion")


def dark_palette():
    """Coastline is dark on every system (Windows in light mode too): greys, white text."""
    from PySide6.QtGui import QColor, QPalette
    p = QPalette()
    roles = {QPalette.ColorRole.Window: "#0e0e0e", QPalette.ColorRole.WindowText: "#ececec", QPalette.ColorRole.Base: "#1b1b1d",
             QPalette.ColorRole.AlternateBase: "#232326", QPalette.ColorRole.ToolTipBase: "#2a2a2d", QPalette.ColorRole.ToolTipText: "#ececec",
             QPalette.ColorRole.PlaceholderText: "#6c6c70", QPalette.ColorRole.Text: "#ececec", QPalette.ColorRole.Button: "#2a2a2d",
             QPalette.ColorRole.ButtonText: "#ececec", QPalette.ColorRole.BrightText: "#ffffff", QPalette.ColorRole.Highlight: "#5a5a60",
             QPalette.ColorRole.HighlightedText: "#ffffff", QPalette.ColorRole.Light: "#3a3a3e", QPalette.ColorRole.Midlight: "#303034",
             QPalette.ColorRole.Mid: "#232326", QPalette.ColorRole.Dark: "#121212", QPalette.ColorRole.Shadow: "#000000",
             QPalette.ColorRole.Link: "#d0d0d0"}
    for role, c in roles.items():
        p.setColor(role, QColor(c))
    for role in (QPalette.ColorRole.WindowText, QPalette.ColorRole.Text, QPalette.ColorRole.ButtonText):
        p.setColor(QPalette.ColorGroup.Disabled, role, QColor("#6c6c70"))
    p.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Button, QColor("#1f1f22"))
    return p


def create_app(argv: list[str]) -> App:
    configure_qt()
    qt = QGuiApplication(argv)
    qt.setApplicationName("Coastline")
    qt.setOrganizationName("Coastline")
    qt.styleHints().setColorScheme(Qt.ColorScheme.Dark)
    qt.setPalette(dark_palette())
    if sys.platform != "darwin":  # the Mac bundle has its own icon; Windows and Linux take it from here
        from PySide6.QtGui import QIcon
        qt.setWindowIcon(QIcon(str(Path(__file__).resolve().parent / "ui" / "coastline.ico")))
    if sys.platform == "win32":
        # The taskbar groups and labels windows by app ID: without one it shows Python's icon.
        import ctypes
        try:
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("Coastline.Coastline")
        except (AttributeError, OSError):
            pass
    root = AppRoot()
    backend = root.workspace
    qml = QQmlApplicationEngine()
    from .ui.symbols import SymbolProvider
    qml.addImageProvider("sf", SymbolProvider())
    from .ui.thumbnails import ThumbnailProvider
    qml.addImageProvider("thumb", ThumbnailProvider())
    qml.setInitialProperties({"app": root})
    qml.load(QUrl.fromLocalFile(str(paths.APP_DIR / "qml" / "Main.qml")))
    roots = qml.rootObjects()
    if not roots:
        raise RuntimeError("The main window failed to load (see the QML errors above).")
    from .ui import window_chrome
    window_chrome.apply(roots[0])
    return App(qt, backend, root, qml, roots[0])
