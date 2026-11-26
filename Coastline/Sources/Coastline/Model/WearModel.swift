import CoastlineCore
import Foundation

/// K10: which bit cuts each program, its wear before and after, and the worn-bit mode.
extension AppModel {
    /// Operations whose surface shows on the part: a worn bit there shows too.
    static func finishes(_ kind: OperationKind) -> Bool {
        switch kind {
        case .facing, .adaptive, .drill: false
        default: true
        }
    }

    /// Every program as a tool load, in the order they run (the prep first).
    func wearLoads(pace: Double? = nil, from: Tuning? = nil, to: Tuning? = nil) -> [Consumables.ProgramLoad] {
        (prepPrograms + programs).map { p in
            // ~15 % of program time is rapids and links (as the tuner counts it).
            var minutes = p.seconds / 60 * 0.85
            if let from, let to {
                minutes = p.operations.isEmpty ? minutes
                    : minutes * (scaled(1, op: p.operations[0], tool: p.tool, side: p.side, from: from, to: to))
            }
            return .init(program: p.index, title: p.opsTitle, tool: p.tool, minutes: minutes,
                         finishes: p.operations.contains { Self.finishes($0.kind) })
        }
    }

    /// The forecast for the job as generated, or at another tuning (the tuner's what-if).
    func wearForecast(_ t: Tuning? = nil) -> [Consumables.ForecastItem] {
        guard !programs.isEmpty, let material = stock?.material else { return [] }
        let target = t ?? generatedTuning
        let loads = t == nil ? wearLoads() : wearLoads(from: generatedTuning, to: target)
        return Consumables.forecast(loads, inventory: inventoryLookup(), material: material, pace: target.pace,
                                    toolSaver: target.saveTools)
    }

    /// The bit Coastline picked for a program (nil: the tool has no bits recorded).
    func unit(forProgram index: Int) -> ToolUnit? {
        wearForecast().first { $0.program == index }?.unit
    }

    /// The wear an operation's bit starts at, for the feeds: the program's bit from the last
    /// forecast, else the bit in use. nil below `wornMode` (it cuts as planned).
    func bitWearForGeneration(_ op: Operation, tool: Tool, inventory: Inventory) -> Double? {
        let fromForecast = programs.first { $0.operations.contains { $0.id == op.id } && $0.tool.id == tool.id }
            .flatMap { p in wearForecast().first { $0.program == p.index }?.before }
        let owned = inventory.tools.first { $0.id == tool.id } ?? tool
        let w = fromForecast ?? Consumables.loadedUnit(owned, learning: inventory.lifeLearning)
            .map { Consumables.wear($0, tool: owned, learning: inventory.lifeLearning) }
        guard let w, w >= WearPolicy.wornMode else { return nil }
        return w
    }

    /// Fills the bits in a journal entry from the forecast, and the tuning it ran at.
    func assignBits(_ e: inout JournalEntry) {
        let f = wearForecast()
        let all = prepPrograms + programs
        for k in e.programs.indices where k < all.count && e.programs[k].unitID == nil {
            if let u = f.first(where: { $0.program == all[k].index })?.unit {
                e.programs[k].unitID = u.id
                e.programs[k].unitLabel = u.label
            }
        }
        e.pace = generatedTuning.pace
        e.toolSaver = generatedTuning.saveTools ? true : nil
    }

    /// Feeds for an operation Coastline adds itself (prep, reference bores, side setups): the
    /// feeds engine's values with Save tools and worn-bit mode, as the planned operations get.
    func wearFeeds(tool: Tool, material: Material, kind: OperationKind) -> CuttingData {
        var op = Operation(kind: kind, toolID: tool.id)
        op.toolSaver = operations.first?.toolSaver
        op.bitWear = bitWearForGeneration(op, tool: tool, inventory: inventoryLookup())
        var d = FeedsEngine.compute(tool: tool, material: material, kind: kind, machine: machine)
        if op.toolSaver == true { WearAwareFeeds.applySaver(&d, machine: machine) }
        if let w = op.bitWear { WearAwareFeeds.applyWorn(&d, wear: w, kind: kind, machine: machine) }
        return d
    }
}
