import Foundation
import simd

/// The stock as the job leaves it, cut by cut: tri-dexel columns along side A's X, Y and Z (the
/// stock box, side A's work frame). Each column holds what the cuts swept along it and what the
/// part fills; the rest of the box is material still to cut ("excess"). Three directions, so a
/// wall facing any of them is resolved along its normal exactly (a 0.2 mm finishing allowance
/// shows as 0.2 mm), not to the grid's cell.
///
/// Every setup's cuts are swept in, in the order they run at the machine, each through its own
/// frame (SetupSide.toA); finishing, floors, holes and threads are first checked against it:
/// where the cutter meets no excess the pass is air, and long stretches of air lift over.
public struct StockModel: Sendable {
    public let stock: SIMD3<Double>
    public let cell: Double
    /// Per axis k (0 X, 1 Y, 2 Z): the grid over the other two axes (StockModel.plane(k)).
    var removed: [DexelGrid]
    var part: [DexelGrid]
    let flipAxis: Int?

    /// - Parameters: partVertices: the part's mesh in side A's work frame (x, y, z per vertex);
    ///   flipAxis: side B's turn (Setup.flipAxis).
    public init(stock s: SIMD3<Double>, cell: Double = 0.5, partVertices: [Float], indices: [UInt32], flipAxis: Int?) {
        stock = s
        self.cell = cell
        self.flipAxis = flipAxis
        let lo = SIMD3(-s.x / 2, -s.y / 2, -s.z), hi = SIMD3(s.x / 2, s.y / 2, 0)
        var removed: [DexelGrid] = [], part: [DexelGrid] = []
        for k in 0..<3 {
            let (a, b) = Self.plane(k)
            let g = DexelGrid(min: SIMD2(lo[a], lo[b]), max: SIMD2(hi[a], hi[b]), cell: cell)
            removed.append(g)
            // The part along this axis: its mesh with the axes turned so k is the column axis.
            var v = [Float](repeating: 0, count: partVertices.count)
            var i = 0
            while i + 2 < partVertices.count {
                let p = SIMD3(partVertices[i], partVertices[i + 1], partVertices[i + 2])
                v[i] = p[a]; v[i + 1] = p[b]; v[i + 2] = p[k]
                i += 3
            }
            var f = g
            f.fill(vertices: v, indices: indices)
            part.append(f)
        }
        self.removed = removed
        self.part = part
    }

    /// The two in-plane axes of the grid whose columns run along axis k.
    @inline(__always) static func plane(_ k: Int) -> (Int, Int) { k == 0 ? (1, 2) : k == 1 ? (0, 2) : (0, 1) }

    @inline(__always) func span(_ k: Int) -> (lo: Double, hi: Double) {
        k == 0 ? (-stock.x / 2, stock.x / 2) : k == 1 ? (-stock.y / 2, stock.y / 2) : (-stock.z, 0)
    }

    /// The A axis a side's tool lies along, and the way its shank points (+1 toward +).
    public func toolAxis(side: Int) -> (axis: Int, sign: Double) {
        let d = SetupSide.rotation(side, flipAxis: flipAxis).transpose * SIMD3(0, 0, 1)
        let k = (0..<3).max { abs(d[$0]) < abs(d[$1]) }!
        return (k, d[k] > 0 ? 1 : -1)
    }

    /// The cutting part of a tool as this model sweeps it: its radius, how far above the tip the
    /// full radius starts (a ball's radius, a drill's cone), and the flutes' length.
    struct Cutter {
        enum Tip { case flat, ball, corner(Double), cone(halfAngle: Double) }
        var tip: Tip
        var radius: Double
        var start: Double
        var length: Double
        /// How far above the tip the across-the-axis sweep goes (the flutes, or a slice of them).
        var crossLength: Double
        init(_ tool: Tool) {
            radius = tool.diameter / 2
            length = max(tool.fluteLength, 0.1)
            crossLength = length
            switch tool.kind {
            case .ballEndMill:
                tip = .ball; start = radius
            case .bullNoseEndMill where tool.cornerRadius > 1e-6:
                let cr = min(tool.cornerRadius, radius)
                tip = .corner(cr); start = cr
            case .drill, .spotDrill, .chamferMill, .engraver:
                // The tool's own point angle (118° when it has none).
                let half = min(max((tool.angle ?? 118) / 2, 5), 89) * Double.pi / 180
                tip = .cone(halfAngle: half); start = radius / tan(half)
            default:
                tip = .flat; start = 0
            }
        }

