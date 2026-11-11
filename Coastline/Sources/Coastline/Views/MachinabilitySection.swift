import CoastlineCore
import SwiftUI

/// Can this part be made with what you own (DFM.assess against the library's tools, collets and
/// stock and the job's machine): one row per finding, what blocks the job first. Picking a row
/// lights its faces in the viewport and shows its details and ways forward. It follows every
/// change to the tools, stock, machine or orientation by itself.
struct MachinabilitySection: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    var title = "Machinability"
    /// Plan: rows numbered like the pins on the part, details in the card beside the pin.
    /// Elsewhere (the setups sheet, no pins): details and ways forward in the row.
    var numbered = false
    /// Plan: one line ("3 warnings on this part") with the rows behind it. The setups and the
    /// plan matter more there; the checks are warnings to open when wanted.
    var compact = false
    @State private var showPassed = false
    @State private var showProblems = false

    var body: some View {
        if model.part != nil {
            let findings = model.dfmFindings(inventory: inventory.inventory)
            Section {
                if let findings {
                    let passed = findings.filter { $0.category == .ok }
                    let problems = findings.filter { $0.category != .ok }
                    if problems.isEmpty {
                        Label("No problems found for this setup.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(Theme.ok)
                    } else if compact {
                        DisclosureGroup(isExpanded: $showProblems) {
                            ForEach(Array(problems.enumerated()), id: \.element.id) { n, f in row(f, number: n + 1) }
                        } label: {
                            Label("\(problems.count) warning\(problems.count == 1 ? "" : "s") on this part", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(Theme.warning)
                        }
                    } else {
                        ForEach(Array(problems.enumerated()), id: \.element.id) { n, f in row(f, number: n + 1) }
                    }
                    if !passed.isEmpty {
                        DisclosureGroup(isExpanded: $showPassed) {
                            ForEach(passed) { row($0, number: nil) }
                        } label: {
                            Text("\(passed.count) check\(passed.count == 1 ? "" : "s") passed").font(.callout)
                        }
                    }
                } else if model.analysisFailed {
                    HStack(alignment: .top) {
                        FindingRow(title: "Couldn't check the part", summary: "The part analysis failed.") {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                        }
                        Button("Try Again") { model.scheduleAnalysis() }.controlSize(.small)
                    }
                } else {
                    // The same height as a finding, so the section doesn't jump when they come.
                    FindingRow(title: "Checking the part…", summary: "Tool reach, access and stock for this setup.") {
                        ProgressView().controlSize(.small)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                HStack {
                    Text(title)
                    InfoTip(text: "Checked on the exact CAD as the part sits now, against your tools, collets, stock and machine. Problems are marked on the part: click a pin or a row.")
                }
            } footer: {
                if !compact { Text(DFM.notChecked).font(.caption).foregroundStyle(.secondary) }
            }
            .onChange(of: findings, initial: true) { _, now in model.syncFindingSelection(now) }
        }
    }

    private func row(_ f: DFMFinding, number: Int?) -> some View {
        let selected = model.selectedFindingID == f.id
        return VStack(alignment: .leading, spacing: 6) {
            Button { model.selectFinding(selected ? nil : f) } label: {
                FindingRow(title: f.title, summary: f.summary) {
                    if numbered, let number {
                        Text("\(number)")
                            .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(f.category.colour))
                    } else {
                        Image(systemName: f.category.symbol).foregroundStyle(f.category.colour)
                    }
                }
                .background {
                    // Outside the row's own frame: selecting it never moves the rows.
                    if selected { RoundedRectangle(cornerRadius: 6).fill(.quaternary).padding(-4) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(f.category.title): \(f.title)")
            .accessibilityValue(f.summary)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(f.faces.isEmpty ? "Show the details" : "Show these faces on the part")
            if selected && numbered, let fix = f.fix {
                Label(fix, systemImage: "wrench.adjustable").font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if selected && !numbered {
                if let measure = f.measure { Text(measure).font(.caption).foregroundStyle(.secondary) }
                if let fix = f.fix { Label(fix, systemImage: "wrench.adjustable").font(.caption).fixedSize(horizontal: false, vertical: true) }
                if !f.details.isEmpty {
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(f.details.enumerated()), id: \.offset) { _, line in
                                Text(line).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .font(.caption)
                }
                remedies(f)
            }
        }
    }

    /// Buttons for the ways forward; a stick-out is a value to set on the tool, so it's text.
    @ViewBuilder private func remedies(_ f: DFMFinding) -> some View {
        let library = inventory.inventory
        ForEach(Self.unique(f.remedies), id: \.self) { r in
            let text = r.title(in: library, currentStock: model.stockID)
            if case .setStickout = r {
                Label(text, systemImage: "ruler").font(.caption)
            } else {
                Button(text, systemImage: Self.symbol(r)) { model.applyDFMRemedy(r, inventory: inventory) }
                    .controlSize(.small)
                    .disabled(Self.changesJob(r) && (model.isPlanningJob || model.isGenerating))
            }
        }
    }

    /// The ways forward that are buttons: each once; a stick-out is in the fix text.
    static func buttons(_ remedies: [DFMFinding.Remedy]) -> [DFMFinding.Remedy] {
        unique(remedies).filter { if case .setStickout = $0 { false } else { true } }
    }

    /// Each way forward once (they are the rows' identities).
    private static func unique(_ remedies: [DFMFinding.Remedy]) -> [DFMFinding.Remedy] {
        var seen = Set<DFMFinding.Remedy>()
        return remedies.filter { seen.insert($0).inserted }
    }

    static func symbol(_ r: DFMFinding.Remedy) -> String {
        switch r {
        case .useStock: "shippingbox"
        case .showTool: "wrench.and.screwdriver"
        case .buyTool: "cart"
        case .addTool: "cart.badge.plus"
        case .addCollet: "plus.circle"
        case .reviewSetups: JobStage.setups.symbol
        case .setStickout: "ruler"
        }
    }

    /// Changing the stock mid-plan would pull the inputs from under the planner.
    static func changesJob(_ r: DFMFinding.Remedy) -> Bool {
        if case .useStock = r { true } else { false }
    }
}

/// A finding's line: its symbol, title and one-sentence summary.
/// The setups the part needs (every one of the stock's six sides considered) and what each
/// cuts; once a plan is built, what its toolpaths leave out. Rows light their faces on the part.
/// From the part check: the simulation shows what the toolpaths really cut.
struct PlanCoverageSection: View {
    @Environment(AppModel.self) private var model
    let coverage: PlanCoverage
    @State private var showOtherSides = false

    var body: some View {
        let built = !model.operations.isEmpty
        Section {
            ForEach(coverage.setups) { cut in
                let selected = model.selectedFindingID == "setup\(cut.side)"
                let hold = SetupSide.index(cut.side).map { model.coverageWorkholding(side: $0) }
                let buy = SetupSide.index(cut.side).flatMap { model.workholdingToBuy(side: $0, number: cut.number) }
                let held = hold?.fixture.map { "\nHeld in \($0.name)." }
                    ?? buy.map { "\nNo fixture you own holds it this way. To buy: \($0.title.prefix(1).lowercased() + $0.title.dropFirst()), on the Shopping List." } ?? ""
                Button { model.selectCoverage(selected ? nil : cut) } label: {
                    FindingRow(title: "Setup \(cut.number): \(DFM.sideWords(cut.side)) toward the spindle",
                               summary: Self.list(cut.titles) + (cut.note.map { "\n" + $0 } ?? "") + held
                                   + (cut.toolpaths || hold?.fixture == nil ? "" : "\nNo toolpaths from this side: see the plan's notes.")) {
                        Text("\(cut.number)")
                            .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(cut.toolpaths ? Theme.ok : DFMFinding.Category.setupChange.colour))
                    }
                    .background { if selected { RoundedRectangle(cornerRadius: 6).fill(.quaternary).padding(-4) } }
                }
                .buttonStyle(.plain)
                .disabled(cut.faces.isEmpty)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help("Show what this setup cuts on the part")
            }
            if !coverage.unused.isEmpty {
                DisclosureGroup(isExpanded: $showOtherSides) {
                    ForEach(coverage.unused) { side in
                        FindingRow(title: DFM.sideWords(side.side).prefix(1).uppercased() + DFM.sideWords(side.side).dropFirst(), summary: side.why) {
                            Image(systemName: side.fits ? "minus.circle" : "xmark.circle")
                                .foregroundStyle(side.fits ? Color.secondary : DFMFinding.Category.notSupported.colour)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } label: {
                    Text("Other sides: \(coverage.unused.count) not used").font(.callout)
                }
            }
            if built {
                ForEach(coverage.gaps) { gap in
                    let selected = model.selectedFindingID == gap.finding
                    Button {
                        let f = model.dfmCache?.findings.first { $0.id == gap.finding }
                        model.selectFinding(selected ? nil : f)
                    } label: {
                        FindingRow(title: gap.title, summary: gap.text) {
                            Image(systemName: gap.category == .notSupported ? "xmark.octagon" : "circle.dashed")
                                .foregroundStyle(gap.category == .ok ? DFMFinding.Category.setupChange.colour : gap.category.colour)
                        }
                        .background { if selected { RoundedRectangle(cornerRadius: 6).fill(.quaternary).padding(-4) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not in the toolpaths: \(gap.title)")
                    .accessibilityValue(gap.text)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help("Show these faces on the part")
                }
            }
        } header: {
            HStack {
                Text("Setups")
                InfoTip(text: "All six sides of the stock are checked. Each setup has one side toward the spindle. From the part check: the simulation in Toolpaths shows what the toolpaths really cut.")
            }
        } footer: {
            if built, coverage.open > 0 {
                Text("\(coverage.open) feature\(coverage.open == 1 ? " is" : "s are") not in the toolpaths. Toolpaths are made for the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// "Pocket 20 x 30 mm, Hole 6 mm and 3 more"
    static func list(_ titles: [String]) -> String {
        guard !titles.isEmpty else { return "The outside only." }
        let shown = titles.prefix(3).joined(separator: ", ")
        return titles.count > 3 ? "\(shown) and \(titles.count - 3) more" : shown
    }
}

private struct FindingRow<Icon: View>: View {
    let title: String
    let summary: String
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon.font(.callout).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

extension DFMFinding.Category {
    /// The same colours as on the part (AppModel.highlightColor).
    @MainActor var colour: Color {
        let c = AppModel.highlightColor(self)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}
