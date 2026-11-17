"""Machine profile browsing, separate from the job assignment: "Use for Job" selects the immutable
planning snapshot; browsing never changes a physical controller. Port of Model/MachineProfileLibrary.swift."""

from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QObject, Slot

from .. import paths
from ..core.machine.definition import MachineDefinitionError
from ..core.machine.package import MachineDefinitionPackage
from ..core.storage import application_support
from .bindable import prop
from .settings import AppSettings
from .tasks import Work, spawn


def key(package) -> str:
    return f"{package.definition.id}@{package.definition.revision}"


def library_path() -> Path:
    return application_support() / "Machine Profiles"


def _scan(bundled: Path, installed: Path):
    found, issues = [], []
    for folder in (bundled, installed):
        if not folder.exists():
            continue
        try:
            entries = sorted((p for p in folder.iterdir() if not p.name.startswith(".")), key=lambda p: p.name)
        except OSError as e:
            issues.append(f"Couldn't read {folder.name}: {e}")
            continue
        for url in entries:
            if not url.is_dir():
                continue
            try:
                package = MachineDefinitionPackage.load(url)
            except Exception as e:  # noqa: BLE001
                issues.append(f"{url.name}: {e}")
                continue
            existing = next((p for p in found if key(p) == key(package)), None)
            if existing is not None:
                if existing.definition != package.definition:
                    issues.append(f"{package.definition.name} revision {package.definition.revision} conflicts with a bundled profile. Export it with a new revision.")
            else:
                found.append(package)
    return found, issues


class MachineProfileLibrary(QObject):
    loading, loadingChanged = prop(bool, "loading", False)
    revision, revisionChanged = prop(int, "revision", 0)
    selectedKey, selectedKeyChanged = prop(str, "selectedKey", "", on_set=lambda s, v: AppSettings.set_value("reviewMachineProfile", v) if v else None)
    error, errorChanged = prop(str, "error", "")
    message, messageChanged = prop(str, "message", "")

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.packages: list = []
        self.library_issues: list[str] = []
        self.selectedKey = str(AppSettings.value("reviewMachineProfile", "") or "")

    @property
    def selected(self):
        return next((p for p in self.packages if key(p) == self.selectedKey), None)

    def reload(self, select: str | None = None):
        """A task: rescans the bundled and installed profiles."""
        if self.loading:
            # Callers resolving a saved job join an existing refresh, not a half-read library.
            from .tasks import Sleep
            while self.loading:
                yield Sleep(0.025)
            return
        self.loading = True
        try:
            bundled = paths.REPO_ROOT / "resources" / "machines"
            found, issues = yield Work(lambda: _scan(bundled, library_path()), lane="files")
            self.packages, self.library_issues = found, issues
            desired = select or self.selectedKey
            self.selectedKey = desired if any(key(p) == desired for p in found) else (key(found[0]) if found else "")
            self.revision = self.revision + 1
        finally:
            self.loading = False

    def reload_blocking(self) -> None:
        """For callers outside a task (start-up, tests)."""
        self.packages, self.library_issues = _scan(paths.REPO_ROOT / "resources" / "machines", library_path())
        if not any(key(p) == self.selectedKey for p in self.packages):
            self.selectedKey = key(self.packages[0]) if self.packages else ""
        self.revision = self.revision + 1

    @Slot()
    def reloadSlot(self) -> None:
        spawn(self.reload())

    @Slot(str)
    def install(self, folder: str) -> None:
        spawn(self._install(Path(folder)))

    def _install(self, url: Path):
        if self.loading:
            return
        self.loading = True
        self.error = ""
        self.message = ""
        try:
            available = [p.definition for p in self.packages]

            def work():
                incoming = MachineDefinitionPackage.load(url)
                existing = next((d for d in available if d.reference == incoming.definition.reference), None)
                if existing is not None and existing != incoming.definition:
                    raise MachineDefinitionError(f"{existing.name} revision {existing.revision} already exists with different data. Export the changed profile with a new revision.")
                return MachineDefinitionPackage.install(url, library_path())
            package = yield Work(work, lane="files")
            self.loading = False
            yield from self.reload(key(package))
            self.message = f"Imported {package.definition.name} for digital review."
        except Exception as e:  # noqa: BLE001
            self.error = str(e)
        finally:
            self.loading = False

    @Slot(result="QVariantList")
    def rows(self) -> list[dict]:
        return [{"key": key(p), "title": f"{p.definition.name} · r{p.definition.revision}"} for p in self.packages]

    @Slot(result="QStringList")
    def issues(self) -> list[str]:
        return list(self.library_issues)
