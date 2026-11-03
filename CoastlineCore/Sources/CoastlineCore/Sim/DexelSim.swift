import Foundation
import simd

/// The shape a tool sweeps, for the cut simulation (work frame: the tool axis is Z, the tip at 0).
public struct ToolShape: Sendable, Equatable {
    public enum Kind: String, Sendable { case flat, ball, drill, disc }
    public var kind: Kind
    public var radius: Double
    /// How far the tool reaches above its tip (the stick-out from the collet nut).
    public var length: Double
    /// A disc's thickness, from the tip up.
    public var discThickness: Double
    /// The shank above a disc.
    public var shankRadius: Double

    public init(kind: Kind, radius: Double, length: Double, discThickness: Double = 0, shankRadius: Double = 0) {
        self.kind = kind
        self.radius = radius
        self.length = length
        self.discThickness = discThickness
        self.shankRadius = shankRadius
    }

    /// From a job's tool, with the stick-out it is used at.
    public init(_ tool: ProgramJob.ToolSpec, stickout: Double) {
        let kind = Kind(rawValue: tool.shape ?? "") ?? (tool.kind.lowercased().contains("drill") ? .drill : .flat)
        self.init(kind: kind, radius: tool.diameter / 2, length: max(stickout, 1),
                  discThickness: tool.discThickness ?? tool.diameter, shankRadius: (tool.shankDiameter ?? tool.diameter) / 2)
    }

    /// The Z ranges above the tip that the tool fills at distance `r` from its axis (up to two;
    /// the second is empty when `hi2 < lo2`).
    @inline(__always)
    func ranges(at r: Double) -> (lo: Double, hi: Double, lo2: Double, hi2: Double) {
        let none = (lo: 1.0, hi: 0.0, lo2: 1.0, hi2: 0.0)
        guard r <= radius else { return none }
        switch kind {
        case .flat: return (0, length, 1, 0)
        case .ball: return (radius - (radius * radius - r * r).squareRoot(), length, 1, 0)
        case .drill: return (r / tan(59 * Double.pi / 180), length, 1, 0)
        case .disc:
            if r <= shankRadius { return (0, length, 1, 0) }
            return (0, discThickness, 1, 0)
        }
    }
}

/// Z-dexels over the work XY: per column (cell), the Z spans (sorted, merged) a tool swept. Tools
/// cut along Z, so a slotting cutter under a lip shows as a span with material above it.
public struct DexelGrid: Sendable {
    /// Centre of cell (0, 0).
    public let origin: SIMD2<Double>
    public let cell: Double
    public let cols: Int, rows: Int
    public var spans: [[SIMD2<Float>]]

    public init(min: SIMD2<Double>, max: SIMD2<Double>, cell: Double) {
        self.cell = cell
        cols = Swift.max(Int(((max.x - min.x) / cell).rounded(.up)), 1)
        rows = Swift.max(Int(((max.y - min.y) / cell).rounded(.up)), 1)
        origin = min + SIMD2(cell / 2, cell / 2)
        spans = Array(repeating: [], count: cols * rows)
    }

    public func centre(_ c: Int, _ r: Int) -> SIMD2<Double> { origin + SIMD2(Double(c), Double(r)) * cell }

    /// Adds a span to a column, merging it with those it touches.
    public mutating func add(_ index: Int, _ lo: Float, _ hi: Float) {
        guard hi > lo else { return }
        var list = spans[index]
        var a = lo, b = hi
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(list.count + 1)
        var placed = false
        for s in list {
            if s.y < a { out.append(s); continue }
            if s.x > b {
                if !placed { out.append(SIMD2(a, b)); placed = true }
                out.append(s)
                continue
            }
            a = Swift.min(a, s.x)
            b = Swift.max(b, s.y)
        }
        if !placed { out.append(SIMD2(a, b)) }
        list = out
        spans[index] = list
    }

