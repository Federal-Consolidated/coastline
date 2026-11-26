import Foundation

// K10. Consumables: an ID for every physical bit, wear per bit from the material it cut and the
// pace it ran at, a forecast before the job, what wear does to the part, a gentler cut for a worn
// bit, and life estimates that learn from what the user reports.

/// One physical bit inside a tool entry (a box of three 1/8" flats is one `Tool`, three units).
/// The label is written on its box or tube, so the bit in the collet can be named.
public struct ToolUnit: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Short ID for the box, e.g. "T-014".
    public var label: String
    /// Share of the *estimated* life used (Σ minutes / ToolWear.life for the material and
    /// pace of each job). The learned factor divides it: `Consumables.wear`.
    public var load: Double
    public var minutes: Double
    /// Cutting distance, mm.
    public var distance: Double
    public var condition: Tool.Condition
    public var firstUsed: Date?
    /// Taken out of use (worn out, broken, thrown away). Kept for the history.
    public var retired: Date?
    public var notes: String

    public init(id: UUID = UUID(), label: String, load: Double = 0, minutes: Double = 0, distance: Double = 0,
                condition: Tool.Condition = .new, firstUsed: Date? = nil, retired: Date? = nil, notes: String = "") {
        self.id = id
        self.label = label
        self.load = load
        self.minutes = minutes
        self.distance = distance
        self.condition = condition
        self.firstUsed = firstUsed
        self.retired = retired
        self.notes = notes
    }

    public var isActive: Bool { retired == nil && condition != .broken }
}

/// Wear levels the app acts on.
public enum WearPolicy {
    /// From here the feeds engine cuts gentler (worn-bit mode).
    public static let wornMode = 0.6
    /// From here a fresh bit is recommended, at least for finishing.
    public static let swapAt = 0.85
}

/// Where a bit is in its life, and what that does to the part.
public enum WearStage: Int, Comparable, CaseIterable, Sendable {
    case new, wornIn, dulling, nearEnd, wornOut

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public static func of(_ wear: Double) -> WearStage {
        switch wear {
        case ..<0.1: .new
        case ..<WearPolicy.wornMode: .wornIn
        case ..<WearPolicy.swapAt: .dulling
        case ..<1: .nearEnd
        default: .wornOut
        }
    }

    public var title: String {
        switch self {
        case .new: "Sharp"
        case .wornIn: "Worn in"
        case .dulling: "Dulling"
        case .nearEnd: "Near its end"
        case .wornOut: "Worn out"
        }
    }

    public var symbol: String {
        switch self {
        case .new, .wornIn: "checkmark.circle"
        case .dulling: "circle.lefthalf.filled"
        case .nearEnd: "exclamationmark.triangle"
        case .wornOut: "xmark.octagon"
        }
    }

    /// What this stage does to the part, in plain words, for this tool in this material.
    public func effects(tool: Tool, material: Material) -> [String] {
        let small = tool.diameter < 3
        let sticky = material.family == .aluminium || material.family == .copperAlloy
        let melts = [.plastic, .printedResin, .wax].contains(material.family)
        let hardens = material.family == .stainless || material.family == .titanium
        var out: [String] = []
        switch self {
        case .new:
            out.append("A sharp edge cuts cleanly. The first few minutes hone it slightly; that is normal.")
        case .wornIn:
            out.append("The edge has settled and cuts steadily. Finish and size are as planned.")
        case .dulling:
            out.append("The cutting edge is rounding, so it starts to rub instead of shearing: more heat and more force on the tool.")
            if sticky { out.append("In \(material.name) the heat makes chips weld onto the edge (built-up edge): smeared walls and burrs on the top edges.") }
            if melts { out.append("In \(material.name) the extra heat melts the surface instead of cutting it: fuzzy, gummy edges.") }
            if hardens { out.append("\(material.name) hardens where the edge rubs, which wears the bit faster still.") }
            out.append("Coastline runs it gentler from here (lower speed, lighter cuts): slower, but the edge lasts and the finish holds.")
        case .nearEnd:
            out.append("The blunt edge pushes the tool away from the wall: walls come out a little oversize and floors show steps.")
            out.append("The finish gets visibly rougher and chatter becomes more likely.")
            if small { out.append("A bit under 3 mm can snap at this stage, and a broken bit can mark or scrap the part.") }
            out.append("Use a fresh bit for finishing; this one can still rough.")
        case .wornOut:
            out.append("Past its expected life: rubbing, heat and deflection all rise sharply, and it may break mid-cut.")
            out.append("Replace it. If it still cuts well, mark it so: Coastline learns that this kind of bit lasts longer.")
        }
        return out
    }
}