        /// How far above the tip the cutter reaches out to distance d from its axis (nil past
        /// its radius): its real profile.
        @inline(__always) func offset(at d: Double) -> Double? {
            guard d <= radius else { return nil }
            switch tip {
            case .flat: return 0
            case .ball: return radius - (radius * radius - d * d).squareRoot()
            case .corner(let cr):
                let flat = radius - cr
                guard d > flat else { return 0 }
                let e = d - flat
                return cr - max(cr * cr - e * e, 0).squareRoot()
            case .cone(let half): return d / tan(half)
            }
        }
    }

    // MARK: Sweeping

    /// Sweeps a setup's cutting moves (its work frame) into the stock. Across the tool axis only
    /// the flutes' lowest `slice` mm (the operation's stepdown, at least two cells) are swept: a
    /// level's tool cuts the slab its stepdown deep, what is above it the levels before took;
    /// sweeping less never counts stock as cut, and is ten times quicker. The three directions'
    /// grids are swept at once, each on its own core.
    public mutating func sweep(_ moves: [Move], side: Int, tool: Tool, slice: Double? = nil) {
        var c = Cutter(tool)
        if let slice { c.crossLength = min(c.length, max(slice + cell, 2 * cell) + c.start) }
        let (j, sign) = toolAxis(side: side)
        // The pieces, in side A's frame: points closer than 0.4 mm to the last one merge (a
        // roughing path is thousands of tiny arcs; the chord is about 10 microns off), and each
        // piece changes the tool-axis coordinate by at most a cell (ramps, plunges).
        var pieces: [(SIMD3<Double>, SIMD3<Double>)] = []
        var previous = moves.first?.position ?? .zero
        var from = previous
        for m in moves {
            if m.role != .rapid {
                let angle = min(0.08, sqrt(0.8 * cell / max(hypot(m.i, m.j), cell)))
                let points = ToolpathGeometry.points(of: m, from: previous, segmentAngle: angle)
                for (n, p) in points.enumerated() where simd_distance(from, p) >= 0.4 || n == points.count - 1 {
                    if simd_distance(from, p) > 1e-9 {
                        let a = toA(from, side), b = toA(p, side)
                        let count = max(1, Int((abs(b[j] - a[j]) / cell).rounded(.up)))
                        for k in 0..<count { pieces.append((a + (b - a) * (Double(k) / Double(count)), a + (b - a) * (Double(k + 1) / Double(count)))) }
                    }
                    from = p
                }
            } else {
                from = m.position
            }
            previous = m.position
        }
        guard !pieces.isEmpty else { return }
        let cut = c
        removed.withUnsafeMutableBufferPointer { grids in
            DispatchQueue.concurrentPerform(iterations: 3) { k in
                for (p, q) in pieces {
                    if k == j { Self.sweepAlong(&grids[k], p, q, axis: j, sign: sign, cutter: cut) }
                    else { Self.sweepAcross(&grids[k], p, q, grid: k, axis: j, sign: sign, cutter: cut) }
                }
            }
        }
    }

    @inline(__always) func toA(_ p: SIMD3<Double>, _ side: Int) -> SIMD3<Double> {
        SetupSide.toA(p, side: side, stock: stock, flipAxis: flipAxis)
    }

