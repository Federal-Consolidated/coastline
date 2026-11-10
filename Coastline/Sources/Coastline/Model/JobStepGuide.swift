import CoastlineCore
import Foundation

/// The job's steps as shown at the machine: the step on screen, moving between steps, what to do
/// at each one, the measuring checkpoints with what to do when out of tolerance, the finishing guide.
extension AppModel {
    /// The step on screen: the one the playhead is at, else the one last chosen.
    var currentStep: JobStep? {
        let steps = jobSteps
        if let s = steps.first(where: isActive) { return s }
        if let id = selectedStep?.id { return steps.first { $0.id == id } }
        return steps.first
    }

    /// The playhead is in edge finding with the edge finder: at the machine that's all by
    /// hand (jogging until the finder kicks, storing each edge), the animation only shows it.
    var manualEdgeFindingNow: Bool {
        guard showsMachiningResults, !timeline.entries.isEmpty else { return false }
        let e = timeline.entries[min(max(timeline.index(at: playhead), 0), timeline.entries.count - 1)]
        return e.program >= 2000 && plannedTools.indices.contains(e.operation) && plannedTools[e.operation].id == EdgeFinding.tool.id
    }

    func step(after s: JobStep, by delta: Int) -> JobStep? {
        let steps = jobSteps
        guard let i = steps.firstIndex(where: { $0.id == s.id }) else { return nil }
        let j = i + delta
        return steps.indices.contains(j) ? steps[j] : nil
    }

    /// Shows a step and frames it, always from the front, where you stand at the machine (never
    /// round the back from the spindle's side, however much better the cut face shows there).
    func visit(_ step: JobStep) {
        go(to: step)
        setView(.iso)
        focusWork()
    }

    // MARK: What to do

    /// The step's instructions, short and in order (the guided job has the long form).
    func instructions(for step: JobStep) -> [String] {
        let material = stock?.material
        switch step.kind {
        case .program where (step.program ?? 0) >= 2000:
            return [
                "**By hand, at the machine:** this animation only shows the order. The sender can't feel the stock here, so you jog.",
                "Edge finder in the collet, spinning at \(Int(machine.probeSpindleRPM)) RPM.",
                "In Machine Control, jog to the lower and upper edge (X), then the left and right edge (Y), until the finder kicks each time, and store it: the sender takes the centre as X0 Y0.",
                "Then each tool is touched off on the face with a sheet of paper (Z0) before it cuts.",
            ]
        case .program:
            guard let p = programs.first(where: { $0.index == step.program }) else { return [] }
            var out = ["**\(p.tool.name)**, \(Length.mm(p.tool.stickout)) mm sticking out of the collet nut."]
            out.append("\(p.opsTitle), about \(AppModel.duration(p.seconds)).")
            if let m = p.minStickout, m > p.tool.stickout + 0.1 { out.append("Needs at least \(Length.mm(m)) mm stick-out to keep the collet nut clear.") }
            out.append("The first time: run it as an air cut 10 mm above the work, spindle off.")
            if let material { out.append(material.lubricant) }
            return out
        case .setup:
            if step.id.hasPrefix("library."), let holding = libraryWorkholdingPlan?.steps.first(where: { "library.\($0.id)" == step.id }) {
                return [holding.instructions]
            }
            if setup.holding == .custom {
                return ["Hold the stock in **\(setup.customFixture.name)**, secured independently of material removed by the toolpaths.",
                        setup.customFixture.notes,
                        "Custom fixture geometry is not included in collision checks. Check the jaws and fasteners, then edge-find and touch off the stock in Machine Control."].filter { !$0.isEmpty }
            }
            return ["Secure the stock with its face toward the spindle, square to the spindle.",
                    "Edge-find and touch off the stock in Machine Control before the first cut."]
        case .flip:
            if setup.holding == .custom {
                return ["Turn the stock front-to-back about the vertical axis and secure it in your custom fixture.",
                        "Check clearance again, then edge-find and touch off for side B."]
            }
            return [
                "Vacuum the chips. Release the stock and turn it front-to-back about the vertical axis: the back now faces the spindle, left becomes right.",
                "Secure it again, then edge-find and touch off for side B.",
            ]
        case .measure:
            guard let c = step.checkpoint else { return [] }
            let instrument = inventoryMeasuringName ?? "a caliper"
            return [
                "With \(instrument): \(c.what.lowercased()) should be **\(Length.mm(c.expected)) mm**, between \(Length.mm(c.expected - c.tolerance)) and \(Length.mm(c.expected + c.tolerance)).",
                "Too big: the tool deflected or wore. Run the finishing program again (it only takes what's left) or add a spring pass.",
                "Too small: check the tool's real diameter and stick-out, and the touch-off. Don't unclamp before it's right.",
            ]
        case .finish:
            var out: [String] = []
            if setup.planFromFixtureLibrary {
                out.append("Stop the spindle, move the tool clear, release the final fixture and deburr the part.")
            } else if ((twoSided && holdWithTabs) || cutsThroughWithTabs) && !placedTabs.isEmpty {
                out.append("Unclamp. The part hangs in the frame on \(placedTabs.count) tabs: cut each close to the part with a jeweller's saw.")
            } else if twoSided {
                out.append("Unclamp and saw through the thin web to free the part.")
            } else if partOnBarBack > 0.05 {
                out.append("Unclamp. The part is still joined to the back of the bar (\(Length.mm(partOnBarBack)) mm of it): saw around it, then face or sand the back flat. (With Hold with tabs on, a bar up to \(Length.mm(Self.throughMaxExcess)) mm thicker than the part is cut through instead.)")
            } else {
                out.append("Unclamp and deburr.")
            }
            out += Self.finishingGuide(material)
            return out
        }
    }

    /// Name of the first caliper or micrometer in the inventory, for measuring steps.
    var inventoryMeasuringName: String? { measuringToolNames.first }
    static func finishingGuide(_ m: Material?) -> [String] { FinishingGuide.steps(for: m) }
}