    /// Sweeps the tool from `a` to `b` (tip positions, work frame). Steep moves are split so each
    /// piece changes Z by at most one cell; each piece fills, per column, from its lowest tip plus
    /// the tool's profile at the column's distance from the path, to its highest tip plus the top.
    public mutating func sweep(from a: SIMD3<Double>, to b: SIMD3<Double>, tool: ToolShape) {
        let pieces = Swift.max(1, Int((abs(b.z - a.z) / cell).rounded(.up)))
        for k in 0..<pieces {
            let p = a + (b - a) * (Double(k) / Double(pieces)), q = a + (b - a) * (Double(k + 1) / Double(pieces))
            sweepPiece(p, q, tool)
        }
    }

    private mutating func sweepPiece(_ p: SIMD3<Double>, _ q: SIMD3<Double>, _ tool: ToolShape) {
        let r = tool.radius
        let p2 = SIMD2(p.x, p.y), q2 = SIMD2(q.x, q.y), d = q2 - p2
        let len2 = simd_length_squared(d)
        let zlo = Swift.min(p.z, q.z), zhi = Swift.max(p.z, q.z)
        let c0 = Swift.max(0, Int(((Swift.min(p.x, q.x) - r - origin.x) / cell).rounded(.down)))
        let c1 = Swift.min(cols - 1, Int(((Swift.max(p.x, q.x) + r - origin.x) / cell).rounded(.up)))
        let r0 = Swift.max(0, Int(((Swift.min(p.y, q.y) - r - origin.y) / cell).rounded(.down)))
        let r1 = Swift.min(rows - 1, Int(((Swift.max(p.y, q.y) + r - origin.y) / cell).rounded(.up)))
        guard c0 <= c1, r0 <= r1 else { return }
        for row in r0...r1 {
            for col in c0...c1 {
                let c = centre(col, row)
                let t = len2 > 0 ? Swift.min(Swift.max(simd_dot(c - p2, d) / len2, 0), 1) : 0
                let dist = simd_distance(c, p2 + d * t)
                guard dist <= r else { continue }
                let s = tool.ranges(at: dist)
                add(row * cols + col, Float(zlo + s.lo), Float(zhi + s.hi))
                if s.hi2 > s.lo2 { add(row * cols + col, Float(zlo + s.lo2), Float(zhi + s.hi2)) }
            }
        }
    }

