"""Packages the Qt app with everything it needs, for the system it runs on:

    app/.venv/bin/python scripts/package.py          (from app/; Windows: .venv\\Scripts\\python)

Needs `uv sync` done in app/ and engine/ (with uv's managed CPython 3.11, UV_PYTHON_PREFERENCE=
only-managed: it is relocatable), both C++ kernels built, and the shaders baked.

Makes build/qt/Coastline/ laid out like the repository, with one interpreter for the app and the
engine (coastline_app/paths.py finds it):

    python/  app/coastline_app/  engine/coastline_engine/  resources/

then, on macOS, build/qt/Coastline Qt.app (that folder inside a small app bundle) and, on
Windows, the folder plus `Coastline.cmd`; installer/coastline.iss (Inno Setup) turns it into
Coastline-Setup.exe with Start-menu and desktop shortcuts.
"""

from __future__ import annotations

import compileall
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
ROOT = APP.parent
OUT = ROOT / "build" / "qt"
WINDOWS = sys.platform == "win32"
MAC = sys.platform == "darwin"

# Development tools and modules the app never loads.
SKIP = re.compile(r"^(_pytest|pytest|pluggy|iniconfig|pybind11|setuptools|_distutils_hack|pip|_virtualenv|__editable__|_editable_impl_|"
                  r"matplotlib|mpl_toolkits|coastline_engine|coastline_app|coastline_(app|engine).*\.pth|.*\.dist-info$)", re.I)
KEEP_DIST_INFO = re.compile(r"^(pyside6|shiboken6|numpy)", re.I)  # Qt reads its own metadata


def venv_home(venv: Path) -> Path:
    """uv's managed CPython the venv was made from."""
    cfg = (venv / "pyvenv.cfg").read_text()
    home = Path(re.search(r"^home = (.+)$", cfg, re.M).group(1).strip())
    return home if WINDOWS else home.parent


def site_packages(base: Path) -> Path:
    return base / "Lib" / "site-packages" if WINDOWS else base / "lib" / "python3.11" / "site-packages"


def copy_tree(src: Path, dst: Path, skip=lambda p: False) -> None:
    for item in src.iterdir():
        if item.name == "__pycache__" or skip(item):
            continue
        target = dst / item.name
        if item.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            copy_tree(item, target)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, target)


def skip_package(p: Path) -> bool:
    if p.name.endswith(".dist-info"):
        return not KEEP_DIST_INFO.match(p.name)
    if p.name.startswith("vtk") and MAC:
        return True  # only the libraries OCP loads are copied (below)
    return bool(SKIP.match(p.name))


def mac_vtk(site_src: Path, site_dst: Path) -> None:
    """Of VTK only the libraries OCP's binaries load, directly or through each other."""
    libs = site_src / "vtkmodules" / ".dylibs"
    if not libs.is_dir():
        return
    out = subprocess.run([sys.executable, str(ROOT / "scripts" / "support" / "linked_dylibs.py"), str(site_dst / "OCP"), str(libs)],
                         capture_output=True, text=True, check=True).stdout
    dst = site_dst / "vtkmodules" / ".dylibs"
    dst.mkdir(parents=True, exist_ok=True)
    for name in out.split():
        shutil.copy2(libs / name, dst / name)


QT_UNUSED = ["Assistant.app", "Designer.app", "Linguist.app", "assistant.exe", "designer.exe", "linguist.exe", "qmlls", "qmlformat",
             "qmllint", "lrelease", "lupdate", "balsam", "balsamui", "svgtoqml", "qmlls.exe", "qmlformat.exe", "qmllint.exe",
             "lrelease.exe", "lupdate.exe", "include", "typesystems", "glue", "doc", "scripts", "Qt/metatypes", "Qt/translations",
             "translations", "metatypes"]


def prune_qt(pyside: Path) -> None:
    """Qt's developer tools, headers and translations: not used at run time."""
    for name in QT_UNUSED:
        p = pyside / name
        if p.is_dir():
            shutil.rmtree(p, ignore_errors=True)
        elif p.exists():
            p.unlink()


