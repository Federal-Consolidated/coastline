"""The G-code must be exactly what the Swift app wrote for the same toolpaths (golden data
exported from the Swift post-processor: random lines, arcs, full circles, no-op moves, feeds)."""

import gzip
import json
from pathlib import Path

import numpy as np

from coastline_app.core.inventory.items import Tool, ToolKind
from coastline_app.core.post import grbl_post
from coastline_app.core.post.toolpath import OperationToolpath, moves_from_array

GOLDEN = Path(__file__).resolve().parent.parent / "golden" / "post.json.gz"


def test_post_matches_swift_byte_for_byte():
    cases = json.loads(gzip.decompress(GOLDEN.read_bytes()))
    assert len(cases) == 12
    for n, c in enumerate(cases):
        paths = [OperationToolpath(f"op{k}", moves_from_array(np.array(p, float))) for k, p in enumerate(c["paths"])]
        tool = Tool.make(c["toolName"], ToolKind.FLAT_END_MILL, c["toolDiameter"], 3.175, c["toolFlutes"], 12, c["toolStickout"], 38)
        header = grbl_post.Header(c["programName"], c["setupName"], tool, c["operationNames"], c["stock"])
        text, line_map = grbl_post.program_with_line_map(header, c["rpm"], paths)
        want = c["gcode"].split("\n")
        got = text.split("\n")
        for i, (a, b) in enumerate(zip(got, want)):
            assert a == b, f"case {n} line {i + 1}: {a!r} != {b!r}"
        assert len(got) == len(want)
        assert [[v or 0 for v in m] for m in line_map] == c["lineMap"]


def test_fmt():
    assert grbl_post.fmt(12.5) == "12.5"
    assert grbl_post.fmt(-3.0) == "-3"
    assert grbl_post.fmt(0.125) == "0.125"
    assert grbl_post.fmt(-0.0001) == "0"