    /// The grid along the tool axis: the tool's own profile (either way up).
    static func sweepAlong(_ g: inout DexelGrid, _ p: SIMD3<Double>, _ q: SIMD3<Double>, axis j: Int, sign: Double, cutter c: Cutter) {
        let (a, b) = plane(j)
        let cell = g.cell, r = c.radius
        let p2 = SIMD2(p[a], p[b]), q2 = SIMD2(q[a], q[b]), d = q2 - p2
        let len2 = simd_length_squared(d)
        let wlo = min(p[j], q[j]), whi = max(p[j], q[j])
        let c0 = max(0, Int(((min(p2.x, q2.x) - r - g.origin.x) / cell).rounded(.down)))
        let c1 = min(g.cols - 1, Int(((max(p2.x, q2.x) + r - g.origin.x) / cell).rounded(.up)))
        let r0 = max(0, Int(((min(p2.y, q2.y) - r - g.origin.y) / cell).rounded(.down)))
        let r1 = min(g.rows - 1, Int(((max(p2.y, q2.y) + r - g.origin.y) / cell).rounded(.up)))
        guard c0 <= c1, r0 <= r1 else { return }
        for row in r0...r1 {
            for col in c0...c1 {
                let x = g.centre(col, row)
                let t = len2 > 0 ? min(max(simd_dot(x - p2, d) / len2, 0), 1) : 0
                let dist = simd_distance(x, p2 + d * t)
                guard dist <= r else { continue }
                guard let lo = c.offset(at: dist), lo < c.length else { continue }
                if sign > 0 { add(&g, row * g.cols + col, Float(wlo + lo), Float(whi + c.length)) }
                else { add(&g, row * g.cols + col, Float(wlo - c.length), Float(whi - lo)) }
            }
        }
    }

    /// A grid across the tool axis: each column a line through the swept cylinder (its full
    /// radius only, from `start` above the tip: never more than the tool really cut). For a
    /// piece of constant tool-axis height it is the line through the capsule round the path.
    static func sweepAcross(_ g: inout DexelGrid, _ p: SIMD3<Double>, _ q: SIMD3<Double>, grid k: Int, axis j: Int, sign: Double, cutter c: Cutter) {
        let (a, b) = plane(k)
        let m = a == j ? b : a  // the grid's other in-plane axis
        let cell = g.cell, r = c.radius
        // Along the tool axis: what every point of the piece covers.
        let jlo: Double, jhi: Double
        if sign > 0 { jlo = max(p[j], q[j]) + c.start; jhi = min(p[j], q[j]) + c.crossLength }
        else { jlo = max(p[j], q[j]) - c.crossLength; jhi = min(p[j], q[j]) - c.start }
        guard jhi > jlo else { return }
        let jIndex = a == j ? 0 : 1  // which of the grid's (col, row) runs along the tool axis
        let jOrigin = jIndex == 0 ? g.origin.x : g.origin.y, mOrigin = jIndex == 0 ? g.origin.y : g.origin.x
        let jCount = jIndex == 0 ? g.cols : g.rows, mCount = jIndex == 0 ? g.rows : g.cols
        let j0 = max(0, Int(((jlo - jOrigin) / cell).rounded(.up))), j1 = min(jCount - 1, Int(((jhi - jOrigin) / cell).rounded(.down)))
        let mlo = min(p[m], q[m]) - r, mhi = max(p[m], q[m]) + r
        let m0 = max(0, Int(((mlo - mOrigin) / cell).rounded(.down))), m1 = min(mCount - 1, Int(((mhi - mOrigin) / cell).rounded(.up)))
        guard j0 <= j1, m0 <= m1 else { return }
        let P0 = SIMD2(p[k], p[m]), P1 = SIMD2(q[k], q[m])
        for mi in m0...m1 {
            let cm = mOrigin + Double(mi) * cell
            guard let (lo, hi) = capsule(P0, P1, r, at: cm) else { continue }
            for ji in j0...j1 {
                let index = jIndex == 0 ? mi * g.cols + ji : ji * g.cols + mi
                add(&g, index, Float(lo), Float(hi))
            }
        }
    }

