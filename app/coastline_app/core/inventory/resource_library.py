"""Portable stock, cutting-tool and material libraries (`.coastlib`, JSON), and their import as a
reviewable preview. Port of Inventory/ResourceLibraryPackage.swift."""

from __future__ import annotations

import copy
import hashlib
import json
from dataclasses import dataclass, field, replace
from enum import Enum
from pathlib import Path

from .. import codable
from ..materials import Material, MaterialLibrary
from ..units import Length
from .checks import ResourceLibraryValidation
from .items import StockItem, Tool

CURRENT_SCHEMA = 1


class ImportError_(Exception):
    """A library or import problem; `issues` are shown to the user one per line."""

    def __init__(self, issues: list[str]) -> None:
        self.issues = issues
        super().__init__("\n".join(issues))


@dataclass(frozen=True)
class Units:
    length: str = "mm"
    feed: str = "mm/min"
    density: str = "g/cm3"
    surface_speed: str = "m/min"
    specific_cutting_force: str = "N/mm2"


MILLIMETERS = Units()
INCHES = Units(length="in", feed="in/min")


@dataclass
class ResourceLibraryPackage:
    name: str
    units: Units = MILLIMETERS
    stock: list[StockItem] = field(default_factory=list)
    tools: list[Tool] = field(default_factory=list)
    materials: list[Material] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)  # import notes
    schema_version: int = CURRENT_SCHEMA

    @staticmethod
    def from_json(d) -> "ResourceLibraryPackage":
        return ResourceLibraryPackage(
            name=d["name"], units=codable.from_json(Units, d["units"]),
            stock=codable.from_json(list[StockItem], d.get("stock") or []),
            tools=codable.from_json(list[Tool], d.get("tools") or []),
            materials=codable.from_json(list[Material], d.get("materials") or []),
            warnings=list(d.get("warnings") or []), schema_version=int(d["schemaVersion"]))

    def to_json(self) -> dict:
        return {"schemaVersion": self.schema_version, "name": self.name, "units": codable.to_json(self.units),
                "stock": codable.to_json(self.stock), "tools": codable.to_json(self.tools),
                "materials": codable.to_json(self.materials), "warnings": list(self.warnings)}

    @staticmethod
    def exporting(inventory, name: str, stock_ids: set[str] | None = None, tool_ids: set[str] | None = None,
                  material_ids: set[str] | None = None) -> "ResourceLibraryPackage":
        """Selected rows and every material used by their stock. None selects all rows of that kind."""
        stock = [inventory.resolved_stock(s) for s in inventory.stock if stock_ids is None or s.id in stock_ids]
        tools = [copy.deepcopy(t) for t in inventory.tools if tool_ids is None or t.id in tool_ids]
        materials = [m for m in inventory.materials
                     if (m.id in material_ids if material_ids is not None else MaterialLibrary.material(m.id) is None)]
        for item in stock:
            material = item.material
            if material is None:
                raise ImportError_([f"Stock {item.size_description} has no material definition for {item.material_id}."])
            existing = next((m for m in materials if m.id == material.id), None)
            if existing is not None and existing != material:
                raise ImportError_([f"Stock uses a different saved definition of {material.name}. Export it separately or select the current material first."])
            if existing is None:
                materials.append(material)
        return ResourceLibraryPackage(name, stock=stock, tools=tools, materials=materials).canonicalized()

    def encoded(self) -> bytes:
        return codable.encode(self.canonicalized(), pretty=True, sort_keys=True, escape_slashes=False)

    def canonicalized(self) -> "ResourceLibraryPackage":
        """Normalizes lengths and rejects malformed packages before a merge can change inventory."""
        if self.schema_version != CURRENT_SCHEMA:
            raise ImportError_([f"Unsupported library format {self.schema_version}; this app supports format {CURRENT_SCHEMA}."])
        if self.units not in (MILLIMETERS, INCHES):
            raise ImportError_(["Unsupported or inconsistent units. Use mm with mm/min, or in with in/min; materials use g/cm3, m/min and N/mm2."])
        result = copy.deepcopy(self)
        if self.units == INCHES:
            result.warnings.append("Converted inch dimensions and feeds to millimetres and mm/min. Material values retain their declared SI-derived units.")
            for s in result.stock:
                s.size_x *= 25.4
                s.size_y *= 25.4
                s.size_z *= 25.4
            for t in result.tools:
                t.diameter *= 25.4
                t.shank_diameter *= 25.4
                t.flute_length *= 25.4
                t.stickout *= 25.4
                t.overall_length *= 25.4
                t.corner_radius *= 25.4
                t.tip_diameter *= 25.4
                t.thread_pitch = None if t.thread_pitch is None else t.thread_pitch * 25.4
                t.cutting_distance *= 25.4
                for p in t.presets:
                    p.feed *= 25.4
                    p.plunge_feed *= 25.4
                    p.ramp_feed *= 25.4
                    p.stepdown = None if p.stepdown is None else p.stepdown * 25.4
                    p.stepover = None if p.stepover is None else p.stepover * 25.4
        result.units = MILLIMETERS
        problems = []
        if not self.name.strip():
            problems.append("Give the library a name.")
        if len({s.id for s in self.stock}) != len(self.stock):
            problems.append("The library contains duplicate stock IDs.")
        if len({t.id for t in self.tools}) != len(self.tools):
            problems.append("The library contains duplicate tool IDs.")
        if len({m.id for m in self.materials}) != len(self.materials):
            problems.append("The library contains duplicate material IDs.")
        for s in result.stock:
            problems += [f"Stock {s.size_description}: {m}" for m in ResourceLibraryValidation.stock_issues(s)]
        for t in result.tools:
            problems += [f"{t.name}: {m}" for m in ResourceLibraryValidation.tool_issues(t)]
        for m in result.materials:
            problems += [f"{m.name}: {i}" for i in m.validation_issues]
        if problems:
            raise ImportError_(problems)
        return result


