"""Bakes the viewport's GLSL shaders into .qsb packs for every graphics backend.

    uv run --group shaders python scripts/bake_shaders.py      (from app/)

One Vulkan-style GLSL source per stage becomes a .qsb with SPIR-V, HLSL (Direct3D 11/12),
MSL (Metal) and GLSL (OpenGL) variants, using Qt's own `qsb` tool from the PySide6 wheel.
The .qsb files are committed, so running the app never needs this tool. Rerun it after
editing a shader: shaders/baked.json records a hash of each baked source, and
tests/test_shaders.py fails while a .qsb is out of date.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import PySide6

SHADERS = Path(__file__).resolve().parent.parent / "coastline_app" / "viewport" / "shaders"
STAGES = ("mesh.vert", "mesh.frag", "line.vert", "line.frag")
INCLUDE = "//#include common.glsl"


def qsb_tool() -> Path:
    base = Path(PySide6.__file__).parent
    for name in ("qsb.exe", "qsb", "Qt/libexec/qsb", "Qt/bin/qsb"):
        if (base / name).exists():
            return base / name
    raise SystemExit("qsb not found in the PySide6 package")


def expand(source: Path) -> str:
    """qsb has no #include: paste common.glsl where a stage asks for it."""
    common = (SHADERS / "common.glsl").read_text()
    return source.read_text().replace(INCLUDE, common)


def source_hash(stage: str) -> str:
    return hashlib.sha256(expand(SHADERS / stage).encode()).hexdigest()


def bake(stage: str, tool: Path) -> None:
    source = SHADERS / stage
    with tempfile.TemporaryDirectory() as tmp:
        expanded = Path(tmp) / stage
        expanded.write_text(expand(source))
        out = SHADERS / f"{stage}.qsb"
        cmd = [str(tool), "--glsl", "330,300 es", "--hlsl", "50", "--msl", "12", "-o", str(out), str(expanded)]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"{stage}: qsb failed\n{result.stdout}{result.stderr}")
    print(f"baked {out.name}")


def main() -> None:
    tool = qsb_tool()
    for stage in STAGES:
        bake(stage, tool)
    record = {stage: source_hash(stage) for stage in STAGES}
    (SHADERS / "baked.json").write_text(json.dumps(record, indent=2) + "\n")


if __name__ == "__main__":
    main()
