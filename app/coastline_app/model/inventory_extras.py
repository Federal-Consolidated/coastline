"""Inventory screens beyond the tables: a stock item's material (shown and customised), a
fixture's planning profile (the stock it holds and its grip patches), and resource library
import/export. Port of Views/Library/MaterialsPage.swift, Inventory/FixturePlanningSection.swift
and Inventory/ResourceLibraryActions.swift."""

from __future__ import annotations

import copy
import dataclasses
from pathlib import Path

from PySide6.QtCore import QObject, QUrl, Slot

from ..core.codable import Range
from ..core.geometry import Vec3
from ..core.ids import new_id
from ..core.inventory.resource_library import ConflictPolicy, ImportError_, ResourceLibraryImport, ResourceLibraryPackage
from ..core.materials import MaterialLibrary
from ..core.plan.setup import FACINGS, Facing
from ..core.plan.workholding_profile import Contact, ContactNormal, FixturePlanningProfile
from ..core.units import Length
from .bindable import prop

MATERIAL_TEXT = ("name", "grade", "hardness", "lubricant", "chips", "tooling", "notes", "source")
MATERIAL_NUMBERS = ("density", "chip_load_factor", "adaptive_stepover_max", "adaptive_depth_max", "slot_depth_max",
                    "specific_cutting_force", "tool_wear_factor")


def _path(url: str) -> Path:
    return Path(QUrl(url).toLocalFile() if "://" in str(url) else str(url))


