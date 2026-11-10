import AppKit
import CoastlineCore
import SwiftUI
import UniformTypeIdentifiers

enum ResourceLibraryScope: String {
    case stock, tools
    var title: String { rawValue.capitalized }
}

private struct PendingResourceLibrary: Identifiable {
    let id = UUID()
    let package: ResourceLibraryPackage
}

struct ResourceLibraryActions: View {
    @Environment(InventoryModel.self) private var model
    @Environment(AppModel.self) private var app
    let scope: ResourceLibraryScope
    var selectedToolIDs: Set<UUID> = []
    var selectedStockIDs: Set<UUID> = []
    var onImport: () -> Void = {}
    @State private var importing = false
    @State private var loading = false
    @State private var pending: PendingResourceLibrary?
    @State private var error: String?

    private var hasSelection: Bool {
        !selectedToolIDs.isEmpty || !selectedStockIDs.isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(loading ? "Reading Library…" : "Import Library…", systemImage: "square.and.arrow.down") { importing = true }
                .disabled(loading)
                .help("Preview a Coastline library or Fusion tool library before importing")
            Menu("Export Library", systemImage: "square.and.arrow.up") {
                Button("Export Selected…") { export(selectedOnly: true) }.disabled(!hasSelection)
                Button("Export All \(scope.title)…") { export(selectedOnly: false) }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "coastlib") ?? .json,
                                                                   .json, UTType(filenameExtension: "tools") ?? .zip]) { result in
            switch result {
            case .failure(let failure): error = failure.localizedDescription
            case .success(let url):
                loading = true
                Task {
                    defer { loading = false }
                    do {
                        let package = try await Task.detached {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            return try ResourceLibraryImport.load(url)
                        }.value
                        pending = PendingResourceLibrary(package: package)
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .sheet(item: $pending) { item in
            ResourceLibraryImportSheet(package: item.package, onImport: {
                onImport()
                if scope == .stock, item.package.stock.isEmpty, item.package.tools.isEmpty, !item.package.materials.isEmpty {
                    app.status = "Material definitions installed. Choose a material on your stock."
                }
            })
                .environment(model)
        }
        .alert("Library", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func export(selectedOnly: Bool) {
        do {
            let package = try ResourceLibraryPackage.exporting(model.inventory, name: "\(scope.title) Library",
                stockIDs: scope == .stock ? (selectedOnly ? selectedStockIDs : nil) : [],
                toolIDs: scope == .tools ? (selectedOnly ? selectedToolIDs : nil) : [],
                materialIDs: scope == .stock && !selectedOnly ? nil : [])
            let data = try package.encoded()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "coastlib") ?? .json]
            panel.nameFieldStringValue = "\(scope.title).coastlib"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}

private struct ResourceLibraryImportSheet: View {
    @Environment(InventoryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let package: ResourceLibraryPackage
    var onImport: () -> Void
    @State private var policy = ResourceLibraryImport.ConflictPolicy.keepExisting
    @State private var useFileQuantities = false
    @State private var saveError: String?
    @State private var showNotes = false

    private var incoming: ResourceLibraryPackage {
        var copy = package
        if !useFileQuantities {
            for index in copy.tools.indices { copy.tools[index].quantity = 0 }
            for index in copy.stock.indices { copy.stock[index].quantity = 0 }
        }
        return copy
    }

    private var review: Result<ResourceLibraryImport.Preview, Error> {
        Result { try ResourceLibraryImport.prepare(incoming, into: model.inventory, policy: policy) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import \(package.name)").font(.title2.weight(.semibold))
                Text("\(package.stock.count) stock · \(package.tools.count) tools · \(package.materials.count) materials")
                    .foregroundStyle(.secondary)
                Text("Dimensions shown in millimetres")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Existing entries", selection: $policy) {
                Text("Keep Mine").tag(ResourceLibraryImport.ConflictPolicy.keepExisting)
                Text("Replace Definitions").tag(ResourceLibraryImport.ConflictPolicy.replaceExisting)
                Text("Import Copies").tag(ResourceLibraryImport.ConflictPolicy.addAsCopy)
            }.pickerStyle(.segmented)
            if !package.tools.isEmpty || !package.stock.isEmpty {
                Toggle("Use quantities from file", isOn: $useFileQuantities)
                    .help("When off, new stock and tools are added as Not owned. Existing ownership is preserved.")
                Text(useFileQuantities ? "New entries keep the file's quantities. Existing ownership stays unchanged."
                     : "New stock and tools will be Not owned. Mark them as owned when you have them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch review {
            case .success(let preview):
                Table(preview.rows) {
                    TableColumn("Item") { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            if let dimensions = row.dimensions {
                                Text(dimensions).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .help(row.detail)
                    }.width(min: 260, ideal: 360)
                    TableColumn("Type") { Text($0.kind.rawValue.capitalized).foregroundStyle(.secondary) }.width(70)
                    TableColumn("Qty") { row in Text(row.quantity.map(String.init) ?? "—").monospacedDigit() }.width(40)
                    TableColumn("Action") { row in Text(actionName(row.action)).help(row.detail) }.width(85)
                }
                .frame(minHeight: 180, idealHeight: 260, maxHeight: 320)
                Text("\(preview.addedCount + preview.copiedCount) new · \(preview.replacedCount) replaced · \(preview.keptCount) kept")
                    .font(.callout).foregroundStyle(.secondary)
                if !preview.warnings.isEmpty {
                    DisclosureGroup("Import notes (\(preview.warnings.count))", isExpanded: $showNotes) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, note in Text(note).font(.caption) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 120)
                    }
                }
            case .failure(let failure):
                ContentUnavailableView("Library Needs Changes", systemImage: "exclamationmark.triangle",
                                       description: Text(failure.localizedDescription))
                    .frame(minHeight: 180, maxHeight: 320)
            }
            if let saveError { Text(saveError).font(.callout).foregroundStyle(Theme.danger).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { install() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 660)
    }

    private func install() {
        do {
            // Re-evaluate against the latest inventory at commit, not an old preview.
            let preview = try ResourceLibraryImport.prepare(incoming, into: model.inventory, policy: policy)
            try model.commitLibrary(preview.inventory)
            onImport()
            dismiss()
        } catch { saveError = error.localizedDescription }
    }

    private func actionName(_ action: ResourceLibraryImport.Action) -> String {
        switch action {
        case .add: "Add"
        case .keep: "Keep mine"
        case .replace: "Replace"
        case .copy: "New copy"
        }
    }
}