    /// Fills the grid with the inside of a closed mesh (vertex positions in the work frame):
    /// where a vertical line through each column centre enters and leaves it.
    public mutating func fill(vertices: [Float], indices: [UInt32]) {
        var hits = Array(repeating: [Float](), count: cols * rows)
        // A tiny shift off the grid keeps column centres off shared edges (no double hits).
        let jitter = SIMD2(cell * 0.000137, cell * 0.000291)
        func v(_ i: UInt32) -> SIMD3<Double> {
            let k = Int(i) * 3
            return SIMD3(Double(vertices[k]), Double(vertices[k + 1]), Double(vertices[k + 2]))
        }
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let a = v(indices[t]), b = v(indices[t + 1]), c = v(indices[t + 2])
            let det = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            guard abs(det) > 1e-12 else { continue }  // seen edge-on from above
            let c0 = Swift.max(0, Int(((Swift.min(a.x, b.x, c.x) - origin.x) / cell).rounded(.down)))
            let c1 = Swift.min(cols - 1, Int(((Swift.max(a.x, b.x, c.x) - origin.x) / cell).rounded(.up)))
            let r0 = Swift.max(0, Int(((Swift.min(a.y, b.y, c.y) - origin.y) / cell).rounded(.down)))
            let r1 = Swift.min(rows - 1, Int(((Swift.max(a.y, b.y, c.y) - origin.y) / cell).rounded(.up)))
            guard c0 <= c1, r0 <= r1 else { continue }
            for row in r0...r1 {
                for col in c0...c1 {
                    let p = centre(col, row) + jitter
                    let w1 = ((p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y)) / det
                    let w2 = ((b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)) / det
                    guard w1 >= 0, w2 >= 0, w1 + w2 <= 1 else { continue }
                    hits[row * cols + col].append(Float(a.z + (b.z - a.z) * w1 + (c.z - a.z) * w2))
                }
            }
        }
        for i in hits.indices where hits[i].count >= 2 {
            let z = hits[i].sorted()
            for k in stride(from: 0, to: z.count - 1, by: 2) { add(i, z[k], z[k + 1]) }
        }
    }

    /// Where this grid and another of the same layout overlap by more than `minimum` (mm).
    public func intersection(_ other: DexelGrid, minimum: Float = 0) -> DexelGrid {
        var out = self
        for i in spans.indices {
            var both: [SIMD2<Float>] = []
            for s in spans[i] {
                for o in other.spans[i] {
                    let lo = Swift.max(s.x, o.x), hi = Swift.min(s.y, o.y)
                    if hi - lo > minimum { both.append(SIMD2(lo, hi)) }
                }
            }
            out.spans[i] = both
        }
        return out
    }

    /// The spans inside a box (work frame): columns outside it are emptied, spans cut to its Z.
    public func clipped(min lo: SIMD3<Double>, max hi: SIMD3<Double>) -> DexelGrid {
        var out = self
        for row in 0..<rows {
            for col in 0..<cols {
                let c = centre(col, row), i = row * cols + col
                guard c.x >= lo.x, c.x <= hi.x, c.y >= lo.y, c.y <= hi.y else { out.spans[i] = []; continue }
                out.spans[i] = spans[i].compactMap { s in
                    let a = Swift.max(s.x, Float(lo.z)), b = Swift.min(s.y, Float(hi.z))
                    return b > a ? SIMD2(a, b) : nil
                }
            }
        }
        return out
    }

    /// These spans less another grid's (same layout); pieces thinner than `minimum` are dropped.
    public func subtracting(_ other: DexelGrid, minimum: Float = 0) -> DexelGrid {
        var out = self
        for i in spans.indices {
            var rest: [SIMD2<Float>] = []
            for s in spans[i] {
                var a = s.x
                for o in other.spans[i] where o.y > a && o.x < s.y {
                    if o.x - a > minimum { rest.append(SIMD2(a, o.x)) }
                    a = Swift.max(a, o.y)
                }
                if s.y - a > minimum { rest.append(SIMD2(a, s.y)) }
            }
            out.spans[i] = rest
        }
        return out
    }

    /// Volume in mm³.
    public var volume: Double {
        spans.reduce(0) { $0 + $1.reduce(0) { $0 + Double($1.y - $1.x) } } * cell * cell
    }

    /// A triangle mesh of the spans: tops, bottoms, and the walls where a neighbour's spans
    /// don't cover them (flat-shaded quads).
    public func mesh() -> (positions: [Float], normals: [Float], indices: [UInt32]) {
        var pos: [Float] = [], nrm: [Float] = [], idx: [UInt32] = []
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            let base = UInt32(pos.count / 3)
            for p in [a, b, c, d] { pos += [p.x, p.y, p.z]; nrm += [n.x, n.y, n.z] }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        /// The parts of [lo, hi] not covered by `cover`.
        func uncovered(_ lo: Float, _ hi: Float, _ cover: [SIMD2<Float>]) -> [SIMD2<Float>] {
            var out: [SIMD2<Float>] = [], a = lo
            for s in cover where s.y > a && s.x < hi {
                if s.x > a { out.append(SIMD2(a, s.x)) }
                a = Swift.max(a, s.y)
                if a >= hi { break }
            }
            if a < hi { out.append(SIMD2(a, hi)) }
            return out
        }
        let h = Float(cell / 2)
        for row in 0..<rows {
            for col in 0..<cols {
                let list = spans[row * cols + col]
                guard !list.isEmpty else { continue }
                let c = centre(col, row)
                let x0 = Float(c.x) - h, x1 = Float(c.x) + h, y0 = Float(c.y) - h, y1 = Float(c.y) + h
                let neighbours: [(Int, Int, SIMD3<Float>)] = [(1, 0, SIMD3(1, 0, 0)), (-1, 0, SIMD3(-1, 0, 0)), (0, 1, SIMD3(0, 1, 0)), (0, -1, SIMD3(0, -1, 0))]
                for s in list {
                    quad(SIMD3(x0, y0, s.y), SIMD3(x1, y0, s.y), SIMD3(x1, y1, s.y), SIMD3(x0, y1, s.y), SIMD3(0, 0, 1))
                    quad(SIMD3(x0, y0, s.x), SIMD3(x0, y1, s.x), SIMD3(x1, y1, s.x), SIMD3(x1, y0, s.x), SIMD3(0, 0, -1))
                    for (dc, dr, n) in neighbours {
                        let nc = col + dc, nr = row + dr
                        let cover = (0..<cols).contains(nc) && (0..<rows).contains(nr) ? spans[nr * cols + nc] : []
                        for w in uncovered(s.x, s.y, cover) {
                            switch (dc, dr) {
                            case (1, 0): quad(SIMD3(x1, y0, w.x), SIMD3(x1, y1, w.x), SIMD3(x1, y1, w.y), SIMD3(x1, y0, w.y), n)
                            case (-1, 0): quad(SIMD3(x0, y1, w.x), SIMD3(x0, y0, w.x), SIMD3(x0, y0, w.y), SIMD3(x0, y1, w.y), n)
                            case (0, 1): quad(SIMD3(x1, y1, w.x), SIMD3(x0, y1, w.x), SIMD3(x0, y1, w.y), SIMD3(x1, y1, w.y), n)
                            default: quad(SIMD3(x0, y0, w.x), SIMD3(x1, y0, w.x), SIMD3(x1, y0, w.y), SIMD3(x0, y0, w.y), n)
                            }
                        }
                    }
                }
            }
        }
        return (pos, nrm, idx)
    }
}

