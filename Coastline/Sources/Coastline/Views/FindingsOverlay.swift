import CoastlineCore
import SwiftUI
import simd

/// Machinability on the part (Plan): a numbered pin on every problem area, in its colour, and
/// the picked problem's card beside its pin: what is wrong, the measurement, and what to do.
struct FindingPinsOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        if model.showsFindingsInView, let findings = model.dfmFindings(inventory: inventory.inventory) {
            let problems = findings.filter { $0.category != .ok }
            GeometryReader { geo in
                let _ = model.camera  // re-project when the camera moves
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    ForEach(Array(problems.enumerated()), id: \.element.id) { n, f in
                        ForEach(Array(model.findingPinPoints(f.id).enumerated()), id: \.offset) { _, w in
                            if let p = model.project(w, size), inside(p, size) {
                                pin(n + 1, f).position(p)
                            }
                        }
                    }
                    if let n = problems.firstIndex(where: { $0.id == model.selectedFindingID }) {
                        let f = problems[n]
                        let anchor = model.findingPinPoints(f.id).lazy.compactMap { model.project($0, size) }.first { inside($0, size) }
                        FindingCard(finding: f, number: n + 1)
                            .frame(width: FindingCard.width)
                            .offset(cardOffset(anchor, size))
                            .id(f.id)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
    }

    private func inside(_ p: CGPoint, _ size: CGSize) -> Bool {
        p.x > 8 && p.y > 8 && p.x < size.width - 8 && p.y < size.height - 8
    }

    private func pin(_ number: Int, _ f: DFMFinding) -> some View {
        let selected = model.selectedFindingID == f.id
        return Button { model.selectFinding(selected ? nil : f) } label: {
            Text("\(number)")
                .font(.system(size: selected ? 14 : 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: selected ? 26 : 22, minHeight: selected ? 26 : 22)
                .background(Circle().fill(f.category.colour))
                .overlay(Circle().stroke(.white.opacity(selected ? 1 : 0.8), lineWidth: selected ? 2 : 1))
                .shadow(radius: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(f.title): \(f.summary)")
        .accessibilityLabel("Problem \(number), \(f.category.title): \(f.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Beside the pin, on the side with more room; inside the view (below the toolbar strip).
    private func cardOffset(_ anchor: CGPoint?, _ size: CGSize) -> CGSize {
        let w = FindingCard.width
        guard let p = anchor else { return CGSize(width: max(size.width - w - 16, 16), height: 120) }
        let x = p.x < size.width / 2 ? p.x + 22 : p.x - 22 - w
        let y = min(max(p.y - 30, 70), max(size.height - 330, 70))
        return CGSize(width: min(max(x, 12), max(size.width - w - 12, 12)), height: y)
    }
}

/// A problem explained: what, how big, why, and what to do, with its ways forward.
struct FindingCard: View {
    static let width: CGFloat = 320
    let finding: DFMFinding
    let number: Int
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        let f = finding
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Circle().fill(f.category.colour))
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(f.category.title).font(.caption).foregroundStyle(f.category.colour)
                }
                Spacer(minLength: 4)
                Button { model.selectFinding(nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Close").accessibilityLabel("Close")
            }
            if let measure = f.measure {
                Label(measure, systemImage: "ruler").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(f.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let fix = f.fix {
                Label(fix, systemImage: "wrench.adjustable").font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            let buttons = MachinabilitySection.buttons(f.remedies)
            if !buttons.isEmpty {
                FlowButtons(remedies: buttons)
            }
            if !f.details.isEmpty {
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(f.details.enumerated()), id: \.offset) { _, line in
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// The ways forward as small buttons, wrapping onto lines.
private struct FlowButtons: View {
    let remedies: [DFMFinding.Remedy]
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        let library = inventory.inventory
        VStack(alignment: .leading, spacing: 6) {
            ForEach(remedies, id: \.self) { r in
                Button(r.title(in: library, currentStock: model.stockID), systemImage: MachinabilitySection.symbol(r)) {
                    model.applyDFMRemedy(r, inventory: inventory)
                }
                .controlSize(.small)
                .disabled(MachinabilitySection.changesJob(r) && (model.isPlanningJob || model.isGenerating))
            }
        }
    }
}

/// What the colours on the part mean, with counts; the eye hides or shows them.
struct FindingsLegend: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        if model.stage == .planning, model.fixturePlacement == nil, !model.showsMachiningResults,
           let findings = model.dfmFindings(inventory: inventory.inventory) {
            let problems = findings.filter { $0.category != .ok }
            HStack(spacing: 10) {
                if problems.isEmpty {
                    Label("No problems found", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.ok)
                } else if model.showFindingsOverlay {
                    ForEach(DFMFinding.Category.allCases.filter { $0 != .ok }, id: \.self) { c in
                        let n = problems.filter { $0.category == c }.count
                        if n > 0 {
                            HStack(spacing: 4) {
                                Circle().fill(c.colour).frame(width: 9, height: 9)
                                Text("\(n) \(c.title.lowercased())").font(.caption)
                            }
                        }
                    }
                } else {
                    Text("\(problems.count) problem\(problems.count == 1 ? "" : "s") hidden").font(.caption)
                }
                if !problems.isEmpty {
                    Button { model.showFindingsOverlay.toggle() } label: {
                        Image(systemName: model.showFindingsOverlay ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.plain)
                    .help(model.showFindingsOverlay ? "Hide the problems on the part" : "Show the problems on the part")
                    .accessibilityLabel(model.showFindingsOverlay ? "Hide problems" : "Show problems")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
        }
    }
}
