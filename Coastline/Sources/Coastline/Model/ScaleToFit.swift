import CoastlineCore
import Foundation
import simd

extension AppModel {
    /// The largest uniform scale at which the part fits the stock, when it
    /// doesn't fit at the current scale (nil when it does).
    var scaleToFitStock: Double? {
        guard let part, let stock else { return nil }
        var unit = setup
        unit.partScale = 1
        let (lo, hi) = unit.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        func fits(_ k: Double) -> Bool {
            StockOrientation.options(stock: stock, part: (hi - lo) * k).contains(where: \.workable)
        }
        guard !fits(setup.partScale) else { return nil }
        var a = 0.02, b = setup.partScale
        guard fits(a) else { return nil }
        for _ in 0..<30 { let m = (a + b) / 2; if fits(m) { a = m } else { b = m } }
        return (a * 200).rounded(.down) / 200  // 0.5 % steps
    }
}