class ConflictPolicy(Enum):
    KEEP_EXISTING = "keepExisting"
    REPLACE_EXISTING = "replaceExisting"
    ADD_AS_COPY = "addAsCopy"


class RowKind(Enum):
    STOCK = "stock"
    TOOL = "tool"
    MATERIAL = "material"


class Action(Enum):
    ADD = "add"
    KEEP = "keep"
    REPLACE = "replace"
    COPY = "copy"


@dataclass(frozen=True)
class Row:
    id: str
    kind: RowKind
    name: str
    action: Action
    detail: str
    quantity: int | None = None
    dimensions: str | None = None


@dataclass
class Preview:
    inventory: object
    rows: list[Row]
    warnings: list[str]

    def _count(self, a: Action) -> int:
        return sum(1 for r in self.rows if r.action is a)

    @property
    def added_count(self) -> int:
        return self._count(Action.ADD)

    @property
    def replaced_count(self) -> int:
        return self._count(Action.REPLACE)

    @property
    def kept_count(self) -> int:
        return self._count(Action.KEEP)

    @property
    def copied_count(self) -> int:
        return self._count(Action.COPY)


def canonical_string(value) -> str:
    """Swift's JSONEncoder with [.sortedKeys, .withoutEscapingSlashes]."""
    return codable.dumps(codable.to_json(value), sort_keys=True, escape_slashes=False)


def stable_digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def stable_id(value: str) -> str:
    h = stable_digest(value)[:32]
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}".upper()


