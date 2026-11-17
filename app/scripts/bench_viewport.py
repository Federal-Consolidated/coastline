"""3D view smoothness check: a real part from the engine plus a large synthetic toolpath.

    uv run python scripts/bench_viewport.py [--segments 3000000] [--part ../resources/samples/pendant.step]
                                            [--seconds 5] [--shot /tmp/coastline-bench.png]

Opens the app window, orbits the camera every frame, and reports the frame rate, the slowest
frames and how long the toolpath took to reach the GPU. Closes itself. Run it on each platform
(macOS: Metal, Windows: Direct3D 11) after renderer changes.
"""

from __future__ import annotations

import argparse
import faulthandler
import math
import statistics
import sys
import time
from pathlib import Path

import numpy as np
from PySide6.QtCore import Qt, QTimer

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from coastline_app import paths  # noqa: E402
from coastline_app.application import create_app  # noqa: E402
from coastline_app.core.engine.client import EngineClient  # noqa: E402
from coastline_app.viewport import SEGMENT_DTYPE, PathColor  # noqa: E402


def synthetic_toolpath(lo, hi, segments: int) -> np.ndarray:
    """Dense zig-zag layers over the box (adaptive-roughing-like density), every 200th move a
    dashed rapid."""
    lo, hi = np.asarray(lo, np.float32), np.asarray(hi, np.float32)
    points = segments + 1
    t = np.arange(points, dtype=np.float64)
    layers = 40
    per_layer = points / layers
    layer = np.floor(t / per_layer)
    u = (t % per_layer) / per_layer
    rows = 120
    row = np.floor(u * rows)
    v = (u * rows) % 1.0
    v = np.where(row % 2 == 0, v, 1 - v)  # zig-zag
    wobble = 0.03 * np.sin(t * 0.37)
    pts = np.empty((points, 3), np.float32)
    pts[:, 0] = lo[0] + (hi[0] - lo[0]) * np.clip(v + wobble, 0, 1)
    pts[:, 1] = lo[1] + (hi[1] - lo[1]) * (row + 0.5) / rows
    pts[:, 2] = hi[2] - (hi[2] - lo[2]) * layer / layers
    out = np.empty(segments, SEGMENT_DTYPE)
    out["a"], out["b"] = pts[:-1], pts[1:]
    colors = np.tile(np.array(PathColor.cut, np.uint8), (segments, 1))
    colors[::200] = PathColor.rapid
    out["color_a"] = out["color_b"] = colors
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--segments", type=int, default=3_000_000)
    ap.add_argument("--part", type=Path, default=paths.SAMPLES_DIR / "pendant.step")
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--shot", type=Path, default=Path("/tmp/coastline-bench.png"))
    args = ap.parse_args()
    faulthandler.dump_traceback_later(args.seconds + 90, exit=True)  # never hang a CI run

    coastline = create_app(sys.argv[:1])
    app, backend, window, view = coastline.qt, coastline.backend, coastline.window, coastline.viewport

    t0 = time.perf_counter()
    engine = EngineClient()
    engine.ping()
    t_engine = time.perf_counter() - t0
    t0 = time.perf_counter()
    mesh = engine.import_part(args.part.resolve())
    t_import = time.perf_counter() - t0
    backend._engine = engine
    backend._on_part_loaded(mesh, args.part.name)

    t0 = time.perf_counter()
    lo, hi = np.array(mesh.bounds_min), np.array(mesh.bounds_max)
    margin = 0.15 * (hi - lo)
    segments = synthetic_toolpath(lo - margin * [1, 1, 0], hi + margin * [1, 1, 0.2], args.segments)
    t_build = time.perf_counter() - t0
    t_lines = time.perf_counter()
    backend.scene.set_lines("toolpath", segments)
    view.frameAll()

    swaps: list[float] = []
    state = {"first_frame": None, "measure_from": None, "running": True}

    def on_frame() -> None:
        # One camera step per presented frame, so every frame is a fresh view.
        now = time.perf_counter()
        swaps.append(now)
        if state["first_frame"] is None and now > t_lines:
            state["first_frame"] = now - t_lines
            state["measure_from"] = now + 1.0  # one second of warm-up
        if state["running"]:
            view.camera.yaw += 0.02
            view.camera.pitch = 0.55 + 0.25 * math.sin(now)
            view.update()

    window.frameSwapped.connect(on_frame)
    view.update()

    def finish() -> None:
        state["running"] = False
        image = window.grabWindow()
        image.save(str(args.shot))
        app.quit()

    QTimer.singleShot(int((args.seconds + 4) * 1000), finish)
    app.exec()
    engine.shutdown()

    start = state["measure_from"] or 0
    end = start + args.seconds
    times = [t for t in swaps if start <= t <= end]
    gaps = [(b - a) * 1000 for a, b in zip(times, times[1:])]
    api = window.rendererInterface().graphicsApi().name
    print(f"graphics API        {api}")
    print(f"engine start        {t_engine:.2f} s")
    print(f"STEP import         {t_import:.2f} s  ({mesh.triangle_count:,} triangles)")
    print(f"toolpath            {args.segments:,} segments, built in {t_build:.2f} s")
    if state["first_frame"] is not None:
        print(f"first frame with it {state['first_frame']:.2f} s (upload to GPU)")
    if gaps:
        gaps.sort()
        p95 = gaps[int(len(gaps) * 0.95) - 1] if len(gaps) >= 20 else gaps[-1]
        print(f"frames              {len(gaps)} in {args.seconds:.1f} s → {len(gaps) / args.seconds:.1f} fps")
        print(f"frame time          median {statistics.median(gaps):.1f} ms · 95% under {p95:.1f} ms · worst {gaps[-1]:.1f} ms")
    else:
        print("frames              none measured")
    print(f"screenshot          {args.shot}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
