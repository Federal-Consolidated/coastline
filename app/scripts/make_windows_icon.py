"""Makes the Windows app icon (coastline_app/ui/coastline.ico: the window, the installer and its
shortcuts) from the Mac icon artwork.

    swift ../scripts/support/make-icon.swift /tmp/icon.png       (on a Mac: the same design)
    .venv/bin/python scripts/make_windows_icon.py /tmp/icon.png

The Mac artwork sits on Apple's icon grid with a transparent margin; Windows icons fill their
square, so the margin is cropped. The .ico holds PNG images at the sizes Windows asks for.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

from PySide6.QtCore import QBuffer, QByteArray, QIODevice, QRect, Qt
from PySide6.QtGui import QGuiApplication, QImage

SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)
OUT = Path(__file__).resolve().parent.parent / "coastline_app" / "ui" / "coastline.ico"


def opaque_bounds(img: QImage) -> QRect:
    w, h = img.width(), img.height()
    xs, ys = [], []
    step = max(1, w // 512)
    for y in range(0, h, step):
        for x in range(0, w, step):
            if img.pixelColor(x, y).alpha() > 8:
                xs.append(x)
                ys.append(y)
    left, right, top, bottom = min(xs), max(xs), min(ys), max(ys)
    side = max(right - left, bottom - top) + step
    cx, cy = (left + right) // 2, (top + bottom) // 2
    return QRect(cx - side // 2, cy - side // 2, side, side)


def png_bytes(img: QImage) -> bytes:
    data = QByteArray()
    buf = QBuffer(data)
    buf.open(QIODevice.OpenModeFlag.WriteOnly)
    img.save(buf, "PNG")
    return bytes(data)


def main() -> None:
    QGuiApplication(sys.argv[:1])
    src = QImage(sys.argv[1]).convertToFormat(QImage.Format.Format_ARGB32)
    square = src.copy(opaque_bounds(src))
    images = [png_bytes(square.scaled(s, s, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)) for s in SIZES]
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries, blobs = b"", b""
    for size, blob in zip(SIZES, images):
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(blob), offset + len(blobs))
        blobs += blob
    OUT.write_bytes(header + entries + blobs)
    print(f"made {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
