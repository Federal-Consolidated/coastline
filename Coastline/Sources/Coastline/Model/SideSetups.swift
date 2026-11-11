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
        var sides = PlanCoverage.propose(findings).compactMap(SetupSide.index).filter {
            $0 >= 2 && setup.forSide($0, partMin: part.boundsMin, partMax: part.boundsMax, stock: stock) != nil
        }
        // The end pieces come off from the ends, features there or not.
        for side in [4, 5] where endPieceThickness(side: side) > 0.5 && !sides.contains(side)
            && setup.forSide(side, partMin: part.boundsMin, partMax: part.boundsMax, stock: stock) != nil {
            sides.append(side)
        }
        return sides
    }

    /// A side setup's boring with one tool: the same id every time (the cache knows it again).
    static func sideBoreID(side: Int, tool: Tool) -> UUID {
        let t = tool.id.uuid
        return UUID(uuid: (0x5E, 0xB0, 0, UInt8(side), t.4, t.5, t.6, t.7, t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15))
    }

    /// How much stock the end setup from `side` faces off before the part's end (4: the +Y
    /// end, 5: the −Y end; 0 for the other sides or without end pieces), mm.
    func endPieceThickness(side: Int) -> Double {
        guard side >= 4, let part, let stock, let e = endPieces(part: part, stock: stock) else { return 0 }
        return side == 4 ? e.high : e.low
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
            // An end setup first faces its end piece off down to the part's end, over the whole
            // face, with the plan's largest roughing tool; its features are cut from there.
            let endPiece = endPieceThickness(side: side)
            var facing: [EngineClient.PlannedOperation] = []
            if endPiece > 0.5, let material = stock.material,
               let rougher = base.filter({ $0.operation.kind == .adaptive }).max(by: { $0.tool.diameter < $1.tool.diameter })?.tool {
                let op = Operation(kind: .facing, toolID: rougher.id, faceDepth: endPiece)
                var p = EngineClient.PlannedOperation(operation: op, tool: rougher,
                                                      data: FeedsEngine.compute(tool: rougher, material: material, kind: .facing, machine: machine))
                p.zTop = 0
                p.zMin = -endPiece
                facing = [p]
            }
            guard let w = SideCuts.window(featureBounds: bounds, side: side, stock: a, margin: margin) else {
                if !facing.isEmpty { out.append((side, s, facing)) }
                continue
            }
            var planned = SideCuts.operations(base, window: w, stock: SetupSide.stockSize(a, side: side))
            // Holes from this side are bored (helical), each by the larger flat end mill that fits
            // it, then the smaller: roughing here takes only cavities with nothing of the part
            // beyond them, so a hole over a hollow (an end plate's) would stay uncut. The stock
            // check lifts a smaller tool over the holes a larger one opened.
            if !planned.contains(where: { [.bore, .drill].contains($0.operation.kind) }), let material = stock.material {
                var flats: [Tool] = []
                for p in base where p.tool.kind == .flatEndMill && !flats.contains(where: { abs($0.diameter - p.tool.diameter) < 0.05 }) { flats.append(p.tool) }
                for tool in flats.sorted(by: { $0.diameter > $1.diameter }) {
                    var op = Operation(kind: .bore, toolID: tool.id)
                    op.id = Self.sideBoreID(side: side, tool: tool)
                    var p = EngineClient.PlannedOperation(operation: op, tool: tool, data: FeedsEngine.compute(tool: tool, material: material, kind: .bore, machine: machine))
                    p.zTop = 0
                    p.zMin = w.zMin
                    p.window = (w.min, w.max)
                    planned.append(p)
                }
            }
            // The features start at the faced surface, not in the end piece facing has taken.
            if endPiece > 0.5 { for k in planned.indices { planned[k].zTop = min(planned[k].zTop, -endPiece) } }
            planned = facing + planned
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

    /// The stock past the part's ends along its length (work Y in side A's frame), mm at the
    /// −Y and +Y ends, with library workholding: those end pieces stay on through the long-face
    /// setups (the fixture grips them, the bar sits on full-length faces) and the end setups face
    /// them off. nil when there is less than a facing pass to take.
    func endPieces(part: PartInfo, stock: StockItem) -> (low: Double, high: Double)? {
        guard setup.planFromFixtureLibrary else { return nil }
        let s = setup.stockSize(stock)
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        let half = (hi.y - lo.y) / 2
        let low = s.y / 2 + setup.partOffsetY - half, high = s.y / 2 - setup.partOffsetY - half
        guard max(low, high) > 0.5 else { return nil }
        return (max(low, 0), max(high, 0))
    }

    /// Keep-out over the end pieces in a long-face setup's frame: everything past the part's
    /// length `y` (that setup's work Y), out to 50 mm past the stock.
    static func endKeepOut(partY y: ClosedRange<Double>, stock s: SIMD3<Double>) -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        let x0 = -s.x / 2 - 50, x1 = s.x / 2 + 50
        var out: [(min: SIMD2<Double>, max: SIMD2<Double>)] = []
        if y.upperBound < s.y / 2 - 0.5 { out.append((SIMD2(x0, y.upperBound), SIMD2(x1, s.y / 2 + 50))) }
        if y.lowerBound > -s.y / 2 + 0.5 { out.append((SIMD2(x0, -s.y / 2 - 50), SIMD2(x1, y.lowerBound))) }
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
