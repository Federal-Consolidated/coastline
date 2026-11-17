"""Builds the app's C++ kernels (coastline_app/_kernels) for this platform's Python.

    uv run --group dev python scripts/build_native.py      (from app/)

Uses setuptools' compiler setup, so the same script works with clang on macOS and MSVC on
Windows. Rerun after editing native/src/*.cpp.
"""

from __future__ import annotations

import sysconfig
import shutil
import sys
import tempfile
from pathlib import Path

import pybind11
from setuptools import Distribution, Extension
from setuptools.command.build_ext import build_ext

APP = Path(__file__).resolve().parent.parent


def main() -> None:
    windows = sys.platform == "win32"
    ext = Extension(
        "coastline_app._kernels",
        sources=[str(APP / "native" / "src" / "kernels.cpp")],
        include_dirs=[pybind11.get_include()],
        language="c++",
        extra_compile_args=["/O2", "/std:c++17", "/EHsc", "/D_USE_MATH_DEFINES"] if windows else ["-O2", "-std=c++17", "-fvisibility=hidden"],
    )
    with tempfile.TemporaryDirectory() as tmp:
        dist = Distribution({"name": "coastline-kernels", "ext_modules": [ext]})
        cmd = build_ext(dist)
        cmd.build_lib = tmp
        cmd.build_temp = str(Path(tmp) / "build")
        cmd.ensure_finalized()
        cmd.run()
        # The extension module itself (.so or .pyd), not MSVC's .lib/.exp by-products.
        suffix = sysconfig.get_config_var("EXT_SUFFIX") or (".pyd" if sys.platform == "win32" else ".so")
        built = next(Path(tmp).rglob("_kernels*" + suffix))
        target = APP / "coastline_app" / built.name
        shutil.copy2(built, target)
    print(f"built {target.relative_to(APP)}")


if __name__ == "__main__":
    main()
