import CoastlineCore
import SwiftUI

/// Changes presentation units without changing the stored dimensions or controller modes.
struct UnitsPicker: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Picker("Units", selection: $settings.units) {
            ForEach(DisplayUnits.allCases) { Text($0.symbol).tag($0).accessibilityLabel($0.title) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Display and enter lengths in millimeters or inches")
    }
}

extension Binding where Value == Double {
    func displayed(in units: DisplayUnits, metricUnit: String) -> Binding<Double> {
        Binding(get: { units.displayedValue(wrappedValue, unit: metricUnit) },
                set: { wrappedValue = units.storedValue($0, unit: metricUnit) })
    }
}

extension Binding where Value == Double? {
    func displayed(in units: DisplayUnits, metricUnit: String) -> Binding<Double?> {
        Binding(get: { wrappedValue.map { units.displayedValue($0, unit: metricUnit) } },
                set: { wrappedValue = $0.map { units.storedValue($0, unit: metricUnit) } })
    }
}
