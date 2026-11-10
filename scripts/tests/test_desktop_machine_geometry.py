"""Exact-CAD regression checks for seated stock, mounting and selected contacts."""

import importlib.util
from pathlib import Path

import pytest


SCRIPT = Path(__file__).resolve().parents[1] / "audit-desktop-machine-geometry.py"
SPEC = importlib.util.spec_from_file_location("desktop_geometry_audit", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


@pytest.fixture(scope="module")
def report():
    return MODULE.audit(MODULE.DEFAULT_GEOMETRY,
                        native_audit=MODULE.ROOT / "docs/machine-profile-fusion-audit.json")


def frame(origin=(15.865, -343, 79.04), x=(0, 1, 0), z=(1, 0, 0)):
    return {field: dict(zip("xyz", value))
            for field, value in [("origin", origin), ("xDirection", x), ("zDirection", z)]}


def test_full_export_preserves_every_native_body_and_cover(report):
    assert report["assembledSolidCount"] == 52
    assert report["coverSolidCount"] == 9
    assert report["nativeBodyAgreement"]["bodyCount"] == 52
    assert report["nativeBodyAgreement"]["maximumBoundsErrorMM"] < 0.001


def test_asymmetric_stock_is_seated_on_the_actual_horizontal_table_plane(report):
    assert report["stockSeating"]["worldBoundsMM"][0] == pytest.approx([15.865, -343, 79.04])
    assert report["stockSeating"]["worldBoundsMM"][1] == pytest.approx([66.665, -139.8, 116.04])
    assert report["stockSeating"]["maximumBottomPlaneErrorMM"] < 0.001


def test_machine_wcs_cannot_be_mistaken_for_the_stock_seating_frame(report):
    with pytest.raises(ValueError, match="thickness.*actual table"):
        MODULE.check_seating_frame(report["tableSurface"], frame(x=(1, 0, 0), z=(0, 0, 1)))


def test_tool_frame_matches_cylindrical_spindle_and_remains_horizontal(report):
    assert report["toolAlignment"]["radialOriginErrorMM"] < 0.01
    assert report["toolAlignment"]["nutNosePlaneErrorMM"] < 0.01
    assert report["toolAlignment"]["toolAxisDotTableNormal"] == pytest.approx(0)


@pytest.mark.parametrize("origin, reason", [
    ((16.865, -343, 79.04), "does not sit"),
    ((15.865, -450, 79.04), "extends beyond"),
])
def test_floating_or_off_table_stock_is_rejected_by_actual_cad_support_bounds(report, origin, reason):
    with pytest.raises(ValueError, match=reason):
        MODULE.check_seating_frame(report["tableSurface"], frame(origin=origin))


def test_both_bookend_nut_and_key_envelopes_fit_without_table_intersection(report):
    for slot in report["bookendMounting"]["slots"]:
        assert slot["nutOverlapMM3"] < 1e-6
        assert slot["keyOverlapMM3"] < 1e-6


def test_model_travel_is_inside_selected_cad_contacts_and_crossing_stops_intersects(report):
    samples = {sample["qZ"]: sample for sample in report["zContactChecks"]["samples"]}
    assert samples[1.4]["separationMM"] == pytest.approx(1.4, abs=1e-6)
    assert samples[79.9]["separationMM"] == pytest.approx(0.1, abs=1e-6)
    assert samples[-0.01]["overlapMM3"] > 1
    assert samples[80.01]["overlapMM3"] > 1
    samples = {sample["qY"]: sample for sample in report["yUpperContactChecks"]["samples"]}
    assert samples[69]["separationMM"] == pytest.approx(0.8049759, abs=1e-5)
    assert samples[69.84]["overlapMM3"] > 0.001
