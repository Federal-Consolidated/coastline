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
        /// Clamp kit: milled down to this height first (too tall for the kit as it is).
        public var prepHeight: Double?
        /// Clamp kit: clamped without the soft jaws (the only way a proper frame fits the kit).
        public var softJawOff = false
        /// The extrusion runs left–right (work Y): the bar's straight extruded sides face the
        /// spindle; only its sawn ends are across.
        public var alongExtrusion = true
        /// Material beyond the part's depth, mm³ (smaller is better).
        public var removal: Double
        /// Clamp kit: workable only held by shoulders at the ends (holding path D): the kit grips
        /// the ends, so the part may come right to the bar's top and bottom edges.
        public var viaShoulders = false
        public var summary: String
    }

    /// - Parameter part: the part's size in the work frame.
    public static func options(stock: StockItem, part: SIMD3<Double>, preferredAxes: [Int]? = nil, units: DisplayUnits = .metric) -> [Option] {
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
            let reason = missing.map { "only \(units.format(raw[$0])) \(units.symbol) \(["tall", "long", "deep"][$0]): the part needs \(units.format(part[$0]))" }
            let dims = "\(units.format(raw.x)) up · \(units.format(raw.y)) along · \(units.format(raw.z)) deep (\(units.symbol))"
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

// MARK: - Clamp kit

extension StockOrientation {
    /// For the clamp kit: each way also says what has to come off first to fit the kit, and the
    /// one removing the least is best. With `requiresClampFrame` false it is the plain fit check.
    /// - Parameters: part: the part's size in the work frame; twoSided: machined from both sides.
    public static func options(stock: StockItem, part: SIMD3<Double>, twoSided: Bool, topAllowance: Double,
                               softJaw: Bool, toolDiameter: Double, requiresClampFrame: Bool = true,
                               preferredAxes: [Int]? = nil, units: DisplayUnits = .metric) -> [Option] {
        let e = [stock.envelope.x, stock.envelope.y, stock.envelope.z]
        var perms: [[Int]] = [[1, 0, 2], [0, 1, 2], [2, 0, 1], [0, 2, 1], [2, 1, 0], [1, 2, 0]]
        // Equal stock dimensions produce equivalent permutations. Keep the current one as
        // their representative so a square blank does not lose its selected option.
        if let preferredAxes, let i = perms.firstIndex(of: preferredAxes) {
            perms.remove(at: i)
            perms.insert(preferredAxes, at: 0)
        }
        let jaw = UniversalClamp.onJaw(softJaw: softJaw)
        let bare = UniversalClamp.onJaw(softJaw: false)
        // Room the part needs: a frame (the jaws' strips and a channel one cutter wide) up and
        // down, a tool's width plus a little at the ends, and its depth plus the face-offs.
        let needX = GripZones.neededHeight(partX: part.x)
        let needY = part.y + 2 * (toolDiameter + 1)
        // Grip needs a frame in XY, not an invented face-off along Z. A blank at finished
        // thickness is valid; placement, tabs and the generated paths decide what is cut.
        let needZ = part.z
        _ = (topAllowance, twoSided)
        // The extrusion: given on the stock, else its longest side.
        let ext = stock.extrusionAxis ?? [0, 1, 2].max { e[$0] < e[$1] }!
        var out: [Option] = []
        var seen = Set<[Double]>()
        for p in perms {
            let raw = SIMD3(e[p[0]], e[p[1]], e[p[2]])
            guard seen.insert([raw.x, raw.y, raw.z]).inserted else { continue }
            if !requiresClampFrame {
                // Containment is independent of workholding. A finished stock face needs no
                // machining allowance; grip and cutter clearance are assessed in Holding.
                let missing = (0..<3).first { raw[$0] + 1e-6 < part[$0] }
                let reason = missing.map { "only \(units.format(raw[$0])) \(units.symbol) \(["tall", "long", "deep"][$0]): the part needs \(units.format(part[$0]))" }
                let dims = "\(units.format(raw.x)) up · \(units.format(raw.y)) along · \(units.format(raw.z)) deep (\(units.symbol))"
                out.append(Option(axes: p, raw: raw, workable: reason == nil, reason: reason,
                                  alongExtrusion: p[1] == ext, removal: max(raw.z - part.z, 0) * raw.x * raw.y,
                                  summary: "\(dims): \(reason.map { "no, " + $0 } ?? "contains the part")"))
                continue
            }
            var reason: String?
            if raw.z + 1e-6 < needZ { reason = "only \(units.format(raw.z)) \(units.symbol) deep: the part needs \(units.format(needZ))" }
            else if raw.y < needY { reason = "only \(units.format(raw.y)) \(units.symbol) long: the part needs \(units.format(needY))" }
            else if raw.x < needX { reason = "only \(units.format(raw.x)) \(units.symbol) tall: the part and the jaws need \(units.format(needX))" }
            var prep: Double?
            var softOff = false
            if reason == nil, UniversalClamp.seat(stockHeight: raw.x, softJaw: softJaw).kind == .tooTall {
                let target = (jaw.upperBound - 0.5).rounded(.down)
                if target >= needX { prep = min(target, raw.x) }
                else if softJaw, raw.x >= needX, (bare.upperBound - 0.5).rounded(.down) >= needX {
                    // A proper frame only fits the kit without the soft jaws.
                    softOff = true
                    // As it is when the screws alone hold it, else down to the tallest they hold.
                    prep = raw.x <= bare.upperBound ? nil : (bare.upperBound - 0.5).rounded(.down)
                } else {
                    reason = "the clamp kit holds \(units.format(bare.upperBound)) \(units.symbol); the part and its frame need \(units.format(needX))"
                }
            }
            // Held by shoulders instead: the jaws grip only the two ends, so the part needs just
            // its own height, and its length between the clamps' jaws.
            var viaShoulders = false
            if reason != nil, raw.z + 1e-6 >= needZ, let sh = Shoulders.fit(raw: raw, part: part) {
                viaShoulders = true
                reason = nil
                prep = nil
                softOff = true
                _ = sh
            }
            let height = prep ?? raw.x
            let length = min(raw.y, max(needY, 0))
            var removal = (raw.x - height) * length * raw.z + max(raw.z - needZ, 0) * height * length
            if viaShoulders, let sh = Shoulders.fit(raw: raw, part: part) { removal = 2 * sh.length * (raw.x - sh.height) * raw.z }
            let dims = "\(units.format(raw.x)) up · \(units.format(raw.y)) along · \(units.format(raw.z)) deep (\(units.symbol))"
            let summary: String
            let jaws = (softOff ? ", soft jaws off" : "") + (p[1] == ext ? "" : " (extrusion across: sawn faces in the jaws)")
            if let r = reason { summary = "\(dims): no, \(r)" }
            else if viaShoulders, let sh = Shoulders.fit(raw: raw, part: part) {
                summary = sh.height < raw.x - 0.01 ? "\(dims): shoulders at both ends (\(units.format(sh.height)) \(units.symbol)), the kit grips those"
                    : "\(dims): the kit grips the two ends only"
            }
            else if let h = prep { summary = "\(dims): mill to \(units.format(h)) \(units.symbol) tall first\(jaws)" }
            else { summary = "\(dims): fits the clamp kit as it is\(jaws)" }
            var o = Option(axes: p, raw: raw, workable: reason == nil, reason: reason, prepHeight: prep, softJawOff: softOff,
                           alongExtrusion: p[1] == ext, removal: removal, summary: summary)
            o.viaShoulders = viaShoulders
            out.append(o)
        }
        // Workable first; then the extrusion along Y (true faces in the jaws and toward the
        // spindle); then the least material removed.
        return out.sorted { a, b in
            if a.workable != b.workable { return a.workable }
            if a.viaShoulders != b.viaShoulders { return !a.viaShoulders }
            if a.alongExtrusion != b.alongExtrusion { return a.alongExtrusion }
            return a.removal < b.removal
        }
    }
}
