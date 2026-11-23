import CoastlineCore
import Foundation

let unitsTests: [TestCase] = [
    TestCase(name: "imperialDimensionsAndFeedRoundTripWithoutChangingStoredMillimeters") {
        let units = DisplayUnits.imperial
        try expectEqual(units.displayedValue(25.4), 1)
        try expectEqual(units.storedValue(0.25), 6.35)
        try expectEqual(units.displayedValue(508, unit: "mm/min"), 20)
        for mm in [-254.0, -0.01, 0, 6.35, 123.456] {
            try expect(abs(units.storedValue(units.displayedValue(mm)) - mm) < 1e-10)
        }
    },
    TestCase(name: "unitSwitchPreservesAnglesPricesAndNonLengthQuantities") {
        for unit in ["°", "min", "USD", "RPM", "", "µm"] {
            try expectEqual(DisplayUnits.imperial.displayedValue(45, unit: unit), 45)
            try expectEqual(DisplayUnits.imperial.storedValue(45, unit: unit), 45)
            try expectEqual(DisplayUnits.imperial.symbol(for: unit), unit)
        }
        try expectEqual(DisplayUnits.imperial.symbol(for: "mm/min"), "in/min")
        try expectEqual(DisplayUnits.metric.displayedValue(6.35), 6.35)
        try expectEqual(DisplayUnits.metric.symbol(for: "mm"), "mm")
    },
    TestCase(name: "stockSizesAndOrientationFollowDisplayUnits") {
        var stock = StockItem(materialID: "al-6061", sizeX: 25.4, sizeY: 50.8, sizeZ: 12.7)
        try expectEqual(stock.sizeDescription(in: .imperial), "1 × 2 × 0.5 in")
        try expectEqual(stock.sizeDescription, "25.4 × 50.8 × 12.7 mm")
        let options = StockOrientation.options(stock: stock, part: SIMD3(1, 1, 76.2), units: .imperial)
        try expect(options.contains { $0.reason == "only 0.5 in deep: the part needs 3" })
        stock.shape = .roundBar
        try expectEqual(stock.sizeDescription(in: .imperial), "⌀1 × 2 in")
    },
    TestCase(name: "displayFormattingAndPreferenceRoundTrip") {
        try expectEqual(DisplayUnits.imperial.format(6.35), "0.25")
        try expectEqual(DisplayUnits.metric.format(6.35), "6.35")
        try expectEqual(DisplayUnits.imperial.format(0.01, maxDecimals: 6), "0.000394")
        for units in DisplayUnits.allCases {
            try expectEqual(try JSONDecoder().decode(DisplayUnits.self, from: JSONEncoder().encode(units)), units)
        }
    },
]
