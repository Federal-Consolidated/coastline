import Foundation
import simd

/// One design-for-manufacturing finding: what the part needs from the stock, tools and setups
/// the user owns, with the faces it concerns and the ways forward.
public struct DFMFinding: Identifiable, Sendable, Equatable {
    public enum Category: Int, Sendable, Comparable, CaseIterable {
        // Display order: what blocks the job first.
        case notSupported, missingResource, missingInformation, setupChange, ok
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .notSupported: "Can't be machined"
            case .missingResource: "Missing tool or stock"
            case .missingInformation: "Needs info"
            case .setupChange: "Setup change"
            case .ok: "OK"
            }
        }

        public var symbol: String {
            switch self {
            case .notSupported: "xmark.octagon"
            case .missingResource: "shippingbox"
            case .missingInformation: "questionmark.circle"
            case .setupChange: "arrow.triangle.2.circlepath"
            case .ok: "checkmark.circle"
            }
        }
    }

    public enum Remedy: Sendable, Hashable {
        /// An owned stock item and its work axes (Setup.stockAxes).
        case useStock(UUID, axes: [Int])
        /// Open an owned tool in the library.
        case showTool(UUID)
        /// A stated value only: the app never changes a tool's stick-out by itself.
        case setStickout(toolID: UUID, minimum: Double)
        /// Go to Setups (orientation, sides).
        case reviewSetups
        /// A tool that is not owned (catalog suggestion) that would work.
        case buyTool(UUID)
        /// A collet for this shank size, mm.
        case addCollet(Double)
        /// A tool Coastline specified for this cut (not in the library yet): add it as a tool
        /// to buy. Plans "with tools to buy" can then use it.
        case addTool(Tool)

        /// Short button text without inventory names. `title(in:currentStock:)` names the items.
        public var title: String {
            switch self {
            case .useStock: "Use this stock"
            case .showTool: "Show the tool"
            case .setStickout(_, let s): "Set stick-out to \(DFM.mm(s, 0.1)) mm or more"
            case .reviewSetups: "Review setups"
            case .buyTool: "Tool to buy"
            case .addCollet(let d): "Add a \(DFM.size(d)) collet"
            case .addTool: "Add to buy"
            }
        }

        /// Button text naming the stock or tool. `currentStock`: the job's stock, so the same
        /// item in another orientation reads "Turn the stock".
        public func title(in inventory: Inventory, currentStock: UUID? = nil) -> String {
            switch self {
            case .useStock(let id, _):
                if id == currentStock { return "Turn the stock" }
                guard let s = inventory.stock.first(where: { $0.id == id }) else { return title }
                return "Use the \(DFM.dims(SIMD3(s.envelope.x, s.envelope.y, s.envelope.z))) mm \(s.shape.title.lowercased())"
            case .showTool(let id):
                return inventory.tools.first { $0.id == id }.map { "Show the \(DFM.label($0))" } ?? title
            case .setStickout(let id, let s):
                return inventory.tools.first { $0.id == id }.map { "Set the \(DFM.label($0)) stick-out to \(DFM.mm(s, 0.1)) mm" } ?? title
            case .buyTool(let id):
                return inventory.tools.first { $0.id == id }.map { "Buy the \(DFM.label($0))" } ?? title
            case .addTool(let t):
                return inventory.tools.contains { $0.id == t.id } ? "Buy the \(t.name)" : "Add to buy: \(t.name)"
            case .reviewSetups, .addCollet:
                return title
            }
        }
    }

    /// Stable: "stock", "floor-<face>", "hole-<first face>", "region-<first face>", "profile",
    /// "back", "corner", "concave", "thin", "tools", "tools-info", "exact".
    public var id: String
    public var category: Category
    public var title: String
    /// What is wrong (or right), in one plain sentence.
    public var summary: String
    /// Short lines: per-tool reasons and other notes.
    public var details: [String]
    /// Engine face indices to highlight (PartAccess.triangles(forFaces:)).
    public var faces: [Int]
    public var remedies: [Remedy]
    /// The key measurement, e.g. "6 mm wide, 30 mm deep".
    public var measure: String?
    /// What to do about it, in one plain sentence (nil when nothing is needed).
    public var fix: String?
    /// The separate places it occurs (face groups): one pin on the part for each.
    public var areas: [[Int]]
    /// The directions a tool comes from to cut it ("+z" the front, "-z" the back, "+x" ...),
    /// every one needed. Empty: not a cut of its own (stock, tool notes, corners).
    public var sides: [String]

    public init(id: String, category: Category, title: String, summary: String, details: [String] = [],
                faces: [Int] = [], remedies: [Remedy] = [], measure: String? = nil, fix: String? = nil, areas: [[Int]]? = nil,
                sides: [String] = []) {
        (self.id, self.category, self.title, self.summary) = (id, category, title, summary)
        (self.details, self.faces, self.remedies) = (details, faces, remedies)
        (self.measure, self.fix) = (measure, fix)
        self.areas = areas ?? (faces.isEmpty ? [] : [faces])
        self.sides = sides
    }
}

/// Design for manufacturing against what the user owns: does the stock hold the part, which
/// owned tool reaches each pocket and hole (cutter, shank and collet nut), and which faces need
/// another side or position. Geometry only: forces, rigidity and holding are not judged.
public enum DFM {
    /// Shank left in the collet, mm: the same threshold as InventoryChecks' grip warning.
    public static let minimumGrip = 10.0
    public static let notChecked = "Not checked: cutting force, rigidity, clamping, fixtures before toolpaths, and the spindle above the collet nut."
    /// A boundary face this close to the stock face (mm) stays as supplied: no cut, no allowance.
    static let keptTolerance = 0.01

    public struct Input: Sendable {
        public var analysis: PartAnalysis
        public var setup: Setup
        /// The part's own bounds (part coordinates, PartInfo.boundsMin/Max).
        public var partMin: SIMD3<Double>
        public var partMax: SIMD3<Double>
        public var stock: StockItem?
        public var inventory: Inventory
        public var machine: MachineProfile
        public var twoSided: Bool
        /// Names for the part's features (quiddity), to title the access findings; may be empty.
        public var named: [NamedFeature]
        /// The machine's room for the stock turned to each side (nil: not checked).
        public var room: SetupRoom?
        public init(analysis: PartAnalysis, setup: Setup, partMin: SIMD3<Double>, partMax: SIMD3<Double>,
                    stock: StockItem?, inventory: Inventory, machine: MachineProfile = .standard, twoSided: Bool = false,
                    named: [NamedFeature] = [], room: SetupRoom? = nil) {
            (self.analysis, self.setup, self.partMin, self.partMax) = (analysis, setup, partMin, partMax)
            (self.stock, self.inventory, self.machine, self.twoSided, self.named) = (stock, inventory, machine, twoSided, named)
            self.room = room
        }
    }

    public struct Reach: Sendable, Equatable {
        public enum Verdict: Sendable, Equatable {
            case reaches
            /// Reaches with at least this stick-out (mm), which still leaves the minimum grip.
            case needsStickout(Double)
            case cannot
        }
        public var verdict: Verdict
        public var reason: String
        public var warnings: [String]
        public init(verdict: Verdict, reason: String, warnings: [String] = []) {
            (self.verdict, self.reason, self.warnings) = (verdict, reason, warnings)
        }
    }

    // MARK: Reach

