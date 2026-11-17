"""Guided jobs, air cuts, facing, reference bores and surface probing must match what the Swift
app wrote for the same inputs (golden data exported from the Swift code)."""

import base64
import gzip
import json
from pathlib import Path

import pytest

from coastline_app.core import feeds
from coastline_app.core.codable import Range
from coastline_app.core.export import generated_job, guided_job as G, surface_probe as S
from coastline_app.core.inventory.items import MeasuringKind, MeasuringTool, StockItem, Tool, ToolKind
from coastline_app.core.materials import MaterialLibrary
from coastline_app.core.plan import edge_finding, reference_bores as R
from coastline_app.core.plan.holding_tabs import HoldingTabs
from coastline_app.core.plan.operation import ReferenceFeature
from coastline_app.core.plan.setup import CustomFixture

GOLDEN = json.loads(gzip.decompress((Path(__file__).resolve().parent.parent / "golden" / "guided.json.gz").read_bytes()))

STEP_KEYS = {"manifest": "manifest", "title": "title", "prompt": "prompt", "markdown": "markdown", "imagePath": "image_path",
             "gcodePath": "gcode_path", "pause": "pause", "reset": "reset", "timeout": "timeout", "unskippable": "unskippable",
             "popupText": "popup_text", "popupTitle": "popup_title", "popupWaitTime": "popup_wait_time",
             "popupYesStep": "popup_yes_step", "popupNoStep": "popup_no_step", "goTo": "go_to"}


def assert_steps(got, want, where):
    for k, (s, w) in enumerate(zip(got, want)):
        for key, attr in STEP_KEYS.items():
            assert getattr(s, attr) == w[key], f"{where} step {k} ({w['title']}) {key}: {getattr(s, attr)!r} != {w[key]!r}"
    assert len(got) == len(want), where


def plan_of(j, flip=None):
    return R.Plan([tuple(p) for p in j["a"]], j["depth"], j["thickness"], flip)


def guided_input(c):
    mat = MaterialLibrary.material(c["material"])
    tools = [Tool.make(t["name"], ToolKind.FLAT_END_MILL, t["diameter"], t["shank"], t["flutes"], 10, t["stickout"], t["oal"])
             for t in c["tools"]]
    programs = []
    for p in c["programs"]:
        pr = G.Program(tools[p["tool"]], p["gcode"], p["ops"], p["minutes"], p["side"])
        pr.touch_z = p.get("touchZ", 0.0)
        if "reference" in p:
            pr.reference = ReferenceFeature(p["reference"])
        pr.surface_probe = p.get("surfaceProbe")
        programs.append(pr)
    size = tuple(c["size"])
    inp = G.Input(c["partName"], mat, StockItem.make(mat.id, *size), size, c["setupName"], programs,
                  [G.Checkpoint(k["after"], k["what"], k["expected"], k["tolerance"]) for k in c["checkpoints"]],
                  [MeasuringTool.make(m["name"], MeasuringKind(m["kind"])) for m in c["measuring"]],
                  bytes([1, 2, 3]) if c["setupImage"] else None)
    if c.get("flipImage"):
        inp.flip_image = bytes([4, 5])
    inp.flip_axis = c.get("flipAxis")
    if "tabs" in c:
        inp.tabs = HoldingTabs(c["tabs"][0], c["tabs"][1], c["tabs"][2])
    if "custom" in c:
        name, height, face, notes = c["custom"]
        inp.custom_holding = CustomFixture(name, height, face, notes)
    if "reach" in c:
        inp.probing.lower_x_reachable, inp.probing.upper_x_reachable = c["reach"]
    if "bores" in c:
        inp.probing.bores = plan_of(c["bores"], inp.flip_axis)
    if "toolChange" in c:
        inp.tool_change_z, inp.tool_change_y = c["toolChange"]
    return inp


