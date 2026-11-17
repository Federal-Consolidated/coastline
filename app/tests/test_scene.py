import numpy as np
import pytest

from coastline_app.viewport import SEGMENT_DTYPE, PathColor, Scene, polyline_segments


def test_segment_layout_matches_the_gpu():
    assert SEGMENT_DTYPE.itemsize == 32
    assert [SEGMENT_DTYPE.fields[k][1] for k in ("a", "b", "color_a", "color_b")] == [0, 12, 24, 28]


def test_polyline_segments_join_consecutive_points():
    seg = polyline_segments([[0, 0, 0], [1, 0, 0], [1, 2, 0]], PathColor.cut)
    assert len(seg) == 2
    assert np.allclose(seg["b"][0], seg["a"][1])
    assert tuple(seg["color_a"][1]) == PathColor.cut


def test_bounds_cover_meshes_and_lines():
    scene = Scene()
    assert scene.bounds() is None
    scene.set_mesh("m", [[0, 0, 0], [1, 0, 0], [0, 1, 0]], [[0, 0, 1]] * 3, [0, 1, 2])
    scene.set_lines("l", polyline_segments([[-5, 0, 0], [0, 0, 9]], PathColor.rapid))
    lo, hi = scene.bounds()
    assert np.allclose(lo, [-5, 0, 0]) and np.allclose(hi, [1, 1, 9])


def test_visible_segments_are_clamped():
    scene = Scene()
    scene.set_lines("l", polyline_segments(np.zeros((11, 3)), PathColor.cut))
    scene.set_visible_segments("l", 99)
    assert scene.lines["l"].visible_count == 10
    scene.set_visible_segments("l", -3)
    assert scene.lines["l"].visible_count == 0


def test_lines_need_the_gpu_layout():
    with pytest.raises(TypeError):
        Scene().set_lines("l", np.zeros(3, np.float32))


def test_property_changes_redraw_and_groups_move_meshes():
    from coastline_app.viewport.scene import box_mesh
    scene = Scene()
    hits = []
    scene.changed.connect(lambda: hits.append(1))
    m = scene.add(box_mesh("stock", (0, 0, 0), (1, 2, 3), (0.5, 0.5, 0.5, 1)))
    n = len(hits)
    m.visible = False
    assert len(hits) == n + 1
    m.visible = True
    m.group = "x"
    scene.set_group_transform("x", np.array([[1, 0, 0, 10], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1.0]]))
    lo, hi = scene.visible_bounds()
    assert np.allclose(lo, [10, 0, 0]) and np.allclose(hi, [11, 2, 3])
    scene.remove_prefix("sto")
    assert scene.visible_bounds() is None


def test_picking_finds_the_nearest_mesh_through_its_group():
    from coastline_app.viewport.scene import box_mesh
    scene = Scene()
    near = box_mesh("near", (-1, -1, 4), (1, 1, 5), (1, 1, 1, 1))
    far = box_mesh("far", (-1, -1, 0), (1, 1, 1), (1, 1, 1, 1))
    for m in (near, far):
        m.pickable = True
        scene.add(m)
    hit = scene.pick((0, 0, 10), (0, 0, -1))
    assert hit is not None and hit[0] == "near" and np.allclose(hit[1], [0, 0, 5])
    near.visible = False
    assert scene.pick((0, 0, 10), (0, 0, -1))[0] == "far"
    far.group = "z"
    scene.set_group_transform("z", np.array([[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, -3], [0, 0, 0, 1.0]]))
    assert np.allclose(scene.pick((0, 0, 10), (0, 0, -1))[1], [0, 0, -2])
