"""The job journal on disk: `journal.json` and a photos folder next to the inventory.
Port of Model/JournalModel.swift (dates as ISO 8601, as the Swift app wrote them)."""

from __future__ import annotations

import datetime as _dt
import json
import os
import shutil
import uuid
from pathlib import Path

from PySide6.QtCore import QObject, Slot

from ..core import codable
from ..core.inventory.inventory import InventoryStore
from ..core.journal import FeedLearning, JournalEntry, Outcome
from ..core.machine import maintenance
from ..core.storage import write_atomic
from .bindable import prop


def resolved_path() -> Path:
    p = os.environ.get("COASTLINE_INVENTORY")
    if p:
        return Path(p + ".journal.json")
    return InventoryStore.default_path().parent / "journal.json"


def _date_from(v) -> _dt.datetime:
    return codable.date_from_json(v)


class JournalModel(QObject):
    revision, revisionChanged = prop(int, "revision", 0)

    def __init__(self, path: Path | None = None, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.path = path or resolved_path()
        self.entries: list[JournalEntry] = []
        self.learning = FeedLearning()
        self.maintenance: dict[str, maintenance.Record] = {}
        try:
            d = json.loads(self.path.read_text())
            self.entries = [_entry_from(e) for e in d.get("entries", [])]
            self.learning = codable.from_json(FeedLearning, d.get("learning", {}))
            self.maintenance = {k: maintenance.Record(_date_from(v["date"]), int(v["jobs"]), float(v["cuttingMinutes"]))
                                for k, v in (d.get("maintenance") or {}).items()}
        except (OSError, ValueError, KeyError, TypeError, codable.DecodeError):
            pass

    @property
    def photos_dir(self) -> Path:
        return self.path.parent / "journal-photos"

    def add(self, e: JournalEntry, tools: list) -> None:
        self.entries.insert(0, e)
        self.learning.learn(e, tools)
        self._save()

    @Slot(str)
    def remove(self, id: str) -> None:
        self.entries = [e for e in self.entries if e.id != id]
        self._save()

    @property
    def total_cutting_minutes(self) -> float:
        return sum(e.cutting_minutes for e in self.entries)

    def maintenance_status(self) -> list[maintenance.Due]:
        since = self.entries[-1].date if self.entries else None
        return maintenance.status(self.maintenance, len(self.entries), self.total_cutting_minutes, since)

    @Slot(result="QVariantList")
    def maintenanceRows(self) -> list[dict]:
        return [{"id": d.task.id, "title": d.task.title, "detail": d.task.detail, "due": d.due, "why": d.why}
                for d in self.maintenance_status()]

    @Slot(result=int)
    def dueCount(self) -> int:
        return sum(1 for d in self.maintenance_status() if d.due)

    @Slot(str)
    def markDone(self, task_id: str) -> None:
        self.maintenance[task_id] = maintenance.Record(_dt.datetime.now(_dt.timezone.utc), len(self.entries), self.total_cutting_minutes)
        self._save()

    def import_photo(self, src: Path) -> str | None:
        """Copies a photo into the journal's folder; returns its file name there."""
        self.photos_dir.mkdir(parents=True, exist_ok=True)
        name = str(uuid.uuid4()).upper() + (Path(src).suffix.lower() or ".jpg")
        try:
            shutil.copyfile(src, self.photos_dir / name)
            return name
        except OSError:
            return None

    @Slot(result="QVariantList")
    def learnedRows(self) -> list[dict]:
        """"Learned from your jobs": the feed factors chatter reports have moved."""
        from ..core.inventory.items import ToolKind
        out = []
        inv = getattr(self, "inventory_model", None)
        for k, v in sorted(self.learning.factors.items()):
            if abs(v - 1) <= 0.001:
                continue
            parts = k.split("|")
            mid, kind = parts[0], parts[-1]
            m = inv.inventory.material(mid) if inv is not None and hasattr(inv.inventory, "material") else None
            name = m.name if m is not None else next((e.material_snapshot.name for e in self.entries if e.material_snapshot is not None and e.material_snapshot.id == mid), mid)
            try:
                kt = ToolKind(kind).title
            except ValueError:
                kt = kind
            out.append({"label": f"{kt} in {name}", "value": f"feeds ×{v:.2f}"})
        return out

    @Slot(result="QVariantList")
    def rows(self) -> list[dict]:
        out = []
        for e in self.entries:
            d = e.date.astimezone()
            mat = e.material_snapshot.name if e.material_snapshot is not None and e.material_snapshot.id == e.material_id else e.material_id
            mins = e.cutting_minutes
            dur = f"{int(mins // 60)} h {int(round(mins % 60))} min" if mins >= 60 else f"{max(int(round(mins)), 1)} min"
            out.append({"outcomeKey": e.outcome.value, "copies": e.copies,
                        "line": f"{d.strftime('%b')} {d.day}, {d.year} at {d.strftime('%I:%M %p').lstrip('0')} · {mat} · {dur}",
                        "id": e.id, "part": e.part_name, "date": e.date.astimezone().strftime("%Y-%m-%d %H:%M"),
                        "outcome": e.outcome.title, "minutes": round(e.cutting_minutes, 1), "stock": e.stock_description,
                        "chatter": e.chatter, "finish": e.finish, "notes": e.notes,
                        "measurements": [{"what": m.what, "expected": m.expected, "tolerance": m.tolerance,
                                          "measured": m.measured, "ok": m.in_tolerance} for m in e.measurements]})
        return out

    def _save(self) -> None:
        stored = {"entries": [_entry_to(e) for e in self.entries], "learning": codable.to_json(self.learning),
                  "maintenance": {k: {"date": codable.date_to_json(r.date, True), "jobs": r.jobs, "cuttingMinutes": r.cutting_minutes}
                                  for k, r in self.maintenance.items()}}
        write_atomic(self.path, codable.dumps(stored, pretty=True).encode())
        self.revision = self.revision + 1


def _entry_to(e: JournalEntry) -> dict:
    d = codable.to_json(e)
    d["date"] = codable.date_to_json(e.date, True)  # the journal stores ISO 8601 dates
    return d


def _entry_from(d: dict) -> JournalEntry:
    d = dict(d)
    return codable.from_json(JournalEntry, d)


class JournalUI(JournalModel):
    """The record-a-job form (RecordJobSheet) and an entry's detail (JournalDetail)."""

    def __init__(self, path: Path | None = None, parent: QObject | None = None) -> None:
        super().__init__(path, parent)
        self.draft: JournalEntry | None = None
        self.put_back = True
        self.inventory_model = None  # set by AppRoot
        self.on_recorded = lambda message: None

    def touch(self) -> None:
        self.revision = self.revision + 1

    def begin_draft(self, e: JournalEntry) -> None:
        self.draft = e
        self.put_back = True
        self.touch()

    @Slot(result="QVariantMap")
    def draftInfo(self) -> dict:
        e = self.draft
        if e is None:
            return {}
        return {"part": e.part_name, "outcome": e.outcome.value, "finish": e.finish, "chatter": e.chatter, "notes": e.notes,
                "copies": e.copies, "photos": list(e.photos), "putBack": self.put_back,
                "remnant": e.remnant_length if e.remnant_length is not None else -1,
                "tools": [{"id": p.tool_id, "name": p.tool_name, "chatter": p.tool_id in e.chatter_tool_ids}
                          for k, p in enumerate(e.programs) if all(q.tool_id != p.tool_id for q in e.programs[:k])],
                "measurements": [{"what": m.what, "expected": m.expected, "tolerance": m.tolerance,
                                  "measured": m.measured if m.measured is not None else None} for m in e.measurements],
                "outcomes": [{"value": o.value, "title": o.title} for o in Outcome]}

    @Slot(str, "QVariant")
    def setDraftField(self, key: str, value) -> None:
        e = self.draft
        if e is None:
            return
        if key == "outcome":
            e.outcome = Outcome(str(value))
        elif key == "finish":
            e.finish = int(value)
        elif key == "chatter":
            e.chatter = bool(value)
        elif key == "notes":
            e.notes = str(value)
        elif key == "copies":
            e.copies = max(int(value), 1)
        elif key == "putBack":
            self.put_back = bool(value)
        elif key == "remnant":
            e.remnant_length = float(value) if value is not None and float(value) > 0 else None
        self.touch()

    @Slot(int, "QVariant")
    def setDraftMeasured(self, index: int, value) -> None:
        e = self.draft
        if e is None or not 0 <= index < len(e.measurements):
            return
        e.measurements[index].measured = float(value) if value is not None and value != "" else None
        self.touch()

    @Slot(str, bool)
    def setChatterTool(self, tool_id: str, on: bool) -> None:
        e = self.draft
        if e is None:
            return
        ids = [t for t in e.chatter_tool_ids if t != tool_id]
        if on:
            ids.append(tool_id)
        e.chatter_tool_ids = ids
        self.touch()

    @Slot("QVariantList")
    def addDraftPhotos(self, urls) -> None:
        from PySide6.QtCore import QUrl
        e = self.draft
        if e is None:
            return
        for u in urls:
            p = Path(QUrl(str(u)).toLocalFile() if "://" in str(u) else str(u))
            name = self.import_photo(p)
            if name is not None:
                e.photos.append(name)
        self.touch()

    @Slot()
    def cancelDraft(self) -> None:
        self.draft = None
        self.touch()

    @Slot()
    def commitDraft(self) -> None:
        from ..core.journal import record
        e = self.draft
        if e is None:
            return
        if not self.put_back:
            e.remnant_length = None
        notes: list[str] = []
        inv = self.inventory_model
        if inv is not None:
            def change(i):
                notes.extend(record(e, i))
            inv.update(change)
        self.add(e, inv.inventory.tools if inv is not None else [])
        self.draft = None
        self.on_recorded(" ".join(["Recorded in the journal."] + notes))
        self.touch()

    @Slot(str, result="QVariantMap")
    def entryDetail(self, id: str) -> dict:
        e = next((x for x in self.entries if x.id == id), None)
        if e is None:
            return {}
        return {"id": e.id, "part": e.part_name, "date": e.date.astimezone().strftime("%Y-%m-%d %H:%M"), "outcome": e.outcome.title,
                "stock": e.stock_description, "material": e.material_snapshot.name if e.material_snapshot is not None else e.material_id,
                "minutes": round(e.cutting_minutes, 1), "copies": e.copies, "finish": e.finish, "chatter": e.chatter, "notes": e.notes,
                "programs": [{"title": p.title, "tool": p.tool_name, "minutes": round(p.minutes, 1)} for p in e.programs],
                "measurements": [{"what": m.what, "expected": m.expected, "tolerance": m.tolerance, "measured": m.measured,
                                  "ok": m.in_tolerance} for m in e.measurements],
                "photos": [str(self.photos_dir / p) for p in e.photos], "project": e.project_path or ""}
