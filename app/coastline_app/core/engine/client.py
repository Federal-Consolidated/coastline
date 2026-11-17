"""Talks to the geometry engine (`python -m coastline_engine.server`) over its stdio pipes.

Frame layout, both directions (see engine/coastline_engine/rpc.py):
    u32 big-endian JSON length · JSON header · blobs (lengths listed in header["blobs"])
Blobs carry little-endian float32/uint32 arrays (meshes, toolpaths).

The engine is a separate process, so a crash in a native CAD library cannot take the app
down, and long computations never block the screens. Calls are serialised: the engine is
single-threaded and answers in order. Call from a worker thread, never the UI thread.
"""

from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from ... import paths
from ..geometry import Vec3
from ..mesh import MeshData


class EngineError(Exception):
    def __init__(self, type: str, message: str):
        super().__init__(f"{type}: {message}")
        self.type = type
        self.message = message


class _LogTail:
    """The engine's recent stderr (last 64 KB), drained continuously: an unread pipe fills
    up and blocks the engine mid-computation."""

    LIMIT = 65_536

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._data = bytearray()

    def append(self, chunk: bytes) -> None:
        with self._lock:
            self._data += chunk
            if len(self._data) > self.LIMIT:
                del self._data[: len(self._data) - self.LIMIT]

    @property
    def text(self) -> str:
        with self._lock:
            return self._data.decode("utf-8", "replace")


