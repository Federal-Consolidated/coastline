import Foundation

/// Presentation units only. Geometry, saved dimensions and controller commands stay in mm.
public enum DisplayUnits: String, CaseIterable, Codable, Identifiable, Sendable {
    case metric, imperial

    public var id: String { rawValue }
    public var title: String { self == .metric ? "Metric (mm)" : "Imperial (in)" }
    public var symbol: String { self == .metric ? "mm" : "in" }
    public var spokenUnit: String { self == .metric ? "millimeters" : "inches" }
    public var coordinateDecimals: Int { self == .metric ? 3 : 4 }

    /// Only known length units are converted; angles, prices and times retain their meaning.
    public func symbol(for metricUnit: String) -> String {
        guard self == .imperial else { return metricUnit }
        switch metricUnit {
        case "mm": return "in"
        case "mm/min": return "in/min"
        case "mm/s²": return "in/s²"
        default: return metricUnit
        }
    }

    private func scale(for metricUnit: String) -> Double {
        self == .imperial && ["mm", "mm/min", "mm/s²"].contains(metricUnit) ? 25.4 : 1
    }

    public func displayedValue(_ millimeters: Double, unit: String = "mm") -> Double {
        millimeters / scale(for: unit)
    }

    public func storedValue(_ displayed: Double, unit: String = "mm") -> Double {
        displayed * scale(for: unit)
    }

    public func format(_ millimeters: Double, maxDecimals: Int? = nil) -> String {
        displayedValue(millimeters).formatted(.number.precision(.fractionLength(0 ... (maxDecimals ?? coordinateDecimals)))
            .grouping(.never).locale(Length.locale))
    }
}
