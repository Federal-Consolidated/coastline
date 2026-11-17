import math

import numpy as np

from coastline_app.viewport.camera import OrbitCamera


def project(cam: OrbitCamera, p, aspect=1.5):
    clip = cam.view_projection(aspect) @ np.array([*p, 1.0])
    return clip[:3] / clip[3]


def test_frame_keeps_the_box_in_view():
    cam = OrbitCamera()
    lo, hi = np.array([-10.0, 0.0, -5.0]), np.array([190.0, 50.0, 45.0])
    cam.frame(lo, hi)
    for corner in np.array(np.meshgrid(*zip(lo, hi))).T.reshape(-1, 3):
        ndc = project(cam, corner)
        assert np.all(np.abs(ndc[:2]) <= 1.0) and -1.0 <= ndc[2] <= 1.0


def test_target_projects_to_the_centre():
    cam = OrbitCamera(target=np.array([3.0, 4.0, 5.0]))
    assert np.allclose(project(cam, cam.target)[:2], 0.0, atol=1e-9)


def test_z_is_up_and_x_is_right_from_the_front():
    cam = OrbitCamera(yaw=0.0, pitch=0.0)  # looking along +Y
    assert project(cam, [0, 0, 10])[1] > 0
    assert project(cam, [10, 0, 0])[0] > 0


def test_orbit_clamps_pitch_short_of_vertical():
    cam = OrbitCamera()
    cam.orbit(0, 10_000)
    assert cam.pitch < math.pi / 2
    cam.orbit(0, -20_000)
    assert cam.pitch > -math.pi / 2
