import AppKit
import CoastlineCore
import Foundation
import SwiftUI

/// Coastline ▸ Settings: the app's own preferences (not the project's), kept in UserDefaults.
/// Observable, so `Theme.accent` and everything else that reads these redraw when they change.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Grays only (the palette is monotone). Each stays dark enough for white text on it, and is a
    /// little lighter in dark mode so it still shows on the near-black panels.
    enum Accent: String, CaseIterable, Identifiable {
        case graphite, charcoal, steel
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var color: Color {
            let (dark, light): (CGFloat, CGFloat) = switch self {
            case .graphite: (0.50, 0.32)
            case .charcoal: (0.40, 0.20)
            case .steel: (0.58, 0.42)
            }
            return Color(nsColor: NSColor(name: "coastline.accent.\(rawValue)") { a in
                NSColor(white: a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
            })
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    private let defaults = UserDefaults.standard

    var units: DisplayUnits { didSet { defaults.set(units.rawValue, forKey: "displayUnits") } }
    var accent: Accent { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); apply() } }
    /// 0 = automatic (by the number of cores).
    var engines: Int { didSet { defaults.set(engines, forKey: "engines") } }
    /// Two-sided jobs mill reference bores on side A and find side B's zero from them.
    var referenceBores: Bool { didSet { defaults.set(referenceBores, forKey: "referenceBores") } }

    private init() {
        units = DisplayUnits(rawValue: defaults.string(forKey: "displayUnits") ?? "") ?? .metric
        accent = Accent(rawValue: defaults.string(forKey: "accent") ?? "") ?? .graphite
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        engines = defaults.integer(forKey: "engines")
        referenceBores = defaults.object(forKey: "referenceBores") as? Bool ?? true
    }

    func apply() { NSApp?.appearance = appearance.nsAppearance }
}
