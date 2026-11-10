"""Regions with straight walls are the same at every level: solved once (cam.ops._solve_all)."""

from coastline_engine.cam import geometry as g
from coastline_engine.cam.ops import _solve_all


def _slot(x0, dy=0.0, n=8):
    # A slot with round ends, from a different number of facets each time (as at each level).
    import math
    pts = [(x0 + 10, 0.0), (x0 + 10, 5.0)]
    pts += [(x0 + 5 + 5 * math.cos(math.pi * k / n), 5 + 2.5 * math.sin(math.pi * k / n) + dy) for k in range(n + 1)]
    return g.to_int(pts)


def test_a_region_near_one_solved_takes_its_result():
    cache, calls = [], []

    def job(paths, tag):
        return (paths, None, lambda: calls.append(tag) or tag)

    a = _slot(0)
    a2 = _slot(0, dy=0.004)    # 4 µm off: the same region
    b = _slot(0, dy=0.5)       # 0.5 mm off: another region
    out = _solve_all(cache, [job([a], "a"), job([a2], "a2"), job([b], "b")])
    assert out == ["a", "a", "b"]
    assert calls == ["a", "b"]
