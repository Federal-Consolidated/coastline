"""The machine's care, from the Operator Manual (7.1, Basic Maintenance), tracked against the job
journal: what's due after how many jobs, cutting hours or days. Port of Machine/Maintenance.swift."""

from __future__ import annotations

import datetime as _dt
from dataclasses import dataclass

DISTANT_PAST = _dt.datetime(1, 1, 1, tzinfo=_dt.timezone.utc)


@dataclass(frozen=True)
class Task:
    id: str
    title: str
    detail: str
    every_jobs: int | None = None  # due after this many recorded jobs, cutting hours or days
    every_hours: float | None = None
    every_days: float | None = None


TASKS = [
    Task("wipe-oil", "Wipe and oil the shafts and ballscrews",
         "Wipe the walls, table and mirrored spindle guard with a rag, then the shafts, ballscrews and sealed bearings (a cotton swab around the seals) and give the shafts and ballscrews a light coat of oil. After every major job (Operator Manual 7.1.1).",
         every_jobs=1),
    Task("belts", "Check the three belts",
         "Spindle, Y and Z belts: black rubber dust at the back or the right side of the mill means one is wearing; turn the mill over to look at them. Replace a worn belt (Operator Manual 7.1.1, 7.2).",
         every_hours=10, every_days=30),
    Task("deep-clean", "Deep clean: vacuum under the table and around the X motors",
         "Vacuum the chips that collect around the X motors and under the table, where the hose reaches from the front. Never compressed air: it pushes chips past the seals into the electronics.",
         every_hours=5, every_days=14),
]


@dataclass
class Record:
    """When a task was last done, and the journal's totals then."""

    date: _dt.datetime
    jobs: int
    cutting_minutes: float


@dataclass
class Due:
    task: Task
    due: bool
    why: str


def _abbreviated(d: _dt.datetime) -> str:
    d = d.astimezone()
    return f"{d:%b} {d.day}, {d.year}"


def status(records: dict[str, Record], jobs: int, cutting_minutes: float, since: _dt.datetime | None = None,
           now: _dt.datetime | None = None) -> list[Due]:
    """Each task's state from the journal totals now. A task never done counts from the first
    recorded job (`since`), not from the beginning of time."""
    now = now or _dt.datetime.now(_dt.timezone.utc)
    out = []
    for t in TASKS:
        r = records.get(t.id) or Record(since or DISTANT_PAST, 0, 0)
        jobs_since = jobs - r.jobs
        hours_since = (cutting_minutes - r.cutting_minutes) / 60
        days_since = (now - r.date).total_seconds() / 86_400
        reasons = []
        if t.every_jobs is not None and jobs_since >= t.every_jobs:
            reasons.append(f"{jobs_since} job{'' if jobs_since == 1 else 's'} since")
        if t.every_hours is not None and hours_since >= t.every_hours:
            reasons.append(f"{hours_since:.1f} cutting hours since")
        # Days only count once the machine has been used since (an idle mill isn't dirtier).
        if t.every_days is not None and days_since >= t.every_days and jobs_since > 0:
            reasons.append("not done yet" if r.date == DISTANT_PAST else f"{int(days_since)} days since")
        if t.id not in records and not reasons and jobs > 0:
            out.append(Due(t, False, "Not due yet (counted from your first recorded job)."))
            continue
        if t.id not in records and jobs == 0:
            out.append(Due(t, False, "Due after your first recorded job."))
            continue
        done = "—" if r.date == DISTANT_PAST else _abbreviated(r.date)
        out.append(Due(t, bool(reasons), ", ".join(reasons) if reasons else f"Done {done}"))
    return out
