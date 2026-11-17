"""The part check (DFM) and plan coverage must say exactly what the Swift app said for the same
part, tools, stock, machine and setup (golden data from the Swift code: 220 generated cases)."""

import gzip
import json
from pathlib import Path

import pytest

from coastline_app.core import codable
from coastline_app.core.inventory.inventory import Inventory
from coastline_app.core.inventory.items import StockItem, Tool
from coastline_app.core.machine.profile import MachineProfile
from coastline_app.core.plan import dfm
from coastline_app.core.plan.named_features import NamedFeature
from coastline_app.core.plan.part_analysis import PartAccess, PartAnalysis
from coastline_app.core.plan.plan_coverage import PlanCoverage, SetupRoom, Turn
from coastline_app.core.plan.setup import Setup

GOLDEN = json.loads(gzip.decompress((Path(__file__).resolve().parent.parent / "golden" / "dfm.json.gz").read_bytes()))


def remedy_json(r: dfm.Remedy, inv, current):
    d = {"kind": r.kind}
    if r.kind == "useStock":
        d.update(id=r.id, axes=list(r.axes))
    elif r.kind in ("showTool", "buyTool"):
        d["id"] = r.id
    elif r.kind == "setStickout":
        d.update(id=r.id, minimum=r.minimum)
    elif r.kind == "addCollet":
        d["size"] = r.size
    elif r.kind == "addTool":
        d["tool"] = codable.to_json(r.tool)
    d["title"] = r.title
    d["titleIn"] = r.title_in(inv, current)
    return d


def finding_json(f: dfm.DFMFinding, inv, current):
    return {"id": f.id, "category": int(f.category), "title": f.title, "summary": f.summary, "details": f.details, "faces": f.faces,
            "remedies": [remedy_json(r, inv, current) for r in f.remedies], "measure": f.measure, "fix": f.fix,
            "areas": f.areas, "sides": f.sides}


def coverage_json(c: PlanCoverage):
    return {"setups": [{"side": s.side, "number": s.number, "findings": s.findings, "titles": s.titles, "faces": s.faces,
                        "toolpaths": s.toolpaths, "note": s.note} for s in c.setups],
            "unused": [{"side": u.side, "why": u.why, "fits": u.fits} for u in c.unused],
            "gaps": [{"finding": g.finding, "title": g.title, "category": int(g.category), "text": g.text, "faces": g.faces} for g in c.gaps],
            "waiting": c.waiting, "toBuy": c.with_tools_to_buy, "open": c.open}


def normalise(v):
    """Swift's JSONSerialization writes whole doubles as integers; compare numbers by value."""
    if isinstance(v, dict):
        return {k: normalise(x) for k, x in v.items()}
    if isinstance(v, list):
        return [normalise(x) for x in v]
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v


def build(c):
    inv = codable.from_json(Inventory, c["inventory"])
    setup = Setup.from_json(c["setup"])
    machine = codable.from_json(MachineProfile, c["machine"])
    stock = codable.from_json(StockItem, c["stock"]) if "stock" in c else None
    a = c["analysis"]
    access = PartAccess.from_json(a["access"]) if "access" in a else None
    analysis = PartAnalysis(a.get("minCornerRadius"), a.get("minConcaveRadius"), a["undercutArea"], a.get("thinnestWall"),
                            a["depth"], a.get("partingZ"), access=access)
    room = None
    if "room" in c:
        room = SetupRoom(c["room"]["tableDepth"], {k: Turn(v[0], v[1]) for k, v in c["room"]["turns"].items()})
    named = [NamedFeature(n["family"], n["label"], n["faces"]) for n in c["named"]]
    return dfm.Input(analysis, setup, (0.0, 0.0, 0.0), (50.8, 203.2, 50.8), stock, inv, machine, c["twoSided"], named, room), inv, stock


@pytest.mark.parametrize("n", range(len(GOLDEN["cases"])))
def test_dfm_matches_swift(n):
    c = GOLDEN["cases"][n]
    inp, inv, stock = build(c)
    findings = dfm.assess(inp)
    got = normalise([finding_json(f, inv, stock.id if stock else None) for f in findings])
    want = normalise(c["findings"])
    for g, w in zip(got, want):
        assert g == w, f"case {n} finding {w['id']}:\n got {g}\nwant {w}"
    assert len(got) == len(want), (n, [f["id"] for f in got], [f["id"] for f in want])
    assert PlanCoverage.propose(findings) == c["proposed"]
    tp = set(c["toolpathSides"]) if "toolpathSides" in c else None
    cov = PlanCoverage.assess(findings, c["sides"], set(c["jobTools"]), tp, inp.room, c.get("roomStock"))
    assert normalise(coverage_json(cov)) == normalise(c["coverage"]), n


def test_reach_matches_swift():
    inv = codable.from_json(Inventory, GOLDEN["inventory"])
    for k, r in enumerate(GOLDEN["reaches"]):
        t = codable.from_json(Tool, r["tool"])
        got = dfm.reach(t, r["opening"], r["wall"], r["holder"], r["hole"], MachineProfile.standard(), inv)
        verdict = ["needsStickout", got.stickout] if got.verdict == dfm.Verdict.NEEDS_STICKOUT else got.verdict
        assert (normalise(verdict), got.reason, got.warnings) == (normalise(r["verdict"]), r["reason"], r["warnings"]), k