    /// A removed span into a column, nothing done when one already covers it.
    @inline(__always) static func add(_ g: inout DexelGrid, _ i: Int, _ lo: Float, _ hi: Float) {
        guard hi > lo else { return }
        for s in g.spans[i] where s.x <= lo && s.y >= hi { return }
        g.add(i, lo, hi)
    }

    /// Where the line {second coordinate = c} crosses the capsule of radius r round the segment
    /// P0–P1 (first coordinate), or nil.
    static func capsule(_ P0: SIMD2<Double>, _ P1: SIMD2<Double>, _ r: Double, at c: Double) -> (Double, Double)? {
        var lo = Double.infinity, hi = -Double.infinity
        for P in [P0, P1] {
            let dy = c - P.y
            if abs(dy) <= r { let w = (r * r - dy * dy).squareRoot(); lo = min(lo, P.x - w); hi = max(hi, P.x + w) }
        }
        let d = P1 - P0, len = simd_length(d)
        if len > 1e-9 {
            let u = d / len, n = SIMD2(-u.y, u.x)
            // Points (x, c): perpendicular distance and position along the segment, linear in x.
            var a = -Double.infinity, b = Double.infinity
            func within(_ slope: Double, _ offset: Double, _ low: Double, _ high: Double) -> Bool {
                // low <= slope * x + offset <= high
                if abs(slope) < 1e-12 { return offset >= low && offset <= high }
                var x0 = (low - offset) / slope, x1 = (high - offset) / slope
                if x0 > x1 { swap(&x0, &x1) }
                a = max(a, x0); b = min(b, x1)
                return true
            }
            let ok = within(n.x, (c - P0.y) * n.y - P0.x * n.x, -r, r) && within(u.x, (c - P0.y) * u.y - P0.x * u.x, 0, len)
            if ok, a <= b { lo = min(lo, a); hi = max(hi, b) }
        }
        return lo <= hi ? (lo, hi) : nil
    }

    // MARK: What is left

    /// Whether column `i` of grid k holds excess (stock not cut, not the part) longer than `tol`
    /// between w0 and w1 (along the column).
    func excess(_ k: Int, _ i: Int, _ w0: Double, _ w1: Double, tol: Double) -> Bool {
        let s = span(k)
        let lo = max(w0, s.lo), hi = min(w1, s.hi)
        guard hi - lo > tol else { return false }
        let a = part[k].spans[i], b = removed[k].spans[i]
        var ia = 0, ib = 0
        var cursor = lo  // everything below is covered (by the part or a cut)
        while cursor < hi - tol {
            // The next span by its start, of either list.
            let next: SIMD2<Float>
            if ia < a.count, ib < b.count { if a[ia].x <= b[ib].x { next = a[ia]; ia += 1 } else { next = b[ib]; ib += 1 } }
            else if ia < a.count { next = a[ia]; ia += 1 }
            else if ib < b.count { next = b[ib]; ib += 1 }
            else { return true }  // nothing covers from cursor to hi
            let x = Double(next.x), y = Double(next.y)
            if y <= cursor { continue }
            if x > cursor + tol { return x - cursor > tol }  // a gap before this span
            cursor = max(cursor, y)
        }
        return false
    }

