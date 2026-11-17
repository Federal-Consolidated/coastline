"""Small still pictures of fixture models for lists (FixtureThumbnail): the mesh drawn iso,
shaded, on a transparent background, cached by key. Drawn with QPainter in a worker, so no
GPU context is needed; QML shows them through image://thumb/<key>."""

from __future__ import annotations

import math
import threading

import numpy as np
from PySide6.QtCore import QPointF, QSize, Qt
from PySide6.QtGui import QColor, QImage, QPainter, QPolygonF
from PySide6.QtQuick import QQuickImageProvider

_images: dict[str, QImage] = {}
_lock = threading.Lock()


def store(key: str, image: QImage) -> None:
    with _lock:
        _images[key] = image


def has(key: str) -> bool:
    with _lock:
        return key in _images


def render(vertices, indices, width: int = 240, height: int = 200, color=(0.62, 0.63, 0.65)) -> QImage:
    """The mesh from the front-right, above (the Iso view), filling the picture."""
    v = np.asarray(vertices, np.float64).reshape(-1, 3)
    tri = np.asarray(indices, np.int64).reshape(-1, 3)
    yaw, pitch = math.pi / 4, math.pi / 6
    eye = np.array([math.cos(pitch) * math.sin(yaw), -math.cos(pitch) * math.cos(yaw), math.sin(pitch)])
    right = np.cross(-eye, [0.0, 0.0, 1.0])
    right /= np.linalg.norm(right)
    up = np.cross(right, -eye)
    c = (v.min(0) + v.max(0)) / 2
    p = v - c
    sx, sy, depth = p @ right, p @ up, p @ eye
    span = max(sx.max() - sx.min(), sy.max() - sy.min(), 1e-6)
    scale = 0.86 * min(width, height) / span
    X = width / 2 + (sx - (sx.max() + sx.min()) / 2) * scale
    Y = height / 2 - (sy - (sy.max() + sy.min()) / 2) * scale
    a, b, d = v[tri[:, 0]], v[tri[:, 1]], v[tri[:, 2]]
    n = np.cross(b - a, d - a)
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
    n[(n @ eye) < 0] *= -1  # two-sided
    light = np.array([-0.3, -0.5, 1.0]) @ np.eye(3)
    light = 0.6 * eye + 0.4 * light / np.linalg.norm(light)
    light /= np.linalg.norm(light)
    shade = np.clip(0.28 + 0.72 * np.clip(n @ light, 0, 1), 0, 1)
    order = np.argsort(depth[tri].mean(1))  # far first
    img = QImage(QSize(width, height), QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(Qt.GlobalColor.transparent)
    painter = QPainter(img)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing, False)
    painter.setPen(Qt.PenStyle.NoPen)
    for k in order:
        i, j, l = tri[k]
        s = shade[k]
        col = QColor.fromRgbF(min(color[0] * s * 1.25, 1), min(color[1] * s * 1.25, 1), min(color[2] * s * 1.25, 1))
        painter.setBrush(col)
        painter.setPen(col)
        painter.drawPolygon(QPolygonF([QPointF(X[i], Y[i]), QPointF(X[j], Y[j]), QPointF(X[l], Y[l])]))
    painter.end()
    return img


class ThumbnailProvider(QQuickImageProvider):
    def __init__(self) -> None:
        super().__init__(QQuickImageProvider.ImageType.Image)

    def requestImage(self, id: str, size, requested) -> QImage:  # noqa: N802 (Qt's name)
        key = id.split("?")[0]
        with _lock:
            img = _images.get(key)
        if img is None:
            img = QImage(1, 1, QImage.Format.Format_ARGB32_Premultiplied)
            img.fill(Qt.GlobalColor.transparent)
        return img
