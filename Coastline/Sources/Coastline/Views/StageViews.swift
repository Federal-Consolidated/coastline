import CoastlineCore
import SwiftUI

/// The six stages across the top of the inspector: each with its state, the reason on hover,
/// and a click to go there (back or forth, any time).
struct StageBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(JobStage.workflow) { stage in
                let st = model.status(stage)
                let current = model.stage == stage
                Button { model.enter(stage) } label: {
                    VStack(spacing: 3) {
                        ZStack {
                            Circle().fill(fill(st.state, current: current)).frame(width: 24, height: 24)
                            Image(systemName: icon(st.state, stage))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(st.state == .later || st.state == .notNeeded ? Color.secondary : .white)
                        }
                        .overlay(Circle().strokeBorder(current ? Color.primary.opacity(0.7) : .clear, lineWidth: 1.5).frame(width: 28, height: 28))
                        // One short word at caption size (the full name is the tooltip and what
                        // VoiceOver reads): a long name in a narrow cell broke as "Machin-ing".
                        Text(shortTitle(stage)).font(.caption.weight(current ? .semibold : .medium))
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .foregroundStyle(st.state == .later ? .secondary : .primary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(!model.canVisit(stage) || model.isPlanningJob)
                .help("\(model.title(stage)): \(st.why)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.title(stage))
                .accessibilityValue(stateName(st.state))
                .accessibilityHint(st.why)
                .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func shortTitle(_ stage: JobStage) -> String {
        switch stage {
        case .partStock: "Part"
        case .stock: "Stock"
        case .planning: "Plan"
        case .setups: "Setups"
        case .machining: "Paths"
        case .review: "Review"
        }
    }

    private func stateName(_ s: StageStatus.State) -> String {
        switch s {
        case .done: "Done"
        case .attention: "Needs attention"
        case .todo: "To do"
        case .blocked: "Blocked"
        case .notNeeded: "Not needed"
        case .later: "Later"
        }
    }

    private func icon(_ s: StageStatus.State, _ stage: JobStage) -> String {
        switch s {
        case .done: "checkmark"
        case .attention: "exclamationmark"
        case .todo: "arrow.right"
        case .blocked: "xmark"
        case .notNeeded: "minus"
        case .later: stage.symbol
        }
    }

    private func fill(_ s: StageStatus.State, current: Bool) -> Color {
        // Deep fills so the white glyphs read clearly (WCAG ≥ 4.5:1).
        switch s {
        case .done: Color(white: 0.36)
        case .attention: Color(red: 0.62, green: 0.48, blue: 0.0)  // dark yellow: white text stays readable
        case .todo: Theme.accent.opacity(current ? 1 : 0.75)
        case .blocked: Color(red: 0.75, green: 0.16, blue: 0.14)  // red: the job can't go on
        case .notNeeded: Color.secondary.opacity(0.18)
        case .later: current ? Theme.accent : Color.secondary.opacity(0.18)
        }
    }
}

/// The stage's "why", under the bar.
struct StageHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let st = model.status(model.stage)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(model.stage.number)").font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 18, height: 18).background(Circle().fill(Theme.accent.opacity(0.25)))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title(model.stage)).font(.headline)
                Text(st.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let next = model.stage.next {
                Button { model.enter(next) } label: { Label("Next", systemImage: "chevron.right").labelStyle(.titleAndIcon) }
                    .controlSize(.small)
                    .disabled(!model.canVisit(next) || st.state == .blocked || model.isPlanningJob
                              || (model.stage == .planning && model.programs.isEmpty)
                              || (model.stage == .stock && st.state != .done))
                    .help("Go to \(model.title(next))")
                    .accessibilityLabel("Next: \(model.title(next))")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Custom workholding: the user's own fixture, outside the collision checks.
struct CustomHoldingInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            if !model.setup.planFromFixtureLibrary {
            Section("Vise / custom fixture") {
                TextField("Fixture", text: $model.setup.customFixture.name)
                NumberField(title: "Stock above the table", value: Binding(
                    get: { model.setup.customFixture.height },
                    set: { model.setup.customFixture.height = max($0, 0) }),
                    tip: "Distance from the machine table to the bottom of your stock, including the fixture and parallels, in mm.")
                NumberField(title: "Face past table edge", value: Binding(
                    get: { model.setup.customFixture.faceProtrusion },
                    set: { model.setup.customFixture.faceProtrusion = $0 }),
                    tip: "Position of the stock face toward the spindle, relative to the front edge of the table, in mm.")
                TextField("Setup notes", text: $model.setup.customFixture.notes, axis: .vertical)
                    .lineLimit(3...6)
                Text("Custom fixture geometry is not modelled. Machine and table checks still apply; verify clearance to your vise, jaws and fasteners. These notes are included in the guided job.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            Section("Sides") {
                Toggle("Machine both sides", isOn: Binding(get: { model.twoSided }, set: {
                    model.twoSided = $0; model.twoSidedChosen = true
                }))
                Text("Secure the part independently of any material the toolpaths remove. Coastline does not add automatic holding tabs for a custom fixture.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            IssuesSection(issues: model.setupIssues)
            Section {
                Button("Change Workholding") { model.enter(.setups) }
            }
        }
        .formStyle(.grouped)
        .darkPanel()
    }
}

/// Stage 6: what's ready, the tour and the export.
struct ReviewInspector: View {
    @Environment(AppModel.self) private var model
    @State private var recording: JournalEntry?

    var body: some View {
        Form {
            if model.setup.planFromFixtureLibrary && model.libraryWorkholdingPlan?.reviewed != true {
                Section("Finish setup review") {
                    Text("Review the placement, secure grip and work zero of every setup before exporting or running.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Review Setups", systemImage: "hand.raised") { model.enter(.setups) }
                }
            }
            if !model.programs.isEmpty { ResultsSection() }
            Section {
                Button { recording = model.draftJournalEntry() } label: {
                    Label("Record This Job in the Journal…", systemImage: "book.closed").frame(maxWidth: .infinity)
                }
                .disabled(model.programs.isEmpty)
                Text("After it ran on the machine: what you measured, how it went, photos. Tool wear, the stock and the feeds learn from it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .darkPanel()
        .sheet(item: $recording) { e in RecordJobSheet(entry: e) }
    }
}