def main() -> None:
    for need, why in ((APP / ".venv", "run `uv sync` in app/"), (ROOT / "engine" / ".venv", "run `uv sync` in engine/")):
        if not need.is_dir():
            sys.exit(f"Missing {need}: {why}.")
    if not list((APP / "coastline_app").glob("_kernels*")):
        sys.exit("Build the app's kernels first: scripts/build_native.py")
    if not list((ROOT / "engine" / "coastline_engine").glob("_native*")):
        sys.exit("Build the engine's kernels first: engine/native/build.py")
    if not list((APP / "coastline_app" / "viewport" / "shaders").glob("*.qsb")):
        sys.exit("Bake the shaders first: scripts/bake_shaders.py")

    shutil.rmtree(OUT, ignore_errors=True)
    bundle = OUT / "Coastline"
    print("interpreter…")
    py_src = venv_home(APP / ".venv")
    shutil.copytree(py_src, bundle / "python", ignore=shutil.ignore_patterns("__pycache__", "EXTERNALLY-MANAGED", "test", "tests", "idlelib", "tkinter",
                                                                            "turtledemo", "ensurepip"))
    site = site_packages(bundle / "python")
    print("packages…")
    # The app's runtime packages only (its venv also has the dev and shader tools).
    reqs = subprocess.run(["uv", "export", "--frozen", "--no-dev", "--no-hashes", "--no-emit-project"], cwd=APP,
                          capture_output=True, text=True, check=True).stdout
    req_file = OUT / "requirements.txt"
    req_file.write_text(reqs)
    subprocess.run(["uv", "pip", "install", "--quiet", "--python", str(py_src / ("python.exe" if WINDOWS else "bin/python3.11")),
                    "--target", str(site), "-r", str(req_file)], check=True)
    copy_tree(site_packages(ROOT / "engine" / ".venv"), site, skip_package)
    prune_qt(site / "PySide6")
    if MAC:
        mac_vtk(site_packages(ROOT / "engine" / ".venv"), site)
    print("app, engine and resources…")
    copy_tree(APP / "coastline_app", bundle / "app" / "coastline_app")
    copy_tree(ROOT / "engine" / "coastline_engine", bundle / "engine" / "coastline_engine")
    copy_tree(ROOT / "resources", bundle / "resources", lambda p: p.name in (".DS_Store", "machine-profile-sources"))
    compileall.compile_dir(str(bundle), quiet=1, workers=0)

    if WINDOWS:
        (bundle / "Coastline.cmd").write_text('@echo off\r\ncd /d "%~dp0app"\r\nstart "" "%~dp0python\\pythonw.exe" -m coastline_app %*\r\n')
        print(f"made {bundle}")
        iscc = shutil.which("iscc") or r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
        if Path(iscc).exists():
            version = os.environ.get("COASTLINE_VERSION", "0.1")  # the release workflow passes 0.<commit count>
            subprocess.run([iscc, f"/DSource={bundle}", f"/DOutputDir={OUT}", f"/DAppVersion={version}",
                            str(APP / "installer" / "coastline.iss")], check=True)
            print(f"made {OUT / 'Coastline-Setup.exe'}")
        else:
            print("Inno Setup not found: the folder is ready; install Inno Setup 6 to make the installer.")
    elif MAC:
        app = OUT / "Coastline Qt.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "Resources").mkdir(parents=True)
        shutil.move(str(bundle), app / "Contents" / "Resources" / "Coastline")
        launcher = app / "Contents" / "MacOS" / "Coastline"
        launcher.write_text('#!/bin/sh\nR="$(cd "$(dirname "$0")/../Resources/Coastline" && pwd)"\ncd "$R/app"\n'
                            'exec "$R/python/bin/python3.11" -m coastline_app "$@"\n')
        launcher.chmod(0o755)
        icns = ROOT / "build" / "Coastline.icns"
        if icns.exists():
            shutil.copy2(icns, app / "Contents" / "Resources" / "Coastline.icns")
        version = subprocess.run(["git", "rev-list", "--count", "HEAD"], capture_output=True, text=True, cwd=ROOT).stdout.strip() or "1"
        (app / "Contents" / "Info.plist").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Coastline Qt</string>
  <key>CFBundleDisplayName</key><string>Coastline Qt</string>
  <key>CFBundleIdentifier</key><string>app.coastline.qt</string>
  <key>CFBundleExecutable</key><string>Coastline</string>
  <key>CFBundleIconFile</key><string>Coastline</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.{version}</string>
  <key>CFBundleVersion</key><string>{version}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
""")
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], capture_output=True)
        print(f"made {app}")
    else:
        print(f"made {bundle} (run: python/bin/python3.11 -m coastline_app from app/)")


if __name__ == "__main__":
    main()