class InventoryExtras(QObject):
    revision, revisionChanged = prop(int, "revision", 0)
    lastError, lastErrorChanged = prop(str, "lastError", "")
    message, messageChanged = prop(str, "message", "")

    def __init__(self, inventory_model, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.model = inventory_model
        self._pending_import = None
        inventory_model.revisionChanged.connect(self.touch)

    def touch(self) -> None:
        self.revision = self.revision + 1

    @property
    def inv(self):
        return self.model.inventory

    # ---------------------------------------------------------------- materials

    @Slot(str, result="QVariantMap")
    def material(self, stock_id: str) -> dict:
        s = next((x for x in self.inv.stock if x.id == stock_id), None)
        m = s.material if s is not None else None
        if m is None:
            return {}
        d = {k: getattr(m, k) or "" for k in MATERIAL_TEXT}
        d.update({k: float(getattr(m, k)) for k in MATERIAL_NUMBERS})
        d.update({"id": m.id, "family": m.family.title, "difficulty": m.difficulty.title, "speedMin": m.surface_speed.lower,
                  "speedMax": m.surface_speed.upper, "builtIn": MaterialLibrary.material(m.id) is not None,
                  "summary": [["Grade", m.grade], ["Density", f"{m.density:.2f} g/cm³"],
                              ["Surface speed", f"{m.surface_speed.lower:.0f}–{m.surface_speed.upper:.0f} m/min"],
                              ["Chip load factor", f"{m.chip_load_factor:.2f} × aluminium"], ["Family", m.family.title],
                              ["Cutting mode", m.difficulty.title], ["Maximum stepover", f"{m.adaptive_stepover_max * 100:.0f}% of ⌀"],
                              ["Adaptive depth", f"{Length.mm(m.adaptive_depth_max)} × ⌀"], ["Slot depth", f"{Length.mm(m.slot_depth_max)} × ⌀"],
                              ["Cutting force", f"{m.specific_cutting_force:.0f} N/mm²"], ["Tool wear", f"{m.tool_wear_factor:.1f} × aluminium"]],
                  "notesList": [[t, v] for t, v in (("Lubricant", m.lubricant), ("Chips", m.chips), ("Tooling", m.tooling), ("Notes", m.notes),
                                                    ("Source", m.source or "")) if v]})
        return d

    @Slot(str, "QVariantMap", result=str)
    def customizeMaterial(self, stock_id: str, fields) -> str:
        """Gives one stock item its own material definition. Returns the problem, or ""."""
        s = next((x for x in self.inv.stock if x.id == stock_id), None)
        if s is None or s.material is None:
            return "This stock is no longer available."
        m = copy.deepcopy(s.material)
        try:
            lo, hi = float(fields.get("speedMin", m.surface_speed.lower)), float(fields.get("speedMax", m.surface_speed.upper))
        except (TypeError, ValueError):
            return "Enter a positive surface-speed range, with the maximum at least as large as the minimum."
        if not (lo > 0 and hi >= lo):
            return "Enter a positive surface-speed range, with the maximum at least as large as the minimum."
        changes = {"surface_speed": Range(lo, hi)}
        for k in MATERIAL_TEXT:
            if k in fields:
                changes[k] = str(fields[k]) if k != "source" or fields[k] else None
        for k in MATERIAL_NUMBERS:
            if k in fields:
                changes[k] = float(fields[k])
        m = dataclasses.replace(m, **changes)
        if MaterialLibrary.material(m.id) is not None or any(x.material_id == m.id for x in self.inv.stock if x.id != stock_id):
            m = dataclasses.replace(m, id="custom-" + new_id().lower())
        issues = m.validation_issues
        if issues:
            return "\n".join(issues)
        try:
            nxt = self.inv.customizing_stock_material(m, stock_id, s.material_id)
            self.model.commit_library(nxt)
        except ImportError_ as e:
            return " ".join(e.args[0]) if e.args and isinstance(e.args[0], list) else str(e)
        except Exception as e:  # noqa: BLE001
            return str(e)
        self.touch()
        return ""

    # ---------------------------------------------------------------- fixture planning

    @Slot(str, result="QVariantMap")
    def fixturePlanning(self, fixture_id: str) -> dict:
        f = next((x for x in self.inv.fixtures if x.id == fixture_id), None)
        if f is None:
            return {}
        p = f.planning
        if p is None:
            return {"enabled": False, "defined": False}
        return {"enabled": p.enabled, "defined": True, "stockX": p.stock_size.x, "stockY": p.stock_size.y, "stockZ": p.stock_size.z,
                "datumX": p.datum.x, "datumY": p.datum.y, "datumZ": p.datum.z, "facing": p.facing.value, "spin": p.spin,
                "facings": [{"value": x.value, "title": x.title} for x in FACINGS], "facePastTable": p.face_past_table,
                "allowsRoughing": p.allows_roughing, "reviewed": p.grip_definition_reviewed,
                "contacts": [{"id": c.id, "x": c.point.x, "y": c.point.y, "z": c.point.z, "radius": c.radius,
                              "normal": (c.normal or ContactNormal.Z).value} for c in p.contacts],
                "issues": list(p.definition_issues)}

    def _change_profile(self, fixture_id: str, fn, keep_review: bool = False) -> None:
        def change(inv):
            for f in inv.fixtures:
                if f.id == fixture_id:
                    p = copy.deepcopy(f.planning) if f.planning is not None else FixturePlanningProfile()
                    fn(p)
                    if not keep_review:
                        p.grip_definition_reviewed = False
                    f.planning = p
        self.model.update(change)

    @Slot(str, str, "QVariant")
    def setFixturePlanning(self, fixture_id: str, key: str, value) -> None:
        def fn(p):
            if key == "enabled":
                p.enabled = bool(value)
            elif key in ("stockX", "stockY", "stockZ"):
                v = p.stock_size
                p.stock_size = Vec3(float(value) if key == "stockX" else v.x, float(value) if key == "stockY" else v.y, float(value) if key == "stockZ" else v.z)
            elif key in ("datumX", "datumY", "datumZ"):
                v = p.datum
                p.datum = Vec3(float(value) if key == "datumX" else v.x, float(value) if key == "datumY" else v.y, float(value) if key == "datumZ" else v.z)
            elif key == "facing":
                p.facing = Facing(str(value))
            elif key == "spin":
                p.spin = int(value) % 4
            elif key == "facePastTable":
                p.face_past_table = float(value)
            elif key == "allowsRoughing":
                p.allows_roughing = bool(value)
            elif key == "reviewed":
                p.grip_definition_reviewed = bool(value)
        self._change_profile(fixture_id, fn, keep_review=key in ("reviewed", "enabled"))

    @Slot(str, "QVariantList")
    def useStockSizeForFixture(self, fixture_id: str, size) -> None:
        if len(size) == 3:
            self._change_profile(fixture_id, lambda p: setattr(p, "stock_size", Vec3(*map(float, size))))

    @Slot(str)
    def addContact(self, fixture_id: str) -> None:
        self._change_profile(fixture_id, lambda p: p.contacts.append(Contact()))

    @Slot(str, str)
    def removeContact(self, fixture_id: str, contact_id: str) -> None:
        self._change_profile(fixture_id, lambda p: setattr(p, "contacts", [c for c in p.contacts if c.id != contact_id]))

    @Slot(str, str, str, "QVariant")
    def setContact(self, fixture_id: str, contact_id: str, key: str, value) -> None:
        def fn(p):
            for c in p.contacts:
                if c.id != contact_id:
                    continue
                if key in ("x", "y", "z"):
                    v = c.point
                    c.point = Vec3(float(value) if key == "x" else v.x, float(value) if key == "y" else v.y, float(value) if key == "z" else v.z)
                elif key == "radius":
                    c.radius = max(float(value), 0.1)
                elif key == "normal":
                    c.normal = ContactNormal(str(value))
        self._change_profile(fixture_id, fn)

    # ---------------------------------------------------------------- resource library

    @Slot(str, str, "QVariantList")
    def exportLibrary(self, url: str, scope: str, ids) -> None:
        """scope: "stock" or "tools"; ids: the selection (empty: all of that kind)."""
        selected = {str(i) for i in ids} or None
        try:
            pkg = ResourceLibraryPackage.exporting(self.inv, "Coastline " + ("Stock" if scope == "stock" else "Tools"),
                                                   stock_ids=(selected if scope == "stock" else set()),
                                                   tool_ids=(selected if scope == "tools" else set()),
                                                   material_ids=None if scope == "stock" else set())
            path = _path(url)
            if path.suffix != ".json":
                path = path.with_suffix(".json")
            path.write_bytes(pkg.encoded())
            self.message = f"Exported to {path.name}"
        except ImportError_ as e:
            self.lastError = " ".join(e.args[0]) if e.args and isinstance(e.args[0], list) else str(e)
        except Exception as e:  # noqa: BLE001
            self.lastError = str(e)

    @Slot(str, str, result="QVariantMap")
    def previewImport(self, url: str, policy: str) -> dict:
        try:
            incoming = ResourceLibraryImport.load(_path(url))
            preview = ResourceLibraryImport.prepare(incoming, self.inv, ConflictPolicy(policy))
        except ImportError_ as e:
            self._pending_import = None
            return {"error": " ".join(e.args[0]) if e.args and isinstance(e.args[0], list) else str(e)}
        except Exception as e:  # noqa: BLE001
            self._pending_import = None
            return {"error": str(e)}
        self._pending_import = preview
        return {"error": "", "name": incoming.name, "added": preview.added_count, "replaced": preview.replaced_count,
                "kept": preview.kept_count, "copied": preview.copied_count, "warnings": list(preview.warnings),
                "rows": [{"name": r.name, "kind": r.kind.value, "action": r.action.value, "detail": r.detail} for r in preview.rows]}

    @Slot(result=str)
    def applyImport(self) -> str:
        p = self._pending_import
        if p is None:
            return "Choose a library file first."
        try:
            self.model.commit_library(p.inventory)
        except Exception as e:  # noqa: BLE001
            return str(e)
        self._pending_import = None
        self.message = f"Imported: {p.added_count} added, {p.replaced_count} replaced, {p.copied_count} added as copies."
        self.touch()
        return ""
