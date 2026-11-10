import Foundation
import simd

/// What a setup from a side (upper, lower side or an end: SetupSide 2…5) cuts: only the
/// features the part check sends to that side, inside a window around them. The rest of the
/// stock stays as it is, so the grip faces of the other setups are not cut. The cuts take
/// the plan's own tools: roughing (kept to the window), floors, drilling, boring and threads.
public enum SideCuts {
    /// The window in the side's work frame: XY around the features, and how deep they go.
    public struct Window: Equatable, Sendable {
        public var min: SIMD2<Double>
        public var max: SIMD2<Double>
        public var zMin: Double
        public init(min: SIMD2<Double>, max: SIMD2<Double>, zMin: Double) { (self.min, self.max, self.zMin) = (min, max, zMin) }
    }

    /// The kinds of operation a side setup runs.
    public static let kinds: Set<OperationKind> = [.adaptive, .floor, .drill, .bore, .thread]

    /// The window around these feature bounds (side-A work frame), in the side's frame, with
    /// `margin` around them in X and Y (room for the tool to reach their walls).
    public static func window(featureBounds: [(min: SIMD3<Double>, max: SIMD3<Double>)], side: Int, stock a: SIMD3<Double>,
                              margin: Double) -> Window? {
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        for b in featureBounds {
            for i in 0..<8 {
                let q = SIMD3(i & 1 == 0 ? b.min.x : b.max.x, i & 2 == 0 ? b.min.y : b.max.y, i & 4 == 0 ? b.min.z : b.max.z)
                let p = SetupSide.fromA(q, side: side, stock: a)
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
        }
        guard lo.x.isFinite, hi.x >= lo.x else { return nil }
        let s = SetupSide.stockSize(a, side: side)
        let wlo = simd_max(SIMD2(lo.x, lo.y) - margin, SIMD2(-s.x / 2, -s.y / 2) - margin)
        let whi = simd_min(SIMD2(hi.x, hi.y) + margin, SIMD2(s.x / 2, s.y / 2) + margin)
        return Window(min: wlo, max: whi, zMin: Swift.max(lo.z - 0.2, -s.z))
    }

    /// Keep-out rectangles covering everything around the window (out to `reach` past the
    /// stock): roughing stays inside it.
    public static func keepOut(around w: Window, stock s: SIMD3<Double>, reach: Double = 50) -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        let x0 = -s.x / 2 - reach, x1 = s.x / 2 + reach, y0 = -s.y / 2 - reach, y1 = s.y / 2 + reach
        var out: [(min: SIMD2<Double>, max: SIMD2<Double>)] = []
        if w.min.x > x0 { out.append((SIMD2(x0, y0), SIMD2(w.min.x, y1))) }
        if w.max.x < x1 { out.append((SIMD2(w.max.x, y0), SIMD2(x1, y1))) }
        if w.min.y > y0 { out.append((SIMD2(w.min.x, y0), SIMD2(w.max.x, w.min.y))) }
        if w.max.y < y1 { out.append((SIMD2(w.min.x, w.max.y), SIMD2(w.max.x, y1))) }
        return out
    }

    /// The side setup's operations from the plan's: the kinds above, each to the window's depth,
    /// roughing only this side's cavities inside it and leaving nothing on their walls (no
    /// finishing pass follows).
    public static func operations(_ base: [EngineClient.PlannedOperation], window w: Window,
                                  stock s: SIMD3<Double>) -> [EngineClient.PlannedOperation] {
        let ko = keepOut(around: w, stock: s)
        return base.compactMap { p in
            guard kinds.contains(p.operation.kind) else { return nil }
            var p = p
            p.zTop = 0
            p.zMin = Swift.max(p.zMin ?? -.infinity, w.zMin)
            p.window = (w.min, w.max)
            p.keepOut = []
            p.band = nil
            p.frameTop = nil
            p.tile = nil
            if p.operation.kind == .adaptive {
                // The engine roughs only this side's own cavities in the window (pockets, holes
                // and steps open to the part's edge: "side_cavity"), not the stock around the
                // part's outline (the other setups' faces; strips the solver works for minutes).
                p.keepOut = ko
                // Every level: the keep-out holds from the face down.
                p.keepOutBelow = 1
                p.operation.leaveRadial = 0
                p.operation.leaveAxial = 0
            }
            return p
        }
    }
}
