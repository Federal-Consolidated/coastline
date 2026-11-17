"""The app's own preferences (not the project's), kept with QSettings (the registry on
Windows, a plist on macOS). Port of Model/AppSettings.swift."""

from __future__ import annotations

from PySide6.QtCore import QObject, QSettings, Slot

from ..core.units import DisplayUnits
from .bindable import prop

ACCENTS = {"graphite": 0.50, "charcoal": 0.40, "steel": 0.58}  # greys (the palette is monotone)


def _store() -> QSettings:
    return QSettings("Coastline", "Coastline")


class AppSettings(QObject):

    units, unitsChanged = prop(str, "units", "metric", on_set=lambda s, v: s._persist("displayUnits", v))
    accent, accentChanged = prop(str, "accent", "graphite", on_set=lambda s, v: s._persist("accent", v))
    appearance, appearanceChanged = prop(str, "appearance", "dark", on_set=lambda s, v: s._persist("appearance", v))
    engines, enginesChanged = prop(int, "engines", 0, on_set=lambda s, v: s._persist("engines", v))  # 0: automatic
    referenceBores, referenceBoresChanged = prop(bool, "referenceBores", True, on_set=lambda s, v: s._persist("referenceBores", v))

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        s = _store()
        self._loading = True
        self.units = str(s.value("displayUnits", "metric"))
        if self.units not in ("metric", "imperial"):
            self.units = "metric"
        self.accent = str(s.value("accent", "graphite"))
        self.appearance = str(s.value("appearance", "dark"))
        self.engines = int(s.value("engines", 0) or 0)
        self.referenceBores = str(s.value("referenceBores", "true")).lower() in ("true", "1")
        self._loading = False

    def _persist(self, key: str, value) -> None:
        if not getattr(self, "_loading", False):
            _store().setValue(key, value)

    @property
    def display_units(self) -> DisplayUnits:
        return DisplayUnits(self.units)

    @Slot(str, result=float)
    def accentGrey(self, name: str) -> float:
        return ACCENTS.get(name, 0.5)

    @staticmethod
    def value(key: str, default=None):
        """A loose app preference (view options remembered between runs)."""
        v = _store().value(key, default)
        if isinstance(default, bool) and isinstance(v, str):
            return v.lower() in ("true", "1")
        return v

    @staticmethod
    def set_value(key: str, value) -> None:
        _store().setValue(key, value)
