import CoastlineCore
import Foundation
import simd

/// Rhino-style typed moves: click an arrow or a ring of the gumball (without dragging) and type
/// how far to move or turn. Arrows take millimetres, rings degrees.
struct GumballPrompt: Equatable {
    var axis: String
    var target: AppModel.GumballTarget
    var point: CGPoint
    var isRing: Bool { axis.hasPrefix("gumball.ring") }
    var title: String {
        let name = ["gumball.x": "Up / down", "gumball.y": "Along Y", "gumball.z": "Toward the spindle",
                    "gumball.ring.x": "Turn about X", "gumball.ring.y": "Turn about Y", "gumball.ring.z": "Turn about Z"][axis] ?? "Move"
        return name
    }
    var unit: String { isRing ? "°" : "mm" }
}

extension AppModel {
    /// Applies a typed move or turn to what the gumball holds.
    func applyTyped(_ v: Double, _ prompt: GumballPrompt) {
        defer { gumballPrompt = nil; layoutGumball() }
        guard v.isFinite, abs(v) > 1e-9 else { return }
        switch prompt.target {
        case .libraryFixture(let id):
            guard abs(v) < 100_000 else { return }
            if let axis = Self.ringIDs.firstIndex(of: prompt.axis) {
                rotatePlacement(axis: axis, turns: Int((v / 90).rounded()), componentID: id, useSelection: false)
            } else {
                let delta = SIMD3(prompt.axis == "gumball.x" ? v : 0, prompt.axis == "gumball.y" ? v : 0, prompt.axis == "gumball.z" ? v : 0)
                movePlacement(delta, componentID: id, useSelection: false)
            }
        case .part:
            if let k = Self.ringIDs.firstIndex(of: prompt.axis) {
                let q = Int((v / 90).rounded())
                guard q != 0 else { status = "The part turns in quarter turns (90°)."; return }
                setup = placementLimited(setup.turned(about: k, quarterTurns: q))
                return
            }
            var s = setup
            switch prompt.axis {
            case "gumball.x": s.partOffsetX += v
            case "gumball.y": s.partOffsetY += v
            default: s.topAllowance -= v
            }
            let limited = placementLimited(s)
            if limited != s { status = "Moved as far as the part's frame allows." }
            setup = limited
        }
    }
}
