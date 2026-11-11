import CoastlineCore
import Foundation
import simd

let setupTests: [TestCase] = [
    TestCase(name: "exactSizeBlankFitsWithoutMachiningAllowance") {
        let stock = StockItem(materialID: "al-6061", sizeX: 60, sizeY: 30, sizeZ: 10)
        var s = Setup()
        s.topAllowance = 0
        let size = SIMD3<Double>(30, 60, 10)
        let issues = SetupChecks.check(s, partMin: .zero, partMax: size, stock: stock)
        try expect(!issues.contains { $0.severity >= .warning }, "\(issues)")
        let limits = s.placementLimits(partMin: .zero, partMax: size, stock: stock)
        try expectEqual(limits.depth, 0...0, "zero allowance must remain editable")
        try expectEqual(limits.x, 0...0)
        try expectEqual(limits.y, 0...0)
        let physical = StockOrientation.options(stock: stock, part: size)
        try expect(physical.contains { $0.axes == s.stockAxes && $0.workable })
    },
    TestCase(name: "zeroAllowanceDoesNotAllowAnOversizedOrShiftedPart") {
        let stock = StockItem(materialID: "al-6061", sizeX: 60, sizeY: 30, sizeZ: 10)
        var s = Setup()
        s.topAllowance = 0
        for size in [SIMD3<Double>(30.01, 60, 10), SIMD3(30, 60.01, 10), SIMD3(30, 60, 10.01)] {
            try expect(SetupChecks.check(s, partMin: .zero, partMax: size, stock: stock).contains { $0.severity == .error })
        }
        s.partOffsetX = 0.01
        try expect(SetupChecks.check(s, partMin: .zero, partMax: SIMD3(30, 60, 10), stock: stock).contains { $0.severity == .error })
    },
    TestCase(name: "squareBlankKeepsItsSelectedStockOrientation") {
        let stock = StockItem(materialID: "al-6061", sizeX: 30, sizeY: 30, sizeZ: 10)
        for axes in [[0, 1, 2], [1, 0, 2]] {
            let options = StockOrientation.options(stock: stock, part: SIMD3(30, 30, 10), preferredAxes: axes)
            try expect(options.contains { $0.axes == axes && $0.workable }, "\(axes)")
            try expectEqual(options.filter { $0.raw == SIMD3(30, 30, 10) }.count, 1, "deduplicate equivalent menu entries")
        }
    },
    TestCase(name: "placementMayMeetAnyExistingStockFace") {
        let stock = StockItem(materialID: "al-6061", sizeX: 60, sizeY: 30, sizeZ: 10)
        let s = Setup()
        let limits = s.placementLimits(partMin: .zero, partMax: SIMD3(20, 40, 8), stock: stock)
        try expectEqual(limits.x, -5...5)
        try expectEqual(limits.y, -10...10)
        try expectEqual(limits.depth, 0...2)
    },
    TestCase(name: "facingPutsTheChosenAxisTowardTheSpindle") {
        for facing in Setup.Facing.allCases {
            var s = Setup()
            s.facing = facing
            let dir: SIMD3<Double> = switch facing {
            case .plusZ: SIMD3(0, 0, 1)
            case .minusZ: SIMD3(0, 0, -1)
            case .plusX: SIMD3(1, 0, 0)
            case .minusX: SIMD3(-1, 0, 0)
            case .plusY: SIMD3(0, 1, 0)
            case .minusY: SIMD3(0, -1, 0)
            }
            try expectEqual(s.partRotation * dir, SIMD3(0, 0, 1), "\(facing)")
            try expect(abs(simd_determinant(s.partRotation) - 1) < 1e-12, "proper rotation")
        }
    },
    TestCase(name: "spinTurnsAboutTheToolAxis") {
        var s = Setup()
        s.spin = 1
        try expectEqual(s.partRotation * SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        try expectEqual(s.partRotation * SIMD3(0, 0, 1), SIMD3(0, 0, 1))
    },
    TestCase(name: "partSitsBelowTheStockTopCentred") {
        var s = Setup()
        s.topAllowance = 0.5
        let m = s.partToWork(partMin: SIMD3(10, 20, 0), partMax: SIMD3(30, 60, 5))
        let top = m * SIMD4(30, 60, 5, 1)
        let corner = m * SIMD4(10, 20, 0, 1)
        try expect(abs(top.z + 0.5) < 1e-9, "top at −allowance, got \(top.z)")
        try expect(abs(corner.z + 5.5) < 1e-9)
        try expect(abs((top.x + corner.x) / 2) < 1e-9 && abs((top.y + corner.y) / 2) < 1e-9, "centred")
    },
    TestCase(name: "defaultsPutThinAlongToolAndLongAlongY") {
        let stock = StockItem(materialID: "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20)
        var s = Setup()
        s.stockAxes = Setup.defaultStockAxes(stock)
        try expectEqual(s.stockSize(stock), SIMD3(80, 150, 20))  // matches the measured dimensions model
        // A ring blank lying in XZ (thin in Y): +Y should face the spindle.
        let (facing, spin) = Setup.defaultOrientation(partMin: SIMD3(0, 0, 0), partMax: SIMD3(30, 4, 20))
        try expectEqual(facing, .plusY)
        s.facing = facing
        s.spin = spin
        let (lo, hi) = s.rotatedPartBounds(min: SIMD3(0, 0, 0), max: SIMD3(30, 4, 20))
        try expect(abs((hi.z - lo.z) - 4) < 1e-9)
        try expect(hi.y - lo.y >= hi.x - lo.x)
    },
    TestCase(name: "fitChecks") {
        let stock = StockItem(materialID: "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20)
        var s = Setup()
        s.stockAxes = Setup.defaultStockAxes(stock)
        let fits = SetupChecks.check(s, partMin: SIMD3(0, 0, 0), partMax: SIMD3(40, 60, 8), stock: stock)
        try expect(fits.allSatisfy { $0.severity < .warning }, "\(fits)")
        let tooBig = SetupChecks.check(s, partMin: SIMD3(0, 0, 0), partMax: SIMD3(90, 60, 8), stock: stock)
        try expect(tooBig.contains { $0.severity == .error && $0.message.contains("sticks out") })
        let tooDeep = SetupChecks.check(s, partMin: SIMD3(0, 0, 0), partMax: SIMD3(40, 60, 25), stock: stock)
        try expect(tooDeep.contains { $0.severity == .error && $0.message.contains("thicker") })
    },
]

let sideBTests: [TestCase] = [
    TestCase(name: "sideBKeepsThePartInPlaceInTheStock") {
        let stock = StockItem(materialID: "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20)
        var a = Setup()
        a.stockAxes = Setup.defaultStockAxes(stock)
        a.topAllowance = 0.5
        a.partOffsetY = 7
        let lo = SIMD3<Double>(-15, -15, 0), hi = SIMD3<Double>(15, 15, 5)
        let b = a.sideB(partMin: lo, partMax: hi, stock: stock)
        // The stock lies along work Y (150 long), so it rolls over about its length: a part point
        // maps through side A, then the flip (x → −x, z → −T − z), to side B, and stays in place.
        try expect(b.flipAxis == 1)
        let ma = a.partToWork(partMin: lo, partMax: hi), mb = b.partToWork(partMin: lo, partMax: hi)
        for p in [SIMD3<Double>(10, -3, 1), SIMD3<Double>(-15, 15, 5), SIMD3<Double>(0, 0, 0)] {
            let wa = ma * SIMD4(p, 1), wb = mb * SIMD4(p, 1)
            try expect(abs(wb.x + wa.x) < 1e-9 && abs(wb.y - wa.y) < 1e-9 && abs(wb.z - (-20 - wa.z)) < 1e-9, "\(p): \(wa) vs \(wb)")
        }
        try expect(abs(b.topAllowance - 14.5) < 1e-9, "20 − 0.5 − 5")
    },
]