/// Life estimates corrected by what the user reports: a bit marked worn early means this kind
/// wears faster than estimated; one still cutting cleanly past its life means it lasts longer.
/// One factor per tool kind and tool material, bounded to 0.3 … 3.
public struct ToolLifeLearning: Codable, Equatable, Sendable {
    public var factors: [String: Double] = [:]
    public var observations: [String: Int] = [:]
    public init() {}

    public static func key(_ t: Tool) -> String { "\(t.kind.rawValue)|\(t.toolMaterial.rawValue)" }
    public func factor(for t: Tool) -> Double { factors[Self.key(t)] ?? 1 }

    /// The user says this unit is done at `load` of the estimate: its real life was `load` × the
    /// estimate. Blended in log space; the first report counts half, later ones less.
    public mutating func reportWornOut(tool: Tool, load: Double) {
        guard load.isFinite, load > 0.05 else { return }
        let k = Self.key(tool)
        let n = observations[k] ?? 0
        let w = max(0.5 / Double(n + 1), 0.15)
        let f = factors[k] ?? 1
        let next = exp((1 - w) * log(f) + w * log(min(max(load, 0.3), 3)))
        factors[k] = min(max(next, 0.3), 3)
        observations[k] = n + 1
    }

    /// A rough finish or chatter on a dulling bit: it wears a little faster than estimated. A
    /// clean, fine finish from a bit past its estimate: a little slower.
    public mutating func learn(finish: Int, chatter: Bool, tool: Tool, wear: Double) {
        let k = Self.key(tool)
        var f = factors[k] ?? 1
        if (finish <= 2 || chatter) && wear >= 0.5 { f *= 0.95 }
        else if finish >= 4 && !chatter && wear >= 0.9 { f *= 1.03 }
        else { return }
        factors[k] = min(max(f, 0.3), 3)
    }
}

/// IDs, wear and the forecast.
public enum Consumables {
    /// "T-014".
    public static func toolLabel(_ n: Int) -> String { String(format: "T-%03d", n) }

    /// Gives every owned tool one unit per bit (labels numbered across the inventory) and moves
    /// usage recorded before units existed onto the first one. Safe to run on every change.
    /// Returns true when it changed anything.
    @discardableResult
    public static func normalize(_ inv: inout Inventory) -> Bool {
        let before = inv
        var next = max(inv.nextUnitNumber ?? 1, highestLabel(inv) + 1)
        func newLabel() -> String { defer { next += 1 }; return toolLabel(next) }
        let al = MaterialLibrary.material(id: "al-6061") ?? MaterialLibrary.all[0]
        for k in inv.tools.indices {
            var t = inv.tools[k]
            let wanted = max(t.quantity, 0)
            var units = t.units ?? []
            if t.units == nil, wanted > 0 {
                // Usage recorded before units: on the first bit, judged in aluminium as before.
                var first = ToolUnit(label: newLabel(), minutes: t.cuttingMinutes, distance: t.cuttingDistance, condition: t.condition)
                first.load = t.cuttingMinutes / max(ToolWear.life(tool: t, material: al, pace: 1), 1)
                units = [first]
            }
            var active = units.filter(\.isActive).count
            while active < wanted { units.append(ToolUnit(label: newLabel())); active += 1 }
            // Fewer bits than units: unused ones go first, then the most worn is retired.
            while active > wanted {
                if let i = units.lastIndex(where: { $0.isActive && $0.minutes == 0 && $0.load == 0 }) {
                    units.remove(at: i)
                } else if let i = units.indices.filter({ units[$0].isActive }).max(by: { units[$0].load < units[$1].load }) {
                    units[i].retired = Date()
                }
                active -= 1
            }
            if units.isEmpty && t.units == nil { continue }
            t.units = units
            if let l = t.loadedUnitID, !units.contains(where: { $0.id == l && $0.isActive }) { t.loadedUnitID = nil }
            inv.tools[k] = t
        }
        if next != (inv.nextUnitNumber ?? 1) { inv.nextUnitNumber = next }
        return inv != before
    }

    private static func highestLabel(_ inv: Inventory) -> Int {
        inv.tools.flatMap { $0.units ?? [] }.compactMap { Int($0.label.dropFirst(2)) }.max() ?? 0
    }

    public static func activeUnits(_ t: Tool) -> [ToolUnit] { (t.units ?? []).filter(\.isActive) }

    /// The bit in use: the one marked loaded, else the most worn one still usable (use bits up in
    /// order rather than dulling all of them at once).
    public static func loadedUnit(_ t: Tool, learning: ToolLifeLearning? = nil) -> ToolUnit? {
        let active = activeUnits(t)
        if let id = t.loadedUnitID, let u = active.first(where: { $0.id == id }) { return u }
        let f = learning?.factor(for: t) ?? 1
        return active.filter { $0.load / f < WearPolicy.swapAt }.max { $0.load < $1.load }
            ?? active.min { $0.load < $1.load }
    }

