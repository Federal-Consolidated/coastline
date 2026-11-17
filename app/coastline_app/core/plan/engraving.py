"""Text engraved into the part: its glyph outlines, traced at a fixed depth below the part's
surface. Port of Plan/Engraving.swift. Glyph outlines come from Qt's font engine (CoreText on the
Mac app), so the same font names work on Windows and macOS."""

from __future__ import annotations

import math
from dataclasses import dataclass

from .texture import Texture


@dataclass
class Engraving:
    text: str
    height: float = 4.0  # cap height, mm
    x: float = 0.0  # centre in the work frame (X up, Y along the bar)
    y: float = 0.0
    angle: float = 0.0  # degrees
    depth: float = 0.15  # below the surface, mm
    font: str = "Helvetica-Bold"
    side: int = 0  # 0 = A, the face; 1 = B, the back of a two-sided part
    # Probe the face first and follow it (contour mapping): flat face, conductive stock only.
    probe_surface: bool | None = None
    texture: Texture | None = None  # a decorative texture instead of the text

    def polylines(self, tolerance: float = 0.02) -> list[list[tuple[float, float]]]:
        """Glyph outlines as closed polylines in the work frame's XY (text reads along +Y with
        its top toward +X, like reading the face from the spindle)."""
        a = self.angle * math.pi / 180
        ca, sa = math.cos(a), math.sin(a)
        if self.texture is not None:
            return [[(self.x + u * sa + v * ca, self.y + u * ca - v * sa) for u, v in line] for line in self.texture.lines()]
        if not self.text:
            return []
        loops, width, cap = _glyph_loops(self.text, self.font, self.height, tolerance)
        if not loops:
            return []
        scale = self.height / max(cap, 1.0)
        cx, cy = width / 2, cap / 2
        out = []
        for loop in loops:
            pts = []
            for qx, qy in loop:
                u, v = (qx - cx) * scale, (qy - cy) * scale  # along, up
                along, up = u * ca - v * sa, u * sa + v * ca
                pts.append((self.x + up, self.y + along))
            out.append(pts)
        return out

    @staticmethod
    def steps(chord: float, tol: float) -> int:
        return min(max(math.ceil(chord / max(tol * 20, 0.05)), 2), 24)

    @property
    def size(self) -> tuple[float, float]:
        """Width (along Y) and height (X) of the text, mm."""
        if self.texture is not None:
            return self.texture.size
        pts = [p for line in self.polylines() for p in line]
        if not pts:
            return (0.0, 0.0)
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        return (max(ys) - min(ys), max(xs) - min(xs))


def _qfont(name: str):
    from PySide6.QtGui import QFont
    family, _, style = name.partition("-")
    font = QFont(family)
    font.setPixelSize(100)
    if style:
        font.setStyleName(style)
        lowered = style.lower()
        if "bold" in lowered:
            font.setBold(True)
        if "italic" in lowered or "oblique" in lowered:
            font.setItalic(True)
    return font


def _glyph_loops(text: str, font_name: str, height: float, tolerance: float):
    """Outlines in font units (y up), the text's advance width and the cap height."""
    from PySide6.QtGui import QFontMetricsF, QPainterPath
    _ensure_gui()
    font = _qfont(font_name)
    metrics = QFontMetricsF(font)
    cap = max(metrics.capHeight(), 1.0)
    width = metrics.horizontalAdvance(text)
    scale = height / cap
    path = QPainterPath()
    path.addText(0, 0, font, text)
    loops: list[list[tuple[float, float]]] = []
    current: list[tuple[float, float]] = []
    start = (0.0, 0.0)
    E = QPainterPath.ElementType
    i, n = 0, path.elementCount()
    while i < n:
        e = path.elementAt(i)
        p = (e.x, -e.y)  # Qt's y points down
        if e.type == E.MoveToElement:
            if len(current) > 2:
                loops.append(current)
            start = p
            current = [start]
            i += 1
        elif e.type == E.LineToElement:
            current.append(p)
            i += 1
        elif e.type == E.CurveToElement:
            c1 = p
            c2e, be = path.elementAt(i + 1), path.elementAt(i + 2)
            c2, b = (c2e.x, -c2e.y), (be.x, -be.y)
            a = current[-1] if current else start
            steps = Engraving.steps(math.dist(a, b) * scale, tolerance)
            for k in range(1, steps + 1):
                t = k / steps
                u = 1 - t
                current.append((a[0] * u * u * u + c1[0] * 3 * u * u * t + c2[0] * 3 * u * t * t + b[0] * t * t * t,
                                a[1] * u * u * u + c1[1] * 3 * u * u * t + c2[1] * 3 * u * t * t + b[1] * t * t * t))
            i += 3
        else:
            i += 1
    if len(current) > 2:
        loops.append(current)
    # Qt leaves subpaths unclosed: close each loop as CoreText's closeSubpath did.
    closed = [loop + [loop[0]] if loop[0] != loop[-1] else loop for loop in loops]
    return closed, width, cap


_app = None


def _ensure_gui() -> None:
    """Font metrics need a QGuiApplication (the app has one; tests and scripts get an offscreen one)."""
    global _app
    from PySide6.QtGui import QGuiApplication
    if QGuiApplication.instance() is None:
        import os
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        _app = QGuiApplication([])
