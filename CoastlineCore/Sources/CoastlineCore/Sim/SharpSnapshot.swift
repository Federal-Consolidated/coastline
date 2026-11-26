import Foundation
import simd

// K12. Sharp snapshots and exact readouts. The playback simulation is a grid of ~250 000
// heights (0.1–0.2 mm cells): enough to watch material go, too coarse for 8 µm cusps or a
// ±20 µm deviation band. A sharp snapshot re-simulates the moves up to the playhead at
// 2–20 µm; the exact readouts evaluate the tool's envelope over a point straight from the moves.

/// One straight cutting stretch of the tool: from a to b (work frame, tool tip), radius r,
/// corner radius rc (0 flat, r ball, between bull nose).
public struct CutSegment: Sendable, Equatable {
    public var a: SIMD3<Double>
    public var b: SIMD3<Double>
    public var r: Double
    public var rc: Double
    public init(a: SIMD3<Double>, b: SIMD3<Double>, r: Double, rc: Double) {
        self.a = a
        self.b = b
        self.r = r
        self.rc = min(max(rc, 0), r)
    }
    var minZ: Double { min(a.z, b.z) }
}

public extension Heightmap {
    /// A grid with explicit placement (a sharp snapshot's region).
    init(origin: SIMD2<Double>, cell: Double, cols: Int, rows: Int, top: Double, bottom: Double, heights: [Float]) {
        self.init(stockMin: SIMD3(origin.x - cell / 2, origin.y - cell / 2, bottom),
                  stockMax: SIMD3(origin.x - cell / 2 + Double(cols) * cell, origin.y - cell / 2 + Double(rows) * cell, top),
                  explicitCell: cell, cols: cols, rows: rows)
        self.heights = heights
    }

    /// The height of the cell containing p (clamped to the grid).
    func sample(_ p: SIMD2<Double>) -> Double {
        let c = min(max(Int(((p.x - origin.x) / cell).rounded()), 0), cols - 1)
        let r = min(max(Int(((p.y - origin.y) / cell).rounded()), 0), rows - 1)
        return Double(heights[r * cols + c])
    }

    /// Cell index range covering [lo, hi] in X and Y.
    func cellRange(_ lo: SIMD2<Double>, _ hi: SIMD2<Double>) -> (c0: Int, r0: Int, c1: Int, r1: Int)? {
        let c0 = max(Int(((lo.x - origin.x) / cell).rounded(.down)), 0)
        let c1 = min(Int(((hi.x - origin.x) / cell).rounded(.up)), cols - 1)
        let r0 = max(Int(((lo.y - origin.y) / cell).rounded(.down)), 0)
        let r1 = min(Int(((hi.y - origin.y) / cell).rounded(.up)), rows - 1)
        return c0 <= c1 && r0 <= r1 ? (c0, r0, c1, r1) : nil
    }
}

public enum SharpSim {
    /// The tool's profile: height above the tip at distance d from the axis (nil: outside).
    @inline(__always) static func profile(_ d: Double, r: Double, rc: Double) -> Double? {
        guard d <= r else { return nil }
        let flat = r - rc
        guard d > flat else { return 0 }
        let u = d - flat
        return rc - max(rc * rc - u * u, 0).squareRoot()
    }

    /// The cutting stretches of moves (rapids skipped). Arcs are split finely (chord error well
    /// under a µm for desktop tools), and sloped stretches so Z changes at most `dzMax` along
    /// one, which keeps the closest-point envelope used by the grid within `dzMax` of exact
    /// (the exact readouts evaluate each stretch exactly, whatever its length).
    public static func segments(_ moves: [(move: Move, start: SIMD3<Double>, radius: Double, corner: Double)],
                                dzMax: Double = 0.01) -> [CutSegment] {
        var out: [CutSegment] = []
        out.reserveCapacity(moves.count * 2)
        for m in moves where m.move.role != .rapid && m.radius > 0 {
            var p = m.start
            for q in ToolpathGeometry.points(of: m.move, from: m.start, segmentAngle: 0.02) {
                let n = max(Int((abs(q.z - p.z) / dzMax).rounded(.up)), 1)
                for k in 0..<n {
                    let a = p + (q - p) * (Double(k) / Double(n)), b = p + (q - p) * (Double(k + 1) / Double(n))
                    out.append(CutSegment(a: a, b: b, r: m.radius, rc: m.corner))
                }
                p = q
            }
        }
        return out
    }

