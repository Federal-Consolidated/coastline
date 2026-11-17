"""Feeds and speeds must equal the Swift engine's for every material, catalog tool, operation
kind and roughing style (golden data exported from the Swift app), including the notes."""

import gzip
import json
from pathlib import Path

from coastline_app.core import feeds
from coastline_app.core.feeds import OperationKind, RoughingStyle
from coastline_app.core.inventory.catalogs import ToolCatalog
from coastline_app.core.inventory.items import ToolMaterial
from coastline_app.core.materials import MaterialLibrary
from coastline_app.core.plan.operation import Operation

GOLDEN = Path(__file__).resolve().parent.parent / "golden" / "feeds.json.gz"


def test_feeds_match_swift():
    rows = json.loads(gzip.decompress(GOLDEN.read_bytes()))
    tools = {t.id: t for t in ToolCatalog.suggestions()}
    for row in rows:
        tool = tools[row["t"]].copy()
        if row["hss"]:
            tool.tool_material = ToolMaterial.HSS
        material = MaterialLibrary.material(row["m"])
        kind = OperationKind(row["k"])
        if row["r"] == "op":
            op = Operation(kind, tool_id=tool.id, feed_scale=1.15, scallop=0.004)
            if kind is OperationKind.CONTOUR:
                op.stepdown_override = 0.7
            c = op.cutting_data(tool, material)
        else:
            c = feeds.compute(tool, material, kind, roughing=RoughingStyle(row["r"]))
        got = (c.rpm, c.feed, c.plunge_feed, c.ramp_feed, c.chip_load, c.stepdown, c.stepover, c.ramp_angle, c.power, c.notes)
        want = (row["rpm"], row["feed"], row["plunge"], row["ramp"], row["fz"], row["sd"], row["so"], row["ra"], row["p"], row["notes"])
        assert got == want, f"{row['m']} {tool.name} {row['k']} {row['r']}:\n {got}\n {want}"
    assert len(rows) > 10_000
