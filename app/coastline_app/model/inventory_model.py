"""The inventory as the screens see it: loads `Inventory.json`, autosaves edits (debounced) and
hands out rows and items to the pages. Port of Model/InventoryModel.swift.

QML reads lists through row slots (`toolRows(...)` …) and depends on `revision`, which goes up
with every change; items are edited field by field with `setField(list, id, key, value)`, keys
being the item's JSON (Codable) names, so pages and saved files speak the same language."""

from __future__ import annotations

import copy
import os
from pathlib import Path

from PySide6.QtCore import QObject, Signal, Slot

from .. import paths
from ..core import codable
from ..core.ids import new_id
from ..core.inventory.checks import InventoryChecks, Severity
from ..core.inventory.inventory import Inventory, InventoryStore
from ..core.inventory.items import (Accessory, AccessoryKind, Fixture, FixtureKind, MeasuringKind, MeasuringTool,
                                    StockItem, Tool, ToolKind)
from ..core.inventory.vetted_fixtures import VettedFixtureLibrary
from ..core.journal import ToolLife
from ..core.machine.profile import MachineProfile
from ..core.materials import MaterialLibrary
from ..core.units import Length
from .bindable import Debouncer, prop

LISTS = {"tools": Tool, "stock": StockItem, "fixtures": Fixture, "measuring": MeasuringTool, "accessories": Accessory}


def resolved_path() -> Path:
    """`COASTLINE_INVENTORY` overrides the location (automation must not touch the real file)."""
    p = os.environ.get("COASTLINE_INVENTORY")
    return Path(p) if p else InventoryStore.default_path()


def bundled_tool_libraries() -> list[Path]:
    d = paths.REPO_ROOT / "resources" / "libraries"
    return sorted(d.glob("*.tools")) if d.exists() else []


def _al():
    return MaterialLibrary.material("al-6061") or MaterialLibrary.all()[0]


