import pytest

from coastline_app import paths
from coastline_app.core.engine.client import EngineClient, EngineError

pytestmark = pytest.mark.skipif(not paths.engine_python().exists(), reason="engine environment not set up (uv sync in engine/)")


@pytest.fixture(scope="module")
def engine():
    with EngineClient() as client:
        yield client


def test_ping_reports_versions(engine):
    info = engine.ping()
    assert info["engine"] and info["ocp"]


def test_import_step_returns_an_exact_mesh(engine):
    mesh = engine.import_part(paths.SAMPLES_DIR / "dfm_coupon.step")
    assert mesh.exact and mesh.part_id
    assert mesh.triangle_count > 100
    assert mesh.vertices.shape == mesh.normals.shape
    assert mesh.indices.max() < len(mesh.vertices)
    assert tuple(mesh.size) == pytest.approx((203.2, 50.8, 50.8), abs=0.01)


def test_engine_errors_come_back_as_exceptions(engine):
    with pytest.raises(EngineError):
        engine.import_part(paths.SAMPLES_DIR / "does-not-exist.step")
    assert engine.ping()  # still answering after an error
