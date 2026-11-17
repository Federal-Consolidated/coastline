import QtQuick

// StockPreview: the stock in its material colour, isometric, with its dimensions.
Canvas {
    id: cv
    property var envelope: [50, 50, 20]
    property string shape: "block"
    property color swatch: "#c7ccd4"
    implicitHeight: 150
    onEnvelopeChanged: requestPaint()
    onShapeChanged: requestPaint()
    onSwatchChanged: requestPaint()
    onWidthChanged: requestPaint()
    function mm(v) { const s = Number(v).toFixed(2); return s.replace(/0+$/, "").replace(/\.$/, "") }
    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        const ex = envelope[0], ey = envelope[1], ez = envelope[2]
        const c30 = Math.cos(Math.PI / 6), s30 = Math.sin(Math.PI / 6)
        const extentW = (ex + ey) * c30, extentH = (ex + ey) * s30 + ez
        const scale = Math.min((width - 40) / extentW, (height - 40) / extentH)
        const ox = width / 2 + (ey - ex) * c30 * scale / 2, oy = height / 2 + extentH * scale / 2 - (ex + ey) * s30 * scale
        function p(x, y, z) { return [ox + (x - y) * c30 * scale, oy + (x + y) * s30 * scale - z * scale] }
        function poly(pts, fill, alpha) {
            ctx.beginPath(); ctx.moveTo(pts[0][0], pts[0][1]); for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]); ctx.closePath()
            ctx.globalAlpha = alpha; ctx.fillStyle = fill; ctx.fill(); ctx.globalAlpha = 1
            ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.35); ctx.lineWidth = 1; ctx.stroke()
        }
        if (shape === "roundBar") {
            const r = ex / 2, a = p(r, 0, r), b = p(r, ey, r), rx = r * scale * 0.95, ry = r * scale
            ctx.beginPath(); ctx.moveTo(a[0] - rx * 0.5, a[1] - ry); ctx.lineTo(b[0] - rx * 0.5, b[1] - ry)
            ctx.lineTo(b[0] + rx * 0.5, b[1] + ry); ctx.lineTo(a[0] + rx * 0.5, a[1] + ry); ctx.closePath()
            ctx.globalAlpha = 0.85; ctx.fillStyle = swatch; ctx.fill(); ctx.globalAlpha = 1
            ctx.beginPath(); ctx.ellipse(a[0] - rx * 0.5, a[1] - ry, rx, ry * 2); ctx.fillStyle = swatch; ctx.fill()
            ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.4); ctx.stroke()
            return
        }
        poly([p(0, ey, 0), p(ex, ey, 0), p(ex, ey, ez), p(0, ey, ez)], swatch, 0.72)
        poly([p(ex, 0, 0), p(ex, ey, 0), p(ex, ey, ez), p(ex, 0, ez)], swatch, 0.88)
        poly([p(0, 0, ez), p(ex, 0, ez), p(ex, ey, ez), p(0, ey, ez)], swatch, 1)
        ctx.fillStyle = Qt.rgba(1, 1, 1, 0.55)
        ctx.font = "10px sans-serif"
        ctx.textAlign = "center"
        const a1 = p(0, ey, 0), b1 = p(ex, ey, 0), a2 = p(ex, 0, 0), b2 = p(ex, ey, 0), m3 = p(ex, 0, ez / 2)
        ctx.fillText(mm(ex), (a1[0] + b1[0]) / 2 - 10, (a1[1] + b1[1]) / 2 + 16)
        ctx.fillText(mm(ey), (a2[0] + b2[0]) / 2 + 10, (a2[1] + b2[1]) / 2 + 16)
        ctx.fillText(mm(ez), m3[0] + 18, m3[1] + 4)
    }
}
