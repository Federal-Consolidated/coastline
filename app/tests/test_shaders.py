import json
import sys
from pathlib import Path

from PySide6.QtGui import QShader, QShaderKey, QShaderVersion

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import bake_shaders  # noqa: E402


def test_baked_shaders_match_their_sources():
    baked = json.loads((bake_shaders.SHADERS / "baked.json").read_text())
    for stage in bake_shaders.STAGES:
        assert baked.get(stage) == bake_shaders.source_hash(stage), (
            f"{stage} changed since it was baked: run `uv run --group shaders python scripts/bake_shaders.py`")


def test_every_backend_has_a_shader_variant():
    wanted = {
        "Metal (macOS)": (QShader.Source.MslShader, 12),
        "Direct3D 11/12 (Windows)": (QShader.Source.HlslShader, 50),
        "Vulkan": (QShader.Source.SpirvShader, 100),
        "OpenGL": (QShader.Source.GlslShader, 330),
    }
    for stage in bake_shaders.STAGES:
        shader = QShader.fromSerialized((bake_shaders.SHADERS / f"{stage}.qsb").read_bytes())
        assert shader.isValid(), stage
        for name, (source, version) in wanted.items():
            code = shader.shader(QShaderKey(source, QShaderVersion(version))).shader()
            assert len(code) > 0, f"{stage}: no {name} variant"