class InventoryModel(QObject):
    changed = Signal()
    revision, revisionChanged = prop(int, "revision", 0)
    lastError, lastErrorChanged = prop(str, "lastError", "")
    showStarterBanner, showStarterBannerChanged = prop(bool, "showStarterBanner", False)

    def __init__(self, path: Path | None = None, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.path = path or resolved_path()
        self.inventory = Inventory()
        self._load_failed = False
        self._saver = Debouncer(400, self.save_now)
        self.machine = MachineProfile.standard()
        try:
            loaded = InventoryStore.load(self.path)
            if loaded is not None:
                # Install new definitions without replacing the user's measurements, notes or quantities.
                if loaded.install_catalog_updates():
                    InventoryStore.save(loaded, self.path)
                if loaded.flat_kit_added is not True:
                    have = {f.kind for f in loaded.fixtures}
                    loaded.fixtures += [f for f in Inventory.flat_clamping_kit() if f.kind not in have]
                    loaded.flat_kit_added = True
                    InventoryStore.save(loaded, self.path)
                loaded.stock = [loaded.resolved_stock(s) for s in loaded.stock]
                self.inventory = loaded
            else:
                self.inventory = Inventory.starter(bundled_tool_libraries())
                self.inventory.install_catalog_updates()
                self.showStarterBanner = True
                InventoryStore.save(self.inventory, self.path)
            if VettedFixtureLibrary.migrate(self.inventory, paths.REPO_ROOT / "resources"):
                InventoryStore.save(self.inventory, self.path)
        except Exception as e:  # noqa: BLE001 — shown to the user; editing stays off
            self._load_failed = True
            self.lastError = str(e)

    # ------------------------------------------------------------ editing

    def update(self, change) -> None:
        if self._load_failed:
            return
        change(self.inventory)
        self.inventory.stock = [self.inventory.resolved_stock(s) for s in self.inventory.stock]
        self._changed()
        self._saver.poke()

    def _changed(self) -> None:
        self.revision = self.revision + 1
        self.changed.emit()

    def commit_library(self, candidate: Inventory) -> None:
        """Save before publishing the replacement, so a failed import leaves memory and disk intact."""
        if self._load_failed:
            raise RuntimeError("The existing inventory could not be loaded. Restore it before importing or replacing library entries.")
        nxt = candidate
        nxt.stock = [nxt.resolved_stock(s) for s in nxt.stock]
        InventoryStore.save(nxt, self.path)
        self._saver.cancel()
        self.inventory = nxt
        self.lastError = ""
        self._changed()

    def save_now(self) -> None:
        if self._load_failed:
            return
        try:
            InventoryStore.save(self.inventory, self.path)
            self.lastError = ""
        except Exception as e:  # noqa: BLE001
            self.lastError = f"Couldn't save the inventory: {e}"

    def list_of(self, name: str) -> list:
        return getattr(self.inventory, name)

    def find(self, name: str, id: str):
        return next((x for x in self.list_of(name) if x.id == id), None)

    @Slot(str, str, result="QVariantMap")
    def item(self, name: str, id: str) -> dict:
        """One item as JSON (its Codable keys), with a few derived values for the inspector."""
        x = self.find(name, id)
        if x is None:
            return {}
        d = codable.to_json(x)
        d["_issues"] = [{"severity": i.severity.name.lower(), "message": i.message} for i in self.issues(name, x)]
        if name == "tools":
            d["_kindTitle"] = x.kind.title
            d["_suggestion"] = x.is_suggestion
            d["_needsSpecs"] = x.requires_specification_review
        elif name == "stock":
            d["_size"] = x.size_description
            m = x.material
            d["_materialName"] = m.name if m is not None else x.material_id
            d["_difficulty"] = m.difficulty.title if m is not None else ""
            d["_difficultyKey"] = m.difficulty.value if m is not None else ""
            from .workspace.swatches import swatch_hex
            d["_swatch"] = swatch_hex(m)
            e = x.envelope
            d["_envelope"] = [e.x, e.y, e.z]
            w = x.weight
            d["_weight"] = f"{w:.1f} g each" if w is not None else ""
        return d

    @Slot(str, str, str, "QVariant")
    def setField(self, name: str, id: str, key: str, value) -> None:
        """Sets one JSON key of an item (None removes an optional value)."""
        tp = LISTS[name]

        def change(inv) -> None:
            items = getattr(inv, name)
            for k, x in enumerate(items):
                if x.id != id:
                    continue
                d = codable.to_json(x)
                if value is None:
                    d.pop(key, None)
                else:
                    d[key] = value
                try:
                    items[k] = codable.from_json(tp, d)
                except (codable.DecodeError, ValueError, TypeError, KeyError) as e:
                    self.lastError = f"Couldn't set {key}: {e}"
                return

        self.update(change)

    @Slot(str, "QStringList")
    def remove(self, name: str, ids) -> None:
        ids = set(ids)
        self.update(lambda inv: setattr(inv, name, [x for x in getattr(inv, name) if x.id not in ids]))

    @Slot(str, "QStringList", result="QStringList")
    def duplicate(self, name: str, ids) -> list[str]:
        made = []

        def change(inv) -> None:
            items = getattr(inv, name)
            for id in ids:
                x = next((x for x in items if x.id == id), None)
                if x is None:
                    continue
                c = copy.deepcopy(x)
                c.id = new_id()
                if hasattr(c, "name"):
                    c.name += " copy"
                items.append(c)
                made.append(c.id)

        self.update(change)
        return made

    @Slot(str, result=str)
    def add(self, name: str) -> str:
        """A new item with sensible defaults; returns its id."""
        if name == "tools":
            x = Tool.make('New 1/8" flat end mill', ToolKind.FLAT_END_MILL, 3.175, 3.175, 3, 9.5, 19, 38.1)
        elif name == "stock":
            x = StockItem.make("al-6061", 100, 50, 20)
        elif name == "fixtures":
            x = Fixture.make("New fixture", FixtureKind.OTHER)
        elif name == "measuring":
            x = MeasuringTool.make("Digital caliper", MeasuringKind.CALIPER)
        else:
            x = Accessory.make("ER-11 1/8\" collet", AccessoryKind.COLLET, size=3.175)
        self.update(lambda inv: getattr(inv, name).append(x))
        return x.id

    @Slot(str, str, result=str)
    def addKind(self, name: str, kind: str) -> str:
        """A fixture, instrument or accessory of this kind, named after it."""
        from ..core.inventory.items import ClampAxis
        if name == "fixtures":
            k = FixtureKind(kind)
            axis = ClampAxis.Y if k is FixtureKind.VISE else ClampAxis.X if k is FixtureKind.UNIVERSAL_CLAMP else ClampAxis.NONE
            x = Fixture.make(k.title, k, clamp_axis=axis)
        elif name == "measuring":
            k = MeasuringKind(kind)
            x = MeasuringTool.make(k.title, k)
        else:
            k = AccessoryKind(kind)
            x = Accessory.make(k.title, k)
        self.add_item(name, x)
        return x.id

    @Slot(str, result=str)
    def importFixtureModel(self, local_path: str) -> str:
        """A new jig from its CAD model (copied into Coastline's library)."""
        x = Fixture.make(Path(local_path).stem, FixtureKind.JIG_PLATE)
        self.add_item("fixtures", x)
        self.setFixtureModel(x.id, local_path)
        return x.id

    @Slot(str, result=str)
    def addStock(self, shape: str) -> str:
        from ..core.inventory.items import StockFinish, StockShape
        sh = StockShape(shape)
        if sh is StockShape.ROUND_BAR:
            x = StockItem.make("brass-c360", 20, 100, 0, shape=sh)
        elif sh is StockShape.PLATE:
            x = StockItem.make("al-6061", 100, 50, 3, shape=sh)
        elif sh is StockShape.PRINTED_BLANK:
            x = StockItem.make("fl-rigid-10k", 40, 30, 15, shape=sh, finish=StockFinish.AS_PRINTED)
        else:
            x = StockItem.make("al-6061", 50, 50, 20)
        self.add_item("stock", x)
        return x.id

    @Slot(str, str)
    def setStockMaterial(self, id: str, material_id: str) -> None:
        def change(inv) -> None:
            for s in inv.stock:
                if s.id == id and s.material_id != material_id:
                    s.material_id = material_id
                    s.material_snapshot = inv.material(material_id)
        self.update(change)

    @Slot(str, str)
    def setFixtureModel(self, id: str, local_path: str) -> None:
        """Copies a fixture's CAD model into Coastline's folder and attaches it."""
        import shutil
        import uuid
        from ..core.storage import application_support
        src = Path(local_path)
        folder = application_support() / "Fixture Models"
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / (str(uuid.uuid4()).upper() + src.suffix.lower())
        try:
            shutil.copyfile(src, target)
        except OSError as e:
            self.lastError = f"Couldn't copy the model: {e}"
            return
        self.setField("fixtures", id, "modelPath", str(target))

    def add_item(self, name: str, x) -> None:
        self.update(lambda inv: getattr(inv, name).append(x))

    @Slot()
    def resetToStarter(self) -> None:
        self._load_failed = False
        self.inventory = Inventory.starter(bundled_tool_libraries())
        self.inventory.install_catalog_updates()
        VettedFixtureLibrary.migrate(self.inventory, paths.REPO_ROOT / "resources")
        self.save_now()  # immediately, so Inventory.json.bak holds the replaced inventory
        self.showStarterBanner = True
        self._changed()

    @Slot("QStringList")
    def markStockOwned(self, ids) -> None:
        ids = set(ids)

        def change(inv) -> None:
            for s in inv.stock:
                if s.id in ids and s.quantity == 0:
                    suggested = s.is_suggestion
                    s.quantity = 1
                    if suggested:
                        s.supplier = ""
                        s.notes = s.notes.replace("Not in your inventory: a standard size. ", "")

        self.update(change)

    @Slot("QStringList")
    def markToolsOwned(self, ids) -> None:
        ids = set(ids)

        def change(inv) -> None:
            for t in inv.tools:
                if t.id in ids and t.quantity <= 0:
                    suggested = t.is_suggestion
                    t.quantity = 1
                    if suggested:
                        t.source = "Bought on Coastline's suggestion"

        self.update(change)

    @Slot(str, result="QStringList")
    def missingSpecifications(self, id: str) -> list[str]:
        """Specifications a catalog tool still needs before it can cut."""
        from ..core.inventory.items import Coating, ToolMaterial
        t = self.find("tools", id)
        if t is None:
            return []

        def pos(v) -> bool:
            return v is not None and v == v and v > 0 and v != float("inf")

        checks = {"Shank diameter": pos(t.shank_diameter), "Flute count": t.flutes > 0, "Flute length": pos(t.flute_length),
                  "Stick-out": pos(t.stickout), "Overall length": pos(t.overall_length), "Point angle": pos(t.angle or 0),
                  "Coating": t.coating is not Coating.UNSPECIFIED, "Tool material": t.tool_material is not ToolMaterial.UNSPECIFIED}
        return [f for f in (t.unconfirmed_specifications or []) if not checks.get(f, False)]

    @Slot(str, result=str)
    def confirmSpecifications(self, id: str) -> str:
        """Marks a catalog tool's specifications as measured; returns what still blocks it ("" = done)."""
        from ..core.inventory.checks import ResourceLibraryValidation
        from ..core.inventory.items import Coating
        t = self.find("tools", id)
        if t is None:
            return ""
        confirmed = copy.deepcopy(t)
        confirmed.unconfirmed_specifications = None
        issues = ResourceLibraryValidation.tool_issues(confirmed)
        if confirmed.coating is Coating.UNSPECIFIED and not issues:
            issues.append("Choose the tool's coating, or Uncoated if it has none.")
        if "Point angle" in (t.unconfirmed_specifications or []) and not (confirmed.angle or 0) > 0:
            issues.append("Enter the tool's positive point angle.")
        if issues:
            return "\n".join(issues)
        self.update(lambda inv: inv.tools.__setitem__(next(k for k, x in enumerate(inv.tools) if x.id == id), confirmed))
        return ""

    # ------------------------------------------------------------ checks

    def issues(self, name: str, x) -> list:
        if name == "tools":
            return InventoryChecks.check_tool(x, self.inventory, self.machine)
        if name == "stock":
            return InventoryChecks.check_stock(x, self.machine)
        return []

    def worst(self, name: str, x) -> str:
        found = self.issues(name, x)
        if not found:
            return ""
        return max((i.severity for i in found), key=lambda s: s.value).name.lower()

    # ------------------------------------------------------------ rows for the tables

    @Slot(str, str, str, str, bool, result="QVariantList")
    def toolRows(self, filter: str, ownership: str, search: str, sort: str, ascending: bool) -> list[dict]:
        groups = {"endMills": {ToolKind.FLAT_END_MILL, ToolKind.FACE_MILL}, "ball": {ToolKind.BALL_END_MILL, ToolKind.BULL_NOSE_END_MILL},
                  "holes": {ToolKind.DRILL, ToolKind.SPOT_DRILL, ToolKind.THREAD_MILL}, "chamfer": {ToolKind.CHAMFER_MILL, ToolKind.ENGRAVER}}
        al = _al()
        rows = []
        needle = search.lower().strip()
        for t in self.inventory.tools:
            if not _owned(ownership, t.quantity):
                continue
            worst = self.worst("tools", t)
            if filter in groups and t.kind not in groups[filter]:
                continue
            if filter == "attention" and worst not in ("warning", "error"):
                continue
            if needle and needle not in f"{t.name} {t.vendor} {t.part_number} {t.intended_for}".lower():
                continue
            subtitle = (t.notes.replace("Not in your inventory: Coastline suggests it. ", "") if t.is_suggestion
                        else t.kind.title if not t.intended_for else t.intended_for)
            life = ToolLife.status(t, al) if not t.requires_specification_review else None
            rows.append({"symbol": {"flatEndMill": "rectangle.portrait.bottomhalf.filled", "bullNoseEndMill": "rectangle.portrait.bottomhalf.filled",
                                    "faceMill": "rectangle.portrait.bottomhalf.filled", "ballEndMill": "capsule.portrait.bottomhalf.filled",
                                    "chamferMill": "triangle", "engraver": "triangle", "spotDrill": "triangle", "drill": "arrowtriangle.down.fill",
                                    "threadMill": "screwdriver"}.get(t.kind.value, "circle"),
                         "id": t.id, "name": t.name, "subtitle": subtitle,
                         "issueMark": "⛔" if worst == "error" else "⚠" if worst == "warning" else "",
                         "wearMark": f"{round(min(life.used, 1) * 100)} %" if life else "—", "kind": t.kind.value, "kindTitle": t.kind.title,
                         "diameter": t.diameter, "diameterText": Length.describe(t.diameter) if t.diameter > 0 else "—",
                         "flutes": t.flutes, "flutesText": str(t.flutes) if t.flutes > 0 else "—",
                         "stickout": t.stickout, "stickoutText": f"{Length.mm(t.stickout)} mm" if t.stickout > 0 else "—",
                         "coating": t.coating.title, "quantity": t.quantity, "issue": worst,
                         "needsSpecs": t.requires_specification_review, "notOwned": t.quantity <= 0,
                         "wear": min(life.used, 1) if life else -1,
                         "wearState": ("worn" if life.worn_out else "soon" if life.replace_soon else "ok") if life else "",
                         "wearText": (f"{int(life.minutes)} of about {int(life.life_minutes)} cutting minutes" if life else
                                      "Confirm tool specifications to show estimated wear")})
        return _sorted(rows, sort or "diameter", ascending)

    @Slot(str, str, str, bool, result="QVariantList")
    def stockRows(self, ownership: str, search: str, sort: str, ascending: bool) -> list[dict]:
        rows = []
        needle = search.lower().strip()
        for s in self.inventory.stock:
            if not _owned(ownership, s.quantity):
                continue
            m = s.material
            mname = m.name if m is not None else s.material_id
            if needle and needle not in f"{mname} {s.supplier} {s.location} {s.notes} {s.size_description}".lower():
                continue
            worst = self.worst("stock", s)
            from .workspace.swatches import swatch as _swatch
            r_, g_, b_ = (_swatch(m) if m is not None else (0.5, 0.5, 0.5))[:3]
            w = s.weight
            rows.append({"family": m.family.value if m is not None else "", "familyTitle": m.family.title if m is not None else "",
                         "swatch": f"#{int(r_ * 255):02x}{int(g_ * 255):02x}{int(b_ * 255):02x}",
                         "shapeSymbol": {"block": "cube", "roundBar": "cylinder", "plate": "rectangle", "printedBlank": "printer.dotmatrix"}[s.shape.value],
                         "weight": f"{w:.0f} g" if w is not None else "—",
                         "caption": "Offcut" if s.is_remnant else (s.notes.replace("Not in your inventory: a standard size. ", "") if s.is_suggestion else ""),
                         "id": s.id, "name": s.size_description,
                         "issueMark": "⛔" if worst == "error" else "⚠" if worst == "warning" else "", "material": mname, "shape": s.shape.title,
                         "finish": s.finish.title, "quantity": s.quantity, "remnant": s.is_remnant, "location": s.location,
                         "volume": s.volume, "issue": self.worst("stock", s), "notOwned": s.quantity <= 0,
                         "suggestion": s.is_suggestion})
        return _sorted(rows, sort, ascending) if sort else rows

    @Slot(str, str, result="QVariantList")
    def simpleRows(self, name: str, search: str) -> list[dict]:
        rows = []
        needle = search.lower().strip()
        for x in self.list_of(name):
            if needle and needle not in f"{x.name} {x.notes}".lower():
                continue
            row = {"id": x.id, "name": x.name, "kind": x.kind.title, "quantity": x.quantity, "notes": x.notes,
                   "symbol": KIND_SYMBOLS.get(x.kind.value, "circle")}
            if name == "accessories":
                row["size"] = (Length.describe(x.size) if x.kind is AccessoryKind.COLLET else f"{Length.mm(x.size)} mm") if x.size else "—"
            if name == "measuring":
                row["range"] = f"{Length.mm(x.range.lower)}–{Length.mm(x.range.upper)} mm" if x.range else "—"
                row["resolution"] = f"{Length.mm(x.resolution)} mm" if x.resolution else "—"
            if name == "fixtures":
                row["height"] = f"{Length.mm(x.height)} mm"
                row["clamps"] = x.clamp_axis.title
                row["probing"] = "Isolated" if x.isolated else "—"
                row["modelMark"] = "■" if x.model_path else "—"
                row["planned"] = x.planning is not None and x.planning.enabled
                row["model"] = bool(x.model_path)
            rows.append(row)
        return rows

    @Slot(result="QVariantList")
    def shoppingRows(self) -> list[dict]:
        return [{"id": t.id, "name": t.name, "why": why, "vendor": t.vendor, "partNumber": t.part_number, "link": t.product_link,
                 "cost": f"{t.unit_cost:.2f}" if t.unit_cost else "", "maker": " · ".join(x for x in (t.vendor, t.part_number) if x)}
                for t, why in ToolLife.shopping_list(self.inventory, _al())]

    @Slot(result="QVariantMap")
    def counts(self) -> dict:
        inv = self.inventory
        return {"stock": sum(s.quantity for s in inv.stock), "tools": sum(t.quantity for t in inv.tools),
                "fixtures": len(inv.fixtures), "measuring": len(inv.measuring), "accessories": len(inv.accessories),
                "shopping": len(ToolLife.shopping_list(inv, _al())), "toolsTotal": len(inv.tools), "stockTotal": len(inv.stock)}

    @Slot(str, result="QVariantList")
    def choices(self, enum_name: str) -> list[dict]:
        """An enum's values and titles for pickers ("ToolKind", "Coating", …)."""
        from ..core.inventory import items
        e = getattr(items, enum_name)
        return [{"value": v.value, "title": getattr(v, "title", v.value)} for v in e]

    @Slot(result="QVariantList")
    def materialChoices(self) -> list[dict]:
        return [{"value": m.id, "title": m.name, "family": m.family.title} for m in self.inventory.materials]


def _owned(ownership: str, quantity: int) -> bool:
    return quantity > 0 if ownership == "owned" else quantity <= 0 if ownership == "notOwned" else True


KIND_SYMBOLS = {
    # fixtures
    "universalClamp": "rectangle.compress.vertical", "vise": "arrow.right.and.line.vertical.and.arrow.left", "jigPlate": "square.grid.3x3",
    "fixturePlate": "square.grid.3x3", "tombstone": "rectangle.portrait", "squaringBoss": "l.square", "softJaws": "square.split.2x1",
    "printedNest": "printer.dotmatrix", "tSlotNuts": "t.square", "cClamp": "c.square", "squaringStop": "rectangle.portrait.and.arrow.right",
    "riser": "square.stack.3d.down.forward", "other": "wrench.adjustable",
    # measuring
    "caliper": "ruler", "micrometer": "ruler", "depthMicrometer": "ruler", "heightGauge": "ruler", "dialIndicator": "gauge.with.dots.needle.33percent",
    "testIndicator": "gauge.with.dots.needle.33percent", "edgeFinder": "scope", "touchProbe": "scope", "gaugePins": "square.stack",
    "gaugeBlocks": "square.stack", "feelerGauge": "square.stack", "radiusGauge": "circle.dashed", "threadGauge": "circle.dashed",
    "loupe": "magnifyingglass", "surfacePlate": "square",
    # accessories
    "collet": "circle.circle", "lubricant": "drop", "adhesive": "bandage", "dowelPin": "pin", "tape": "rectangle.dashed",
    "deburring": "scissors", "polishing": "sparkles",
}


def _sorted(rows: list[dict], key: str, ascending: bool) -> list[dict]:
    def k(r):
        v = r.get(key)
        return (v is None, v.lower() if isinstance(v, str) else v)
    return sorted(rows, key=k, reverse=not ascending)
