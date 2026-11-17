"""Everything the screens bind to, in one object passed to QML as `app`: navigation, the
inventory, the journal, settings and (as they are ported) the workspace, machine control and
jobs. Swift: the environment objects of CoastlineApp/ContentView."""

from __future__ import annotations

from PySide6.QtCore import Property, QObject, QUrl, Signal, Slot

from .bindable import prop
from .inventory_model import InventoryModel
from .journal_model import JournalUI
from .mill_control import MillControl
from .settings import AppSettings

PAGES = ["workspace", "projects", "stock", "tools", "fixtures", "measuring", "accessories", "shopping", "machine", "control"]


class AppRoot(QObject):
    page, pageChanged = prop(str, "page", "workspace")
    showInspector, showInspectorChanged = prop(bool, "showInspector", True)
    toolToShow, toolToShowChanged = prop(str, "toolToShow", "")  # a tool for the Tools page to select when it opens
    status, statusChanged = prop(str, "status", "")

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._settings = AppSettings(self)
        self._inventory = InventoryModel(parent=self)
        self._journal = JournalUI(parent=self)
        self._journal.inventory_model = self._inventory
        from ..core.machine.profile import MachineProfile
        # Physical control stays on its commissioned machine until instance calibration exists.
        self.control_machine = MachineProfile.standard()
        self._mill = MillControl(self._settings, self.control_machine, self)
        from .workspace import Workspace
        self._workspace = Workspace(self._inventory, self._journal, self._settings, self._mill, self)
        self._workspace.navigate = self._navigate
        self._workspace.navigate_to_tool = self.showTool
        self._workspace.page_hint = lambda: self.page
        from .jobs_model import JobsUI
        self._jobs = JobsUI(self._mill, self)
        self._workspace.jobs = self._jobs
        self._jobs.engine = self._workspace.connected_engine
        self._jobs.machine_source = self._job_machine

    @Property(QObject, constant=True)
    def machinePreview(self):
        if getattr(self, "_machine_preview", None) is None:
            from .machine_preview import MachinePreview
            ws = self._workspace
            self._machine_preview = MachinePreview(ws.machine_profiles, ws.connected_engine, ws, self)
        return self._machine_preview

    @Property(QObject, constant=True)
    def itemPreview(self):
        if getattr(self, "_item_preview", None) is None:
            from .item_preview import ItemPreview
            self._item_preview = ItemPreview(self._inventory, self._workspace, self)
        return self._item_preview

    @Property(QObject, constant=True)
    def inventoryExtras(self):
        if getattr(self, "_inventory_extras", None) is None:
            from .inventory_extras import InventoryExtras
            self._inventory_extras = InventoryExtras(self._inventory, self)
        return self._inventory_extras

    @Slot(result="QVariantList")
    def jobStockSize(self) -> list:
        ws = self._workspace
        return [float(v) for v in ws.setup.stock_size(ws.stock)] if ws.stock is not None else []

    @Property(QObject, constant=True)
    def controlMachine(self):
        if getattr(self, "_control_machine", None) is None:
            from .control_machine import ControlMachine
            self._control_machine = ControlMachine(self._mill, self._workspace, self)
        return self._control_machine

    @Property(QObject, constant=True)
    def machineProfiles(self):
        return self._workspace.machine_profiles

    def _job_machine(self):
        ws = self._workspace
        if ws.machine_model is None:
            yield from ws.load_machine()
        return ws.machine_model

    @Property(QObject, constant=True)
    def jobs(self):
        return self._jobs

    def _navigate(self, page: str) -> None:
        if page in PAGES:
            self.page = page

    @Property(str, constant=True)
    def controlMachineName(self) -> str:
        return self.control_machine.name

    @Property(QObject, constant=True)
    def mill(self) -> MillControl:
        return self._mill

    def shutdown(self) -> None:
        self._workspace.save_session()
        self._workspace.shutdown()
        for e, _, _ in self._workspace.worker_engines:
            e.terminate()
        self._mill.shutdown()
        self._inventory.save_now()

    @Property(QObject, constant=True)
    def settings(self) -> AppSettings:
        return self._settings

    @Property(QObject, constant=True)
    def inventory(self) -> InventoryModel:
        return self._inventory

    @Property(QObject, constant=True)
    def journal(self):
        return self._journal

    @Property(QObject, constant=True)
    def workspace(self) -> QObject:
        return self._workspace

    @Slot("QVariant", result=str)
    def localPath(self, url) -> str:
        """A file dialog's URL as a local path."""
        return url.toLocalFile() if isinstance(url, QUrl) else QUrl(str(url)).toLocalFile() or str(url)

    @Slot(str)
    def showTool(self, tool_id: str) -> None:
        self.toolToShow = tool_id
        self.page = "tools"