    /// Share of the life used, after what the user's reports taught.
    public static func wear(_ u: ToolUnit, tool: Tool, learning: ToolLifeLearning?) -> Double {
        u.load / (learning?.factor(for: tool) ?? 1)
    }

    public static func find(label: String, in inv: Inventory) -> (tool: Tool, unit: ToolUnit)? {
        let l = label.trimmingCharacters(in: .whitespaces).uppercased()
        for t in inv.tools { if let u = (t.units ?? []).first(where: { $0.label.uppercased() == l }) { return (t, u) } }
        return nil
    }

    /// Takes a unit out of use: it's worn out or broken. Lowers the quantity and teaches the
    /// life estimate (unless it broke: a break says little about wear).
    public static func retire(unit unitID: UUID, of toolID: UUID, broken: Bool = false, in inv: inout Inventory) {
        guard let k = inv.tools.firstIndex(where: { $0.id == toolID }),
              let i = inv.tools[k].units?.firstIndex(where: { $0.id == unitID }) else { return }
        let u = inv.tools[k].units![i]
        guard u.isActive else { return }
        if !broken {
            var learning = inv.lifeLearning ?? ToolLifeLearning()
            learning.reportWornOut(tool: inv.tools[k], load: u.load)
            inv.lifeLearning = learning
        }
        inv.tools[k].units![i].retired = Date()
        inv.tools[k].units![i].condition = broken ? .broken : .worn
        inv.tools[k].quantity = max(inv.tools[k].quantity - 1, 0)
        if inv.tools[k].loadedUnitID == unitID { inv.tools[k].loadedUnitID = nil }
    }

    /// Adds wear to a unit for minutes cut in a material at a pace.
    public static func addWear(minutes: Double, distance: Double, tool toolID: UUID, unit unitID: UUID?, material: Material,
                               pace: Double, toolSaver: Bool, date: Date, in inv: inout Inventory) -> ToolUnit? {
        guard let k = inv.tools.firstIndex(where: { $0.id == toolID }) else { return nil }
        let t = inv.tools[k]
        guard var units = t.units, !units.isEmpty else { return nil }
        let id = unitID.flatMap { u in units.contains { $0.id == u && $0.isActive } ? u : nil }
            ?? loadedUnit(t, learning: inv.lifeLearning)?.id
        guard let i = units.firstIndex(where: { $0.id == id }) else { return nil }
        units[i].load += minutes / max(ToolWear.life(tool: t, material: material, pace: pace, toolSaver: toolSaver), 1)
        units[i].minutes += minutes
        units[i].distance += distance
        if units[i].firstUsed == nil { units[i].firstUsed = date }
        if units[i].condition == .new, units[i].load > 0.05 { units[i].condition = .good }
        inv.tools[k].units = units
        return units[i]
    }

    // MARK: Forecast

    /// One tool load in the job: a program, the tool, how long it cuts, whether it finishes.
    public struct ProgramLoad: Sendable {
        public var program: Int
        public var title: String
        public var tool: Tool
        public var minutes: Double
        public var finishes: Bool
        public init(program: Int, title: String, tool: Tool, minutes: Double, finishes: Bool) {
            self.program = program
            self.title = title
            self.tool = tool
            self.minutes = minutes
            self.finishes = finishes
        }
    }

    public struct ForecastItem: Identifiable, Sendable {
        public var id: Int { program }
        public var program: Int
        public var title: String
        public var tool: Tool
        public var unit: ToolUnit?
        public var before: Double
        public var after: Double
        /// The bit that would have been used, when Coastline suggests another.
        public var swappedFrom: ToolUnit?
        public var advice: String?
        public var stage: WearStage { WearStage.of(after) }
        public var wornMode: Bool { before >= WearPolicy.wornMode }
    }

