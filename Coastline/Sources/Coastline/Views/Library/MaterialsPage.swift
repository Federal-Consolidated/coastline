import CoastlineCore
import SwiftUI

/// Edits a copy so partially entered cutting data never reaches the planner.
struct MaterialEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Material
    @State private var speedMinimum: Double
    @State private var speedMaximum: Double
    @State private var errorMessage: String?
    let title: String
    let onSave: (Material) throws -> Void

    init(material: Material, title: String, onSave: @escaping (Material) throws -> Void) {
        _draft = State(initialValue: material)
        _speedMinimum = State(initialValue: material.surfaceSpeed.lowerBound)
        _speedMaximum = State(initialValue: material.surfaceSpeed.upperBound)
        self.title = title
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text("Applies to this stock item.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            Divider()
            Form {
                Section("Material") {
                    TextField("Name", text: $draft.name)
                    TextField("Grade", text: $draft.grade)
                    Picker("Family", selection: $draft.family) {
                        ForEach(Material.Family.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Cutting mode", selection: $draft.difficulty) {
                        ForEach(Material.Difficulty.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    NumberField(title: "Density", value: $draft.density, unit: "g/cm³")
                    TextField("Hardness", text: $draft.hardness)
                }
                Section("Cutting data") {
                    NumberField(title: "Minimum surface speed", value: $speedMinimum, unit: "m/min")
                    NumberField(title: "Maximum surface speed", value: $speedMaximum, unit: "m/min")
                    NumberField(title: "Chip load factor", value: $draft.chipLoadFactor, unit: "×", tip: "Relative to 6061 aluminium, which is 1.0.")
                    NumberField(title: "Maximum stepover", value: $draft.adaptiveStepoverMax, unit: "× ⌀", tip: "Fraction of tool diameter; 0.2 means 20%.")
                    NumberField(title: "Maximum adaptive depth", value: $draft.adaptiveDepthMax, unit: "× ⌀")
                    NumberField(title: "Maximum slot depth", value: $draft.slotDepthMax, unit: "× ⌀")
                    NumberField(title: "Specific cutting force", value: $draft.specificCuttingForce, unit: "N/mm²")
                    NumberField(title: "Tool wear factor", value: $draft.toolWearFactor, unit: "×")
                }
                Section("Source") {
                    TextField("Source", text: Binding(get: { draft.source ?? "" }, set: { draft.source = $0 }),
                              prompt: Text("Manufacturer, reference or test results"))
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2 ... 4)
                }
                Section {
                    DisclosureGroup("Machining notes") {
                        TextField("Lubricant", text: $draft.lubricant, axis: .vertical).lineLimit(2 ... 4)
                        TextField("Chips", text: $draft.chips, axis: .vertical).lineLimit(2 ... 4)
                        TextField("Tooling", text: $draft.tooling, axis: .vertical).lineLimit(2 ... 4)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply to Stock") { save() }.keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .frame(width: 540, height: 650)
        .alert("Couldn't Save Material", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        guard speedMinimum.isFinite, speedMaximum.isFinite, speedMinimum > 0, speedMaximum >= speedMinimum else {
            errorMessage = "Enter a positive surface-speed range, with the maximum at least as large as the minimum."
            return
        }
        var material = draft
        material.surfaceSpeed = speedMinimum ... speedMaximum
        let issues = material.validationIssues
        guard issues.isEmpty else {
            errorMessage = issues.joined(separator: "\n")
            return
        }
        do {
            try onSave(material)
            dismiss()
        } catch { errorMessage = "\(error)" }
    }
}

/// Stock carries the material definition used for its weight and machining data.
struct StockMaterialProperties: View {
    let material: Material

    var body: some View {
        LabeledContent("Grade", value: material.grade)
        LabeledContent("Density", value: "\(material.density.formatted(.number.precision(.fractionLength(2)))) g/cm³")
        LabeledContent("Surface speed", value: "\(material.surfaceSpeed.lowerBound.formatted(.number.precision(.fractionLength(0))))–\(material.surfaceSpeed.upperBound.formatted(.number.precision(.fractionLength(0)))) m/min")
        LabeledContent("Chip load factor", value: "\(material.chipLoadFactor.formatted(.number.precision(.fractionLength(2)))) × aluminium")
        DisclosureGroup("Cutting limits and notes") {
            LabeledContent("Family", value: material.family.title)
            LabeledContent("Cutting mode", value: material.difficulty.title)
            if !material.hardness.isEmpty { LabeledContent("Hardness", value: material.hardness) }
            LabeledContent("Maximum stepover", value: "\((material.adaptiveStepoverMax * 100).formatted(.number.precision(.fractionLength(0))))% of ⌀")
            LabeledContent("Adaptive depth", value: "\(Length.mm(material.adaptiveDepthMax)) × ⌀")
            LabeledContent("Slot depth", value: "\(Length.mm(material.slotDepthMax)) × ⌀")
            LabeledContent("Cutting force", value: "\(material.specificCuttingForce.formatted(.number.precision(.fractionLength(0)))) N/mm²")
            LabeledContent("Tool wear", value: "\(material.toolWearFactor.formatted(.number.precision(.fractionLength(1)))) × aluminium")
            note("Lubricant", material.lubricant)
            note("Chips", material.chips)
            note("Tooling", material.tooling)
            note("Notes", material.notes)
            if let source = material.source, !source.isEmpty { note("Source", source) }
        }
    }

    @ViewBuilder private func note(_ title: String, _ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