class EngineClient:
    def __init__(self, python: Path | None = None, engine_dir: Path | None = None) -> None:
        python = python or paths.engine_python()
        engine_dir = engine_dir or paths.ENGINE_DIR
        if not python.exists():
            raise EngineError("EngineMissing", f"No engine interpreter at {python}. Run `uv sync` in engine/.")
        env = dict(os.environ, PYTHONUNBUFFERED="1")
        flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0  # no console window
        self._process = subprocess.Popen(
            [str(python), "-m", "coastline_engine.server"],
            cwd=engine_dir,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            creationflags=flags,
        )
        self._log = _LogTail()
        self._lock = threading.Lock()
        self._next_id = 1
        threading.Thread(target=self._drain_stderr, name="engine-stderr", daemon=True).start()

    def _drain_stderr(self) -> None:
        stream = self._process.stderr
        while chunk := stream.read1(65_536):
            self._log.append(chunk)

    @property
    def log(self) -> str:
        return self._log.text

    def is_running(self) -> bool:
        return self._process.poll() is None

    def call(self, method: str, params: dict[str, Any] | None = None,
             blobs: list[bytes] = ()) -> tuple[dict[str, Any], list[bytes]]:
        """Sends one request and waits for its response: (result, blobs)."""
        with self._lock:
            rid = self._next_id
            self._next_id += 1
            header = {"id": rid, "method": method, "params": params or {}, "blobs": [len(b) for b in blobs]}
            data = json.dumps(header, separators=(",", ":")).encode()
            try:
                out = self._process.stdin
                out.write(struct.pack(">I", len(data)))
                out.write(data)
                for b in blobs:
                    out.write(b)
                out.flush()
            except (BrokenPipeError, OSError, ValueError):
                raise self._exited() from None
            (length,) = struct.unpack(">I", self._read_exactly(4))
            response = json.loads(self._read_exactly(length))
            out_blobs = [self._read_exactly(n) for n in response.get("blobs", [])]
        if "error" in response:
            error = response["error"] or {}
            raise EngineError(error.get("type", "Error"), error.get("message", ""))
        return response.get("result") or {}, out_blobs

    def _read_exactly(self, count: int) -> bytes:
        stream = self._process.stdout
        parts, got = [], 0
        while got < count:
            chunk = stream.read(count - got)
            if not chunk:
                raise self._exited()
            parts.append(chunk)
            got += len(chunk)
        return b"".join(parts)

    def _exited(self) -> EngineError:
        return EngineError("EngineExited", "The engine stopped responding.\n" + self.log[-2000:])

    # ------------------------------------------------------------------ requests

    def ping(self) -> dict[str, Any]:
        return self.call("ping")[0]

    def import_part(self, path: str | Path, linear_deflection: float = 0.01) -> MeshData:
        result, blobs = self.call("import_part", {"path": str(path), "linear_deflection": linear_deflection})
        return mesh_from_blobs(result, blobs, part_id=result.get("part_id", ""))

    def fixture_assembly(self, part_id: str, definition) -> list:
        """Exact STEP occurrences using an audited mechanical definition."""
        from .. import codable
        from ..plan.fixture_assembly import FixtureAssemblyPart
        definition.validate()
        result, blobs = self.call("fixture_assembly", {"part_id": part_id, "definition": codable.to_json(definition)})
        meta = result.get("parts") or []
        if not meta or len(blobs) != len(meta) * 3:
            raise EngineError("Fixture", "The vetted fixture did not return its exact CAD bodies.")
        out = []
        for k, item in enumerate(meta):
            lo, hi = item.get("bounds_min"), item.get("bounds_max")
            ok = (isinstance(item.get("component_id"), str) and isinstance(item.get("entity_path"), str)
                  and isinstance(item.get("solid_index"), int) and item["solid_index"] >= 0
                  and isinstance(lo, list) and len(lo) == 3 and isinstance(hi, list) and len(hi) == 3
                  and all(np.isfinite(v) for v in lo + hi) and isinstance(item.get("face_count"), int) and item["face_count"] > 0
                  and all(len(blobs[k * 3 + j]) % 4 == 0 for j in range(3)))
            if not ok:
                raise EngineError("Fixture", "The fixture engine returned invalid CAD body metadata.")
            mesh = _raw_mesh(blobs, k, part_id, _vec(lo), _vec(hi), True, item["face_count"])
            out.append(FixtureAssemblyPart(item["component_id"], item["entity_path"], item["solid_index"], mesh))
        return out

    def fixture_solids(self, part_id: str) -> list[MeshData]:
        result, blobs = self.call("fixture_solids", {"part_id": part_id})
        meta = result.get("solids") or []
        if not meta or len(blobs) != 3 * len(meta):
            raise EngineError("Fixture", "The fixture does not contain valid closed solids.")
        return [_raw_mesh(blobs, k, part_id, _vec(item.get("bounds_min")), _vec(item.get("bounds_max")), True,
                          int(item.get("face_count", 0) or 0)) for k, item in enumerate(meta)]

    def machine_model(self, step: str | Path) -> "MachineModel":
        """The machine assembly as display meshes grouped by motion axis (cached by the engine)."""
        result, blobs = self.call("machine_model", {"path": str(step)})
        parts = []
        for k, m in enumerate(result.get("parts") or []):
            c = m.get("color") or [0.3, 0.3, 0.3]
            parts.append(MachinePart(m.get("group", "static"), m.get("role", ""), tuple(float(v) for v in c), _raw_mesh(blobs, k)))
        nose = result.get("spindle_nose") or [0, 0, 0]
        pose = result.get("model_pose") or [-1.25, -146.5, -54.0]
        return MachineModel(parts, _vec(nose), float(result.get("table_top_x", 0) or 0), _vec(pose),
                            list(result.get("tslot_z") or [-53.5, -13.4]))

    def machine_profile_parts(self, manifest: str | Path, cache_directory: str | Path | None = None) -> list["MachinePart"]:
        """Geometry for a reviewed package, at its authored reference pose (component IDs are
        motion groups; the caller applies the definition's translations)."""
        params: dict[str, Any] = {"manifestPath": str(manifest)}
        if cache_directory is not None:
            params["cache_dir"] = str(cache_directory)
        result, blobs = self.call("machine_model", params)
        meta = result.get("parts") or []
        if not meta or len(blobs) != len(meta) * 3 or any(len(b) % 4 for b in blobs):
            raise EngineError("MachineDefinition", "The machine profile returned incomplete model geometry.")
        out = []
        for k, m in enumerate(meta):
            mesh = _raw_mesh(blobs, k)
            c = m.get("color")
            ok = (isinstance(m.get("group"), str) and m["group"] and isinstance(c, list) and len(c) == 3
                  and all(isinstance(v, (int, float)) and 0 <= v <= 1 for v in c) and len(mesh.vertices)
                  and len(mesh.normals) == len(mesh.vertices) and len(mesh.indices) and len(mesh.indices) % 3 == 0
                  and int(mesh.indices.max()) < len(mesh.vertices)
                  and np.all(np.isfinite(mesh.vertices)) and np.all(np.isfinite(mesh.normals)))
            if not ok:
                raise EngineError("MachineDefinition", "The machine profile returned invalid mesh data.")
            out.append(MachinePart(m["group"], m.get("role", ""), (float(c[0]), float(c[1]), float(c[2])), mesh))
        return out

    def face_info(self, part_id: str, point) -> "FaceInfo":
        """Describes the exact surface nearest `point` (part coordinates)."""
        result, _ = self.call("face_info", {"part_id": part_id, "point": [float(point[0]), float(point[1]), float(point[2])]})
        return FaceInfo.from_result(result)

    # ------------------------------------------------------------------ lifetime

    def shutdown(self, timeout: float = 5.0) -> None:
        """Closes the engine's input so it exits by itself; kills it if it does not."""
        try:
            self._process.stdin.close()
        except OSError:
            pass
        try:
            self._process.wait(timeout)
        except subprocess.TimeoutExpired:
            self._process.kill()
            self._process.wait()

    def terminate(self) -> None:
        """Stops the engine at once, even in the middle of a long call."""
        self._process.kill()

    def __enter__(self) -> EngineClient:
        return self

    def __exit__(self, *exc) -> None:
        self.shutdown()


