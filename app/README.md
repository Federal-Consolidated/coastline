# Coastline (Qt)

The cross-platform Coastline app for Windows and macOS, replacing the Swift app step by step.
Built with Qt 6 (PySide6): Qt Quick screens, a QRhi 3D view (Metal on macOS,
Direct3D 11 on Windows) and the existing Python geometry engine in `../engine`.

**Status: step 1.** Opens a STEP, IGES or Rhino part through the engine and shows it in
3D. The Swift app in `../Coastline` is still the shipping app.

## Run

Needs [uv](https://docs.astral.sh/uv/). Set up the engine once (`cd ../engine && uv sync`), then:

```bash
cd app
uv run coastline                      # the app
uv run coastline ../resources/samples/dfm_coupon.step
uv run pytest -q                      # tests (engine, camera, shaders, headless window)
uv run python scripts/bench_viewport.py --segments 3000000   # 3D speed check (opens a window)
```

These commands are the same on Windows (PowerShell). On Windows the engine's interpreter is
`engine\.venv\Scripts\python.exe`. `COASTLINE_ENGINE_PYTHON` overrides it on either system.

| Input | Action |
|---|---|
| Drag | Orbit |
| Right-, middle- or Alt-drag; two-finger scroll (Mac) | Pan |
| Mouse wheel, pinch, Ctrl + scroll | Zoom |
| Double-click, **Fit** | Frame everything |

## Layout

| Path | What |
|---|---|
| `coastline_app/backend.py` | App state the screens bind to. No UI code. |
| `coastline_app/engine_client.py` | Talks to the engine process (same protocol as the Swift app). |
| `coastline_app/viewport/` | The 3D view: camera, scene, QRhi renderer, shaders. |
| `coastline_app/qml/` | The screens. |
| `coastline_app/application.py` | Creates the Qt app and window (app, tests and benchmark share it). |
| `scripts/bake_shaders.py` | Compiles the shaders for every graphics backend. |
| `scripts/bench_viewport.py` | Real-GPU frame-rate check with a large toolpath. |

## Rules

- **Logic stays out of the screens.** QML shows state and calls slots. Everything else goes in
  Python modules that run and test without a window.
- **The engine stays a separate process.** A crash in a CAD library cannot close the app, and
  long jobs never freeze the screens.
- **Shaders:** edit the `.vert` and `.frag` files, then run
  `uv run --group shaders python scripts/bake_shaders.py`. Commit the `.qsb` files.
  A test fails if a baked shader is out of date.
- **Drawing runs on the UI thread** (`QSG_RENDER_LOOP=basic`, set in `application.py`). The
  renderer is Python, so a separate render thread can deadlock on Python's lock.
