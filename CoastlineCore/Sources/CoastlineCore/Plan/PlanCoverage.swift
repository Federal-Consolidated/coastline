import Foundation

/// How much stock the machine takes with a given side toward the spindle. On the horizontal
/// spindle mill the stock lies on the table with its face at the table's spindle-side edge; the
/// rest lies across the table and may hang past its far edge, as long as it clears the machine
/// over the whole travel (MachinePlanningGeometry.roomBehindTable). The enclosure counts apart:
/// stock that only meets it fits with the enclosure open.
public struct SetupRoom: Sendable, Equatable {
    /// How far the stock may hang past the table's far edge for one side's turn, mm.
    public struct Turn: Sendable, Equatable {
        /// With the enclosure in place.
        public var behind: Double
        /// Without it (only the machine itself).
        public var behindOpen: Double
        public init(behind: Double, behindOpen: Double) { (self.behind, self.behindOpen) = (behind, behindOpen) }
    }

    public enum Fit: Sendable, Equatable {
        case fits
        /// Fits only with the enclosure open; why, in a sentence.
        case enclosureOpen(String)
        /// Doesn't fit; why.
        case no(String)
    }

    /// How deep the table's seating surface is toward the spindle, mm.
    public var tableDepth: Double
    /// Per side ("+x" ...). A side without an entry counts the table alone.
    public var turns: [String: Turn]
    public init(tableDepth: Double, turns: [String: Turn] = [:]) { (self.tableDepth, self.turns) = (tableDepth, turns) }

    /// Whether stock of this size (work frame: X up, Y across, Z toward the spindle) fits with
    /// this side toward the spindle.
    public func fit(_ size: SIMD3<Double>, side: String) -> Fit {
        let past = size.z - tableDepth
        guard past > 0.05 else { return .fits }
        let turn = turns[side] ?? Turn(behind: 0, behindOpen: 0)
        let depth = "It is \(DFM.mm(size.z, 0.1)) mm deep that way, \(DFM.mm(past, 0.1)) mm past the \(DFM.mm(tableDepth, 0.1)) mm table"
        if past <= turn.behind + 0.05 { return .fits }
        if past <= turn.behindOpen + 0.05 {
            return .enclosureOpen("\(depth). That fits with the enclosure open: its panel leaves \(DFM.mm(turn.behind, 0.1)) mm.")
        }
        return .no("\(depth), and the machine leaves \(DFM.mm(turn.behindOpen, 0.1)) mm there.")
    }

    /// nil when it fits (or fits with the enclosure open), else why not.
    public func problem(_ size: SIMD3<Double>, side: String) -> String? {
        if case .no(let why) = fit(size, side: side) { return why }
        return nil
    }

    /// The stock's size with this side toward the spindle, from its size in the first setup:
    /// turned about Y for the upper and lower sides, about X for the ends.
    public static func size(_ stock: SIMD3<Double>, facing side: String) -> SIMD3<Double> {
        switch side.dropFirst() {
        case "x": SIMD3(stock.z, stock.y, stock.x)
        case "y": SIMD3(stock.x, stock.z, stock.y)
        default: stock
        }
    }
}

/// What a job's setups cut, read from the part check (DFM): the features each setup makes, and
/// the ones no setup makes: they need a side the plan doesn't machine, a tool the plan doesn't
/// use, or can't be machined. Line of sight and reach only: whether the toolpaths really clear
/// each feature is for the simulation. Every one of the stock's six sides is considered.
public struct PlanCoverage: Sendable, Equatable {
    /// The six sides in the order setups take them: the front, the back, then the long sides
    /// and the ends.
    public static let sides = ["+z", "-z", "+x", "-x", "+y", "-y"]

    public struct SetupCut: Sendable, Equatable, Identifiable {
        /// The side toward the spindle: "+z" the front, "-z" the back, "+x" the upper side ...
        public var side: String
        /// 1, 2, 3 ... in the order of the job.
        public var number: Int
        /// The findings (features) it cuts, problems and OK ones, in the check's order.
        public var findings: [String]
        public var titles: [String]
        public var faces: [Int]
        /// Coastline makes this setup's toolpaths (false: the setup is proposed only).
        public var toolpaths: Bool
        /// A condition for this setup, e.g. the enclosure open for stock hanging past the table.
        public var note: String? = nil
        public var id: String { side }
    }

    /// A side no setup uses, and why.
    public struct Unused: Sendable, Equatable, Identifiable {
        public var side: String
        /// Why not: it doesn't fit the machine, or nothing needs it.
        public var why: String
        public var fits: Bool
        public var id: String { side }
    }

    public struct Gap: Sendable, Equatable, Identifiable {
        public enum Reason: Sendable, Equatable {
            case cannotMachine
            /// Sides no setup of the plan comes from.
            case needsSides([String])
            /// None of the tools that reach it is in the plan.
            case needsTool
            /// It is cut from this side, and the stock doesn't fit the machine that way.
            case noRoom(String)
        }
        public var finding: String
        public var title: String
        public var category: DFMFinding.Category
        public var reason: Reason
        public var faces: [Int]
        public var id: String { finding }

        /// Why it is not in the plan, and what to do, in one or two short sentences.
        public var text: String {
            switch reason {
            case .cannotMachine:
                return "Can't be machined as drawn."
            case .needsSides(let sides):
                let names = sides.map(DFM.sideWords)
                let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
                return sides == ["-z"] ? "Needs a setup from the back. Turn on Machine both sides in Setups."
                    : "Needs a setup from the \(list). The plan has no setup from there yet."
            case .needsTool:
                return "Needs a tool the plan doesn't use. Add it to buy, then build again."
            case .noRoom(let side):
                return "Cut from the \(DFM.sideWords(side)), and the stock doesn't fit the machine that way."
            }
        }
    }

