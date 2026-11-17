"""Builds coastline_engine/_native (pybind11 C++ kernels) for this platform's Python: clang on
macOS, MSVC on Windows (setuptools picks the compiler). native/build.sh does the same on a Mac.

    ../app/.venv/bin/python native/build.py      (from engine/; any Python 3.11 with pybind11 and
                                                  setuptools, e.g. the app's dev environment)
"""

from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

import pybind11
from setuptools import Distribution, Extension
from setuptools.command.build_ext import build_ext

ENGINE = Path(__file__).resolve().parent.parent
TP = ENGINE / "native" / "third_party"


def main() -> None:
    windows = sys.platform == "win32"
    sources = [ENGINE / "native" / "src" / "module.cpp", TP / "freecad_adaptive" / "Adaptive.cpp", TP / "freecad_adaptive" / "clipper.cpp",
               *sorted((TP / "clipper2" / "src").glob("*.cpp"))]
    flags = (["/O2", "/std:c++20", "/EHsc", "/DUSINGZ", "/D_USE_MATH_DEFINES", "/bigobj", "/w"] if windows
             else ["-O2", "-std=c++20", "-fvisibility=hidden", "-w", "-DUSINGZ"])
    ext = Extension("coastline_engine._native", sources=[str(s) for s in sources],
                    include_dirs=[pybind11.get_include(), str(TP / "freecad_adaptive"), str(TP / "clipper2" / "include")],
                    language="c++", extra_compile_args=flags)
    with tempfile.TemporaryDirectory() as tmp:
        dist = Distribution({"name": "coastline-engine-native", "ext_modules": [ext]})
        cmd = build_ext(dist)
        cmd.build_lib = tmp
        cmd.build_temp = str(Path(tmp) / "build")
        cmd.ensure_finalized()
        cmd.run()
        built = next(Path(tmp).rglob("_native*"))
        target = ENGINE / "coastline_engine" / built.name
        shutil.copy2(built, target)
    print(f"built {target.relative_to(ENGINE)}")


if __name__ == "__main__":
    main()
