"""Where Coastline keeps its files, per platform. On macOS these are the Swift app's folders,
so an existing inventory, projects and caches carry over."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def application_support() -> Path:
    """macOS ~/Library/Application Support/Coastline · Windows %APPDATA%\\Coastline ·
    Linux ~/.local/share/Coastline. `COASTLINE_DATA_DIR` overrides it (tests)."""
    override = os.environ.get("COASTLINE_DATA_DIR")
    if override:
        return Path(override)
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Coastline"
    if sys.platform == "win32":
        return Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming") / "Coastline"
    return Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "Coastline"


def caches() -> Path:
    """macOS ~/Library/Caches/Coastline · Windows %LOCALAPPDATA%\\Coastline\\Cache · Linux ~/.cache/Coastline."""
    override = os.environ.get("COASTLINE_CACHE_DIR")
    if override:
        return Path(override)
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "Coastline"
    if sys.platform == "win32":
        return Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local") / "Coastline" / "Cache"
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "Coastline"


def write_atomic(path: Path, data: bytes, backup: bool = False) -> None:
    """Writes atomically; with `backup`, keeps the previous version as `<name>.bak`."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if backup and path.exists():
        bak = path.with_name(path.name + ".bak")
        try:
            bak.unlink(missing_ok=True)
            bak.write_bytes(path.read_bytes())
        except OSError:
            pass
    tmp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    tmp.write_bytes(data)
    os.replace(tmp, path)