    /// Whether the cutter with its tip at p (side A frame) meets excess: the cylinder of its full
    /// radius over its flutes (a ball's or drill's tip counted as full: never calls stock air).
    func meetsExcess(_ p: SIMD3<Double>, axis j: Int, sign: Double, cutter c: Cutter, tol: Double = 0.03) -> Bool {
        let r = c.radius
        let w0 = sign > 0 ? p[j] : p[j] - c.length, w1 = sign > 0 ? p[j] + c.length : p[j]
        // Along the tool axis: columns within the radius.
        do {
            let (a, b) = Self.plane(j)
            let g = removed[j]
            let c0 = max(0, Int(((p[a] - r - g.origin.x) / cell).rounded(.down))), c1 = min(g.cols - 1, Int(((p[a] + r - g.origin.x) / cell).rounded(.up)))
            let r0 = max(0, Int(((p[b] - r - g.origin.y) / cell).rounded(.down))), r1 = min(g.rows - 1, Int(((p[b] + r - g.origin.y) / cell).rounded(.up)))
            if c0 <= c1, r0 <= r1 {
                for row in r0...r1 {
                    for col in c0...c1 {
                        let x = g.centre(col, row)
                        guard simd_distance(x, SIMD2(p[a], p[b])) <= r + cell * 0.5 else { continue }
                        if excess(j, row * g.cols + col, w0, w1, tol: tol) { return true }
                    }
                }
            }
        }
        // Across it: lines through the cylinder.
        for k in 0..<3 where k != j {
            let (a, b) = Self.plane(k)
            let m = a == j ? b : a
            let g = removed[k]
            let jIndex = a == j ? 0 : 1
            let jOrigin = jIndex == 0 ? g.origin.x : g.origin.y, mOrigin = jIndex == 0 ? g.origin.y : g.origin.x
            let jCount = jIndex == 0 ? g.cols : g.rows, mCount = jIndex == 0 ? g.rows : g.cols
            let j0 = max(0, Int(((w0 - jOrigin) / cell).rounded(.down))), j1 = min(jCount - 1, Int(((w1 - jOrigin) / cell).rounded(.up)))
            let m0 = max(0, Int(((p[m] - r - mOrigin) / cell).rounded(.down))), m1 = min(mCount - 1, Int(((p[m] + r - mOrigin) / cell).rounded(.up)))
            guard j0 <= j1, m0 <= m1 else { continue }
            for mi in m0...m1 {
                let dm = mOrigin + Double(mi) * cell - p[m]
                guard abs(dm) <= r else { continue }
                let w = (r * r - dm * dm).squareRoot()
                for ji in j0...j1 {
                    let index = jIndex == 0 ? mi * g.cols + ji : ji * g.cols + mi
                    if excess(k, index, p[k] - w, p[k] + w, tol: tol) { return true }
                }
            }
        }
        return false
    }

    /// The moves (a setup's work frame) with every stretch of air longer than `minimum` mm
    /// lifted over: the tool rises to `safeZ`, crosses, and comes down where there is stock to
    /// cut again. The skipped cutting length with it. Rapids stay as they are.
    /// `slice`: check only the flutes' lowest slice mm (roughing: the slab a level cuts, what is
    /// above it the levels before took); nil: all the flutes.
    public func liftAir(_ moves: [Move], side: Int, tool: Tool, minimum: Double = 4, step: Double = 0.5, safeZ: Double = 3,
                        slice: Double? = nil, plungeFeed: Double) -> (moves: [Move], skipped: Double) {
        guard let first = moves.first else { return (moves, 0) }
        var c = Cutter(tool)
        if let slice { c.length = min(c.length, max(slice + cell, 2 * cell) + c.start) }
        let (j, sign) = toolAxis(side: side)
        // Each cutting move sampled; air where the cutter meets nothing at a sample (all cores).
        struct Sample { var p: SIMD3<Double>; var move: Int; var air: Bool }
        var samples: [Sample] = []
        var previous = first.position
        for (k, m) in moves.enumerated() {
            defer { previous = m.position }
            guard k > 0, m.role != .rapid else { continue }
            for q in FixtureClearance.samples(from: previous, m, step: step) { samples.append(Sample(p: q, move: k, air: false)) }
        }
        let cutter = c, chunk = 256
        samples.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: (buf.count + chunk - 1) / chunk) { n in
                for i in (n * chunk)..<min(buf.count, (n + 1) * chunk) {
                    buf[i].air = !meetsExcess(toA(buf[i].p, side), axis: j, sign: sign, cutter: cutter)
                }
            }
        }
        // Only stretches long enough to be worth the lift count.
        var lifted = [Bool](repeating: false, count: samples.count)
        var i = 0
        while i < samples.count {
            guard samples[i].air else { i += 1; continue }
            var e = i
            var length = 0.0
            while e + 1 < samples.count, samples[e + 1].air { length += simd_distance(samples[e].p, samples[e + 1].p); e += 1 }
            if length >= minimum { for t in i...e { lifted[t] = true } }
            i = e + 1
        }
        guard lifted.contains(true) else { return (moves, 0) }
        var out: [Move] = []
        out.reserveCapacity(moves.count)
        var skipped = 0.0, up = false, s = 0
        out.append(first)
        var last = first.position
        for (k, m) in moves.enumerated() where k > 0 {
            if m.role == .rapid {
                if up { out.append(Move(.rapid, x: m.x, y: m.y, z: max(m.z, safeZ))); up = false }
                out.append(m)
                last = m.position
                continue
            }
            // This move's samples.
            var mine: [(p: SIMD3<Double>, lift: Bool)] = []
            while s < samples.count, samples[s].move == k { mine.append((samples[s].p, lifted[s])); s += 1 }
            if !mine.contains(where: \.lift), !up { out.append(m); last = m.position; continue }
            for q in mine {
                if q.lift {
                    if !up { out.append(Move(.rapid, x: last.x, y: last.y, z: safeZ)); up = true }
                    skipped += simd_distance(last, q.p)
                } else if up {
                    out.append(Move(.rapid, x: q.p.x, y: q.p.y, z: safeZ))
                    out.append(Move(.plunge, x: q.p.x, y: q.p.y, z: q.p.z, feed: plungeFeed))
                    up = false
                } else {
                    out.append(Move(m.role, x: q.p.x, y: q.p.y, z: q.p.z, feed: m.feed))
                }
                last = q.p
            }
        }
        if up { out.append(Move(.rapid, x: last.x, y: last.y, z: safeZ)) }
        return (out, skipped)
    }
}

