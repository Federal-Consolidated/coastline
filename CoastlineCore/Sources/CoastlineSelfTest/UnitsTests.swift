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
    TestCase(name: "displayFormattingAndPreferenceRoundTrip") {
        try expectEqual(DisplayUnits.imperial.format(6.35), "0.25")
        try expectEqual(DisplayUnits.metric.format(6.35), "6.35")
        try expectEqual(DisplayUnits.imperial.format(0.01, maxDecimals: 6), "0.000394")
        for units in DisplayUnits.allCases {
            try expectEqual(try JSONDecoder().decode(DisplayUnits.self, from: JSONEncoder().encode(units)), units)
        }
    },
]
