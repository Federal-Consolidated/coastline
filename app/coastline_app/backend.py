"""App state the screens bind to. No UI code here: QML reads these properties and calls
these slots; long work runs on a worker thread and reports back through signals."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PySide6.QtCore import Property, QObject, QUrl, Signal, Slot

from .core.engine.client import EngineClient, EngineError
from .core.mesh import MeshData
from .viewport import Scene, SceneColor


class Backend(QObject):
    statusChanged = Signal()
    busyChanged = Signal()
    # Worker thread → UI thread (queued: emitted off the UI thread).
    _engineReady = Signal(object)
    _partLoaded = Signal(object, str)
    _failed = Signal(str)

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._scene = Scene(self)
        self._status = "Starting the geometry engine…"
        self._busy = True
        self._engine: EngineClient | None = None
        # One worker: the engine answers one request at a time.
        self._worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="engine")
        self._engineReady.connect(self._on_engine_ready)
        self._partLoaded.connect(self._on_part_loaded)
        self._failed.connect(self._on_failed)

    # ---- properties

    @Property(QObject, constant=True)
    def scene(self) -> Scene:
        return self._scene

    @Property(str, notify=statusChanged)
    def status(self) -> str:
        return self._status

    @Property(bool, notify=busyChanged)
    def busy(self) -> bool:
        return self._busy

    def _set(self, status: str, busy: bool) -> None:
        self._status, self._busy = status, busy
        self.statusChanged.emit()
        self.busyChanged.emit()

    # ---- engine

    def start(self) -> None:
        self._worker.submit(self._start_engine)

    def _start_engine(self) -> None:
        try:
            engine = EngineClient()
            info = engine.ping()
            self._engineReady.emit((engine, info))
        except Exception as e:  # noqa: BLE001 — every failure is shown to the user
            self._failed.emit(f"The geometry engine did not start. {e}")

    def _on_engine_ready(self, payload) -> None:
        self._engine, info = payload
        self._set(f"Ready · engine {info.get('engine', '?')} · OpenCASCADE {info.get('ocp', '?')}", False)

    def shutdown(self) -> None:
        self._worker.shutdown(wait=False, cancel_futures=True)
        if self._engine is not None:
            self._engine.shutdown()

    # ---- parts

    @Slot(QUrl)
    def openPart(self, url: QUrl) -> None:
        path = Path(url.toLocalFile()) if isinstance(url, QUrl) else Path(str(url))
        self.open_path(path)

    def open_path(self, path: Path) -> None:
        if self._engine is None:
            self._set("The geometry engine is not ready yet.", self._busy)
            return
        self._set(f"Importing {path.name}…", True)
        self._worker.submit(self._import, path)

    def _import(self, path: Path) -> None:
        try:
            mesh = self._engine.import_part(path)
            self._partLoaded.emit(mesh, path.name)
        except EngineError as e:
            self._failed.emit(f"Could not import {path.name}: {e.message}")
        except Exception as e:  # noqa: BLE001
            self._failed.emit(f"Could not import {path.name}: {e}")

    def _on_part_loaded(self, mesh: MeshData, name: str) -> None:
        self._scene.clear()
        self._scene.set_mesh("part", mesh.vertices, mesh.normals, mesh.indices, SceneColor.part)
        self._scene.request_frame()
        x, y, z = mesh.size
        kind = "exact" if mesh.exact else "mesh only"
        warn = f" · {len(mesh.warnings)} warning(s)" if mesh.warnings else ""
        self._set(f"{name} · {x:.2f} × {y:.2f} × {z:.2f} mm · {mesh.face_count} faces · {kind}{warn}", False)

    def _on_failed(self, message: str) -> None:
        self._set(message, False)