// MARK: Showing it

extension StockModel {
    /// The stock still there (the part included: it is stock until the job is done) along
    /// column k's direction: per column, the box's span less what the cuts swept.
    public func material(axis k: Int) -> DexelGrid {
        var g = removed[k]
        let s = span(k)
        for i in g.spans.indices {
            var out: [SIMD2<Float>] = []
            var cursor = Float(s.lo)
            for v in removed[k].spans[i] where v.y > cursor {
                if v.x > cursor { out.append(SIMD2(cursor, min(v.x, Float(s.hi)))) }
                cursor = max(cursor, v.y)
                if cursor >= Float(s.hi) { break }
            }
            if cursor < Float(s.hi) { out.append(SIMD2(cursor, Float(s.hi))) }
            g.spans[i] = out.filter { $0.y - $0.x > 0.01 }
        }
        return g
    }

    /// The stock still there along a line through side A's frame: from p along axis k (the
    /// column through p's in-plane position), as spans of that axis. Empty past the box.
    public func materialAlong(axis k: Int, through p: SIMD3<Double>) -> [SIMD2<Float>] {
        let (a, b) = Self.plane(k)
        let g = removed[k]
        let col = Int(((p[a] - g.origin.x) / cell).rounded()), row = Int(((p[b] - g.origin.y) / cell).rounded())
        guard col >= 0, row >= 0, col < g.cols, row < g.rows else { return [] }
        let s = span(k)
        var out: [SIMD2<Float>] = []
        var cursor = Float(s.lo)
        for v in g.spans[row * g.cols + col] where v.y > cursor {
            if v.x > cursor { out.append(SIMD2(cursor, min(v.x, Float(s.hi)))) }
            cursor = max(cursor, v.y)
        }
        if cursor < Float(s.hi) { out.append(SIMD2(cursor, Float(s.hi))) }
        return out.filter { $0.y - $0.x > 0.01 }
    }
}