    public var setups: [SetupCut]
    /// The other sides, each with why no setup uses it.
    public var unused: [Unused]
    public var gaps: [Gap]
    /// Findings in setups whose toolpaths Coastline doesn't make yet.
    public var waiting: [String]
    /// Findings the plan cuts with a tool still to buy.
    public var withToolsToBuy: [String]
    /// Features not made by the toolpaths: gaps and the ones waiting for their setup.
    public var open: Int { gaps.count + waiting.count }
    public var complete: Bool { open == 0 }

    /// Notes about the tools, the stock or the CAD: not cuts.
    static let notes: Set<String> = ["tools", "tools-info", "exact", "stock", "thin"]

    public static func isCut(_ f: DFMFinding) -> Bool { !notes.contains(f.id) && f.category != .missingInformation }

    /// The fewest sides that cut the most features, every one of the six considered (the front
    /// always: the job starts there). A side that doesn't fit the machine makes its findings
    /// "can't be machined" in the part check, so no setup is proposed there.
    public static func propose(_ findings: [DFMFinding]) -> [String] {
        let needs = findings.filter { isCut($0) && $0.category != .notSupported && !$0.sides.isEmpty }.map { Set($0.sides) }
        var best: (covered: Int, count: Int, sides: Set<String>) = (-1, 0, [])
        for mask in 0..<(1 << sides.count) where mask & 1 == 1 {
            let chosen = Set(sides.indices.filter { mask >> $0 & 1 == 1 }.map { sides[$0] })
            let covered = needs.filter { $0.isSubset(of: chosen) }.count
            if covered > best.covered || (covered == best.covered && chosen.count < best.count) {
                best = (covered, chosen.count, chosen)
            }
        }
        return sides.filter(best.sides.contains)
    }

    /// - Parameters:
    ///   - findings: the part check for the job as set up (its sides follow `twoSided`).
    ///   - sides: the sides the plan's setups cut from, any order (taken in `sides` order).
    ///   - jobTools: the tools the plan's operations use.
    ///   - toolpathSides: the sides Coastline makes toolpaths for (nil: all of them).
    ///   - room, stock: the machine's room and the stock's size in the first setup, to say why a
    ///     side no setup uses doesn't fit.
    public static func assess(_ findings: [DFMFinding], sides chosen: [String], jobTools: Set<UUID>,
                              toolpathSides: Set<String>? = nil, room: SetupRoom? = nil,
                              stock: SIMD3<Double>? = nil) -> PlanCoverage {
        let order = sides.filter(chosen.contains)
        var setups = order.enumerated().map { k, side in
            SetupCut(side: side, number: k + 1, findings: [], titles: [], faces: [], toolpaths: toolpathSides?.contains(side) ?? true)
        }
        func noRoom(_ side: String) -> String? {
            guard let room, let stock else { return nil }
            return room.problem(SetupRoom.size(stock, facing: side), side: side)
        }
        if let room, let stock {
            for k in setups.indices {
                if case .enclosureOpen(let why) = room.fit(SetupRoom.size(stock, facing: setups[k].side), side: setups[k].side) {
                    setups[k].note = why
                }
            }
        }
        var gaps: [Gap] = []
        var waiting: [String] = []
        var toBuy: [String] = []
        for f in findings where isCut(f) {
            func gap(_ r: Gap.Reason) { gaps.append(Gap(finding: f.id, title: f.title, category: f.category, reason: r, faces: f.faces)) }
            if let side = f.sides.first(where: { noRoom($0) != nil }) { gap(.noRoom(side)); continue }
            let missing = f.sides.filter { !order.contains($0) }
            if f.category == .notSupported { gap(.cannotMachine); continue }
            if !missing.isEmpty { gap(.needsSides(missing)); continue }
            if f.category == .missingResource {
                // Only the tools to buy that reach it: an owned one that doesn't is why it's here.
                let tools = f.remedies.compactMap { r -> UUID? in
                    switch r {
                    case .buyTool(let id): id
                    case .addTool(let t): t.id
                    default: nil
                    }
                }
                if tools.contains(where: jobTools.contains) { toBuy.append(f.id) } else { gap(.needsTool) }
            }
            // The setup lists it even while it waits for a tool: that side is still where it's cut.
            for side in f.sides {
                guard let k = setups.firstIndex(where: { $0.side == side }) else { continue }
                setups[k].findings.append(f.id)
                setups[k].titles.append(f.title)
                for face in f.faces where !setups[k].faces.contains(face) { setups[k].faces.append(face) }
            }
            if gaps.last?.finding != f.id,
               f.sides.contains(where: { side in setups.first { $0.side == side }?.toolpaths == false }) { waiting.append(f.id) }
        }
        let unused = sides.filter { !order.contains($0) }.map { side -> Unused in
            if let why = noRoom(side) { return Unused(side: side, why: "Doesn't fit the machine. \(why)", fits: false) }
            let needed = findings.contains { isCut($0) && $0.sides.contains(side) }
            return Unused(side: side, why: needed ? "Its features can't be made from there." : "Nothing needs it.", fits: true)
        }
        return PlanCoverage(setups: setups, unused: unused, gaps: gaps, waiting: waiting, withToolsToBuy: toBuy)
    }
}