class ResourceLibraryImport:
    @staticmethod
    def load(path: Path) -> ResourceLibraryPackage:
        from .tool_library_import import ToolLibraryImport
        if path.suffix.lower() == ".tools":
            return ResourceLibraryImport._fusion_package(ToolLibraryImport.load(path), path.stem)
        data = path.read_bytes()
        try:
            root = json.loads(data)
        except ValueError:
            root = None
        if isinstance(root, dict) and "data" in root and "schemaVersion" not in root:
            return ResourceLibraryImport._fusion_package(ToolLibraryImport.parse(data, path.name), path.stem)
        return ResourceLibraryImport.parse(data)

    @staticmethod
    def parse(data: bytes) -> ResourceLibraryPackage:
        return codable.decode(ResourceLibraryPackage, data).canonicalized()

    @staticmethod
    def _fusion_package(result, name: str) -> ResourceLibraryPackage:
        if not result.tools:
            raise ImportError_(["No supported cutting tools were found."] + result.skipped)
        package = ResourceLibraryPackage(name, tools=result.tools)
        package.warnings = result.warnings + [f"Skipped: {s}" for s in result.skipped]
        return package.canonicalized()

    @staticmethod
    def prepare(incoming: ResourceLibraryPackage, inventory, policy: ConflictPolicy = ConflictPolicy.KEEP_EXISTING) -> Preview:
        """Pure transaction: no caller-owned inventory changes until it accepts this preview."""
        package = incoming.canonicalized()
        merged = inventory.copy()
        rows: list[Row] = []
        warnings = list(package.warnings)
        remapped: dict[str, str] = {}
        candidates = list(package.materials)
        for stock in package.stock:  # an embedded stock definition also makes a custom material portable
            embedded = stock.material_snapshot
            if embedded is None:
                continue
            m = next((c for c in candidates if c.id == embedded.id), None)
            if m is not None:
                if m != embedded:
                    raise ImportError_([f"Stock and library disagree about material {embedded.id}."])
            else:
                candidates.append(embedded)
        for material in candidates:
            existing = merged.material(material.id)
            builtin = MaterialLibrary.material(material.id) is not None
            value = material
            detail = "New material"
            if existing is not None:
                if existing == material or policy is ConflictPolicy.KEEP_EXISTING:
                    action = Action.KEEP
                    detail = "Already installed" if existing == material else "Keep your existing material"
                    if existing != material:
                        warnings.append(f"{material.name}: stock will use your existing material definition.")
                elif policy is ConflictPolicy.ADD_AS_COPY or builtin:
                    value = replace(material, id="custom-" + stable_digest("material-copy:" + canonical_string(material))[:24])
                    remapped[material.id] = value.id
                    if any(c.id == value.id for c in candidates):
                        raise ImportError_([f"The copied material ID for {material.name} conflicts with another incoming material."])
                    prior = merged.material(value.id)
                    if prior is not None:
                        if prior != value:
                            raise ImportError_([f"The saved copy of {material.name} has a different definition. Keep the existing material or give the edited copy a new ID before importing another copy."])
                        action, detail = Action.KEEP, "Copy already installed"
                    else:
                        action = Action.COPY
                        detail = "Built-in material kept; install a custom copy" if builtin else "Install a separate material"
                        merged.custom_materials = list(merged.custom_materials or []) + [value]
                    if builtin and policy is ConflictPolicy.REPLACE_EXISTING:
                        warnings.append(f"{material.name} is built in. A custom copy will be installed instead of changing it.")
                else:
                    action, detail = Action.REPLACE, "Replace material definition"
                    for i, m in enumerate(merged.custom_materials or []):
                        if m.id == material.id:
                            merged.custom_materials[i] = material
                            break
            else:
                action = Action.ADD
                merged.custom_materials = list(merged.custom_materials or []) + [material]
            rows.append(Row(f"material:{material.id}", RowKind.MATERIAL, material.name, action, detail))
        for original in package.stock:
            stock = original.copy()
            existing_item = next((s for s in merged.stock if s.id == stock.id), None)
            if existing_item is not None and policy is ConflictPolicy.KEEP_EXISTING:
                m = merged.material(existing_item.material_id)
                name = ((m.name if m else None) or (existing_item.material.name if existing_item.material else None)
                        or existing_item.material_id) + " · " + existing_item.size_description
                rows.append(Row(f"stock:{original.id}", RowKind.STOCK, name, Action.KEEP, "Keep your existing stock and quantity",
                                existing_item.quantity, existing_item.size_description))
                continue
            stock.material_id = remapped.get(stock.material_id, stock.material_id)
            material = merged.material(stock.material_id)
            if material is None:
                raise ImportError_([f"Stock {stock.size_description} needs material {stock.material_id}, which is not in this library or your installed materials."])
            stock.material_snapshot = material
            index = next((i for i, s in enumerate(merged.stock) if s.id == stock.id), None)
            action, detail = Action.ADD, "New stock"
            if index is not None:
                if policy is ConflictPolicy.KEEP_EXISTING or merged.stock[index] == stock:
                    action, detail = Action.KEEP, "Keep your existing stock and quantity"
                elif policy is ConflictPolicy.REPLACE_EXISTING:
                    stock.quantity, stock.location = merged.stock[index].quantity, merged.stock[index].location
                    merged.stock[index] = stock
                    action, detail = Action.REPLACE, "Replace stock definition; keep quantity and location"
                else:
                    stock.id = stable_id("stock-copy:" + canonical_string(stock))
                    if any(s.id == stock.id for s in package.stock):
                        raise ImportError_(["A copied stock ID conflicts with another incoming stock entry."])
                    prior = next((s for s in merged.stock if s.id == stock.id), None)
                    if prior is not None:
                        definition = prior.copy()
                        definition.quantity, definition.location = stock.quantity, stock.location
                        if definition != stock:
                            raise ImportError_(["The saved stock copy has a different definition. Keep the existing stock or give the edited copy a new ID before importing another copy."])
                        action, detail = Action.KEEP, "Copy already installed"
                    else:
                        merged.stock.append(stock)
                        action, detail = Action.COPY, "Install separate stock"
            else:
                merged.stock.append(stock)
            if stock.model_path:
                warnings.append(f"{stock.size_description}: its printed-blank CAD file is referenced, not included in this library.")
            installed = next((s for s in merged.stock if s.id == stock.id), stock)
            rows.append(Row(f"stock:{original.id}", RowKind.STOCK, material.name, action, detail, installed.quantity,
                            installed.size_description))
        for original in package.tools:
            tool = original.copy()
            action, detail = Action.ADD, "New tool"
            index = next((i for i, t in enumerate(merged.tools) if t.id == tool.id), None)
            if index is not None:
                if policy is ConflictPolicy.KEEP_EXISTING or merged.tools[index] == tool:
                    action, detail = Action.KEEP, "Keep your existing tool and quantity"
                elif policy is ConflictPolicy.REPLACE_EXISTING:
                    o = merged.tools[index]
                    tool.quantity, tool.condition = o.quantity, o.condition
                    tool.cutting_minutes, tool.cutting_distance = o.cutting_minutes, o.cutting_distance
                    merged.tools[index] = tool
                    action, detail = Action.REPLACE, "Replace tool definition; keep quantity, condition and usage"
                else:
                    tool.id = stable_id("tool-copy:" + canonical_string(tool))
                    if any(t.id == tool.id for t in package.tools):
                        raise ImportError_([f"The copied tool ID for {tool.name} conflicts with another incoming tool."])
                    prior = next((t for t in merged.tools if t.id == tool.id), None)
                    if prior is not None:
                        definition = prior.copy()
                        definition.quantity, definition.condition = tool.quantity, tool.condition
                        definition.cutting_minutes, definition.cutting_distance = tool.cutting_minutes, tool.cutting_distance
                        if definition != tool:
                            raise ImportError_([f"The saved copy of {tool.name} has a different definition. Keep the existing tool or give the edited copy a new ID before importing another copy."])
                        action, detail = Action.KEEP, "Copy already installed"
                    else:
                        merged.tools.append(tool)
                        action, detail = Action.COPY, "Install a separate tool"
            else:
                merged.tools.append(tool)
            installed = next((t for t in merged.tools if t.id == tool.id), tool)
            dims = (f"⌀{Length.mm(installed.diameter)} · shank {Length.mm(installed.shank_diameter)} · flute "
                    f"{Length.mm(installed.flute_length)} · stickout {Length.mm(installed.stickout)} mm")
            rows.append(Row(f"tool:{original.id}", RowKind.TOOL, installed.name, action, detail, installed.quantity, dims))
        return Preview(merged, rows, sorted(set(warnings)))