    /// Can this tool cut a feature: the cutter fits the opening, the flutes or a shank no wider
    /// than the cutter reach the wall depth, and the collet nut clears the part at the stick-out.
    /// - Parameters:
    ///   - opening: the widest cutter the feature takes (floor width), nil for an outside profile.
    ///   - wallDepth: how far the walls rise above the cutting tip, mm.
    ///   - holderDepth: the shortest stick-out that keeps the collet nut clear of the part, mm.
    ///   - hole: the hole diameter when the feature is a hole (drills must match it; end mills bore it).
    public static func reach(tool t: Tool, opening: Double?, wallDepth: Double, holderDepth: Double, hole: Double?,
                             machine: MachineProfile, inventory: Inventory) -> Reach {
        func no(_ reason: String) -> Reach { Reach(verdict: .cannot, reason: reason) }
        if t.condition == .broken { return no("marked broken") }
        if t.requiresSpecificationReview || !ResourceLibraryValidation.issues(for: t).isEmpty { return no("specs not confirmed") }
        if t.shankDiameter > machine.maxShankDiameter + 1e-6 {
            return no("shank over the \(machine.colletName) limit (\(mm(machine.maxShankDiameter)) mm)")
        }
        if t.overallLength > machine.maxToolLength + 1e-6 {
            return no("\(mm(t.overallLength)) mm long, over the \(mm(machine.maxToolLength)) mm limit")
        }
        if !hasCollet(t, inventory) { return no("no collet for its \(size(t.shankDiameter)) shank") }
        if t.kind == .drill {
            guard let h = hole else { return no("a drill only makes holes") }
            if abs(t.diameter - h) > 0.05 { return no("\(mm(t.diameter)) mm drill, \(mm(h)) mm hole") }
            // A drill's body above the flutes doesn't clear chips: the flutes must cover the hole.
            if t.fluteLength + 0.05 < wallDepth { return no("flutes \(mm(t.fluteLength)) mm, hole \(mm(wallDepth, 0.1)) mm deep") }
        } else if !t.kind.cutsSideways {
            return no("doesn't cut sideways")
        } else if let h = hole {
            // Helical boring needs room to move the cutter around.
            if t.diameter >= h - 0.1 - 1e-9 { return no("too wide to bore it (needs under \(mm(h - 0.1)) mm)") }
        } else if let w = opening, t.diameter > w - 0.02 + 1e-9 {
            return no("too wide (\(mm(t.diameter)) > \(mm(w, 0.01)) mm)")
        }
        var warnings: [String] = []
        let wideShank = t.shankDiameter > t.diameter + 0.02
        if wideShank && wallDepth > t.fluteLength + 1e-6 {
            return no("shank wider than the cutter stops it at \(mm(t.fluteLength)) mm")
        }
        if !wideShank && t.kind != .drill && wallDepth > t.fluteLength + 0.05 {
            warnings.append("shank rubs the wall below \(mm(t.fluteLength)) mm")
        }
        let longest = t.overallLength - minimumGrip
        let verdict: Reach.Verdict
        let used: Double
        // Measured depths carry float noise; 0.005 mm is nothing next to the 1 mm nut clearance.
        let need = holderDepth - 0.005
        if t.stickout >= need {
            verdict = .reaches
            used = t.stickout
        } else if need <= longest {
            // Stated in half millimetres, never past the grip limit.
            var s = (need * 2).rounded(.up) / 2
            if s > longest + 1e-6 { s = Swift.min((need * 10).rounded(.up) / 10, longest) }
            verdict = .needsStickout(s)
            used = s
        } else {
            return no("the collet nut would hit the part (needs \(mm(holderDepth, 0.1)) mm stick-out, at most \(mm(longest, 0.1)))")
        }
        // Slenderness as InventoryChecks measures it: flutes at the cutting diameter, the plain
        // shank below the nut at the shank diameter.
        if t.kind.cutsSideways {
            let fluted = Swift.min(t.fluteLength, used)
            let ratio = fluted / Swift.max(t.diameter, 0.01) + (used - fluted) / Swift.max(t.shankDiameter, 0.01)
            if ratio > 10 { warnings.append("very slender at \(mm(used, 0.1)) mm stick-out (\(Int(ratio.rounded()))× its diameter)") }
        }
        switch verdict {
        case .needsStickout(let s): return Reach(verdict: verdict, reason: "reaches at \(mm(s, 0.1)) mm stick-out (now \(mm(t.stickout)))", warnings: warnings)
        default: return Reach(verdict: verdict, reason: "reaches", warnings: warnings)
        }
    }

    // MARK: Assessment

    /// Findings sorted by category, then title. Without `analysis.access` (a mesh part, or not
    /// analysed for access yet: PartAnalysis has no exact flag) only the stock fit and an
    /// "Exact CAD needed" note come back.
    public static func assess(_ input: Input) -> [DFMFinding] {
        var out: [DFMFinding] = []
        let fit = stockFit(input)
        out.append(fit.finding)
        guard let access = input.analysis.access else {
            out.append(DFMFinding(id: "exact", category: .missingInformation, title: "Exact CAD needed",
                                  summary: "Tool reach is checked only on STEP parts, after analysis.",
                                  fix: "Import the part as STEP or IGES."))
            return sorted(out)
        }
        if let room = fit.room {
            let back = access.boundaryFaces("-z")
            if !input.twoSided, room.side("-z") > keptTolerance, !back.isEmpty {
                out.append(DFMFinding(id: "back", category: .setupChange, title: "Stock behind the part",
                                      summary: "\(mm(room.side("-z"), 0.1)) mm of stock stays behind the part. Cut the part free, or machine the back.",
                                      details: ["Holding while it is cut free is not checked."],
                                      faces: back.map(\.index), remedies: [.reviewSetups], sides: ["-z"]))
            }
            let sides = ["+x", "-x", "+y", "-y"].filter { room.side($0) > keptTolerance }
            let depth = profileDepth(access, input)
            if !sides.isEmpty, depth > 0.05 {
                let perSide = input.twoSided ? " per side" : ""
                out.append(cut(from: input.twoSided ? ["+z", "-z"] : ["+z"], feature(Feature(id: "profile", title: "Outside profile, \(mm(depth, 0.1)) deep\(perSide)",
                                           faces: access.faces.filter { sides.contains($0.boundary ?? "") }.map(\.index),
                                           opening: nil, wallDepth: depth, holderDepth: depth + 1, hole: nil,
                                           measure: "Walls \(mm(depth, 0.1)) mm deep\(input.twoSided ? " from each side" : ""), stick-out at least \(mm(depth + 1, 0.1)) mm"), input)))
            }
        }
        for f in access.floors where f.wallDepth > 0.05 {
            let cx = (f.min.x + f.max.x) / 2, cy = (f.min.y + f.max.y) / 2
            // A flat-bottomed hole's floor is the hole's own business.
            if access.holes.contains(where: { abs(f.width - $0.diameter) <= 0.06 && hypot(cx - $0.x, cy - $0.y) <= $0.diameter / 2 }) { continue }
            let dx = f.max.x - f.min.x, dy = f.max.y - f.min.y
            let a = Swift.min(dx, dy), b = Swift.max(dx, dy)
            let title = a > 0.05 ? "\(floorKind(f, long: b >= 4 * a)) \(mm(a, 0.1)) x \(mm(b, 0.1)) mm, \(mm(f.wallDepth, 0.1)) deep"
                : "Floor \(mm(f.width, 0.1)) mm wide, \(mm(f.wallDepth, 0.1)) deep"
            out.append(cut(from: ["+z"], feature(Feature(id: "floor-\(f.face)", title: title, faces: [f.face], opening: f.width,
                                       wallDepth: f.wallDepth, holderDepth: f.holderDepth, hole: nil,
                                       measure: "\(mm(f.width, 0.01)) mm wide, \(mm(f.wallDepth, 0.1)) mm deep, stick-out at least \(mm(f.holderDepth, 0.1)) mm"), input)))
        }
        for h in access.holes where h.access == .thisSide {
            let d = mm(h.diameter), len = mm(h.length, 0.1)
            out.append(cut(from: ["+z"], feature(Feature(id: "hole-\(h.faces.first ?? -1)", title: h.through ? "Through hole \(d) mm, \(len) deep" : "Hole \(d) mm, \(len) deep",
                                       faces: h.faces, opening: h.diameter, wallDepth: h.length, holderDepth: h.holderDepth, hole: h.diameter,
                                       measure: "\(d) mm, \(len) mm deep\(h.through ? ", through" : ""), stick-out at least \(mm(h.holderDepth, 0.1)) mm"), input)))
        }
        for g in regionGroups(access.regions, input) {
            guard var f = region(g[0], input) else { continue }
            // What it is, when the feature names know, then where it is cut from ("Slot 16.89 x
            // 31 mm: cut from the upper side"). A thread keeps its own measured name.
            if g[0].thread == nil, let name = NamedFeature.name(for: g[0].faces, in: input.named) {
                f.title = "\(name): \(inline(f.title))"
            }
            if g.count > 1 {
                f.faces = g.flatMap(\.faces)
                f.areas = g.map(\.faces)
            }
            out.append(roomChecked(f, input))
        }
        out += shapeFindings(input)
        out += toolFindings(input)
        return sorted(merged(out))
    }

