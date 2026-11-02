import AppKit
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

    /// How the guided job finds edges and the top on clamp-kit setups. The clamp kit is
    /// electrically isolated from the machine, so a wire on the stock and the tool closing the
    /// circuit (G38.2) can do it; acetal stops on the bed can't, there it's the edge finder and paper.
    enum ClampKitProbing: String, CaseIterable, Identifiable {
        case electrical, edgeFinder
        var id: String { rawValue }
        var title: String { self == .electrical ? "Electrical probing (G38.2)" : "Edge finder and paper" }
    }

    private let defaults = UserDefaults.standard

    var accent: Accent { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); apply() } }
    /// 0 = automatic (by the number of cores).
    var engines: Int { didSet { defaults.set(engines, forKey: "engines") } }
    var clampKitProbing: ClampKitProbing { didSet { defaults.set(clampKitProbing.rawValue, forKey: "clampKitProbing") } }
    /// Two-sided jobs mill reference bores on side A and find side B's zero from them.
    var referenceBores: Bool { didSet { defaults.set(referenceBores, forKey: "referenceBores") } }

    private init() {
        accent = Accent(rawValue: defaults.string(forKey: "accent") ?? "") ?? .graphite
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        engines = defaults.integer(forKey: "engines")
        clampKitProbing = ClampKitProbing(rawValue: defaults.string(forKey: "clampKitProbing") ?? "") ?? .electrical
        referenceBores = defaults.object(forKey: "referenceBores") as? Bool ?? true
    }

    func apply() { NSApp?.appearance = appearance.nsAppearance }
}
