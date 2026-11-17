"""Where things are on disk, for Windows and macOS.

During development the repository holds the engine (`engine/`) and its uv environment
(`engine/.venv`). A packaged app (scripts/package.py) keeps the same layout, with one bundled
interpreter in `python/` for both the app and the engine:

    <root>/python/   app/coastline_app/   engine/coastline_engine/   resources/
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent
REPO_ROOT = APP_DIR.parent.parent
ENGINE_DIR = REPO_ROOT / "engine"
SAMPLES_DIR = REPO_ROOT / "resources" / "samples"


def venv_python(venv: Path) -> Path:
    """The interpreter of a virtual environment (`Scripts\\python.exe` on Windows)."""
    if sys.platform == "win32":
        return venv / "Scripts" / "python.exe"
    return venv / "bin" / "python"


BUNDLED_PYTHON = REPO_ROOT / "python"
PACKAGED = BUNDLED_PYTHON.is_dir() and not (ENGINE_DIR / ".venv").exists()


def bundled_python() -> Path:
    """The packaged app's own interpreter."""
    if sys.platform == "win32":
        return BUNDLED_PYTHON / "python.exe"
    return BUNDLED_PYTHON / "bin" / "python3.11"


def engine_python() -> Path:
    """The engine's interpreter. `COASTLINE_ENGINE_PYTHON` overrides it."""
    override = os.environ.get("COASTLINE_ENGINE_PYTHON")
    if override:
        return Path(override)
    if PACKAGED:
        return bundled_python()
    return venv_python(ENGINE_DIR / ".venv")
