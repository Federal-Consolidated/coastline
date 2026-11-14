import CoastlineCore
import Foundation
import simd

let setupSideTests: [TestCase] = [
    TestCase(name: "eachSideSetupKeepsThePartWhereItIsInTheStock") {
        let stock = StockItem(materialID: "al-6061", sizeX: 50.8, sizeY: 203.2, sizeZ: 38.1)
        var a = Setup()
        a.facing = .plusZ; a.spin = 1; a.topAllowance = 1.5; a.partOffsetX = 2; a.partOffsetY = -7
        let lo = SIMD3<Double>(-10, -40, 0), hi = SIMD3<Double>(25, 60, 30)
        let size = a.stockSize(stock)
        let mA = a.partToWork(partMin: lo, partMax: hi)
        for side in 1...5 {
            let s = try unwrap(a.forSide(side, partMin: lo, partMax: hi, stock: stock))
            try expect(simd_length(s.stockSize(stock) - SetupSide.stockSize(size, side: side)) < 1e-9, "side \(side) stock")
            let m = s.partToWork(partMin: lo, partMax: hi)
            for p in [lo, hi, SIMD3(lo.x, hi.y, lo.z), SIMD3(3, 4, 5)] {
                let w = m * SIMD4(p, 1), wa = mA * SIMD4(p, 1)
                let back = SetupSide.toA(SIMD3(w.x, w.y, w.z), side: side, stock: size)
                try expect(simd_distance(back, SIMD3(wa.x, wa.y, wa.z)) < 1e-9, "side \(side) point \(p)")
                try expect(simd_distance(SetupSide.fromA(back, side: side, stock: size), SIMD3(w.x, w.y, w.z)) < 1e-9)
            }
            // The side's face is the stock's top: the part is below Z 0, inside the box.
            let (rlo, rhi) = s.rotatedPartBounds(min: lo, max: hi)
            try expect(abs(-s.topAllowance - (rhi.z - rlo.z) - (-s.topAllowance - rhi.z + rlo.z)) < 1e-9)
            try expect(s.topAllowance >= -1e-9 && s.topAllowance + (rhi.z - rlo.z) <= s.stockSize(stock).z + 1e-9, "side \(side) depth")
        }
        // Side A's +X (the upper side) faces the spindle in setup 3.
        try expect(simd_distance(SetupSide.rotation(2) * SIMD3(1, 0, 0), SIMD3(0, 0, 1)) < 1e-12)
        try expect(simd_distance(SetupSide.rotation(5) * SIMD3(0, -1, 0), SIMD3(0, 0, 1)) < 1e-12)
        var prepped = a; prepped.downsizeHeight = 40
        try expect(prepped.forSide(2, partMin: lo, partMax: hi, stock: stock) == nil)
    },
    TestCase(name: "aSideSetupCutsOnlyInsideTheWindowAroundItsFeatures") {
        let stock = SIMD3<Double>(50, 200, 40)  // side A's frame
        // A hole in the upper side (A's +X face), 10 mm in, at Y 30, Z −20.
        let hole = (min: SIMD3<Double>(15, 27, -23), max: SIMD3<Double>(25, 33, -17))
        let w = try unwrap(SideCuts.window(featureBounds: [hole], side: 2, stock: stock, margin: 4))
        // Upper side toward the spindle: work X is A's −Z (from the stock centre), Y stays, the
        // hole goes 10 mm in from the face.
        try expect(abs(w.min.y - 23) < 1e-9 && abs(w.max.y - 37) < 1e-9, "\(w)")
        try expect(abs(w.min.x - (-3 - 4)) < 1e-9 && abs(w.max.x - (3 + 4)) < 1e-9, "\(w)")
        try expect(abs(w.zMin - (-10.2)) < 1e-9, "\(w)")
        let size = SetupSide.stockSize(stock, side: 2)
        let ko = SideCuts.keepOut(around: w, stock: size)
        try expect(ko.allSatisfy { r in r.max.x <= w.min.x + 1e-9 || r.min.x >= w.max.x - 1e-9 || r.max.y <= w.min.y + 1e-9 || r.min.y >= w.max.y - 1e-9 })
        // Every point of the stock face outside the window is under a keep-out rectangle.
        for p in [SIMD2(-20.0, 0), SIMD2(0, 90), SIMD2(0, -90), SIMD2(19, 30)] {
            try expect(ko.contains { p.x >= $0.min.x && p.x <= $0.max.x && p.y >= $0.min.y && p.y <= $0.max.y }, "\(p)")
        }
        let tool = Tool(name: "6", kind: .flatEndMill, diameter: 6, shankDiameter: 6, flutes: 3, fluteLength: 18, stickout: 25, overallLength: 50)
        let material = MaterialLibrary.material(id: "al-6061")!
        let base = [OperationKind.facing, .adaptive, .contour, .drill, .parallel].map { k in
            EngineClient.PlannedOperation(operation: Operation(kind: k, toolID: tool.id), tool: tool,
                                          data: FeedsEngine.compute(tool: tool, material: material, kind: k))
        }
        let ops = SideCuts.operations(base, window: w, stock: size)
        try expectEqual(ops.map(\.operation.kind), [.adaptive, .drill])
        try expect(ops.allSatisfy { $0.zMin == w.zMin && $0.window != nil && $0.zTop == 0 })
        try expect(ops[0].keepOut.count == ko.count && ops[0].keepOutBelow > 0 && ops[0].operation.leaveRadial == 0)
    },
]