def mesh_from_blobs(result: dict[str, Any], blobs: list[bytes], part_id: str = "") -> MeshData:
    if len(blobs) != 3 or any(len(b) % 4 for b in blobs):
        raise EngineError("Mesh", "The engine returned an invalid mesh.")
    vertices = np.frombuffer(blobs[0], "<f4").reshape(-1, 3)
    normals = np.frombuffer(blobs[1], "<f4").reshape(-1, 3)
    indices = np.frombuffer(blobs[2], "<u4")
    if len(normals) != len(vertices) or len(indices) % 3 or (len(indices) and indices.max() >= len(vertices)):
        raise EngineError("Mesh", "The engine returned an invalid mesh.")
    return MeshData(vertices=vertices, normals=normals, indices=indices,
                    bounds_min=_vec(result.get("bounds_min")), bounds_max=_vec(result.get("bounds_max")),
                    exact=bool(result.get("exact", False)), face_count=int(result.get("face_count", 0) or 0),
                    part_id=part_id, warnings=list(result.get("warnings", []) or []))


def _vec(a) -> Vec3:
    return Vec3(float(a[0]), float(a[1]), float(a[2])) if isinstance(a, list) and len(a) >= 3 else Vec3()


def _raw_mesh(blobs: list[bytes], k: int, part_id: str = "", lo=None, hi=None, exact: bool = False, faces: int = 0) -> MeshData:
    v = np.frombuffer(blobs[3 * k], "<f4").reshape(-1, 3)
    n = np.frombuffer(blobs[3 * k + 1], "<f4").reshape(-1, 3)
    t = np.frombuffer(blobs[3 * k + 2], "<u4")
    return MeshData(v, n, t, lo if lo is not None else Vec3(), hi if hi is not None else Vec3(), exact, faces, part_id)


def row_major(m) -> list[float]:
    """A 4×4 transform as the engine wants it: 16 numbers, row by row."""
    m = np.asarray(m, float)
    return [float(m[r, c]) for r in range(4) for c in range(4)]


@dataclass
class MachinePart:
    group: str  # authored component ID; legacy models use "static", "x", "y" or "z"
    role: str  # "enclosure", "aluminium", "steel", "motor", …
    color: tuple[float, float, float]  # linear RGB
    mesh: MeshData


@dataclass
class MachineModel:
    """The machine assembly for the viewport, in machine axes."""

    parts: list[MachinePart]
    spindle_nose: Vec3  # the collet nut face on the spindle axis, model coordinates
    table_top_x: float  # the table's top face (model X)
    model_pose: Vec3  # machine coordinates the assembly is modelled at
    t_slot_z: list[float] = field(default_factory=lambda: [-53.5, -13.4])


@dataclass
class FaceInfo:
    """What the engine found under a measuring click."""

    type: str  # plane, cylinder, cone, sphere, torus, freeform, edge, none
    distance: float | None = None
    normal: Vec3 | None = None
    radius: float | None = None
    axis: Vec3 | None = None
    min_radius_of_curvature: float | None = None
    recognised_from_nurbs: bool = False

    @staticmethod
    def from_result(d: dict) -> "FaceInfo":
        def v(k):
            a = d.get(k)
            return Vec3(float(a[0]), float(a[1]), float(a[2])) if isinstance(a, list) and len(a) >= 3 else None
        radius = d.get("radius")
        if radius is None:
            radius = d.get("major_radius")
        return FaceInfo(d.get("type", "none") or "none", d.get("distance"), v("normal"), radius, v("axis"),
                        d.get("min_radius_of_curvature"), bool(d.get("recognised_from_nurbs", False)))

    @property
    def summary(self) -> str:
        from ..units import Length
        r = self.radius or 0.0
        if self.type == "plane":
            return "Flat face"
        if self.type == "cylinder":
            return f"Cylinder · R {Length.mm(r)} mm (⌀ {Length.mm(2 * r)})"
        if self.type == "cone":
            return f"Cone · R {Length.mm(r)} mm"
        if self.type == "sphere":
            return f"Sphere · R {Length.mm(r)} mm"
        if self.type == "torus":
            return f"Torus · R {Length.mm(r)} mm"
        if self.type == "freeform":
            m = self.min_radius_of_curvature
            return f"Freeform · tightest curve R {Length.mm(m)} mm" if m is not None else "Freeform surface"
        if self.type == "edge":
            return "Edge"
        return "No exact surface"