/// A closed mesh of a dexel grid's spans (side A's frame): each span's two ends as caps (runs of
/// equal columns along a row merged) and walls where a neighbour column has no material.
public enum DexelMesher {
    public static func mesh(_ g: DexelGrid, axis k: Int) -> (positions: [Float], normals: [Float], indices: [UInt32]) {
        var p: [Float] = [], n: [Float] = [], t: [UInt32] = []
        let (a, b) = StockModel.plane(k)
        let h = Float(g.cell / 2)
        func point(_ u: Float, _ v: Float, _ w: Float) -> SIMD3<Float> {
            var q = SIMD3<Float>(0, 0, 0); q[a] = u; q[b] = v; q[k] = w; return q
        }
        func axis(_ i: Int, _ s: Float) -> SIMD3<Float> { var q = SIMD3<Float>(0, 0, 0); q[i] = s; return q }
        // A quad with corners c0…c3 (counter-clockwise seen from outside), facing `normal`.
        func quad(_ c0: SIMD3<Float>, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>, _ c3: SIMD3<Float>, _ normal: SIMD3<Float>) {
            // Keep the winding consistent with the normal.
            let flip = simd_dot(simd_cross(c1 - c0, c2 - c0), normal) < 0
            let base = UInt32(p.count / 3)
            for c in (flip ? [c0, c3, c2, c1] : [c0, c1, c2, c3]) { p += [c.x, c.y, c.z]; n += [normal.x, normal.y, normal.z] }
            t += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        func spans(_ c: Int, _ r: Int) -> [SIMD2<Float>] {
            guard c >= 0, r >= 0, c < g.cols, r < g.rows else { return [] }
            return g.spans[r * g.cols + c]
        }
        // What of `mine` the other column doesn't have (the wall between them).
        func minus(_ mine: [SIMD2<Float>], _ other: [SIMD2<Float>]) -> [SIMD2<Float>] {
            var out: [SIMD2<Float>] = []
            for s in mine {
                var cursor = s.x
                for o in other where o.y > cursor && o.x < s.y {
                    if o.x > cursor { out.append(SIMD2(cursor, o.x)) }
                    cursor = max(cursor, o.y)
                }
                if cursor < s.y { out.append(SIMD2(cursor, s.y)) }
            }
            return out.filter { $0.y - $0.x > 0.005 }
        }
        for r in 0..<g.rows {
            var c = 0
            while c < g.cols {
                let mine = spans(c, r)
                // Caps: this column and the ones after it with the same spans, as one strip.
                var e = c
                while e + 1 < g.cols, spans(e + 1, r) == mine { e += 1 }
                if !mine.isEmpty {
                    let u0 = Float(g.centre(c, r).x) - h, u1 = Float(g.centre(e, r).x) + h
                    let v0 = Float(g.centre(c, r).y) - h, v1 = v0 + 2 * h
                    for s in mine {
                        quad(point(u0, v0, s.y), point(u1, v0, s.y), point(u1, v1, s.y), point(u0, v1, s.y), axis(k, 1))
                        quad(point(u0, v0, s.x), point(u1, v0, s.x), point(u1, v1, s.x), point(u0, v1, s.x), axis(k, -1))
                    }
                }
                for cc in c...e where !mine.isEmpty {
                    let x = g.centre(cc, r)
                    let u0 = Float(x.x) - h, u1 = Float(x.x) + h, v0 = Float(x.y) - h, v1 = Float(x.y) + h
                    // Along the row only at the strip's ends (inside it the columns match).
                    if cc == c { for s in minus(mine, spans(cc - 1, r)) { quad(point(u0, v0, s.x), point(u0, v1, s.x), point(u0, v1, s.y), point(u0, v0, s.y), axis(a, -1)) } }
                    if cc == e { for s in minus(mine, spans(cc + 1, r)) { quad(point(u1, v0, s.x), point(u1, v1, s.x), point(u1, v1, s.y), point(u1, v0, s.y), axis(a, 1)) } }
                    for s in minus(mine, spans(cc, r - 1)) { quad(point(u0, v0, s.x), point(u1, v0, s.x), point(u1, v0, s.y), point(u0, v0, s.y), axis(b, -1)) }
                    for s in minus(mine, spans(cc, r + 1)) { quad(point(u0, v1, s.x), point(u1, v1, s.x), point(u1, v1, s.y), point(u0, v1, s.y), axis(b, 1)) }
                }
                c = e + 1
            }
        }
        return (p, n, t)
    }
}
