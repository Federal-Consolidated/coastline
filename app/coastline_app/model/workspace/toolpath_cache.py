"""Toolpaths from earlier runs, kept on disk (the same request to the engine gives the same
result), and the in-memory cache of the last few dozen operations. Port of
Model/ToolpathCache.swift. Stored in its own folder and format (not shared with the Mac app)."""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import threading
from pathlib import Path

import numpy as np

from ... import paths
from ...core.plan.holding_tabs import PlacedTab
from ...core.post.toolpath import OperationToolpath, moves_from_array, moves_to_array
from ...core.storage import application_support

VERSION = 1
SAME_ID = "00000000-0000-0000-0000-000000000001"  # stands in for an operation's id in the key
LIMIT = 1_500_000_000


def directory() -> Path:
    return application_support() / "ToolpathCachePy"


def enabled() -> bool:
    return "COASTLINE_NO_CACHE" not in os.environ


def _file(key: str) -> Path:
    return directory() / (hashlib.sha256(key.encode()).hexdigest() + ".toolpaths")


def has(key: str) -> bool:
    return enabled() and _file(key).exists()


def load(key: str):
    if not enabled():
        return None
    f = _file(key)
    try:
        d = json.loads(gzip.decompress(f.read_bytes()))
        if d.get("version") != VERSION:
            return None
        out = []
        for p in d["paths"]:
            rows = np.frombuffer(bytes.fromhex(p["moves"]), "<f4").astype(float).reshape(-1, 8)
            out.append(OperationToolpath(p["operationID"], moves_from_array(rows), list(p["warnings"]), list(p["notes"]), p.get("minStickout")))
        tabs = [PlacedTab(tuple(t["centre"]), tuple(t["normal"]), [tuple(c) for c in t["corners"]]) for t in d["tabs"]]
        os.utime(f)  # read: recent again
        return out, tabs
    except (OSError, ValueError, KeyError, TypeError):
        return None


def store(key: str, value) -> None:
    if not enabled():
        return
    paths_, tabs = value
    d = {"version": VERSION,
         "paths": [{"operationID": p.operation_id, "moves": moves_to_array(p.moves).astype("<f4").tobytes().hex(),
                    "warnings": p.warnings, "notes": p.notes, "minStickout": p.min_stickout} for p in paths_],
         "tabs": [{"centre": list(t.centre), "normal": list(t.normal), "corners": [list(c) for c in t.corners]} for t in tabs]}
    try:
        directory().mkdir(parents=True, exist_ok=True)
        f = _file(key)
        tmp = f.with_suffix(".tmp")
        tmp.write_bytes(gzip.compress(json.dumps(d).encode(), 3))
        tmp.replace(f)
        prune()
    except OSError:
        pass


def prune() -> None:
    """Keeps the cache under its limit: the entries not read for longest go first."""
    try:
        entries = [(p, p.stat()) for p in directory().iterdir()]
    except OSError:
        return
    total = sum(s.st_size for _, s in entries)
    if total <= LIMIT:
        return
    for p, s in sorted(entries, key=lambda e: e[1].st_mtime):
        if total <= LIMIT * 8 // 10:
            break
        try:
            p.unlink()
            total -= s.st_size
        except OSError:
            pass


_engine_fingerprint: str | None = None


def engine_fingerprint() -> str:
    """A change to any of the engine's files makes every entry stale."""
    global _engine_fingerprint
    if _engine_fingerprint is None:
        parts = []
        root = paths.ENGINE_DIR / "coastline_engine"
        for f in sorted(root.rglob("*")):
            if f.suffix in (".py", ".so", ".pyd", ".cpp", ".hpp") and "__pycache__" not in f.parts:
                st = f.stat()
                parts.append(f"{f}|{st.st_size}|{st.st_mtime}")
        _engine_fingerprint = hashlib.sha256("\n".join(sorted(parts)).encode()).hexdigest()
    return _engine_fingerprint


_fingerprints: dict[str, str] = {}
_lock = threading.Lock()


def file_fingerprint(path) -> str:
    """A fingerprint of a part file's contents (hashed once per file and modification date)."""
    p = Path(path)
    try:
        k = f"{p}|{p.stat().st_mtime}"
    except OSError:
        return str(p)
    with _lock:
        hit = _fingerprints.get(k)
    if hit is not None:
        return hit
    try:
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
    except OSError:
        digest = str(p)
    with _lock:
        _fingerprints[k] = digest
    return digest