    static func sorted(_ f: [DFMFinding]) -> [DFMFinding] {
        f.sorted { ($0.category, $0.title, $0.id) < ($1.category, $1.title, $1.id) }
    }

    /// The same finding in several places (four identical holes, five areas that need the same
    /// other position) reads once, with a pin on the part for each place.
    static func merged(_ findings: [DFMFinding]) -> [DFMFinding] {
        var out: [DFMFinding] = []
        var index: [String: Int] = [:]
        for f in findings {
            let place = ["floor-", "hole-", "region-"].contains { f.id.hasPrefix($0) }
            let key = "\(f.category.rawValue)|\(f.title)|\(f.summary)|\(f.fix ?? "")"
            guard place, let k = index[key] else {
                if place { index[key] = out.count }
                out.append(f)
                continue
            }
            out[k].faces += f.faces
            out[k].areas += f.areas
            for r in f.remedies where !out[k].remedies.contains(r) { out[k].remedies.append(r) }
            for side in f.sides where !out[k].sides.contains(side) { out[k].sides.append(side) }
        }
        for k in out.indices where out[k].areas.count > 1 {
            out[k].title += " (\(out[k].areas.count) places)"
        }
        return out
    }

    /// A cut from a side the stock doesn't fit the machine on (too deep for the table with that
    /// side toward the spindle): it can't be machined here, whatever the tools.
    static func roomChecked(_ f: DFMFinding, _ i: Input) -> DFMFinding {
        guard let room = i.room, let stock = i.stock else { return f }
        let size = i.setup.stockSize(stock)
        var f = f
        for side in f.sides {
            switch room.fit(SetupRoom.size(size, facing: side), side: side) {
            case .fits:
                continue
            case .enclosureOpen(let why):
                let line = "With the \(sideWords(side)) toward the spindle: \(why)"
                if !f.details.contains(line) { f.details.append(line) }
            case .no(let why):
                let line = "The stock doesn't fit the machine with the \(sideWords(side)) toward the spindle. \(why)"
                if f.category == .notSupported { f.details.append(line); return f }
                f.category = .notSupported
                f.summary = "Cut from the \(sideWords(side)). \(line)"
                f.remedies = []
                f.fix = "Change the design so a side that fits reaches it, or make it on a machine with more room."
                return f
            }
        }
        return f
    }

    /// The finding with the sides its cut comes from.
    static func cut(from sides: [String], _ f: DFMFinding) -> DFMFinding {
        var f = f
        f.sides = sides
        return f
    }

    // MARK: Stock

    /// Stock left around the part per side, mm (negative: the part sticks out).
    struct Room {
        var low: SIMD3<Double>
        var high: SIMD3<Double>
        func side(_ s: String) -> Double {
            let axis = ["x": 0, "y": 1, "z": 2][String(s.dropFirst())] ?? 2
            return s.hasPrefix("+") ? high[axis] : low[axis]
        }
    }

    static let sides = ["+z", "-z", "+x", "-x", "+y", "-y"]

    /// The part's bounds in the work frame, exactly as SetupChecks.check places it.
    static func workBounds(_ i: Input) -> (SIMD3<Double>, SIMD3<Double>) {
        let m = i.setup.partToWork(partMin: i.partMin, partMax: i.partMax)
        let (rlo, rhi) = i.setup.rotatedPartBounds(min: i.partMin, max: i.partMax)
        let shift = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        return (rlo + shift, rhi + shift)
    }

    /// The stock finding, and the room around the part when it fits.
    static func stockFit(_ i: Input) -> (finding: DFMFinding, room: Room?) {
        let (plo, phi) = workBounds(i)
        let size = phi - plo
        let partLine = "Part \(dims(size)) mm (up x along x deep)."
        let choices = JobLibraryGuide.stockChoices(partSize: size, inventory: i.inventory, preferredAxes: i.setup.stockAxes)
        guard let stock = i.stock else {
            let remedies = choices.map { DFMFinding.Remedy.useStock($0.stock.id, axes: $0.axes) }
            if remedies.isEmpty {
                return (DFMFinding(id: "stock", category: .missingResource, title: "No stock fits",
                                   summary: "None of your stock holds the part.", details: [partLine]), nil)
            }
            return (DFMFinding(id: "stock", category: .missingInformation, title: "No stock chosen",
                               summary: "Choose stock. \(remedies.count) of yours fit\(remedies.count == 1 ? "s" : "").",
                               details: [partLine], remedies: remedies), nil)
        }
        let box = i.setup.stockBox(stock)
        let room = Room(low: plo - box.min, high: box.max - phi)
        let stockSize = box.max - box.min
        let faces = i.analysis.access?.faces ?? []
        let out = sides.filter { room.side($0) < -1e-6 }
        if !out.isEmpty {
            let fitsAsIs = (0..<3).allSatisfy { stockSize[$0] + 1e-6 >= size[$0] }
            var remedies: [DFMFinding.Remedy] = fitsAsIs ? [.reviewSetups] : []
            let current = i.setup.rawStockSize(stock)
            for c in choices {
                // The current stock only when another orientation is what makes it fit.
                if c.stock.id == stock.id {
                    var turned = i.setup
                    turned.stockAxes = c.axes
                    if fitsAsIs || simd_length(turned.rawStockSize(stock) - current) < 1e-6 { continue }
                }
                remedies.append(.useStock(c.stock.id, axes: c.axes))
            }
            var details = [partLine, "Stock \(dims(stockSize)) mm as set up."]
            details += out.map { "Sticks out \(mm(-room.side($0), 0.1)) mm at the \(sideName($0))." }
            if !fitsAsIs && !remedies.contains(where: { if case .useStock = $0 { true } else { false } }) {
                details.append("None of your stock holds the part.")
            }
            let worst = out.map { -room.side($0) }.max() ?? 0
            let finding = fitsAsIs
                ? DFMFinding(id: "stock", category: .setupChange, title: "Part outside the stock",
                             summary: "The stock is big enough, but the part sits partly outside it.", details: details,
                             faces: faces.filter { out.contains($0.boundary ?? "") }.map(\.index), remedies: remedies,
                             measure: partLine, fix: "Move the part inside the stock in Setups.")
                : DFMFinding(id: "stock", category: .missingResource, title: "Stock too small",
                             summary: "The part sticks out of this stock by \(mm(worst, 0.1)) mm.", details: details,
                             faces: faces.filter { out.contains($0.boundary ?? "") }.map(\.index), remedies: remedies,
                             measure: partLine, fix: remedies.contains { if case .useStock = $0 { true } else { false } }
                                ? "Use bigger stock you own (below)." : "Get stock at least \(dims(size)) mm. The part keeps its size.")
            return (finding, nil)
        }
        // Fits. A face on the stock boundary needs no cut: zero allowance is valid there.
        let keptSides = sides.filter { room.side($0) <= keptTolerance }
        let kept = faces.filter { keptSides.contains($0.boundary ?? "") }
        let named = i.analysis.access == nil ? keptSides : keptSides.filter { s in kept.contains { $0.boundary == s } }
        let exact = keptSides.count == sides.count
        var summary = exact ? "Exact size." : "Fits."
        if !kept.isEmpty { summary += " \(kept.count) face\(kept.count == 1 ? "" : "s") stay\(kept.count == 1 ? "s" : "") as supplied." }
        let cut = sides.filter { room.side($0) > keptTolerance }
        var details = ["Stock \(dims(SIMD3(stock.envelope.x, stock.envelope.y, stock.envelope.z))) mm.",
                       cut.isEmpty ? "Stock to cut: none."
                           : "Stock to cut: " + cut.map { "\(sideName($0)) \(mm(room.side($0), 0.01))" }.joined(separator: ", ") + " mm."]
        if !named.isEmpty {
            details.append("Kept as supplied: " + (named.count == sides.count ? "all six faces" : named.map(sideName).joined(separator: ", ")) + ".")
        }
        return (DFMFinding(id: "stock", category: .ok, title: "Stock fits", summary: summary, details: details,
                           faces: kept.map(\.index), measure: partLine), room)
    }

