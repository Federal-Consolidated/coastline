import Foundation
import simd

/// The job's setups by the side of the stock toward the spindle. Index 0 is the front (side A,
/// the first setup's frame), 1 the back (side B, turned front-to-back about X), 2 and 3 the
/// upper and lower sides (+x, −x: turned a quarter about Y), 4 and 5 the ends (+y, −y: a
/// quarter about X). Every frame keeps the work-frame rules (`Setup`): origin at the centre of
/// the face toward the spindle, the stock below Z 0.
public enum SetupSide {
    public static let names = ["+z", "-z", "+x", "-x", "+y", "-y"]

    public static func index(_ side: String) -> Int? { names.firstIndex(of: side) }

    /// "Setup 3 · upper side" style words for a side index.
    public static func words(_ side: Int) -> String {
        names.indices.contains(side) ? DFM.sideWords(names[side]) : "side \(side)"
    }

    /// The rotation taking side-A work directions into this side's work frame: the side's
    /// outward direction becomes +Z. Side B turns about the setup's flip axis (`Setup.flipAxis`:
    /// 0 the vertical X, 1 the stock's length Y).
    public static func rotation(_ side: Int, flipAxis: Int? = nil) -> simd_double3x3 {
        switch side {
        case 1: Setup.rotation(axis: flipAxis == 1 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0), quarterTurns: 2)
        case 2: Setup.rotation(axis: SIMD3(0, 1, 0), quarterTurns: -1)
        case 3: Setup.rotation(axis: SIMD3(0, 1, 0), quarterTurns: 1)
        case 4: Setup.rotation(axis: SIMD3(1, 0, 0), quarterTurns: 1)
        case 5: Setup.rotation(axis: SIMD3(1, 0, 0), quarterTurns: -1)
        default: matrix_identity_double3x3
        }
    }

    /// The (work X, Y, Z) axis of side A along each of this side's work axes.
    public static func axisMap(_ side: Int) -> [Int] {
        let r = rotation(side)
        return (0..<3).map { k in (0..<3).first { j in abs((r * unit(j))[k]) > 0.5 }! }
    }

    /// The stock's size in this side's frame, from its size in side A's.
    public static func stockSize(_ a: SIMD3<Double>, side: Int) -> SIMD3<Double> {
        let m = axisMap(side)
        return SIMD3(a[m[0]], a[m[1]], a[m[2]])
    }

    /// A point in this side's work frame, in side A's (both relative to the same stock).
    public static func toA(_ p: SIMD3<Double>, side: Int, stock a: SIMD3<Double>, flipAxis: Int? = nil) -> SIMD3<Double> {
        let s = stockSize(a, side: side)
        return rotation(side, flipAxis: flipAxis).transpose * (p - SIMD3(0, 0, -s.z / 2)) + SIMD3(0, 0, -a.z / 2)
    }

    /// A point in side A's work frame, in this side's.
    public static func fromA(_ q: SIMD3<Double>, side: Int, stock a: SIMD3<Double>) -> SIMD3<Double> {
        let s = stockSize(a, side: side)
        return rotation(side) * (q - SIMD3(0, 0, -a.z / 2)) + SIMD3(0, 0, -s.z / 2)
    }

    private static func unit(_ j: Int) -> SIMD3<Double> { var v = SIMD3<Double>(0, 0, 0); v[j] = 1; return v }
}

extension Setup {
    /// This side-A setup turned so `side` (SetupSide index) faces the spindle, for the same stock:
    /// the part keeps its place in the stock. nil when the setup can't be turned (side B).
    public func forSide(_ side: Int, partMin lo: SIMD3<Double>, partMax hi: SIMD3<Double>, stock: StockItem) -> Setup? {
        if side == 0 { return self }
        if side == 1 { return sideB(partMin: lo, partMax: hi, stock: stock) }
        guard (2...5).contains(side), !flipped else { return nil }
        let a = stockSize(stock)
        let axis = side < 4 ? 1 : 0
        let quarter = [2: -1, 3: 1, 4: 1, 5: -1][side]!
        var out = turned(about: axis, quarterTurns: quarter)
        let map = SetupSide.axisMap(side)
        out.stockAxes = map.map { stockAxes[$0] }
        // Where the part sits in this frame: its side-A work bounds, turned with the stock.
        let m = partToWork(partMin: lo, partMax: hi)
        var nlo = SIMD3<Double>(repeating: .infinity), nhi = -nlo
        for i in 0..<8 {
            let c = SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
            let w = m * SIMD4(c, 1)
            let p = SetupSide.fromA(SIMD3(w.x, w.y, w.z), side: side, stock: a)
            nlo = simd_min(nlo, p); nhi = simd_max(nhi, p)
        }
        out.partOffsetX = (nlo.x + nhi.x) / 2
        out.partOffsetY = (nlo.y + nhi.y) / 2
        out.topAllowance = -nhi.z
        return out
    }
}
