import CoastlineCore
import SwiftUI

/// A labelled number field with a unit, for inspector forms.
struct NumberField: View {
    let title: String
    @Binding var value: Double
    var unit = "mm"
    var help: String?
    /// What changing this does (an ⓘ with a popover, and the hover tooltip).
    var tip: String?

    var body: some View {
        let units = AppSettings.shared.units
        LabeledContent {
            HStack(spacing: 4) {
                TextField(title, value: $value.displayed(in: units, metricUnit: unit), format: .number.precision(.fractionLength(0 ... (units == .imperial && unit == "mm" ? 6 : 4))))
                    .labelsHidden()
                    .accessibilityLabel(unit == "mm" ? "\(title), \(units.spokenUnit)" : title)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 60, maxWidth: 90)
                Text(units.symbol(for: unit)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if let tip { InfoTip(text: tip) }
            }
            if let help { Text(help) }
        }
        .help(tip ?? "")
    }
}

/// A small ⓘ that explains a setting and what changing it does.
struct InfoTip: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            // A 20-point target; the negative padding keeps the row its height.
            Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
                .padding(.vertical, -4)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel("More Info")
        .accessibilityHint(text)
        .popover(isPresented: $shown, arrowEdge: .trailing) {
            Text(text).font(.callout).padding(12).frame(width: 280, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An optional number (blank = unknown).
struct OptionalNumberField: View {
    let title: String
    @Binding var value: Double?
    var unit = ""

    var body: some View {
        let units = AppSettings.shared.units
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: $value.displayed(in: units, metricUnit: unit), format: .number.precision(.fractionLength(0 ... (units == .imperial && unit == "mm" ? 6 : 4))), prompt: Text("—"))
                    .labelsHidden()
                    .accessibilityLabel(unit == "mm" ? "\(title), \(units.spokenUnit)" : title)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 60, maxWidth: 90)
                Text(units.symbol(for: unit)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            }
        }
    }
}

/// An optional range (lower…upper), for grip ranges and measuring ranges.
struct RangeField: View {
    let title: String
    @Binding var range: ClosedRange<Double>?
    var unit = "mm"

    var body: some View {
        let units = AppSettings.shared.units
        let lower = Binding<Double?>(get: { range?.lowerBound }, set: { set(lower: $0, upper: range?.upperBound) })
        let upper = Binding<Double?>(get: { range?.upperBound }, set: { set(lower: range?.lowerBound, upper: $0) })
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("from", value: lower.displayed(in: units, metricUnit: unit), format: .number.precision(.fractionLength(0 ... 6)), prompt: Text("—")).frame(width: 64)
                    .accessibilityLabel("\(title), from, \(units.symbol(for: unit))")
                Text("–").foregroundStyle(.secondary)
                TextField("to", value: upper.displayed(in: units, metricUnit: unit), format: .number.precision(.fractionLength(0 ... 6)), prompt: Text("—")).frame(width: 64)
                    .accessibilityLabel("\(title), to, \(units.symbol(for: unit))")
                Text(units.symbol(for: unit)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            }
            .labelsHidden()
            .multilineTextAlignment(.trailing)
        }
    }

    private func set(lower: Double?, upper: Double?) {
        guard let lower, let upper else { range = nil; return }
        range = min(lower, upper) ... max(lower, upper)
    }
}

struct QuantityField: View {
    @Binding var quantity: Int
    var body: some View {
        LabeledContent("Quantity") {
            Stepper(value: $quantity, in: 0 ... 999) {
                Text("\(quantity)").monospacedDigit()
            }
        }
    }
}

/// The issues section of an inspector.
struct IssuesSection: View {
    let issues: [Issue]

    var body: some View {
        Section("Checks") {
            if issues.isEmpty {
                Label("Ready to use on the machine", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.ok)
            }
            ForEach(issues.sorted { $0.severity > $1.severity }) { issue in
                Label {
                    Text(issue.message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: Theme.symbol(issue.severity)).foregroundStyle(Theme.color(issue.severity))
                }
            }
        }
    }
}

/// A small status dot for table rows.
struct IssueDot: View {
    let severity: Issue.Severity?
    var body: some View {
        if let severity, severity > .info {
            Image(systemName: Theme.symbol(severity))
                .foregroundStyle(Theme.color(severity))
                .help(severity == .error ? "Has problems" : "Has warnings")
                .accessibilityLabel(severity == .error ? "Has problems" : "Has warnings")
        } else {
            Image(systemName: "checkmark.circle").foregroundStyle(.tertiary)
                .accessibilityLabel("No problems")
        }
    }
}

/// Material picker grouped by family.
struct MaterialPicker: View {
    @Environment(InventoryModel.self) private var model
    @Binding var materialID: String
    var currentMaterial: Material? = nil

    private var materials: [Material] {
        var choices = model.inventory.materials
        if let currentMaterial, currentMaterial.id == materialID {
            if let index = choices.firstIndex(where: { $0.id == currentMaterial.id }) { choices[index] = currentMaterial }
            else { choices.append(currentMaterial) }
        }
        return choices
    }

    var body: some View {
        Picker("Material", selection: $materialID) {
            ForEach(Material.Family.allCases, id: \.self) { family in
                Section(family.title) {
                    ForEach(materials.filter { $0.family == family }) { m in
                        Text(m.name).tag(m.id)
                    }
                }
            }
        }
    }
}

/// Empty state for a page with nothing selected.
struct NothingSelected: View {
    let what: String
    var body: some View {
        ContentUnavailableView("No \(what) Selected", systemImage: "sidebar.right",
                               description: Text("Select a row to see and edit its details."))
    }
}