    // MARK: Features

    struct Feature {
        var id: String
        var title: String
        var faces: [Int]
        var opening: Double?
        var wallDepth: Double
        var holderDepth: Double
        var hole: Double?
        var measure: String
    }

    // MARK: Tools to buy

    /// Overall lengths tools are commonly sold in, mm (1½" to 4"), before the machine's limit.
    static let standardLengths: [Double] = [38.1, 50.8, 63.5, 76.2, 101.6]

    /// The same ID for the same specified tool on every run, so one added to the library is
    /// recognised as on the list.
    static func stableID(_ key: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return h
        }
        let hex = String(format: "%016llX%016llX", fnv(0xcbf29ce484222325), fnv(0x84222325cbf29ce4))
        let c = Array(hex)
        return UUID(uuidString: "\(String(c[0..<8]))-\(String(c[8..<12]))-5\(String(c[13..<16]))-A\(String(c[17..<20]))-\(String(c[20..<32]))")!
    }

    /// Shank sizes the machine can hold with your collets (else the common 1/8" and 1/4").
    static func shanks(_ i: Input) -> [Double] {
        let owned = i.inventory.colletSizes.filter { $0 <= i.machine.maxShankDiameter + 1e-6 }.sorted()
        return owned.isEmpty ? [3.175, 6.35].filter { $0 <= i.machine.maxShankDiameter + 1e-6 } : owned
    }

    /// The shortest common length that holds the stick-out with the minimum grip, within the
    /// machine's limit (which is offered last, as a cut-down length).
    static func length(forStickout s: Double, _ m: MachineProfile) -> Double? {
        let options = standardLengths.filter { $0 <= m.maxToolLength + 1e-6 } + [m.maxToolLength]
        return options.sorted().first { $0 - minimumGrip >= s - 1e-6 }
    }

    /// A tool to buy for a cut nothing in the library does: the largest common end mill through
    /// the opening, on a shank you have a collet for, with flutes (or a reduced neck, past three
    /// diameters) to the depth and long enough for the stick-out, within the machine's limits.
    /// nil: no such tool fits the machine.
    static func suggestedTool(_ f: Feature, _ i: Input) -> Tool? {
        guard let maxShank = shanks(i).max() else { return nil }
        let limit = f.hole.map { $0 - 0.1 - 1e-6 } ?? f.opening.map { $0 - 0.02 } ?? .infinity
        guard let d = Feasibility.standardSizes.filter({ $0 <= Swift.min(limit, maxShank) + 1e-9 }).max() else { return nil }
        let shank = shanks(i).first { $0 >= d - 1e-6 } ?? d
        let reachLength = (f.wallDepth + 0.5).rounded(.up)
        let stick = (Swift.max(f.holderDepth, reachLength) * 2).rounded(.up) / 2
        guard let oal = length(forStickout: stick, i.machine) else { return nil }
        let neck = reachLength > 3 * d + 1e-6
        let name = "\(size(d)) flat end mill, \(mm(reachLength)) mm \(neck ? "reach" : "flutes")"
        let t = Tool(id: stableID("endmill|\(d)|\(shank)|\(reachLength)|\(oal)"), name: name, kind: .flatEndMill,
                     vendor: neck ? "Long reach (reduced neck), e.g. Harvey Tool" : "", diameter: d, shankDiameter: shank,
                     flutes: 3, fluteLength: reachLength, stickout: stick, overallLength: oal, toolMaterial: .carbide, coating: .none,
                     intendedFor: "Aluminium", quantity: 0, condition: .new,
                     notes: "Coastline suggests it for a cut \(mm(f.wallDepth, 0.1)) mm deep\(f.opening.map { " through \(mm($0, 0.1)) mm" } ?? ""). Pick the nearest real tool from a catalogue and check its sizes here.",
                     source: ToolCatalog.source)
        let r = DFM.reach(tool: t, opening: f.opening, wallDepth: f.wallDepth, holderDepth: f.holderDepth, hole: f.hole,
                      machine: i.machine, inventory: i.inventory)
        return r.verdict == .cannot ? nil : t
    }

    /// A single-profile thread mill for a modelled thread: head small enough to circle in the
    /// hole, reach past the far end, on a shank you have a collet for. It cuts any pitch its
    /// tooth suits.
    static func suggestedThreadMill(minor: Double, depth: Double, _ i: Input) -> Tool? {
        guard let maxShank = shanks(i).max(),
              let d = Feasibility.standardSizes.filter({ $0 <= Swift.min(minor - 1, maxShank) + 1e-9 }).max() else { return nil }
        let shank = shanks(i).first { $0 >= d - 1e-6 } ?? d
        let reach = (depth + 1).rounded(.up)
        let stick = ((depth + 1) * 2).rounded(.up) / 2
        guard let oal = length(forStickout: Swift.max(stick, reach), i.machine) else { return nil }
        return Tool(id: stableID("threadmill|\(d)|\(shank)|\(reach)|\(oal)"), name: "Single-profile thread mill, \(size(d)) head, \(mm(reach)) mm reach",
                    kind: .threadMill, vendor: "", diameter: d, shankDiameter: shank, flutes: 1, fluteLength: reach,
                    stickout: Swift.max(stick, reach), overallLength: oal, toolMaterial: .carbide, coating: .none,
                    intendedFor: "Aluminium", quantity: 0, condition: .new,
                    notes: "Coastline suggests it for a thread with a \(mm(minor, 0.1)) mm hole, \(mm(depth, 0.1)) mm deep. Single-profile: one tool for many pitches.",
                    source: ToolCatalog.source)
    }

    /// A name inside a sentence: "Single-profile thread mill" → "single-profile thread mill".
    static func inline(_ name: String) -> String { name.prefix(1).lowercased() + name.dropFirst() }

    /// The sizes that matter when buying a tool, in one line.
    static func spec(_ t: Tool) -> String {
        "\(t.name): \(mm(t.diameter, 0.01)) mm cutter, \(size(t.shankDiameter)) shank, \(mm(t.fluteLength, 0.1)) mm \(t.kind == .threadMill || t.fluteLength > 3 * t.diameter ? "reach" : "flutes"), \(mm(t.overallLength, 0.1)) mm long, set at \(mm(t.stickout, 0.1)) mm stick-out"
    }

    /// 0: reaches cleanly, 1: with more stick-out, 2/3: the same with warnings; nil: cannot.
    static func rank(_ r: Reach) -> Int? {
        switch r.verdict {
        case .cannot: nil
        case .reaches: r.warnings.isEmpty ? 0 : 2
        case .needsStickout: r.warnings.isEmpty ? 1 : 3
        }
    }

    static func feature(_ f: Feature, _ i: Input) -> DFMFinding {
        let m = i.machine
        func check(_ t: Tool, _ inv: Inventory) -> Reach {
            reach(tool: t, opening: f.opening, wallDepth: f.wallDepth, holderDepth: f.holderDepth, hole: f.hole, machine: m, inventory: inv)
        }
        let pool = i.inventory.tools.filter { t in
            guard t.condition != .broken else { return false }
            if t.kind == .drill { return f.hole.map { abs(t.diameter - $0) <= 0.05 } ?? false }
            return t.kind == .flatEndMill || t.kind == .bullNoseEndMill
        }
        let owned = pool.filter { $0.quantity > 0 && !$0.isSuggestion }
        let results = owned.filter { !$0.requiresSpecificationReview }.map { ($0, check($0, i.inventory)) }
        // Best: the cleanest answer, then the stiffest (largest) cutter; a square floor corner
        // before a bull nose; then the shortest stick-out when it reaches cleanly, else the
        // longest flutes (least rubbing).
        func key(_ e: (Tool, Reach)) -> (Int, Double, Int, Int, Double, String) {
            let r = rank(e.1)!
            return (r, -e.0.diameter, e.0.kind == .bullNoseEndMill ? 1 : 0, e.1.warnings.count,
                    r <= 1 ? e.0.stickout : -e.0.fluteLength, e.0.name)
        }
        let best = results.filter { rank($0.1) != nil }.min { key($0) < key($1) }
        // Ways forward beyond what's ready: a collet for an owned tool, a tool to buy, specs to confirm.
        var collets: [Double] = []
        for (t, r) in results where r.verdict == .cannot && !hasCollet(t, i.inventory) && t.shankDiameter <= m.maxShankDiameter + 1e-6 {
            var more = i.inventory
            more.accessories.append(Accessory(name: "collet", kind: .collet, size: t.shankDiameter))
            if check(t, more).verdict != .cannot, !collets.contains(where: { abs($0 - t.shankDiameter) <= 0.05 }) { collets.append(t.shankDiameter) }
        }
        let buys = pool.filter { ($0.quantity <= 0 || $0.isSuggestion) && !$0.requiresSpecificationReview }
            .filter { let r = check($0, i.inventory); return r.verdict == .reaches && r.warnings.isEmpty }
            .sorted { ($0.diameter, $1.name) > ($1.diameter, $0.name) }.prefix(2)
        let unconfirmed = owned.filter(\.requiresSpecificationReview)
        let maybe = unconfirmed.filter { var c = $0; c.unconfirmedSpecifications = nil; return check(c, i.inventory).verdict != .cannot }

        // One line per tool, merged when tools of one size and kind say the same.
        var entries = results.sorted { a, b in (rank(a.1) ?? 9, -a.0.diameter, a.0.name) < (rank(b.1) ?? 9, -b.0.diameter, b.0.name) }
            .map { ($0.0, ([$0.1.reason] + $0.1.warnings).joined(separator: "; ")) }
        entries += unconfirmed.map { ($0, "specs not confirmed" + (maybe.contains($0) ? ", might reach" : "")) }
        let buyLines = buys.map { "\(label($0)) (not owned): reaches" }
        // Nothing to buy in the library: a tool Coastline specifies to fit this machine.
        let made = buys.isEmpty ? suggestedTool(f, i) : nil
        let toBuy: Tool? = buys.first ?? made
        func buyRemedy(_ t: Tool) -> DFMFinding.Remedy { i.inventory.tools.contains { $0.id == t.id } ? .buyTool(t.id) : .addTool(t) }
        func buyText(_ t: Tool) -> String {
            let listed = i.inventory.tools.contains { $0.id == t.id }
            let r = check(t, i.inventory)
            let how = r.warnings.isEmpty ? "it reaches cleanly" : "it reaches (\(r.warnings.joined(separator: "; ")))"
            return listed ? "Buy the \(label(t)), on your list: \(how)." : "Add a \(inline(t.name)) to buy: \(how)."
        }
        let madeLine = made.map { ["Coastline suggests: \(spec($0))."] } ?? []
        var details: [String] = []
        let category: DFMFinding.Category
        let summary: String
        var fix: String?
        var remedies: [DFMFinding.Remedy] = []
        let deep = mm(f.wallDepth, 0.1)
        let colletFix = collets.isEmpty ? "" : " Or add a \(collets.map(size).joined(separator: " and ")) collet."
        if let best {
            let (t, r) = best
            let stickout: Double? = if case .needsStickout(let s) = r.verdict { s } else { nil }
            switch rank(r)! {
            case 0:
                category = .ok
                summary = "The \(label(t)) reaches it."
                details.append("\(label(t)): reaches")
            case 1:
                category = .setupChange
                summary = "The \(label(t)) reaches it only with more stick-out: \(mm(stickout!, 0.1)) mm (now \(mm(t.stickout)))."
                fix = "Set the \(label(t)) to stick out \(mm(stickout!, 0.1)) mm for this cut."
                remedies = [.setStickout(toolID: t.id, minimum: stickout!), .showTool(t.id)]
                details += lines(entries)
            default:
                category = .missingResource
                let rub = r.warnings.joined(separator: "; ")
                summary = "The \(label(t)) reaches it\(stickout.map { " at \(mm($0, 0.1)) mm stick-out" } ?? ""), but its \(rub)."
                fix = (toBuy.map(buyText) ?? f.opening.flatMap { $0 < 20 ? "Use a tool under \(mm($0, 0.01)) mm with \(deep) mm of flute." : nil }
                       ?? "Use an end mill with \(deep) mm of flute.")
                    + colletFix
                if let b = toBuy { remedies.append(buyRemedy(b)) }
                if let s = stickout { remedies.append(.setStickout(toolID: t.id, minimum: s)) }
                remedies.append(.showTool(t.id))
                remedies += buys.dropFirst().map { .buyTool($0.id) } + collets.map { .addCollet($0) }
                details += lines(entries) + buyLines + madeLine
            }
        } else {
            details += lines(entries) + buyLines
            let tooNarrow = (f.opening ?? .infinity) < 0.5
            let tooDeep = f.holderDepth > m.maxToolLength - minimumGrip + 1e-6
            // The tool that came closest: it fits the opening but something else stops it.
            let closest = results.first { e in
                !["too wide", "doesn't cut", "a drill only", "marked broken"].contains { e.1.reason.hasPrefix($0) }
            }
            let why = closest.map { " The \(label($0.0)): \($0.1.reason)." } ?? ""
            if tooNarrow || tooDeep {
                category = .notSupported
                summary = tooNarrow ? "Too narrow for any tool (\(mm(f.opening!, 0.01)) mm)."
                    : "No tool this machine can hold reaches it: it needs \(mm(f.holderDepth, 0.1)) mm stick-out."
                fix = "Change the design: make it \(tooNarrow ? "wider" : "shallower")."
                details.append("Longest tool: \(mm(m.maxToolLength)) mm, with \(mm(minimumGrip)) mm in the collet.")
            } else {
                remedies = (toBuy.map { [buyRemedy($0)] } ?? []) + buys.dropFirst().map { .buyTool($0.id) }
                    + collets.map { .addCollet($0) } + maybe.map { .showTool($0.id) }
                details += madeLine
                if !maybe.isEmpty && buys.isEmpty && collets.isEmpty {
                    category = .missingInformation
                    summary = "Only the \(label(maybe[0])) might reach it. Confirm its specs first."
                    fix = "Measure the \(label(maybe[0])) and confirm its specs in Tools."
                } else if let b = toBuy {
                    // Not owning a tool doesn't stop the job: the one to buy fits this machine.
                    category = .missingResource
                    let size = f.opening.map { "\(mm($0, 0.1)) mm wide and \(deep) mm deep" } ?? "\(deep) mm deep"
                    summary = "None of your tools reaches it (\(size)). One that fits this machine does." + why
                    fix = buyText(b) + colletFix
                } else {
                    category = .missingResource
                    if let h = f.hole {
                        summary = "Needs a \(mm(h)) mm drill, or a smaller end mill, that reaches \(deep) mm." + why
                        fix = "Get a \(mm(h)) mm drill with \(deep) mm of flute that fits this machine." + colletFix
                    } else if let w = f.opening {
                        summary = "Needs a tool under \(mm(w, 0.01)) mm that reaches \(deep) mm." + why
                        fix = "Get an end mill under \(mm(w, 0.01)) mm that reaches \(deep) mm (long neck), or widen it." + colletFix
                    } else {
                        summary = "Needs an end mill that reaches \(deep) mm." + why
                        fix = "Get an end mill with \(deep) mm of flute." + colletFix
                    }
                }
            }
        }
        return DFMFinding(id: f.id, category: category, title: f.title, summary: summary, details: details,
                          faces: f.faces, remedies: remedies, measure: f.measure, fix: fix)
    }

    /// "1/8\" flat: reaches" lines; a size and kind with different answers lists each tool.
    static func lines(_ entries: [(Tool, String)]) -> [String] {
        var order: [String] = []
        var groups: [String: [(Tool, String)]] = [:]
        for e in entries {
            let k = shortLabel(e.0)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(e)
        }
        var out: [String] = []
        for k in order {
            let g = groups[k]!
            if Set(g.map(\.1)).count == 1 {
                out.append("\(k): \(g[0].1)")
            } else {
                for (t, text) in g {
                    let line = "\(label(t)): \(text)"
                    if !out.contains(line) { out.append(line) }
                }
            }
        }
        return out
    }

    // MARK: Access regions

    /// How deep the outside walls go: the whole part, or with both sides machined, the deeper
    /// of the two halves at the split (side B cuts a little past it).
    static func profileDepth(_ access: PartAccess, _ i: Input) -> Double {
        let top = access.partMax.z, bottom = access.partMin.z
        guard i.twoSided else { return top - bottom }
        let split = Swift.min(Swift.max(i.analysis.partingZ ?? (top + bottom) / 2, bottom), top)
        return Swift.max(top - split, split - bottom) + 0.3
    }

    /// Closed all round: a pocket (or a slot when long); walls on most of it: open at an end;
    /// walls on little of it: a step. Without the measure, by shape alone as before.
    static func floorKind(_ f: PartAccess.Floor, long: Bool) -> String {
        guard let e = f.enclosed else { return long ? "Slot" : "Pocket" }
        if e >= 0.95 { return long ? "Slot" : "Pocket" }
        if e >= 0.5 { return long ? "Open slot" : "Open pocket" }
        return "Step"
    }

    /// The widest cutter that goes in from a side: the region's narrower size across that side
    /// (nil when the region is a lone flat face, which says nothing about the opening).
    static func opening(_ r: PartAccess.Region, from side: String) -> Double? {
        let k = ["x": 0, "y": 1, "z": 2][String(side.dropFirst())] ?? 2
        let size = r.max - r.min
        let across = (0..<3).filter { $0 != k }.map { size[$0] }
        let w = across.min() ?? 0
        return w >= 1 ? w : nil
    }

    public static func sideWords(_ side: String) -> String { side == "-z" ? "back" : sideName(side) }

    static func needed(_ r: PartAccess.Region, _ i: Input) -> [PartAccess.Region.Side] {
        (i.twoSided ? r.sidesTwo : r.sides).filter { $0.side != "+z" }
    }

    /// Regions deepest first; one bore or channel seen through several windows (the same
    /// cross-section, reached deepest from the same side) is one group, judged at its deepest.
    static func regionGroups(_ regions: [PartAccess.Region], _ i: Input) -> [[PartAccess.Region]] {
        func deepest(_ r: PartAccess.Region) -> PartAccess.Region.Side? { needed(r, i).max { $0.depth < $1.depth } }
        let order = regions.sorted { (deepest($0)?.depth ?? 0) > (deepest($1)?.depth ?? 0) }
        var groups: [[PartAccess.Region]] = []
        for r in order {
            if r.thread == nil, r.access != .noAccess, let d = deepest(r),
               let k = ["x": 0, "y": 1, "z": 2][String(d.side.dropFirst())],
               let g = groups.firstIndex(where: { g in
                   guard let first = g.first, first.thread == nil, first.access != .noAccess,
                         deepest(first)?.side == d.side else { return false }
                   return (0..<3).filter { $0 != k }.allSatisfy {
                       abs(first.min[$0] - r.min[$0]) <= 0.1 && abs(first.max[$0] - r.max[$0]) <= 0.1
                   }
               }) {
                groups[g].append(r)
            } else {
                groups.append([r])
            }
        }
        return groups
    }

    static func region(_ r: PartAccess.Region, _ i: Input) -> DFMFinding? {
        let id = "region-\(r.faces.first ?? -1)"
        if let t = r.thread { return cut(from: [t.sides.first?.side ?? "+z"], thread(t, r, id, i)) }
        let s = r.max - r.min
        let size = "\(dims(SIMD3(s.x, s.y, s.z))) mm area"
        switch r.access {
        case .thisSide:
            return nil
        case .noAccess:
            return DFMFinding(id: id, category: .notSupported, title: "No straight path for the tool",
                              summary: "No straight line from the 6 main directions reaches these faces.",
                              details: ["Only the six main directions are checked. Special cutters (T-slot, lollipop) are not."],
                              faces: r.faces, remedies: [], measure: size,
                              fix: "Change the design so the tool can get in, or plan it by hand.")
        case .oppositeSide, .otherDirection:
            let need = needed(r, i)
            if need.isEmpty {
                // Without side depths: the back, or the first side that sees all of it.
                return cut(from: r.access == .oppositeSide ? ["-z"] : Array(r.directions.prefix(1)), legacyRegion(r, id, size, i))
            }
            // Every side the cover uses, the front's share included.
            let all = (i.twoSided ? r.sidesTwo : r.sides).map(\.side)
            return cut(from: all.contains("+z") ? ["+z"] + need.map(\.side) : need.map(\.side), sideRegion(r, need, id, i))
        }
    }

    /// Faces the front doesn't reach: which sides do, and whether a tool you own reaches them
    /// from there (cutter through the opening, flutes and stick-out to the depth).
    static func sideRegion(_ r: PartAccess.Region, _ need: [PartAccess.Region.Side], _ id: String, _ i: Input) -> DFMFinding {
        let checks = need.map { s -> (side: PartAccess.Region.Side, width: Double?, f: DFMFinding) in
            let w = opening(r, from: s.side)
            let f = feature(Feature(id: id, title: "", faces: r.faces, opening: w, wallDepth: s.depth,
                                    holderDepth: s.depth + 1, hole: nil, measure: ""), i)
            return (s, w, f)
        }
        let worst = checks.min { $0.f.category < $1.f.category }!
        let back = need.count == 1 && need[0].side == "-z"
        let names = need.map { sideWords($0.side) }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        let title = back ? "Cut from the back" : need.count == 1 ? "Cut from the \(names[0])" : "Cut from \(need.count) sides"
        let setupFix = back ? (i.twoSided ? "Check side B in Setups." : "Add a back-side setup: turn the part over in Setups.")
            : need.count == 1 ? "Add a setup with the \(names[0]) toward the spindle, in Setups."
            : "Add setups with the \(list) toward the spindle, in Setups."
        let way = back ? (i.twoSided ? "Side B gets to it." : "The tool can't reach it from the front, only from the back.")
            : need.count == 1 ? "The tool can only get in from the \(names[0])."
            : "No one side reaches all of it: it needs the \(list)."
        let measure = checks.map { c in
            "From the \(sideWords(c.side.side)): \(mm(c.side.depth, 0.1)) mm deep" + (c.width.map { ", \(mm($0, 0.1)) mm wide" } ?? "")
        }.joined(separator: ". ") + "."
        var details = checks.count > 1 ? checks.map { "\(sideWords($0.side.side).capitalized): \($0.f.summary)" } : worst.f.details
        details.append(back && i.twoSided ? "Holding on side B is not checked." : "Holding from there is not checked.")
        let where_ = checks.count > 1 ? "From the \(sideWords(worst.side.side)): " : ""
        func lowerFirst(_ t: String) -> String { where_.isEmpty ? t : t.prefix(1).lowercased() + t.dropFirst() }
        switch worst.f.category {
        case .ok, .setupChange:
            return DFMFinding(id: id, category: .setupChange, title: title, summary: "\(way) \(where_)\(lowerFirst(worst.f.summary))",
                              details: details, faces: r.faces, remedies: [.reviewSetups] + worst.f.remedies, measure: measure,
                              fix: [setupFix, worst.f.fix].compactMap { $0 }.joined(separator: " "))
        default:
            let deep = worst.f.category == .notSupported
            // Too deep: the depth is in the measure, so the same bore's places read as one.
            let why = deep && (worst.width ?? 1) >= 0.5 ? "No tool this machine can hold reaches that deep." : worst.f.summary
            return DFMFinding(id: id, category: worst.f.category, title: deep ? "Too deep from the \(sideWords(worst.side.side))" : title,
                              summary: "\(way) \(where_)\(lowerFirst(why))",
                              details: details, faces: r.faces, remedies: worst.f.remedies + [.reviewSetups], measure: measure,
                              fix: deep ? (worst.f.fix.map { "\($0) Or open it up so a shorter tool gets in." } ?? setupFix)
                                  : [worst.f.fix, setupFix].compactMap { $0 }.joined(separator: " "))
        }
    }

    /// Without the engine's side depths: the access alone, reach not checked.
    static func legacyRegion(_ r: PartAccess.Region, _ id: String, _ measure: String, _ i: Input) -> DFMFinding {
        if r.access == .oppositeSide {
            return DFMFinding(id: id, category: .setupChange, title: "Needs the back side",
                              summary: i.twoSided ? "Side B is planned for these faces. Its holding and tool reach are not checked yet."
                                  : "The tool can't reach these faces from the front. Holding and tool reach from the back are not checked yet.",
                              details: ["Turning the part over alone doesn't prove it can be cut."],
                              faces: r.faces, remedies: [.reviewSetups], measure: measure,
                              fix: i.twoSided ? "Check side B in Setups." : "Add a back-side setup: turn the part over in Setups.")
        }
        let from = r.directions.map(sideName).joined(separator: " or the ")
        return DFMFinding(id: id, category: .setupChange, title: "Needs another position",
                          summary: from.isEmpty ? "The tool can't get in from the front or the back."
                              : "The tool can only get in from the \(from).",
                          details: ["Holding and tool reach from there are not checked."],
                          faces: r.faces, remedies: [.reviewSetups], measure: measure,
                          fix: from.isEmpty ? "Add a setup with the part turned, in Setups."
                              : "Add a setup with the \(from) toward the spindle, in Setups.")
    }

    /// A modelled thread: cut along its axis from an open end, with a thread mill that fits the
    /// hole and reaches its far end (or tapped by hand).
    static func thread(_ t: PartAccess.Region.Thread, _ r: PartAccess.Region, _ id: String, _ i: Input) -> DFMFinding {
        let end = t.sides.first ?? .init(side: "+z", depth: t.length, open: true)
        let name = end.side == "+z" ? "front" : sideWords(end.side)
        let title = "Thread \(mm(t.major, 0.1)) mm, \(mm(t.length, 0.1)) long"
        let measure = "\(mm(t.minor, 0.1)) to \(mm(t.major, 0.1)) mm across, \(mm(t.length, 0.1)) mm long, \(mm(end.depth, 0.1)) mm in from the \(name)."
        let mills = i.inventory.tools.filter { $0.kind == .threadMill && $0.quantity > 0 && !$0.isSuggestion && $0.condition != .broken }
        let fits = mills.filter { $0.diameter < t.minor - 0.05 }
        let checked: [(Tool, Reach)] = fits.map { tool in
            (tool, reach(tool: tool, opening: t.minor, wallDepth: end.depth, holderDepth: end.depth + 1, hole: nil,
                         machine: i.machine, inventory: i.inventory))
        }
        func order(_ e: (Tool, Reach)) -> (Int, Double) { (e.1.verdict == .reaches ? 0 : 1, -e.0.diameter) }
        let reaches = checked.filter { $0.1.verdict != .cannot }.sorted { order($0) < order($1) }
        var details = ["Its peaks hide each other, so the check finds it by its shape.",
                       "The pitch is not read from the model. Check it on the drawing.",
                       "Make the \(mm(t.minor, 0.1)) mm hole first."]
        if !end.open { details.append("Neither end reaches the outside. The way in is not checked.") }
        let setupFix = end.side == "+z" ? nil : "Add a setup with the \(name) toward the spindle, in Setups."
        guard let (tool, rr) = reaches.first else {
            details += mills.isEmpty ? ["You have no thread mills."]
                : mills.map { "\(label($0)): " + ($0.diameter >= t.minor - 0.05 ? "too wide for the \(mm(t.minor, 0.1)) mm hole" : "doesn't reach \(mm(end.depth, 0.1)) mm") }
            // One to buy: on your list already, else one Coastline specifies to fit this machine.
            let listed = i.inventory.tools.filter { $0.kind == .threadMill && $0.quantity <= 0 && $0.condition != .broken && $0.diameter < t.minor - 0.05 }
                .first { reach(tool: $0, opening: t.minor, wallDepth: end.depth, holderDepth: end.depth + 1, hole: nil,
                               machine: i.machine, inventory: i.inventory).verdict != .cannot }
            let buy = listed ?? suggestedThreadMill(minor: t.minor, depth: end.depth, i)
            var remedies: [DFMFinding.Remedy] = []
            var fix = "Get a thread mill smaller than the \(mm(t.minor, 0.1)) mm hole that reaches \(mm(end.depth, 0.1)) mm, or tap it by hand."
            if let b = buy {
                let onList = i.inventory.tools.contains { $0.id == b.id }
                remedies.append(onList ? .buyTool(b.id) : .addTool(b))
                fix = onList ? "Buy the \(inline(b.name)), on your list. Or tap it by hand." : "Add a \(inline(b.name)) to buy. Or tap it by hand."
                if !onList { details.append("Coastline suggests: \(spec(b)).") }
            }
            if setupFix != nil { remedies.append(.reviewSetups) }
            return DFMFinding(id: id, category: .missingResource, title: title,
                              summary: "Cut from the \(name). None of your thread mills fits and reaches it."
                                  + (buy == nil ? "" : " One that fits this machine does."),
                              details: details, faces: r.faces, remedies: remedies, measure: measure,
                              fix: fix + (setupFix.map { " " + $0 } ?? ""))
        }
        var remedies: [DFMFinding.Remedy] = setupFix == nil ? [] : [.reviewSetups]
        var fix = setupFix
        if case .needsStickout(let s) = rr.verdict {
            remedies.append(.setStickout(toolID: tool.id, minimum: s))
            fix = [fix, "Set the \(label(tool)) to stick out \(mm(s, 0.1)) mm."].compactMap { $0 }.joined(separator: " ")
        }
        return DFMFinding(id: id, category: setupFix == nil && fix == nil ? .ok : .setupChange, title: title,
                          summary: "Cut from the \(name) with the \(label(tool)).", details: details, faces: r.faces,
                          remedies: remedies, measure: measure, fix: fix)
    }

    // MARK: Corners, curves, thin walls

    static func shapeFindings(_ i: Input) -> [DFMFinding] {
        let a = i.analysis
        let usable = OperationPlanner.usableTools(i.inventory, machine: i.machine)
        var out: [DFMFinding] = []
        if let r = a.minCornerRadius {
            let title = "Inside corners R\(mm(r)) mm"
            let flats = usable.filter { $0.kind == .flatEndMill || $0.kind == .bullNoseEndMill }
            if let t = flats.filter({ $0.diameter <= 2 * r * 0.98 }).max(by: { $0.diameter < $1.diameter }) {
                out.append(DFMFinding(id: "corner", category: .ok, title: title, summary: "The \(label(t)) fits the tightest corner."))
            } else if let buy = Feasibility.standardSizes.filter({ $0 <= 2 * r * 0.98 }).max() {
                out.append(DFMFinding(id: "corner", category: .missingResource, title: title,
                                      summary: "None of your end mills is small enough for the tightest inside corner.",
                                      fix: "Get a \(size(buy)) or smaller end mill, or accept rounder corners."))
            } else {
                out.append(DFMFinding(id: "corner", category: .notSupported, title: title, summary: "Too tight for any end mill.",
                                      fix: "Round the inside corners to at least R0.3 mm."))
            }
        }
        if let r = a.minConcaveRadius {
            let title = "Curves down to R\(mm(r)) mm"
            if let t = usable.filter({ $0.kind == .ballEndMill && $0.diameter / 2 <= r * 0.98 }).max(by: { $0.diameter < $1.diameter }) {
                out.append(DFMFinding(id: "concave", category: .ok, title: title, summary: "The \(label(t)) fits them."))
            } else {
                let buy = Feasibility.standardSizes.filter { $0 / 2 <= r * 0.98 }.max()
                out.append(DFMFinding(id: "concave", category: .missingResource, title: title,
                                      summary: "None of your ball end mills is small enough for a clean finish there.",
                                      fix: "Get a \(buy.map(size) ?? "under 0.5 mm") or smaller ball end mill."))
            }
        }
        // Below 0.1 mm the slice search is at its limit: a reading, not a wall.
        if let w = a.thinnestWall, w < 0.5, w >= 0.1 {
            out.append(DFMFinding(id: "thin", category: .missingInformation, title: "Thin wall, about \(mm(w)) mm",
                                  summary: "Rough measure. Strength is not checked.",
                                  fix: "Check it can take the cutting load, or make it thicker."))
        }
        return out
    }

    // MARK: Tools the planner can't use

    /// Owned tools OperationPlanner leaves out, with why: one finding for missing collets or
    /// machine limits, one for unconfirmed specifications. Broken tools are skipped.
    static func toolFindings(_ i: Input) -> [DFMFinding] {
        let m = i.machine
        let usable = Set(OperationPlanner.usableTools(i.inventory, machine: m).map(\.id))
        var blocked: [(Tool, String)] = [], unconfirmed: [(Tool, String)] = []
        var collets: [Double] = []
        var shown: [UUID] = []
        for t in i.inventory.tools where t.quantity > 0 && !t.isSuggestion && t.condition != .broken && !usable.contains(t.id) {
            if t.requiresSpecificationReview || !ResourceLibraryValidation.issues(for: t).isEmpty {
                let fields = (t.unconfirmedSpecifications ?? []).joined(separator: ", ")
                unconfirmed.append((t, "confirm its specs" + (fields.isEmpty ? "" : " (\(fields))")))
                continue
            }
            var why: [String] = []
            if t.shankDiameter > m.maxShankDiameter + 1e-6 { why.append("shank over the \(m.colletName) limit (\(mm(m.maxShankDiameter)) mm)") }
            if t.overallLength > m.maxToolLength + 1e-6 { why.append("\(mm(t.overallLength)) mm long, over the \(mm(m.maxToolLength)) mm limit") }
            let needsCollet = t.shankDiameter <= m.maxShankDiameter + 1e-6 && !hasCollet(t, i.inventory)
            if needsCollet {
                why.append("no collet for its \(size(t.shankDiameter)) shank")
                if !collets.contains(where: { abs($0 - t.shankDiameter) <= 0.05 }) { collets.append(t.shankDiameter) }
            }
            guard !why.isEmpty else { continue }
            if why.count > (needsCollet ? 1 : 0) { shown.append(t.id) }
            blocked.append((t, why.joined(separator: "; ")))
        }
        var out: [DFMFinding] = []
        if !blocked.isEmpty {
            let n = blocked.count
            out.append(DFMFinding(id: "tools", category: .missingResource, title: "Tools you can't use",
                                  summary: "\(n) owned tool\(n == 1 ? "" : "s") can't be used: no collet or over the machine's limits.",
                                  details: lines(blocked), remedies: collets.sorted().map { .addCollet($0) } + shown.map { .showTool($0) },
                                  fix: collets.isEmpty ? "They don't fit this machine. Use other tools."
                                      : "Add a \(collets.sorted().map(size).joined(separator: " and ")) collet to use \(collets.count == 1 ? "that size" : "those sizes")."))
        }
        if !unconfirmed.isEmpty {
            let n = unconfirmed.count
            out.append(DFMFinding(id: "tools-info", category: .missingInformation, title: "Tool specs not confirmed",
                                  summary: "\(n) owned tool\(n == 1 ? " needs its" : "s need their") specs confirmed before CAM.",
                                  details: lines(unconfirmed), remedies: unconfirmed.map { .showTool($0.0.id) },
                                  fix: "Measure them and confirm their specs in Tools."))
        }
        return out
    }

    // MARK: Words and numbers

    static func hasCollet(_ t: Tool, _ inventory: Inventory) -> Bool {
        inventory.colletSizes.contains { abs($0 - t.shankDiameter) <= InventoryChecks.colletTolerance }
    }

    /// Rounded to `step` first, so measured noise (19.998) reads as the designed size. Tool
    /// sizes keep their 3 decimals (9.525); measured widths use 0.01 (the engine's inscribed
    /// circle reads a 2 mm slot as 1.996).
    static func mm(_ v: Double, _ step: Double = 0.001) -> String { Length.mm((v / step).rounded() * step) }

    /// "1/4\"" when it is a common inch size, else "6 mm".
    static func size(_ d: Double) -> String { Length.inchFraction(d) ?? "\(mm(d)) mm" }

    static func dims(_ v: SIMD3<Double>) -> String { "\(mm(v.x, 0.1)) x \(mm(v.y, 0.1)) x \(mm(v.z, 0.1))" }

    /// "1/4\" flat": size and kind.
    static func shortLabel(_ t: Tool) -> String {
        let kind: String = switch t.kind {
        case .flatEndMill: "flat"
        case .ballEndMill: "ball"
        case .bullNoseEndMill: "bull nose"
        case .chamferMill: "chamfer"
        case .engraver: "engraver"
        case .drill: "drill"
        case .spotDrill: "spot drill"
        case .threadMill: "thread mill"
        case .faceMill: "face mill"
        }
        return "\(size(t.diameter)) \(kind)"
    }

    /// "1/8\" flat 81635": with the part number (or what follows "·" in the name) to tell tools apart.
    static func label(_ t: Tool) -> String {
        let part = t.partNumber.trimmingCharacters(in: .whitespaces)
        if !part.isEmpty { return "\(shortLabel(t)) \(part)" }
        if let tail = t.name.split(separator: "·").dropFirst().first?.trimmingCharacters(in: .whitespaces), !tail.isEmpty {
            return "\(shortLabel(t)) \(tail)"
        }
        return t.name
    }

    /// A work-frame side or direction in plain words, relative to the part as set up.
    public static func sideName(_ s: String) -> String {
        switch s {
        case "+z": "front"
        case "-z": "back"
        case "+x": "upper side"
        case "-x": "lower side"
        case "+y": "right side"
        case "-y": "left side"
        default: s
        }
    }
}
