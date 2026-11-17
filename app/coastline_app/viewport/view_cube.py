"""The orientation cube (PreForm style): bevelled edges and cut corners; faces give the standard
views, edges and corners the views between them. Port of Views/ViewCube.swift."""

from __future__ import annotations

import math

import numpy as np
from PySide6.QtCore import Property, QObject, QPointF, Qt, Signal, Slot
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath, QPen, QPolygonF, QTransform
from PySide6.QtQml import QmlElement
from PySide6.QtQuick import QQuickPaintedItem

QML_IMPORT_NAME = "Coastline.Viewport"
QML_IMPORT_MAJOR_VERSION = 1

NAMES = {0: ("RIGHT", "right"), 1: ("LEFT", "left"), 2: ("TOOL", "tool"), 3: ("FRONT", "front"), 4: ("TOP", "top"), 5: ("BOTTOM", "")}


def _facets():
    edge, corner = 1.6, 2.1
    planes = []
    for axis in range(3):
        for s in (1, -1):
            n = np.zeros(3)
            n[axis] = s
            planes.append((n, 1.0, 0))
    for i in range(3):
        for j in range(i + 1, 3):
            for si in (1, -1):
                for sj in (1, -1):
                    n = np.zeros(3)
                    n[i], n[j] = si, sj
                    planes.append((n / np.linalg.norm(n), edge / math.sqrt(2), 1))
    for sx in (1, -1):
        for sy in (1, -1):
            for sz in (1, -1):
                n = np.array([sx, sy, sz], float)
                planes.append((n / np.linalg.norm(n), corner / math.sqrt(3), 2))

    def polygon(k):
        n, d, _ = planes[k]
        u = np.cross([0, 0, 1], n) if abs(n[2]) < 0.9 else np.cross([1, 0, 0], n)
        u = u / np.linalg.norm(u)
        v = np.cross(n, u)
        c = n * d
        poly = [c - 3 * u - 3 * v, c + 3 * u - 3 * v, c + 3 * u + 3 * v, c - 3 * u + 3 * v]
        for m, (pn, pd, _) in enumerate(planes):
            if m == k:
                continue
            out = []
            for a, b in zip(poly, poly[1:] + poly[:1]):
                da, db = pn @ a - pd, pn @ b - pd
                if da <= 1e-6:
                    out.append(a)
                if (da < -1e-6 and db > 1e-6) or (da > 1e-6 and db < -1e-6):
                    out.append(a + (b - a) * (da / (da - db)))
            poly = out
            if not poly:
                break
        clean = []
        for p in poly:
            if not clean or np.linalg.norm(clean[-1] - p) > 1e-4:
                clean.append(p)
        if len(clean) > 1 and np.linalg.norm(clean[0] - clean[-1]) <= 1e-4:
            clean.pop()
        return clean

    out = []
    for k, (n, _, kind) in enumerate(planes):
        pts = polygon(k)
        if len(pts) >= 3:
            label, view = NAMES.get(k, (None, None)) if kind == 0 else (None, None)
            out.append((n, pts, label, view, kind))
    return out


FACETS = _facets()


@QmlElement
class ViewCube(QQuickPaintedItem):
    picked = Signal(float, float, float, str)  # normal (display space), the standard view or ""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._viewport = None
        self._hover = None
        self._projected = []
        self.setAcceptHoverEvents(True)
        self.setAcceptedMouseButtons(Qt.MouseButton.LeftButton)
        self.setAntialiasing(True)
        self.setImplicitWidth(96)
        self.setImplicitHeight(96)

    def _get_viewport(self):
        return self._viewport

    def _set_viewport(self, v) -> None:
        self._viewport = v
        if v is not None:
            v.cameraChanged.connect(self.update)
        self.update()

    viewportChanged = Signal()
    viewport = Property(QObject, _get_viewport, _set_viewport, notify=viewportChanged)

    def _project(self):
        cam = self._viewport.camera if self._viewport is not None else None
        rot = np.asarray(cam.view_matrix(), float)[:3, :3] if cam is not None else np.eye(3)
        scale, mid = 30.0, 48.0

        def screen(p):
            v = rot @ p
            return QPointF(mid + v[0] * scale, mid - v[1] * scale)

        light = np.array([-0.3, 0.6, 1.0])
        light /= np.linalg.norm(light)
        out = []
        for i, (n0, corners, label, view, kind) in enumerate(FACETS):
            n = rot @ n0
            if n[2] <= 0.001:
                continue
            c = sum(corners) / len(corners)
            up = np.array([0, 1.0, 0]) if abs(n0[2]) > 0.9 else np.array([0, 0, 1.0])
            right = np.cross(up, n0)
            right /= np.linalg.norm(right)
            o, r, d = screen(c), screen(c + right), screen(c - up)
            shade = 0.75 + 0.3 * max(float(n @ light), 0)
            out.append((i, QPolygonF([screen(p) for p in corners]), float(n[2]), float((rot @ c)[2]), shade, r - o, d - o, o))
        out.sort(key=lambda f: f[3])
        self._projected = out
        return out

    def paint(self, p: QPainter) -> None:
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        projected = self._project()
        # The shadow (.shadow(color: .black.opacity(0.35), radius: 6, y: 3)), approximated.
        outline = QPainterPath()
        for f in projected:
            outline.addPolygon(f[1])
        for k in range(6, 0, -1):
            p.save()
            p.translate(0, 3)
            p.setPen(QPen(QColor(0, 0, 0, int(0.35 * 255 / 6)), k * 2, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
            p.drawPath(outline.simplified())
            p.restore()
        for i, poly, facing, _, shade, au, av, centre in projected:
            _, _, label, _, kind = FACETS[i]
            base = 0.90 if kind == 0 else 0.80 if kind == 1 else 0.74
            g = min(base * shade, 0.97)
            fill = QColor.fromRgbF(0.5, 0.5, 0.5) if self._hover == i else QColor.fromRgbF(g, g, g)
            p.setBrush(fill)
            p.setPen(QPen(QColor.fromRgbF(0.45, 0.45, 0.45), 0.8))
            p.drawPolygon(poly)
            if label and facing > 0.25:
                p.save()
                p.setTransform(QTransform(au.x() / 30, au.y() / 30, av.x() / 30, av.y() / 30, centre.x(), centre.y()), True)
                f = QFont()
                f.setPixelSize(9 if len(label) > 4 else 10)
                f.setWeight(QFont.Weight.Black)
                p.setFont(f)
                p.setPen(QColor.fromRgbF(0.28, 0.28, 0.28))
                rect = p.fontMetrics().boundingRect(label)
                p.drawText(QPointF(-rect.width() / 2, rect.height() / 2 - p.fontMetrics().descent()), label)
                p.restore()

    def _hit(self, pos) -> int | None:
        for f in reversed(self._projected):
            if f[1].containsPoint(pos, Qt.FillRule.OddEvenFill):
                return f[0]
        return None

    def hoverMoveEvent(self, e) -> None:
        h = self._hit(e.position())
        if h != self._hover:
            self._hover = h
            self.update()

    def hoverLeaveEvent(self, e) -> None:
        self._hover = None
        self.update()

    def mousePressEvent(self, e) -> None:
        e.accept()

    def mouseReleaseEvent(self, e) -> None:
        i = self._hit(e.position())
        if i is None:
            return
        n, _, _, view, _ = FACETS[i]
        self.picked.emit(float(n[0]), float(n[1]), float(n[2]), view or "")