@pytest.mark.parametrize("n", range(len(GOLDEN["guided"])))
def test_guided_job_matches_swift(n):
    c = GOLDEN["guided"][n]
    inp = guided_input(c)
    jobs, files = G.build(inp)
    assert len(jobs) == len(c["jobs"])
    for job, want in zip(jobs, c["jobs"]):
        assert job.title == want["title"] and job.prompt == want["prompt"]
        assert_steps(job.steps, want["steps"], f"case {n}")
    want_files = {k: base64.b64decode(v) for k, v in c["files"].items()}
    assert sorted(files) == sorted(want_files)
    for k in files:
        assert files[k] == want_files[k], f"case {n} {k}"
    code = generated_job.code_files(inp)
    assert [(f.path, f.title, f.kind.value) for f in code] == [(f["path"], f["title"], f["kind"]) for f in c["codeFiles"]]


def test_reference_bores_match_swift():
    for n, e in enumerate(GOLDEN["bores"]):
        keep = [tuple(tuple(p) for p in e["keep"])] if "keep" in e else []
        reach = Range(*e["reach"]) if "reach" in e else None
        plan = R.place(tuple(e["stock"]), tuple(e["min"]), tuple(e["max"]), 3, keep, reach, 3.175, e["maxDepth"])
        if e["placed"] is None:
            assert plan is None, n
        else:
            assert plan is not None, n
            assert [list(p) for p in plan.centres_a] == e["placed"]["a"], n
            assert (plan.depth_a, plan.thickness) == (e["placed"]["depth"], e["placed"]["thickness"])
        if "plan" not in e:
            continue
        p = plan_of(e["plan"], None if e["flip"] == 0 else 1)
        assert R.bore_program(p, 0, 3.175, True) == e["bore0"]
        assert R.bore_program(p, 1, 6.35, True) == e["bore1"]
        assert R.zero_program(p) == e["zero"]
        files = {}
        steps = G.bore_pickup_steps(p, edge_finding.TOOL, n % 2 == 0, files)
        assert_steps(steps, e["pickup"], f"bores {n}")
        assert {k: v.decode() for k, v in files.items()} == e["pickupFiles"]


def test_small_programs_match_swift():
    s = GOLDEN["small"]
    assert [R.single_edge_program("X", 1, -20.25, 2.54, True), R.single_edge_program("X", -1, 20.25, 2.54, False)] == s["single"]
    assert R.edge_program("Y", -1, 3) == s["edge"]
    assert R.top_program(-0.35) == s["top"]
    assert R.store_centre(1, "Y", 5.08) == s["storeCentre"]
    gcode = "(Program)\nG21 G90\nM3 S9000\nG0 X0 Y0 Z5\nG1 Z-1.25 F200\nG1 X10 Y3.5 F800\nG2 X12 Y5 I1 J0 Z-1.5\nS8000\nG53 G0 Z-1\nM5\nM30"
    assert G.air_cut(gcode + "\nG0 Z-0.0001\ng1 z3\nS100\nM4 S2000\nG1 X1 Z.5 Z7", 7.5) == s["aircut"]
    tool = Tool.make("Face mill", ToolKind.FLAT_END_MILL, 6.35, 6.35, 3, 15, 20, 50)
    data = feeds.compute(tool, MaterialLibrary.material("al-6061"), feeds.OperationKind.FACING)
    from coastline_app.core.machine.profile import MachineProfile
    assert G.facing_program(80, 150, 0.25, tool, data, MachineProfile.standard(), "Test #1") == s["facing"]
    moves = G.facing_moves(31, 47, 1.3, tool, data, Range(-10, 30), True)
    assert [[float(m.role), m.x, m.y, m.z, m.feed] for m in moves] == s["facingMoves"]
    assert_steps(G.edge_find_steps(MachineProfile.standard(), note="Note: here.", previous=tool), s["edgeFind"], "edge find")
    cuts = [tuple(c) for c in s["cuts"]]
    pts = S.points([(c[0], c[1]) for c in cuts])
    assert [list(p) for p in pts] == s["points"]
    face, spread = S.flat_face(cuts, 0.2)
    assert [face, spread] == s["flatFace"]
    assert S.program(pts, -0.3) == s["probe"]
    assert S.program([(1, 2), (3, 4), (5, -6)], -2.5) == s["probeLow"]
    text, moved = S.follow(gcode + "\nG1 X1 (Z5 comment) Z-0.1\nG53 G0 Z-1\nG0 X1", -0.25)
    assert [text, moved] == s["follow"]
    assert G.safe_markdown("abc\nkey: value\n  Note : x\nok\n\n1. a: b\né:\nhey") == s["safe"]