    /// The cell size for a region: `target` unless that's more than `maxCells` cells.
    public static func cell(region lo: SIMD2<Double>, _ hi: SIMD2<Double>, target: Double, maxCells: Int = 30_000_000) -> Double {
        let area = max((hi.x - lo.x) * (hi.y - lo.y), 1e-6)
        return max(target, (area / Double(maxCells)).squareRoot())
    }

    /// Segments that can shape the final surface: a segment whose lowest tip stays above the
    /// highest final height around it (from the coarse simulation at the same moment, plus a
    /// margin for what the coarse cells don't see) can't be the lowest cut anywhere. Most
    /// roughing is cut away again later, so most of the work goes.
    public static func cull(_ segs: [CutSegment], coarse: Heightmap?, region lo: SIMD2<Double>, _ hi: SIMD2<Double>) -> [CutSegment] {
        let inRegion = segs.filter { s in
            s.minZ < (coarse?.top ?? .infinity)
                && max(s.a.x, s.b.x) + s.r >= lo.x && min(s.a.x, s.b.x) - s.r <= hi.x
                && max(s.a.y, s.b.y) + s.r >= lo.y && min(s.a.y, s.b.y) - s.r <= hi.y
        }
        guard let c = coarse else { return inRegion }
        // Block maxima (8 × 8 coarse cells): a conservative, fast footprint maximum.
        let B = 8, bc = (c.cols + B - 1) / B, br = (c.rows + B - 1) / B
        var block = [Float](repeating: -.infinity, count: bc * br)
        for r in 0..<c.rows { for col in 0..<c.cols { let i = (r / B) * bc + col / B; block[i] = max(block[i], c.heights[r * c.cols + col]) } }
        let margin = c.cell * 1.5 + 0.02
        return inRegion.filter { s in
            guard let (c0, r0, c1, r1) = c.cellRange(SIMD2(min(s.a.x, s.b.x) - s.r, min(s.a.y, s.b.y) - s.r),
                                                      SIMD2(max(s.a.x, s.b.x) + s.r, max(s.a.y, s.b.y) + s.r)) else { return false }
            var m: Float = -.infinity
            for r in (r0 / B)...(r1 / B) { for col in (c0 / B)...(c1 / B) { m = max(m, block[r * bc + col]) } }
            return s.minZ <= Double(m) + margin
        }
    }

