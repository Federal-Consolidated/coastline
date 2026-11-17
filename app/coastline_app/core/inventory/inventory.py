"""Everything the user owns: stock, tools, fixtures, measuring tools and accessories. Stored as
one human-readable JSON file. Port of Inventory/Inventory.swift, InventoryCatalogUpdates.swift,
InventoryFixtureSetup.swift and InventoryStockMaterials.swift."""

from __future__ import annotations

import copy
from dataclasses import dataclass, field
from pathlib import Path

from .. import codable
from ..codable import Range
from ..materials import Material, MaterialLibrary
from ..storage import application_support, write_atomic
from .items import (Accessory, AccessoryKind, ClampAxis, Fixture, FixtureKind, MeasuringKind, MeasuringTool, StockItem,
                    Tool)

CURRENT_SCHEMA = 2


@dataclass
class Inventory:
    schema: int = CURRENT_SCHEMA
    stock: list[StockItem] = field(default_factory=list)
    tools: list[Tool] = field(default_factory=list)
    fixtures: list[Fixture] = field(default_factory=list)
    flat_kit_added: bool | None = None  # the flat clamping kit was added once
    tool_suggestions_added: bool | None = None
    tool_suggestions_version: int | None = None
    stock_suggestions_version: int | None = None
    measuring: list[MeasuringTool] = field(default_factory=list)
    accessories: list[Accessory] = field(default_factory=list)
    custom_materials: list[Material] | None = None  # built-in IDs are reserved

    def copy(self) -> "Inventory":
        return copy.deepcopy(self)

    @property
    def is_empty(self) -> bool:
        return (not self.stock and not self.tools and not self.fixtures and not self.measuring and not self.accessories
                and not self.custom_materials)

    @property
    def materials(self) -> list[Material]:
        """Built-ins and installed definitions, one entry per ID (a custom one never shadows a built-in)."""
        seen = {m.id for m in MaterialLibrary.all()}
        out = list(MaterialLibrary.all())
        for m in self.custom_materials or []:
            if m.id not in seen:
                seen.add(m.id)
                out.append(m)
        return out

    def material(self, id: str) -> Material | None:
        builtin = MaterialLibrary.material(id)
        if builtin is not None:
            return builtin
        return next((m for m in self.custom_materials or [] if m.id == id), None)

    def resolved_stock(self, stock: StockItem) -> StockItem:
        """Capture the installed definition when stock is explicitly selected or edited."""
        c = stock.copy()
        m = self.material(stock.material_id)
        if m is not None:
            c.material_snapshot = m
        elif c.material_snapshot is not None and c.material_snapshot.id != stock.material_id:
            c.material_snapshot = None
        return c

    @property
    def collet_sizes(self) -> list[float]:
        """Collet bores you own, in mm."""
        return [a.size for a in self.accessories if a.kind is AccessoryKind.COLLET and a.quantity > 0 and a.size is not None]

    # ---- catalog updates
    def install_catalog_updates(self) -> bool:
        """Install newly published suggestions once, without replacing any existing item."""
        from .catalogs import StockCatalog, ToolCatalog
        changed = False
        if self.tool_suggestions_added is not True or (self.tool_suggestions_version or 1) < ToolCatalog.VERSION:
            have = {t.id for t in self.tools}
            for t in ToolCatalog.suggestions():
                if t.id not in have:
                    have.add(t.id)
                    self.tools.append(t)
            self.tools = [t for t in self.tools if not (t.id in ToolCatalog.RETIRED and t.is_suggestion)]
            self.tool_suggestions_added = True
            self.tool_suggestions_version = ToolCatalog.VERSION
            changed = True
        if (self.stock_suggestions_version or 0) < StockCatalog.VERSION:
            have = {s.id for s in self.stock}
            for s in StockCatalog.suggestions():
                if s.id not in have:
                    have.add(s.id)
                    self.stock.append(s)
            self.stock_suggestions_version = StockCatalog.VERSION
            changed = True
        return changed

    # ---- job-specific workholding
    def for_fixture_setup(self, setup) -> "Inventory":
        """Job-specific workholding without changing the library's reusable defaults. Saved geometry
        stays pinned; availability comes from the live inventory. A removed fixture is never
        resurrected by its saved job snapshot."""
        saved = {f.id: f for f in setup.fixture_assemblies or []}
        selected = set(setup.selected_fixture_ids) if setup.selected_fixture_ids is not None else None
        result = self.copy()
        out = []
        for owned in self.fixtures:
            if selected is not None and owned.id not in selected:
                continue
            fixture = copy.deepcopy(saved.get(owned.id, owned))
            fixture.quantity = owned.quantity
            out.append(fixture)
        result.fixtures = out
        return result

    def customizing_stock_material(self, material: Material, stock_id: str, expected_material_id: str) -> "Inventory":
        """Give one stock item its own material definition without editing shared cutting data."""
        from .resource_library import ImportError_
        if material.validation_issues:
            raise ImportError_(material.validation_issues)
        matching = [i for i, s in enumerate(self.stock) if s.id == stock_id]
        if len(matching) != 1:
            raise ImportError_(["This stock is no longer available. Select it again before editing its material."])
        index = matching[0]
        if self.stock[index].material_id != expected_material_id:
            raise ImportError_(["This stock's material changed while you were editing. Reopen its current material before saving."])
        reserved = ({m.id for m in self.custom_materials or []} | {s.material_id for s in self.stock}
                    | {s.material_snapshot.id for s in self.stock if s.material_snapshot is not None})
        if MaterialLibrary.material(material.id) is not None or material.id in reserved:
            raise ImportError_(["Use a new custom material identity for this stock. Existing material definitions must remain unchanged."])
        nxt = self.copy()
        nxt.custom_materials = list(self.custom_materials or []) + [material]
        nxt.stock[index].material_id = material.id
        nxt.stock[index].material_snapshot = material
        return nxt

    # ---- the starting inventory
    @staticmethod
    def flat_clamping_kit() -> list[Fixture]:
        from .. import data
        return [codable.from_json(Fixture, d) for d in data.load("flat_clamping_kit.json")]

    @staticmethod
    def starter(tool_libraries: list[Path]) -> "Inventory":
        """The first-launch inventory, from what ships in the standard machine kit. Everything is
        editable; the app asks the user to confirm what they own."""
        from .tool_library_import import ToolLibraryImport
        inv = Inventory()
        for path in tool_libraries:
            try:
                result = ToolLibraryImport.load(path)
            except Exception:  # noqa: BLE001
                continue
            for t in result.tools:
                t.notes = "Imported from the maker's library. Set the quantity to what you own."
                inv.tools.append(t)
        inv.accessories = [
            Accessory.make('ER-11 collet 1/8"', AccessoryKind.COLLET, size=3.175, notes="Used by the maker's cutcodes."),
            Accessory.make('ER-11 collet 1/4"', AccessoryKind.COLLET, size=6.35, notes="Used by the maker's cutcodes."),
        ]
        inv.fixtures = [
            Fixture.make("Universal Clamp", FixtureKind.UNIVERSAL_CLAMP, clamp_axis=ClampAxis.X, height=0, isolated=True,
                         model_path="fixtures/universal_clamp_v96.step",
                         notes="Bolts to the T-slots, clamps in X and is electrically isolated, so conductive probing works. [MAN §4.4]"),
            Fixture.make("Quick Release Jig Plate", FixtureKind.JIG_PLATE, model_path="fixtures/quick_release_jig_plate.step",
                         notes="Jig Plate Rev D (metric). M5 shoulder bolts, insulating pad and washer."),
            Fixture.make("M4 T-slot nuts", FixtureKind.T_SLOT_NUTS, quantity=4,
                         notes="Fairway JPPNM04016 (11 × 3.14 × 15.87 mm). 80/20 25-1941 / 25-1951 are equivalent."),
        ]
        # The flat kit's fixtures get fresh IDs, as the Swift static list did per launch.
        from ..ids import new_id
        for f in Inventory.flat_clamping_kit():
            f.id = new_id()
            inv.fixtures.append(f)
        inv.flat_kit_added = True
        inv.measuring = [MeasuringTool.make('0.2" edge finder', MeasuringKind.EDGE_FINDER, resolution=0.01,
                                            notes='0.2" (5.08 mm) tip: offset 2.54 mm. Run at about 1500 RPM. [MAN §4.6]')]
        inv.stock = [StockItem.make("al-6061", 150, 80, 20, notes="From your machine dimensions model.")]
        return inv

    @staticmethod
    def from_json(d) -> "Inventory":
        return codable.decode_dataclass(Inventory, d)

    def to_json(self) -> dict:
        out = {}
        import dataclasses
        for f in dataclasses.fields(self):
            v = getattr(self, f.name)
            if v is not None:
                out[codable.camel(f.name)] = codable.to_json(v)
        return out


class NewerSchema(Exception):
    def __init__(self, version: int) -> None:
        super().__init__(f"This inventory was saved by a newer Coastline (format {version}). Update the app.")
        self.version = version


class InventoryStore:
    """Loads and saves the inventory JSON."""

    @staticmethod
    def default_path() -> Path:
        return application_support() / "Inventory.json"

    @staticmethod
    def load(path: Path | None = None) -> Inventory | None:
        """None when there's no file yet."""
        path = path or InventoryStore.default_path()
        if not path.exists():
            return None
        inventory = codable.decode(Inventory, path.read_bytes())
        if inventory.schema > CURRENT_SCHEMA:
            raise NewerSchema(inventory.schema)
        inventory.schema = CURRENT_SCHEMA
        return inventory

    @staticmethod
    def save(inventory: Inventory, path: Path | None = None) -> None:
        """Writes atomically, keeping the previous version as `Inventory.json.bak`."""
        path = path or InventoryStore.default_path()
        write_atomic(path, codable.encode(inventory, pretty=True, sort_keys=True, escape_slashes=False), backup=True)
