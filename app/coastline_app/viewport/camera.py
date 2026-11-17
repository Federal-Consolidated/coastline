"""Orbit camera around a target point. World is Z-up, like the machine.

Port of Viewport/Sources/Viewport/Camera.swift. Matrices are numpy row-major (4, 4) with
OpenGL clip conventions (y up, depth −1…1); the renderer multiplies by QRhi's
clip-space correction for Metal, Direct3D or Vulkan.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np


def look_at(eye: np.ndarray, target: np.ndarray, up: np.ndarray) -> np.ndarray:
    f = target - eye
    f = f / np.linalg.norm(f)
    s = np.cross(f, up)
    s = s / np.linalg.norm(s)
    u = np.cross(s, f)
    m = np.identity(4)
    m[0, :3], m[1, :3], m[2, :3] = s, u, -f
    m[:3, 3] = -m[:3, :3] @ eye
    return m


def perspective(fov_y: float, aspect: float, near: float, far: float) -> np.ndarray:
    t = 1.0 / math.tan(fov_y / 2)
    m = np.zeros((4, 4))
    m[0, 0], m[1, 1] = t / aspect, t
    m[2, 2], m[2, 3] = (far + near) / (near - far), 2 * far * near / (near - far)
    m[3, 2] = -1.0
    return m


def ortho(left: float, right: float, bottom: float, top: float, near: float, far: float) -> np.ndarray:
    m = np.identity(4)
    m[0, 0], m[1, 1], m[2, 2] = 2 / (right - left), 2 / (top - bottom), -2 / (far - near)
    m[0, 3] = -(right + left) / (right - left)
    m[1, 3] = -(top + bottom) / (top - bottom)
    m[2, 3] = -(far + near) / (far - near)
    return m


@dataclass
class OrbitCamera:
    target: np.ndarray = None  # type: ignore[assignment]
    distance: float = 300.0
    yaw: float = -math.pi / 4  # rotation about Z; 0 looks along +Y
    pitch: float = math.pi / 6  # elevation, clamped short of straight up/down
    field_of_view: float = math.radians(35)
    orthographic: bool = True  # no perspective distortion, like engineering views in CAD
    scene_radius: float = 300.0  # sets the depth range
    pivot: np.ndarray | None = None  # point the camera orbits around; None: the target

    def __post_init__(self) -> None:
        if self.target is None:
            self.target = np.zeros(3)

    @property
    def eye(self) -> np.ndarray:
        cp = math.cos(self.pitch)
        return self.target + self.distance * np.array(
            [cp * math.sin(self.yaw), -cp * math.cos(self.yaw), math.sin(self.pitch)])

    def orbit(self, dx: float, dy: float) -> None:
        """Turntable orbit; dx, dy in points. With a pivot, the target swings around it too, so
        the scene turns about that point rather than the screen centre."""
        new_yaw = self.yaw - dx * 0.008
        new_pitch = min(max(self.pitch + dy * 0.008, -math.pi / 2 + 0.01), math.pi / 2 - 0.01)
        if self.pivot is not None:
            old_dir = self.view_direction
            after_yaw = _rotate_z(old_dir, new_yaw - self.yaw)
            probe = OrbitCamera(self.target.copy(), self.distance, new_yaw, new_pitch)
            new_dir = probe.view_direction
            q = _rotation_between(after_yaw, new_dir) @ _rotation_z(new_yaw - self.yaw)
            self.target = self.pivot + q @ (self.target - self.pivot)
        self.yaw = new_yaw
        self.pitch = new_pitch

    @property
    def view_direction(self) -> np.ndarray:
        """Unit vector from the target to the eye."""
        d = self.eye - self.target
        return d / max(float(np.linalg.norm(d)), 1e-12)

    STANDARD_VIEWS = ("tool", "front", "top", "right", "left", "iso", "toolIso")

    def set_view(self, view: str) -> None:
        """Standard views (display space, Z up, the operator looks along +Y). `tool` looks down
        the spindle at the face being cut."""
        self.yaw, self.pitch = {"tool": (math.pi, 0.0), "front": (0.0, 0.0), "top": (0.0, math.pi / 2 - 0.01),
                                "right": (math.pi / 2, 0.0), "left": (-math.pi / 2, 0.0), "iso": (math.pi / 4, math.pi / 6),
                                "toolIso": (math.pi * 0.75, math.pi / 6)}[view]

    def look(self, direction) -> None:
        """Looks along `direction` (from the target toward the eye)."""
        d = np.asarray(direction, float)
        d = d / np.linalg.norm(d)
        self.pitch = min(max(math.asin(max(-1.0, min(1.0, d[2]))), -math.pi / 2 + 0.01), math.pi / 2 - 0.01)
        self.yaw = math.atan2(d[0], -d[1])

    def copy(self) -> "OrbitCamera":
        return OrbitCamera(self.target.copy(), self.distance, self.yaw, self.pitch, self.field_of_view, self.orthographic,
                           self.scene_radius, None if self.pivot is None else self.pivot.copy())

    def same_as(self, o: "OrbitCamera") -> bool:
        return (np.allclose(self.target, o.target) and self.distance == o.distance and self.yaw == o.yaw
                and self.pitch == o.pitch and self.orthographic == o.orthographic)

    def pan(self, dx: float, dy: float, view_height: float) -> None:
        """Pans in the view plane; dx, dy in points, scaled so the target tracks the cursor."""
        forward = self.target - self.eye
        forward /= np.linalg.norm(forward)
        right = np.cross(forward, [0.0, 0.0, 1.0])
        right /= np.linalg.norm(right)
        up = np.cross(right, forward)
        world_per_point = 2 * self.distance * math.tan(self.field_of_view / 2) / max(view_height, 1.0)
        self.target = self.target + (-dx * right + dy * up) * world_per_point

    def zoom(self, factor: float) -> None:
        self.distance = min(max(self.distance * factor, 2.0), 50_000.0)
        self.scene_radius = max(self.scene_radius, self.distance)

    def frame(self, lo, hi) -> None:
        """Frames a bounding box so it fills the view."""
        lo, hi = np.asarray(lo, float), np.asarray(hi, float)
        self.target = (lo + hi) / 2
        radius = max(float(np.linalg.norm(hi - lo)) / 2, 1.0)
        self.scene_radius = radius
        self.distance = radius / math.sin(self.field_of_view / 2) * 1.05

    ORTHO_STAND_OFF = 3000.0  # orthographic: the eye backs off this far so nothing near it is clipped

    def view_matrix(self) -> np.ndarray:
        e = self.target + self.view_direction * (self.distance + self.ORTHO_STAND_OFF) if self.orthographic else self.eye
        return look_at(e, self.target, np.array([0.0, 0.0, 1.0]))

    def projection_matrix(self, aspect: float) -> np.ndarray:
        depth = 2 * max(self.scene_radius, 1.0) + 1.0
        if self.orthographic:
            h = self.distance * math.tan(self.field_of_view / 2)
            return ortho(-h * aspect, h * aspect, -h, h, 1.0, self.distance * 2 + self.ORTHO_STAND_OFF * 2)
        near = max(self.distance - depth, self.distance * 0.01, 0.1)
        return perspective(self.field_of_view, aspect, near, self.distance + depth)

    def view_projection(self, aspect: float) -> np.ndarray:
        return self.projection_matrix(aspect) @ self.view_matrix()


def _rotation_z(angle: float) -> np.ndarray:
    c, s = math.cos(angle), math.sin(angle)
    return np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])


def _rotate_z(v, angle: float) -> np.ndarray:
    return _rotation_z(angle) @ np.asarray(v, float)


def _rotation_between(a, b) -> np.ndarray:
    """The shortest rotation taking unit vector a to b."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    v = np.cross(a, b)
    c = float(np.dot(a, b))
    if c < -0.999999:
        axis = np.cross(a, [1.0, 0.0, 0.0])
        if np.linalg.norm(axis) < 1e-6:
            axis = np.cross(a, [0.0, 1.0, 0.0])
        axis /= np.linalg.norm(axis)
        return 2 * np.outer(axis, axis) - np.identity(3)
    k = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.identity(3) + k + k @ k / (1 + c)
