"""The strategy engine must list, cost and recommend exactly the plans the Swift app did for the same
part facts and inventory (golden data from the Swift code)."""

import gzip
import json
from pathlib import Path

import pytest

from coastline_app.core import codable
from coastline_app.core.inventory.inventory import Inventory
from coastline_app.core.materials import MaterialLibrary
from coastline_app.core.plan import strategy_engine as S
from coastline_app.core.plan.part_analysis import PartAnalysis

GOLDEN = json.loads(gzip.decompress((Path(__file__).resolve().parent.parent / "golden" / "strategy.json.gz").read_bytes()))


def close(a, b, tol=1e-9):
    return abs(a - b) <= tol * max(1.0, abs(a), abs(b))


def norm(v):
    if isinstance(v, dict):
        return {k: norm(x) for k, x in v.items() if k != "id"}
    if isinstance(v, list):
        return [norm(x) for x in v]
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v


def check(got: S.Candidate, want: dict, where: str):
    assert got.name == want["name"], where
    assert norm([codable.to_json(o) for o in got.operations]) == norm(want["ops"]), where
    assert all(close(got.minutes_by_op[o.id], w) for o, w in zip(got.operations, want["opMinutes"])), where
    assert close(got.minutes, want["minutes"]), (where, got.minutes, want["minutes"])
    assert close(got.finish, want["finish"]) and close(got.risk, want["risk"]), where
    assert got.reasons == want["reasons"], where
    assert [t.id for t in got.tools] == want["tools"], where
    assert got.signature == want["signature"], where
    assert [(r.title, list(r.change)) for r in got.remedies] == [(r["title"], r["change"]) for r in want["remedies"]], where


@pytest.mark.parametrize("n", range(len(GOLDEN["cases"])))
def test_strategy_matches_swift(n):
    c = GOLDEN["cases"][n]
    f = c["facts"]
    a = f["analysis"]
    analysis = PartAnalysis(a["minCornerRadius"], a["minConcaveRadius"], 0, None, 10, None, freeform_area=a["freeformArea"],
                            flat_area=a["flatArea"], wall_area=a["wallArea"], steep_area=a["steepArea"], volume=a["volume"],
                            circularity=a["circularity"])
    facts = S.Facts(analysis, tuple(f["part"]), tuple(f["stock"]), MaterialLibrary.material(f["material"]), f["faceDepth"],
                    list(f["holes"]), f["hasFloors"], list(f["pockets"]), list(f["floorWidths"]), list(f["floorDepths"]), f.get("cutDepth"))
    inv = codable.from_json(Inventory, c["inventory"])
    cal = S.Calibration(dict(c["calibration"]))
    cands = S.candidates(facts, inv, cal, c["suggestions"])
    assert len(cands) == len(c["candidates"])
    for k, (g, w) in enumerate(zip(cands, c["candidates"])):
        check(g, w, f"case {n} candidate {k}")
    assert [cands.index(p) for p in S.pareto(cands)] == c["pareto"]
    rec = S.recommend(cands)
    assert len(rec) == len(c["recommend"])
    for g, w in zip(rec, c["recommend"]):
        check(g, w, f"case {n} recommend")
    if c["applied"]:
        first = next(x for x in cands if x.remedies)
        for r, want in zip(first.remedies, c["applied"]):
            assert norm([codable.to_json(o) for o in S.apply(r, first.operations)]) == norm(want)


def test_calibration_moves_toward_the_observed_ratio():
    cal = S.Calibration()
    from coastline_app.core.feeds import OperationKind
    cal.learn(OperationKind.ADAPTIVE, 10, 20)
    assert abs(cal.factor["adaptive"] - (0.6 + 2 * 0.4)) < 1e-12
    cal.learn(OperationKind.ADAPTIVE, 0.01, 20)  # too small to learn from
    assert abs(cal.factor["adaptive"] - 1.4) < 1e-12
    cal.learn(OperationKind.CONTOUR, 1, 100)  # clamped to 4
    assert abs(cal.factor["contour"] - (0.6 + 4 * 0.4)) < 1e-12
    assert cal.apply(OperationKind.FACING, 3) == 3
