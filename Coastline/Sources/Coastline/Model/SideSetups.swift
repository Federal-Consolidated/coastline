import CoastlineCore
import Foundation
import simd

extension AppModel {
    /// The setups from the stock's other sides (upper, lower side, the ends; SetupSide 2…5)
    /// the part check proposes, in the order the job makes them. Only with automatic
    /// workholding from the library (it fits a fixture to the turned stock), and only for a
    /// blank the job doesn't prepare or batch (those change the stock in side A's frame).
    func sideSetupSides(part: PartInfo, stock: StockItem) -> [Int] {
        guard setup.planFromFixtureLibrary, automaticWorkholding,
              let findings = dfmFindings(inventory: inventoryLookup()) else { return [] }
        return PlanCoverage.propose(findings).compactMap(SetupSide.index).filter {
            $0 >= 2 && setup.forSide($0, partMin: part.boundsMin, partMax: part.boundsMax, stock: stock) != nil
        }
    }

    /// Each side setup with what it cuts: the plan's operations kept to a window around the
    /// features the part check sends to that side (SideCuts).
    func sideSetupPlans(base: [EngineClient.PlannedOperation], part: PartInfo, stock: StockItem)
        -> [(side: Int, setup: Setup, planned: [EngineClient.PlannedOperation])] {
        guard let findings = dfmFindings(inventory: inventoryLookup()), let access = analysis?.access else { return [] }
        let a = setup.stockSize(stock)
        let margin = (base.filter { $0.operation.kind == .adaptive }.map(\.tool.diameter).max() ?? 6.35) / 2 + 1
        var out: [(side: Int, setup: Setup, planned: [EngineClient.PlannedOperation])] = []
        for side in sideSetupSides(part: part, stock: stock) {
            guard let s = setup.forSide(side, partMin: part.boundsMin, partMax: part.boundsMax, stock: stock) else { continue }
            let name = SetupSide.names[side]
            let bounds = findings.filter { PlanCoverage.isCut($0) && $0.category != .notSupported && $0.sides.contains(name) }
                .compactMap { access.bounds(forFaces: $0.faces) }
            guard let w = SideCuts.window(featureBounds: bounds, side: side, stock: a, margin: margin) else { continue }
            var planned = SideCuts.operations(base, window: w, stock: SetupSide.stockSize(a, side: side))
            // Each roughing tool works only what the larger ones before it left (as on side A).
            for k in planned.indices where planned[k].operation.kind == .adaptive {
                planned[k].restFrom = planned[..<k]
                    .filter { $0.operation.kind == .adaptive && $0.tool.diameter > planned[k].tool.diameter + 1e-6 }
                    .map { ($0.tool.diameter, $0.operation.minPocket ?? Operation.defaultMinPocket, $0.operation.leaveRadial) }
            }
            if !planned.isEmpty { out.append((side, s, planned)) }
        }
        return out
    }

    /// "Setup · upper side" for a side setup's programs; side A and B keep their names.
    static func setupTitle(side: Int, twoSided: Bool) -> String {
        switch side {
        case 0: twoSided ? "Side A" : "Setup 1"
        case 1: "Side B (flipped)"
        default: "Setup · \(SetupSide.words(side)) toward the spindle"
        }
    }
}
