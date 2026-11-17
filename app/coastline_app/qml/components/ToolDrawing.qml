import QtQuick

// ToolProfileView: a dimensioned side view of the tool hanging in the ER-11 collet: collet
// nut, shank, flutes and tip shape, with its stick-out, flute length and diameter.
Canvas {
    id: cv
    property var tool: ({})
    implicitHeight: 190
    onToolChanged: requestPaint()
    onWidthChanged: requestPaint()
    function mm(v) { const s = Number(v || 0).toFixed(2); return s.replace(/0+$/, "").replace(/\.$/, "") }
    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        const t = tool
        if (!t || t.diameter === undefined) return
        const nutH = 16, nutW = 19
        const total = nutH + t.stickout
        const scale = Math.min((height - 30) / total, (width * 0.3) / Math.max(t.diameter, t.shankDiameter, 1))
        const cx = width / 2
        let y = 10
        const ink = Qt.rgba(1, 1, 1, 0.85), dim = Qt.rgba(1, 1, 1, 0.55)
        const nw = Math.min(nutW * scale, width * 0.32)
        ctx.fillStyle = Qt.rgba(0.5, 0.5, 0.5, 0.35); ctx.strokeStyle = dim; ctx.lineWidth = 1
        ctx.beginPath(); ctx.roundedRect(cx - nw / 2, y, nw, nutH * scale, 3, 3); ctx.fill(); ctx.stroke()
        const nutBottom = y + nutH * scale
        y = nutBottom
        const shankLen = Math.max(t.stickout - t.fluteLength, 0)
        ctx.fillStyle = Qt.rgba(0.5, 0.5, 0.5, 0.55)
        ctx.fillRect(cx - t.shankDiameter * scale / 2, y, t.shankDiameter * scale, shankLen * scale)
        y += shankLen * scale
        const fl = Math.min(t.fluteLength, t.stickout), w = t.diameter * scale
        const fx = cx - w / 2, fy = y, fh = fl * scale, tipY = fy + fh
        function body() {
            ctx.beginPath()
            if (t.kind === "ballEndMill") {
                ctx.moveTo(fx, fy); ctx.lineTo(fx + w, fy); ctx.lineTo(fx + w, Math.max(tipY - w / 2, fy))
                ctx.arc(cx, Math.max(tipY - w / 2, fy), w / 2, 0, Math.PI, false); ctx.closePath()
            } else if (["chamferMill", "engraver", "spotDrill", "drill"].indexOf(t.kind) >= 0) {
                const half = (t.angle || 45) * (t.kind === "drill" || t.kind === "spotDrill" ? 0.5 : 1)
                const tip = (t.tipDiameter || 0) * scale
                const cone = Math.min((w / 2 - tip / 2) / Math.tan(half * Math.PI / 180), fh)
                ctx.moveTo(fx, fy); ctx.lineTo(fx + w, fy); ctx.lineTo(fx + w, tipY - cone); ctx.lineTo(cx + tip / 2, tipY)
                ctx.lineTo(cx - tip / 2, tipY); ctx.lineTo(fx, tipY - cone); ctx.closePath()
            } else if (t.kind === "bullNoseEndMill") {
                const r = (t.cornerRadius || 0) * scale
                ctx.roundedRect(fx, fy, w, fh, r, r)
            } else ctx.rect(fx, fy, w, fh)
        }
        body()
        ctx.fillStyle = Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55); ctx.fill()
        ctx.strokeStyle = ink; ctx.stroke()
        ctx.save(); body(); ctx.clip()
        ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.25)
        for (let x = fx - fh; x < fx + w; x += Math.max(w / Math.max(t.flutes || 1, 1), 4)) {
            ctx.beginPath(); ctx.moveTo(x, fy + fh); ctx.lineTo(x + fh * 0.6, fy); ctx.stroke()
        }
        ctx.restore()
        ctx.strokeStyle = dim; ctx.fillStyle = dim; ctx.font = "10px sans-serif"
        function bar(x, y0, y1) {
            ctx.beginPath(); ctx.moveTo(x, y0); ctx.lineTo(x, y1); ctx.moveTo(x - 4, y0); ctx.lineTo(x + 4, y0); ctx.moveTo(x - 4, y1); ctx.lineTo(x + 4, y1); ctx.stroke()
        }
        const half = Math.max(t.shankDiameter, t.diameter) * scale / 2
        const right = cx + half + 14, left = cx - half - 14
        bar(right, nutBottom, tipY)
        ctx.textAlign = "left"; ctx.fillText("stick-out " + mm(t.stickout), right + 6, (nutBottom + tipY) / 2 + 3)
        bar(left, fy, tipY)
        ctx.textAlign = "right"; ctx.fillText("flutes " + mm(t.fluteLength), left - 6, (fy + tipY) / 2 + 3)
        ctx.textAlign = "center"; ctx.fillText("⌀ " + (t._diameterText || mm(t.diameter)), cx, tipY + 14)
    }
}
