"""Background work that reads like the Swift app's `async` functions.

A task is a generator running on the UI thread. It yields work for a worker thread and gets the
result back (or the exception thrown into it) on the UI thread:

    def import_part(self, path):
        mesh = yield Work(lambda: engine.import_part(path))   # runs on the engine's thread
        self.scene.add(...)                                    # back on the UI thread

    spawn(self.import_part(path))

`yield Sleep(0.4)` waits without blocking; `yield other_task` waits for another task;
`yield None` lets the UI breathe for one turn. `task.cancel()` throws `Cancelled` into the
generator at its next step. Workers: one thread per lane (an engine answers one request at a
time), so work for the same lane runs in order.
"""

from __future__ import annotations

import threading
import traceback
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any, Callable, Generator

from PySide6.QtCore import QObject, QTimer, Signal, Slot


class Cancelled(Exception):
    """Thrown into a task that was cancelled (Swift's CancellationError)."""


@dataclass
class Work:
    fn: Callable[[], Any]
    lane: str = "engine"


@dataclass
class Sleep:
    seconds: float


class _Bridge(QObject):
    """Delivers worker results to the UI thread (queued signal)."""

    done = Signal(object, object, object)  # task, result, error

    @Slot(object, object, object)
    def _deliver(self, task, result, error) -> None:
        task._resume(result, error)


_bridge: _Bridge | None = None
_lanes: dict[str, ThreadPoolExecutor] = {}
_lock = threading.Lock()


def _ensure_bridge() -> _Bridge:
    global _bridge
    if _bridge is None:
        _bridge = _Bridge()
        _bridge.done.connect(_bridge._deliver)
    return _bridge


def lane(name: str) -> ThreadPoolExecutor:
    with _lock:
        pool = _lanes.get(name)
        if pool is None:
            pool = _lanes[name] = ThreadPoolExecutor(max_workers=1, thread_name_prefix=f"lane-{name}")
        return pool


def shutdown_lanes() -> None:
    with _lock:
        for pool in _lanes.values():
            pool.shutdown(wait=False, cancel_futures=True)
        _lanes.clear()


class Task:
    def __init__(self, gen: Generator, name: str = "", on_error: Callable[[BaseException], None] | None = None) -> None:
        self.gen = gen
        self.name = name
        self.on_error = on_error
        self.cancelled = False
        self.finished = False
        self.result: Any = None
        self.error: BaseException | None = None
        self._waiters: list[Task] = []
        self._bridge = _ensure_bridge()

    def cancel(self) -> None:
        self.cancelled = True

    def _step(self, value=None, error: BaseException | None = None) -> None:
        if self.finished:
            return
        try:
            if self.cancelled and error is None:
                error = Cancelled()
            yielded = self.gen.throw(error) if error is not None else self.gen.send(value)
        except StopIteration as stop:
            self._finish(stop.value, None)
            return
        except Cancelled:
            self._finish(None, None)
            return
        except BaseException as e:  # noqa: BLE001 — reported, never lost
            self._finish(None, e)
            return
        self._dispatch(yielded)

    def _dispatch(self, yielded) -> None:
        if isinstance(yielded, Work):
            def run(fn=yielded.fn):
                try:
                    result, err = fn(), None
                except BaseException as e:  # noqa: BLE001
                    result, err = None, e
                self._bridge.done.emit(self, result, err)
            lane(yielded.lane).submit(run)
        elif isinstance(yielded, Sleep):
            QTimer.singleShot(int(yielded.seconds * 1000), lambda: self._step(None))
        elif isinstance(yielded, Task):
            if yielded.finished:
                QTimer.singleShot(0, lambda: self._step(yielded.result, yielded.error))
            else:
                yielded._waiters.append(self)
        elif yielded is None:
            QTimer.singleShot(0, lambda: self._step(None))
        else:
            self._step(None, TypeError(f"a task yielded {type(yielded).__name__}"))

    def _resume(self, result, error) -> None:
        self._step(result, error)

    def _finish(self, result, error) -> None:
        self.finished = True
        self.result, self.error = result, error
        if error is not None:
            if self.on_error is not None:
                self.on_error(error)
            elif not self._waiters:
                traceback.print_exception(error)
        for w in self._waiters:
            QTimer.singleShot(0, lambda w=w: w._step(result, error))
        self._waiters.clear()


def spawn(gen: Generator, name: str = "", on_error: Callable[[BaseException], None] | None = None) -> Task:
    """Starts a task on the next turn of the event loop."""
    t = Task(gen, name, on_error)
    QTimer.singleShot(0, lambda: t._step(None))
    return t


def run_now(gen: Generator) -> Task:
    """Starts a task immediately (its first step runs inside this call)."""
    t = Task(gen)
    t._step(None)
    return t