    /// Which bit each program should use, and its wear before and after. A program that
    /// finishes moves to the freshest bit when its bit would pass `swapAt`; one that only roughs
    /// keeps a worn bit until it would pass its life (the last of a bit's life goes where it
    /// doesn't show).
    public static func forecast(_ loads: [ProgramLoad], inventory inv: Inventory, material: Material, pace: Double,
                                toolSaver: Bool) -> [ForecastItem] {
        let learning = inv.lifeLearning
        var sim: [UUID: Double] = [:]  // unit → simulated wear
        var current: [UUID: UUID] = [:]  // tool → unit in the collet
        var out: [ForecastItem] = []
        for l in loads {
            let t = inv.tools.first { $0.id == l.tool.id } ?? l.tool
            let units = activeUnits(t)
            let f = learning?.factor(for: t) ?? 1
            let add = l.minutes / max(ToolWear.life(tool: t, material: material, pace: pace, toolSaver: toolSaver) * f, 1)
            func wear(_ u: ToolUnit) -> Double { sim[u.id] ?? u.load / f }
            guard !units.isEmpty else {
                out.append(ForecastItem(program: l.program, title: l.title, tool: t, unit: nil, before: 0, after: 0, swappedFrom: nil,
                                        advice: t.units == nil ? nil : "No usable bit of this tool left."))
                continue
            }
            let start = current[t.id].flatMap { id in units.first { $0.id == id } } ?? loadedUnit(t, learning: learning) ?? units[0]
            var pick = start
            var swapped: ToolUnit?
            var advice: String?
            let limit = l.finishes ? WearPolicy.swapAt : 1.0
            if wear(start) + add > limit {
                let others = units.filter { $0.id != start.id && wear($0) + add <= limit }
                // Finishing: the freshest. Roughing: the most worn that still lasts.
                let alt = l.finishes ? others.min { wear($0) < wear($1) } : others.max { wear($0) < wear($1) }
                if let alt {
                    pick = alt
                    swapped = start
                    advice = l.finishes
                        ? "Load \(alt.label) for this program: \(start.label) would end at \(pct(wear(start) + add)), too worn for a finish that shows. \(start.label) can still rough."
                        : "Load \(alt.label): \(start.label) would pass its expected life in this program."
                } else {
                    advice = units.count == 1
                        ? "\(start.label) would end at \(pct(wear(start) + add)) and there is no spare. Order one, or turn on Save tools."
                        : "Every bit of this tool would end above \(pct(limit)). Order fresh ones, or turn on Save tools."
                }
            }
            let before = wear(pick)
            sim[pick.id] = before + add
            current[t.id] = pick.id
            if advice == nil, before >= WearPolicy.wornMode {
                advice = "\(pick.label) is dulling: this program runs in worn-bit mode (lower speed, lighter cuts)."
            }
            out.append(ForecastItem(program: l.program, title: l.title, tool: t, unit: pick, before: before, after: before + add,
                                    swappedFrom: swapped, advice: advice))
        }
        return out
    }

    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
}

// MARK: Feeds for a worn bit and for saving tools

public enum WearAwareFeeds {
    /// Save tools: surface speed this much lower, chip load kept (Taylor: life ≈ ×1.9).
    public static let saverSpeed = 0.85

    /// How much slower a worn bit spins (1 at `wornMode`, down to 0.8 when worn out).
    public static func wornSpeed(_ wear: Double) -> Double {
        let s = min(max((wear - WearPolicy.wornMode) / (1 - WearPolicy.wornMode), 0), 1)
        return 1 - 0.2 * s
    }

    /// Lowers the spindle speed by `factor` and the feeds with it, so each tooth still takes the
    /// same chip (a dull edge that takes a thinner chip only rubs). Respects the machine's minimum.
    static func slowSpindle(_ data: inout CuttingData, by factor: Double, machine: MachineProfile) -> Double {
        let rpm = max(data.rpm * factor, machine.spindleRPM.lowerBound)
        let f = rpm / max(data.rpm, 1)
        guard f < 0.999 else { return 1 }
        data.rpm = rpm.rounded()
        data.feed = (data.feed * f).rounded()
        data.plungeFeed = (data.plungeFeed * f).rounded()
        data.rampFeed = (data.rampFeed * f).rounded()
        return f
    }

    public static func applyWorn(_ data: inout CuttingData, wear: Double, kind: OperationKind, machine: MachineProfile) {
        guard wear >= WearPolicy.wornMode else { return }
        let s = min(max((wear - WearPolicy.wornMode) / (1 - WearPolicy.wornMode), 0), 1)
        let f = slowSpindle(&data, by: wornSpeed(wear), machine: machine)
        var lighter = false
        switch kind {
        case .adaptive, .facing:
            data.stepover *= 1 - 0.2 * s
            data.stepdown *= 1 - 0.15 * s
            lighter = s > 0
        case .contour:
            data.stepdown *= 1 - 0.15 * s
            lighter = s > 0
        default: break
        }
        data.notes.append("Worn bit (\(Consumables.pct(wear)) of its life): spindle \(Int((f * 100).rounded())) %\(lighter ? ", lighter cuts" : ""), chip per tooth kept so the dull edge still cuts instead of rubbing.")
    }

    public static func applySaver(_ data: inout CuttingData, machine: MachineProfile) {
        let f = slowSpindle(&data, by: saverSpeed, machine: machine)
        if f < 0.999 {
            data.notes.append("Save tools: spindle \(Int((f * 100).rounded())) % with the same chip per tooth; the edge runs cooler and lasts about \(String(format: "%.1f", pow(f, -4)))× as long.")
        } else {
            data.notes.append("Save tools: the spindle is already at the machine's minimum, so the speed can't drop further here.")
        }
    }
}
