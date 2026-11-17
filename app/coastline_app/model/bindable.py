"""Small helpers for QObjects that QML binds to.

    class Thing(QObject):
        name, nameChanged = prop(str, "name", "")

`prop` makes a Qt property with its own change signal; assigning `self.name = …` from Python
emits the signal only when the value changes. Lists and dicts go to QML as JS arrays/objects.
"""

from __future__ import annotations

from typing import Any, Callable

from PySide6.QtCore import Property, QObject, QTimer, Signal


def prop(tp: Any, name: str, default: Any = None, *, readonly: bool = False, on_set: Callable | None = None):
    """A Qt property `name` of type `tp` (str, int, float, bool, "QVariant", "QVariantList",
    "QVariantMap", QObject…) and its notify signal `<name>Changed`."""
    signal = Signal()
    attr = "_p_" + name

    def getter(self):
        return getattr(self, attr, default)

    def setter(self, value):
        if getattr(self, attr, default) != value or isinstance(value, (list, dict)):
            setattr(self, attr, value)
            getattr(self, name + "Changed").emit()
            if on_set is not None:
                on_set(self, value)

    p = Property(tp, getter, None if readonly else setter, notify=signal)
    return p, signal


class Debouncer:
    """Calls `fn` once, `ms` after the last `poke()` (e.g. saving after edits settle)."""

    def __init__(self, ms: int, fn: Callable[[], None]) -> None:
        self._timer = QTimer()
        self._timer.setSingleShot(True)
        self._timer.setInterval(ms)
        self._timer.timeout.connect(fn)

    def poke(self) -> None:
        self._timer.start()

    def cancel(self) -> None:
        self._timer.stop()

    @property
    def pending(self) -> bool:
        return self._timer.isActive()


def emit_later(obj: QObject, signal_name: str) -> None:
    """Emits a signal from the event loop (coalesces bursts of changes in one turn)."""
    QTimer.singleShot(0, lambda: getattr(obj, signal_name).emit())