    /// Re-simulates `segs` over a region at `cell`, starting from `start` (the coarse state the
    /// side began from). Bands of rows run in parallel; the lowest cut wins, so order doesn't
    /// matter, and going from the lowest segment up lets most cells be skipped at a glance.
    /// nil when cancelled.
    public static func sharpen(_ segs: [CutSegment], start: Heightmap, coarse: Heightmap?, region lo: SIMD2<Double>, _ hi: SIMD2<Double>,
                               cell: Double, progress: @escaping @Sendable (Double) -> Void = { _ in },
                               cancelled: @escaping @Sendable () -> Bool = { false }) -> Heightmap? {
        let cols = max(Int(((hi.x - lo.x) / cell).rounded(.up)), 2), rows = max(Int(((hi.y - lo.y) / cell).rounded(.up)), 2)
        let origin = SIMD2(lo.x + cell / 2, lo.y + cell / 2)
        var heights = [Float](repeating: Float(start.top), count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols { heights[r * cols + c] = Float(start.sample(SIMD2(origin.x + Double(c) * cell, origin.y + Double(r) * cell))) }
        }
        let kept = cull(segs, coarse: coarse, region: lo, hi).sorted { $0.minZ < $1.minZ }
        // Tiles of T × T cells keep their highest cell: a segment skips every tile already
        // below its lowest point (most of them, going from the lowest segment up).
        let T = 32, tcols = (cols + T - 1) / T, trows = (rows + T - 1) / T
        var tileMax = [Float](repeating: -.infinity, count: tcols * trows)
        for r in 0..<rows { for c in 0..<cols { let t = (r / T) * tcols + c / T; tileMax[t] = max(tileMax[t], heights[r * cols + c]) } }
        let bands = min(max(ProcessInfo.processInfo.activeProcessorCount * 4, 8), trows)
        let tilesPer = (trows + bands - 1) / bands, rowsPer = tilesPer * T
        var lists = [[Int32]](repeating: [], count: bands)
        for (k, s) in kept.enumerated() {
            let y0 = min(s.a.y, s.b.y) - s.r, y1 = max(s.a.y, s.b.y) + s.r
            let r0 = max(Int(((y0 - origin.y) / cell).rounded(.down)), 0), r1 = min(Int(((y1 - origin.y) / cell).rounded(.up)), rows - 1)
            guard r0 <= r1 else { continue }
            for b in (r0 / rowsPer)...min(r1 / rowsPer, bands - 1) { lists[b].append(Int32(k)) }
        }
        let bottom = Float(start.bottom)
        let done = Counter()
        let stop = Counter()
        let grid = TileGrid(cols: cols, rows: rows, T: T, tcols: tcols, origin: origin, cell: cell, bottom: bottom)
        heights.withUnsafeMutableBufferPointer { buf in
            tileMax.withUnsafeMutableBufferPointer { tbuf in
                nonisolated(unsafe) let h = buf.baseAddress!
                nonisolated(unsafe) let tm = tbuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: bands) { b in
                    let rb0 = b * rowsPer, rb1 = min(rb0 + rowsPer, rows) - 1
                    guard rb0 <= rb1 else { return }
                    for (n, k) in lists[b].enumerated() {
                        if n & 255 == 0, stop.value > 0 || cancelled() { stop.add(); return }
                        stamp(kept[Int(k)], into: h, tileMax: tm, grid: grid, rowRange: rb0...rb1)
                    }
                    progress(Double(done.add()) / Double(bands))
                }
            }
        }
        if stop.value > 0 { return nil }
        return Heightmap(origin: origin, cell: cell, cols: cols, rows: rows, top: start.top, bottom: start.bottom, heights: heights)
    }

    struct TileGrid {
        var cols: Int, rows: Int, T: Int, tcols: Int
        var origin: SIMD2<Double>, cell: Double, bottom: Float
    }

    /// Lowers the cells of rows `rowRange` under one segment (as `Heightmap.cut`), tile by tile,
    /// skipping tiles already lower than the segment's lowest point.
    @inline(__always)
    static func stamp(_ s: CutSegment, into h: UnsafeMutablePointer<Float>, tileMax tm: UnsafeMutablePointer<Float>,
                      grid g: TileGrid, rowRange: ClosedRange<Int>) {
        let a = s.a, b = s.b, r = s.r, cell = g.cell, origin = g.origin, cols = g.cols, T = g.T
        let r0 = max(Int(((min(a.y, b.y) - r - origin.y) / cell).rounded(.down)), rowRange.lowerBound)
        let r1 = min(Int(((max(a.y, b.y) + r - origin.y) / cell).rounded(.up)), rowRange.upperBound)
        let c0 = max(Int(((min(a.x, b.x) - r - origin.x) / cell).rounded(.down)), 0)
        let c1 = min(Int(((max(a.x, b.x) + r - origin.x) / cell).rounded(.up)), cols - 1)
        guard r0 <= r1, c0 <= c1 else { return }
        let d = SIMD2(b.x - a.x, b.y - a.y), len2 = (d * d).sum()
        let flatR = r - s.rc, rc = s.rc
        let floorZ = Float(max(s.minZ, Double(g.bottom)))
        for tr in (r0 / T)...(r1 / T) {
            let rowLo = max(r0, tr * T), rowHi = min(r1, tr * T + T - 1)
            for tc in (c0 / T)...(c1 / T) {
                let ti = tr * g.tcols + tc
                if tm[ti] <= floorZ { continue }
                let colLo = max(c0, tc * T), colHi = min(c1, tc * T + T - 1)
                var changed = false
                for row in rowLo...rowHi {
                    let y = origin.y + Double(row) * cell
                    var lo = colLo, hi = colHi
                    if abs(d.y) > 1e-9 {
                        let ta = min(max((y - r - a.y) / d.y, 0), 1), tb = min(max((y + r - a.y) / d.y, 0), 1)
                        let xa = a.x + d.x * ta, xb = a.x + d.x * tb
                        lo = max(colLo, Int(((min(xa, xb) - r - origin.x) / cell).rounded(.down)))
                        hi = min(colHi, Int(((max(xa, xb) + r - origin.x) / cell).rounded(.up)))
                        if lo > hi { continue }
                    }
                    let base = row * cols
                    for col in lo...hi {
                        let i = base + col
                        if h[i] <= floorZ { continue }
                        let x = origin.x + Double(col) * cell
                        var t = 0.0
                        if len2 > 1e-12 { t = min(max(((x - a.x) * d.x + (y - a.y) * d.y) / len2, 0), 1) }
                        let px = a.x + d.x * t - x, py = a.y + d.y * t - y
                        let dist2 = px * px + py * py
                        guard dist2 <= r * r else { continue }
                        var z = a.z + (b.z - a.z) * t
                        let dist = dist2.squareRoot()
                        if dist > flatR { let u = dist - flatR; z += rc - max(rc * rc - u * u, 0).squareRoot() }
                        let zf = max(Float(z), g.bottom)
                        if zf < h[i] { h[i] = zf; changed = true }
                    }
                }
                if changed {
                    var m: Float = -.infinity
                    for row in (tr * T)...min(tr * T + T - 1, g.rows - 1) {
                        let base = row * cols
                        for col in (tc * T)...min(tc * T + T - 1, cols - 1) { m = max(m, h[base + col]) }
                    }
                    tm[ti] = m
                }
            }
        }
    }

    // MARK: Exact readouts

    /// The lowest point of a segment's tool envelope over p, exactly (nil: the tool never
    /// covers p). z(t) is linear and the profile of a convex distance is convex, so the height
    /// over p is convex in t: a golden-section search finds its minimum.
    public static func envelope(_ s: CutSegment, at p: SIMD2<Double>) -> Double? {
        let a2 = SIMD2(s.a.x, s.a.y), d = SIMD2(s.b.x - s.a.x, s.b.y - s.a.y)
        let w = p - a2, len2 = (d * d).sum()
        // The t interval where the axis is within r of p.
        var t0 = 0.0, t1 = 1.0
        if len2 > 1e-14 {
            let tc = (w * d).sum() / len2
            let perp2 = max((w * w).sum() - tc * tc * len2, 0)
            guard perp2 <= s.r * s.r + 1e-12 else { return nil }
            let half = ((s.r * s.r - perp2) / len2).squareRoot()
            t0 = max(tc - half, 0)
            t1 = min(tc + half, 1)
            guard t0 <= t1 else { return nil }
        } else if (w * w).sum() > s.r * s.r {
            return nil
        }
        func f(_ t: Double) -> Double {
            let q = a2 + d * t, dist = simd_length(p - q)
            return s.a.z + (s.b.z - s.a.z) * t + (profile(min(dist, s.r), r: s.r, rc: s.rc) ?? 0)
        }
        var lo = t0, hi = t1
        let g = 0.6180339887498949
        var x1 = hi - g * (hi - lo), x2 = lo + g * (hi - lo)
        var f1 = f(x1), f2 = f(x2)
        for _ in 0..<60 where hi - lo > 1e-12 {
            if f1 <= f2 { hi = x2; x2 = x1; f2 = f1; x1 = hi - g * (hi - lo); f1 = f(x1) }
            else { lo = x1; x1 = x2; f1 = f2; x2 = lo + g * (hi - lo); f2 = f(x2) }
        }
        return min(f(t0), f(t1), f((lo + hi) / 2))
    }

    /// The material height over p after every segment: the lowest envelope, or `start`.
    public static func exactHeight(at p: SIMD2<Double>, segments segs: [CutSegment], start: Double, bottom: Double) -> Double {
        var h = start
        for s in segs {
            guard s.minZ < h,
                  p.x >= min(s.a.x, s.b.x) - s.r, p.x <= max(s.a.x, s.b.x) + s.r,
                  p.y >= min(s.a.y, s.b.y) - s.r, p.y <= max(s.a.y, s.b.y) + s.r,
                  let z = envelope(s, at: p) else { continue }
            h = min(h, z)
        }
        return max(h, bottom)
    }

    /// Exact heights at `count` points from a to b (a section). Only segments near the line
    /// are looked at, bucketed by where they fall along it.
    public static func exactProfile(from a: SIMD2<Double>, to b: SIMD2<Double>, count: Int, segments segs: [CutSegment],
                                    start: (SIMD2<Double>) -> Double, bottom: Double) -> [Double] {
        let n = max(count, 2), dir = b - a, len = max(simd_length(dir), 1e-9), u = dir / len, v = SIMD2(-u.y, u.x)
        let buckets = max(min(Int(len), 4000), 1)
        var lists = [[Int32]](repeating: [], count: buckets)
        for (k, s) in segs.enumerated() {
            let pa = SIMD2(s.a.x, s.a.y) - a, pb = SIMD2(s.b.x, s.b.y) - a
            let va = (pa * v).sum(), vb = (pb * v).sum()
            guard min(va, vb) <= s.r, max(va, vb) >= -s.r else { continue }
            let ua = (pa * u).sum(), ub = (pb * u).sum()
            let b0 = max(Int((min(ua, ub) - s.r) / len * Double(buckets)), 0), b1 = min(Int((max(ua, ub) + s.r) / len * Double(buckets)), buckets - 1)
            guard b0 <= b1 else { continue }
            for i in b0...b1 { lists[i].append(Int32(k)) }
        }
        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1), p = a + dir * t
            let bi = min(max(Int(t * Double(buckets)), 0), buckets - 1)
            return exactHeight(at: p, segments: lists[bi].map { segs[Int($0)] }, start: start(p), bottom: bottom)
        }
    }

    // MARK: Storage

    /// Heights as whole µm, each row as differences from the cell before (small numbers that
    /// compress well), LZFSE.
    public static func encode(_ hm: Heightmap) -> Data {
        var q = [Int32](repeating: 0, count: hm.heights.count)
        for r in 0..<hm.rows {
            var last: Int32 = 0
            for c in 0..<hm.cols {
                let v = Int32((Double(hm.heights[r * hm.cols + c]) * 1000).rounded())
                q[r * hm.cols + c] = v &- last
                last = v
            }
        }
        let raw = q.withUnsafeBufferPointer { Data(buffer: $0) }
        return ((try? (raw as NSData).compressed(using: .lzfse)) as Data?) ?? raw
    }

    public static func decode(_ data: Data, cols: Int, rows: Int) -> [Float]? {
        guard let raw = (try? (data as NSData).decompressed(using: .lzfse)) as Data?, raw.count == cols * rows * 4 else { return nil }
        var out = [Float](repeating: 0, count: cols * rows)
        raw.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let q = p.bindMemory(to: Int32.self)
            for r in 0..<rows {
                var v: Int32 = 0
                for c in 0..<cols { v = v &+ q[r * cols + c]; out[r * cols + c] = Float(Double(v) / 1000) }
            }
        }
        return out
    }

    // MARK: Mesh export

    /// The grid as a closed triangle mesh (top surface, four walls, flat bottom), every `stride`
    /// cells. Work-frame millimetres, plus `offset`.
    public static func mesh(_ hm: Heightmap, stride: Int = 1, offset: SIMD3<Double> = .zero) -> (vertices: [SIMD3<Float>], triangles: [SIMD3<UInt32>]) {
        let s = max(stride, 1)
        let cs = Array(Swift.stride(from: 0, to: hm.cols, by: s)) + ((hm.cols - 1) % s == 0 ? [] : [hm.cols - 1])
        let rs = Array(Swift.stride(from: 0, to: hm.rows, by: s)) + ((hm.rows - 1) % s == 0 ? [] : [hm.rows - 1])
        let nc = cs.count, nr = rs.count
        var v: [SIMD3<Float>] = []
        v.reserveCapacity(nc * nr + 2 * (nc + nr) * 2)
        func P(_ c: Int, _ r: Int, _ z: Double) -> SIMD3<Float> {
            SIMD3(Float(hm.origin.x + Double(c) * hm.cell + offset.x), Float(hm.origin.y + Double(r) * hm.cell + offset.y), Float(z + offset.z))
        }
        for r in rs { for c in cs { v.append(P(c, r, Double(hm.heights[r * hm.cols + c]))) } }
        var t: [SIMD3<UInt32>] = []
        t.reserveCapacity((nc - 1) * (nr - 1) * 2 + 4 * (nc + nr))
        for j in 0..<(nr - 1) {
            for i in 0..<(nc - 1) {
                let a = UInt32(j * nc + i), b = a + 1, d = a + UInt32(nc), e = d + 1
                t.append(SIMD3(a, b, e)); t.append(SIMD3(a, e, d))
            }
        }
        // Walls: the boundary as one loop (counter-clockwise from above), each top vertex with a
        // bottom one below it; the bottom a fan around its centre. Closed, no slivers.
        let zb = hm.bottom
        var loop: [Int] = []
        for i in 0..<nc { loop.append(i) }
        for j in 1..<nr { loop.append(j * nc + nc - 1) }
        for i in (0..<(nc - 1)).reversed() { loop.append((nr - 1) * nc + i) }
        for j in (1..<(nr - 1)).reversed() { loop.append(j * nc) }
        let firstBottom = v.count
        for g in loop { let p = v[g]; v.append(SIMD3(p.x, p.y, Float(zb + offset.z))) }
        let n = loop.count
        for k in 0..<n {
            let t0 = UInt32(loop[k]), t1 = UInt32(loop[(k + 1) % n])
            let b0 = UInt32(firstBottom + k), b1 = UInt32(firstBottom + (k + 1) % n)
            t.append(SIMD3(t0, b0, b1)); t.append(SIMD3(t0, b1, t1))
        }
        let centre = UInt32(v.count)
        v.append(SIMD3((v[0].x + v[nc * nr - 1].x) / 2, (v[0].y + v[nc * nr - 1].y) / 2, Float(zb + offset.z)))
        for k in 0..<n { t.append(SIMD3(centre, UInt32(firstBottom + (k + 1) % n), UInt32(firstBottom + k))) }
        return (v, t)
    }

    public static func stl(_ m: (vertices: [SIMD3<Float>], triangles: [SIMD3<UInt32>]), name: String) -> Data {
        var d = Data(count: 80)
        d.replaceSubrange(0..<min(name.utf8.count, 80), with: Array(name.utf8.prefix(80)))
        var n = UInt32(m.triangles.count)
        d.append(Data(bytes: &n, count: 4))
        var buf = [Float](repeating: 0, count: 12)
        for tri in m.triangles {
            let a = m.vertices[Int(tri.x)], b = m.vertices[Int(tri.y)], c = m.vertices[Int(tri.z)]
            let nn = simd_normalize(simd_cross(b - a, c - a))
            let fin = nn.x.isFinite ? nn : SIMD3<Float>(0, 0, 1)
            buf[0] = fin.x; buf[1] = fin.y; buf[2] = fin.z
            buf[3] = a.x; buf[4] = a.y; buf[5] = a.z; buf[6] = b.x; buf[7] = b.y; buf[8] = b.z; buf[9] = c.x; buf[10] = c.y; buf[11] = c.z
            buf.withUnsafeBytes { d.append(contentsOf: $0) }
            d.append(contentsOf: [0, 0])
        }
        return d
    }

    public static func obj(_ m: (vertices: [SIMD3<Float>], triangles: [SIMD3<UInt32>]), name: String) -> Data {
        var s = "# \(name)\no snapshot\n"
        s.reserveCapacity(m.vertices.count * 40 + m.triangles.count * 30)
        for p in m.vertices { s += "v \(p.x) \(p.y) \(p.z)\n" }
        for t in m.triangles { s += "f \(t.x + 1) \(t.y + 1) \(t.z + 1)\n" }
        return Data(s.utf8)
    }
}

/// A thread-safe counter.
public final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    public init() {}
    @discardableResult public func add() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    public var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
