"""SF Symbols for QML: `Image { source: "image://sf/gearshape.2?size=15&weight=regular&color=#ececec" }`.

On macOS the symbols are drawn by AppKit, exactly as the Swift app shows them (Apple allows
them on Apple systems only). Elsewhere, the closest open-licence glyph from
resources/symbols/<name>.svg is used, tinted the same way.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from urllib.parse import parse_qs

from PySide6.QtCore import QByteArray, QRectF, QSize, Qt
from PySide6.QtGui import QColor, QImage, QPainter
from PySide6.QtQuick import QQuickImageProvider

WEIGHTS = {"ultralight": 0.0, "thin": 1, "light": 2, "regular": 3, "medium": 4, "semibold": 5, "bold": 6, "heavy": 7, "black": 8}
FALLBACK_DIR = Path(__file__).resolve().parent / "symbols"
# SF Symbols may be used on Apple systems only; elsewhere the Tabler look-alikes (MIT) in symbols/.
# COASTLINE_SYMBOLS=fallback shows the look-alikes on a Mac too (to check the Windows look).
USE_SF_SYMBOLS = sys.platform == "darwin" and os.environ.get("COASTLINE_SYMBOLS") != "fallback"


def _mac_symbol(name: str, size: float, weight: str, color: QColor, scale: float) -> QImage | None:
    try:
        import AppKit
    except ImportError:
        return None
    img = AppKit.NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None)
    if img is None:
        return None
    w = {"ultralight": AppKit.NSFontWeightUltraLight, "thin": AppKit.NSFontWeightThin, "light": AppKit.NSFontWeightLight,
         "regular": AppKit.NSFontWeightRegular, "medium": AppKit.NSFontWeightMedium, "semibold": AppKit.NSFontWeightSemibold,
         "bold": AppKit.NSFontWeightBold, "heavy": AppKit.NSFontWeightHeavy, "black": AppKit.NSFontWeightBlack}.get(weight, AppKit.NSFontWeightRegular)
    cfg = AppKit.NSImageSymbolConfiguration.configurationWithPointSize_weight_scale_(size, w, AppKit.NSImageSymbolScaleMedium)
    img = img.imageWithSymbolConfiguration_(cfg)
    if img is None:
        return None
    sz = img.size()
    pw, ph = max(int(round(sz.width * scale)), 1), max(int(round(sz.height * scale)), 1)
    rep = AppKit.NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, pw, ph, 8, 4, True, False, AppKit.NSDeviceRGBColorSpace, 0, 0)
    rep.setSize_(sz)
    AppKit.NSGraphicsContext.saveGraphicsState()
    AppKit.NSGraphicsContext.setCurrentContext_(AppKit.NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep))
    img.drawInRect_(AppKit.NSMakeRect(0, 0, sz.width, sz.height))
    AppKit.NSGraphicsContext.restoreGraphicsState()
    data = rep.representationUsingType_properties_(AppKit.NSBitmapImageFileTypePNG, {})
    out = QImage.fromData(QByteArray(bytes(data)), "PNG").convertToFormat(QImage.Format.Format_ARGB32_Premultiplied)
    # Monochrome rendering, like .foregroundStyle(colour): the template's shape in one colour
    # (cut-outs such as the check in checkmark.circle.fill stay see-through).
    p = QPainter(out)
    p.setCompositionMode(QPainter.CompositionMode.CompositionMode_SourceIn)
    p.fillRect(out.rect(), color)
    p.end()
    out.setDevicePixelRatio(scale)
    return out


def _fallback(name: str, size: float, color: QColor, scale: float) -> QImage:
    from PySide6.QtSvg import QSvgRenderer
    px = max(int(round(size * 1.25 * scale)), 1)
    img = QImage(px, px, QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(Qt.GlobalColor.transparent)
    path = FALLBACK_DIR / f"{name}.svg"
    if not path.exists():
        path = FALLBACK_DIR / f"{name.split('.')[0]}.svg"
    if path.exists():
        r = QSvgRenderer(str(path))
        p = QPainter(img)
        r.render(p, QRectF(0, 0, px, px))
        p.setCompositionMode(QPainter.CompositionMode.CompositionMode_SourceIn)
        p.fillRect(img.rect(), color)
        p.end()
    img.setDevicePixelRatio(scale)
    return img


class SymbolProvider(QQuickImageProvider):
    def __init__(self) -> None:
        super().__init__(QQuickImageProvider.ImageType.Image)
        self._cache: dict[str, QImage] = {}

    def requestImage(self, id: str, size: QSize, requested: QSize) -> QImage:
        name, _, query = id.partition("?")
        q = {k: v[-1] for k, v in parse_qs(query).items()}
        pt = float(q.get("size", 13))
        weight = q.get("weight", "regular")
        color = QColor(q.get("color", "#ececec"))
        scale = float(q.get("scale", 2))
        key = f"{name}|{pt}|{weight}|{color.name(QColor.NameFormat.HexArgb)}|{scale}"
        img = self._cache.get(key)
        if img is None:
            img = (_mac_symbol(name, pt, weight, color, scale) if USE_SF_SYMBOLS else None) or _fallback(name, pt, color, scale)
            self._cache[key] = img
        if size is not None:
            size.setWidth(img.width())
            size.setHeight(img.height())
        return img
