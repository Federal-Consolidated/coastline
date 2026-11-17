"""Coastline desktop app: Qt Quick screens, a QRhi 3D viewport and the Python engine.

Layout:
    mill/             machine control (GRBL serial link, sessions, programs)
    core/             planning, feeds, G-code, inventory and the engine client (no Qt)
    paths.py          where the engine and its interpreter are, per platform
    backend.py        the app state the screens bind to (no UI code)
    viewport/         the 3D view (QRhi: Metal on macOS, Direct3D on Windows)
    qml/              the screens
"""

__version__ = "0.1.0"
