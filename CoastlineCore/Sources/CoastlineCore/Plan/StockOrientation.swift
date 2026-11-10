import Foundation
import simd

/// The ways a bar can sit for a part: which of its sizes stands up (work X), runs along the
/// table (Y) and points at the spindle (Z). Only ways the part fits are workable; the best
/// keeps the extrusion along the table and leaves the least material beyond the part.
public enum StockOrientation {
    public struct Option: Sendable, Identifiable {
        public var id: [Int] { axes }
        /// Setup.stockAxes: envelope index for work X, Y, Z.
        public var axes: [Int]
        /// The stock as bought in this orientation (work X, Y, Z).
        public var raw: SIMD3<Double>
        public var workable: Bool
        /// Why not, when it isn't.
        public var reason: String?
        /// The extrusion runs left–right (work Y): the bar's straight extruded sides face the
        /// spindle; only its sawn ends are across.
        public var alongExtrusion = true
        /// Material beyond the part's depth, mm³ (smaller is better).
        public var removal: Double
        public var summary: String
    }

    /// - Parameter part: the part's size in the work frame.
    public static func options(stock: StockItem, part: SIMD3<Double>, preferredAxes: [Int]? = nil) -> [Option] {
        let e = [stock.envelope.x, stock.envelope.y, stock.envelope.z]
        var perms: [[Int]] = [[1, 0, 2], [0, 1, 2], [2, 0, 1], [0, 2, 1], [2, 1, 0], [1, 2, 0]]
        // Equal stock dimensions produce equivalent permutations. Keep the current one as
        // their representative so a square blank does not lose its selected option.
        if let preferredAxes, let i = perms.firstIndex(of: preferredAxes) {
            perms.remove(at: i)
            perms.insert(preferredAxes, at: 0)
        }
        // The extrusion: given on the stock, else its longest side.
        let ext = stock.extrusionAxis ?? [0, 1, 2].max { e[$0] < e[$1] }!
        var out: [Option] = []
        var seen = Set<[Double]>()
        for p in perms {
            let raw = SIMD3(e[p[0]], e[p[1]], e[p[2]])
            guard seen.insert([raw.x, raw.y, raw.z]).inserted else { continue }
            // Containment is independent of workholding. A finished stock face needs no
            // machining allowance; grip and cutter clearance are assessed in Setups.
            let missing = (0..<3).first { raw[$0] + 1e-6 < part[$0] }
            let reason = missing.map { "only \(Length.mm(raw[$0])) mm \(["tall", "long", "deep"][$0]): the part needs \(Length.mm(part[$0]))" }
            let dims = "\(Length.mm(raw.x)) up · \(Length.mm(raw.y)) along · \(Length.mm(raw.z)) deep"
            out.append(Option(axes: p, raw: raw, workable: reason == nil, reason: reason,
                              alongExtrusion: p[1] == ext, removal: max(raw.z - part.z, 0) * raw.x * raw.y,
                              summary: "\(dims): \(reason.map { "no, " + $0 } ?? "contains the part")"))
        }
        // Workable first; then the extrusion along Y; then the least material beyond the part.
        return out.sorted { a, b in
            if a.workable != b.workable { return a.workable }
            if a.alongExtrusion != b.alongExtrusion { return a.alongExtrusion }
            return a.removal < b.removal
        }
    }
}