/// What a program cuts, from its toolpath and the finished part: the volume its tool sweeps
/// while cutting, the part of that inside the finished part (a gouge: the model says it stays),
/// and rapid moves that pass through the part.
public enum CutCheck {
    public struct Result: Sendable {
        public var removed: DexelGrid
        public var gouge: DexelGrid?
        public var rapidHits: DexelGrid?
        public var gougeVolume: Double { gouge?.volume ?? 0 }
        public var rapidHitVolume: Double { rapidHits?.volume ?? 0 }
    }

    /// `part` is the finished part's mesh in the work frame (nil: no gouge check). Moves with an
    /// unknown start and probe moves are left out. `cell` is the column size (mm).
    public static func run(_ program: GCodeReader.Program, tool: ToolShape, part: (vertices: [Float], indices: [UInt32])?,
                           cell: Double = 0.2, partMinimum: Float = 0.05) -> Result? {
        // The box of every move that counts (rapids too: they are checked against the part).
        var lo = SIMD3<Double>(repeating: .greatestFiniteMagnitude), hi = -lo
        for (k, m) in program.moves.enumerated() where !program.probeMoves.contains(k) {
            lo = simd_min(lo, m.position)
            hi = simd_max(hi, m.position)
        }
        guard lo.x <= hi.x else { return nil }
        let pad = tool.radius + 2
        let min = SIMD2(lo.x - pad, lo.y - pad), max = SIMD2(hi.x + pad, hi.y + pad)
        var cut = DexelGrid(min: min, max: max, cell: cell), rapid = cut
        for (k, move) in program.moves.enumerated() {
            guard let start = program.start(of: k), !program.unknownStart.contains(k), !program.probeMoves.contains(k) else { continue }
            var a = start
            for p in ToolpathGeometry.points(of: move, from: start) {
                if move.role == .rapid { rapid.sweep(from: a, to: p, tool: tool) } else { cut.sweep(from: a, to: p, tool: tool) }
                a = p
            }
        }
        guard let part else { return Result(removed: cut, gouge: nil, rapidHits: nil) }
        var solid = DexelGrid(min: min, max: max, cell: cell)
        solid.fill(vertices: part.vertices, indices: part.indices)
        // With no model of the blank, what the tool sweeps inside the finished part's box is
        // what it cuts (the shank above the part and the air around it are left out).
        var bmin = SIMD3<Double>(repeating: .greatestFiniteMagnitude), bmax = -bmin
        for k in stride(from: 0, to: part.vertices.count - 2, by: 3) {
            let v = SIMD3(Double(part.vertices[k]), Double(part.vertices[k + 1]), Double(part.vertices[k + 2]))
            bmin = simd_min(bmin, v)
            bmax = simd_max(bmax, v)
        }
        return Result(removed: cut.clipped(min: bmin, max: bmax), gouge: cut.intersection(solid, minimum: partMinimum),
                      rapidHits: rapid.intersection(solid, minimum: partMinimum).subtracting(cut, minimum: partMinimum))
    }
}
