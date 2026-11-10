"""Named features from quiddity on the DFM coupon (scripts/make-dfm-coupon.py lists the known
answers): names with sizes, on the same face numbers the analysis uses."""

from pathlib import Path

import pytest

from coastline_engine.cam.recognition import label, recognise
from coastline_engine.server import _recognise

COUPON = Path(__file__).resolve().parents[2] / "resources/samples/dfm_coupon.step"


def test_coupon_features_are_named_with_their_sizes():
    pytest.importorskip("quiddity")
    r, blobs = _recognise({"path": str(COUPON)}, [])
    assert r["available"] and blobs == []
    names = [f["label"] for f in r["features"]]
    assert "Drilled hole ⌀6.35 mm" in names                    # F4: drilled, drill point
    assert "Pocket 20 x 30 mm" in names                         # F1
    assert "Pocket 6 x 20 mm" in names and "Pocket 2 x 15 mm" in names  # F2, F3
    assert "Pocket 3 x 40 mm" in names                          # F7, the side groove
    assert not any(n.startswith(("Step level", "Plate", "Section")) for n in names)
    assert all(f["faces"] and all(isinstance(i, int) and 0 <= i < 51 for i in f["faces"]) for f in r["features"])


def test_a_file_it_cannot_read_gives_no_names(tmp_path):
    pytest.importorskip("quiddity")
    bad = tmp_path / "bad.step"
    bad.write_text("not a step file")
    r = recognise(str(bad))
    assert r["available"] is False and r["features"] == [] and r["error"]


def test_labels():
    assert label("holes", {"diameter": 10.0, "bottom": "through"}) == "Through hole ⌀10 mm"
    assert label("slots", {"width": 16.89, "length": 31.0}) == "Slot 16.89 x 31 mm"
    assert label("chamfers", {"leg1": 4.85}) == "Chamfer 4.85 mm"
    assert label("step_levels", {"z": 1}) is None
    assert label("interior_voids", {}) == "Interior void"
