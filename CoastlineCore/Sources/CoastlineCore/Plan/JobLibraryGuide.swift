import Foundation
import simd

/// Inventory proposals precede workholding constraints: a blank can contain a part without
/// having a sacrificial frame. A matching jig is a preference, not a fit requirement.
public enum JobLibraryGuide {
    public struct StockChoice: Sendable {
        public var stock: StockItem
        public var axes: [Int]
        public var matchingFixtures: Int
    }

    public static func stockChoices(partSize: SIMD3<Double>, inventory: Inventory,
                                    preferredAxes: [Int]? = nil) -> [StockChoice] {
        inventory.stock.compactMap { item -> StockChoice? in
            guard item.quantity > 0, !item.isSuggestion, item.material != nil else { return nil }
            let options = StockOrientation.options(stock: item, part: partSize, preferredAxes: preferredAxes).filter(\.workable)
            guard let first = options.first else { return nil }
            let matches = options.map { option in
                (option, inventory.fixtures.filter {
                    LibraryWorkholdingPlanner.eligibility($0, stock: option.raw).isEmpty
                }.count)
            }
            let chosen = matches.max { $0.1 < $1.1 }
            let count = chosen?.1 ?? 0
            return StockChoice(stock: item, axes: count > 0 ? chosen!.0.axes : first.axes, matchingFixtures: count)
        }.sorted { a, b in
            if (a.matchingFixtures > 0) != (b.matchingFixtures > 0) { return a.matchingFixtures > 0 }
            return a.stock.volume != b.stock.volume ? a.stock.volume < b.stock.volume : a.stock.id.uuidString < b.stock.id.uuidString
        }
    }
}
