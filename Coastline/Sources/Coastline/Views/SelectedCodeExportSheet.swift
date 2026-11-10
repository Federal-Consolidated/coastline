import AppKit
import CoastlineCore
import SwiftUI

struct SelectedCodeExportSheet: View {
    let files: [GeneratedJob.CodeFile]
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var preview: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Selected Code").font(.title2.weight(.semibold))
            Text("Choose the files you need. Probing and setup files depend on the tool position and workholding described in the guided job.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("All") { selected = Set(files.map(\.id)) }
                Button("Probing Only") { selected = Set(files.filter { $0.kind == .probe }.map(\.id)) }
                Button("None") { selected = [] }
                Spacer()
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(GeneratedJob.CodeFile.Kind.allCases, id: \.self) { kind in
                    let group = files.filter { $0.kind == kind }
                    if !group.isEmpty {
                        Section(kind.rawValue) {
                            ForEach(group) { file in
                                HStack {
                                    Toggle(isOn: Binding(get: { selected.contains(file.id) }, set: { value in
                                        if value { selected.insert(file.id) } else { selected.remove(file.id) }
                                    })) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.title)
                                            Text(file.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    Spacer()
                                    Button("View Code") { preview = file.id }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 240)
            if let file = files.first(where: { $0.id == preview }) {
                GroupBox(file.path) {
                    ScrollView([.vertical, .horizontal]) {
                        Text(file.text).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 130)
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(Theme.warning).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export…") { export() }
                    .buttonStyle(.glassProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: preview == nil ? 550 : 700)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export Selected Code"
        panel.message = "Create a new folder containing the selected code files."
        panel.nameFieldStringValue = "Coastline Code"
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            _ = try GeneratedJob.export(files, selected: selected, to: folder)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
