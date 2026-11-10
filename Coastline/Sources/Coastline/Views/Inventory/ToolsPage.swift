import simd
import CoastlineCore
import SwiftUI

/// Inventory pages: what you own, library entries with no quantity, or both.
enum Ownership: String, CaseIterable, Hashable {
    case owned, notOwned, both
    var title: String {
        switch self {
        case .owned: "Owned"
        case .notOwned: "Not Owned"
        case .both: "Both"
        }
    }
    func admits(quantity: Int) -> Bool {
        switch self {
        case .owned: quantity > 0
        case .notOwned: quantity <= 0
        case .both: true
        }
    }
}

/// The segmented Owned / Not Owned / Both control above an inventory table.
struct OwnershipPicker: View {
    @Binding var selection: Ownership
    var body: some View {
        Picker("Ownership", selection: $selection) {
            ForEach(Ownership.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help("Show items with a quantity, items you don't own, or both.")
    }
}

enum ToolFilter: String, CaseIterable, Hashable {
    case all, endMills, ball, holes, chamfer, attention
    var title: String {
        switch self {
        case .all: "All"
        case .endMills: "End mills"
        case .ball: "Ball & bull"
        case .holes: "Drills"
        case .chamfer: "Chamfer & engrave"
        case .attention: "Needs attention"
        }
    }
}

struct ToolsPage: View {
    @Environment(InventoryModel.self) private var model
    @Environment(AppModel.self) private var app
    @State private var selection: Set<Tool.ID> = []
    @State private var search = ""
    @State private var filter = ToolFilter.all
    @State private var ownership = Ownership.both
    @State private var sortOrder = [KeyPathComparator(\Tool.diameter)]
    @State private var pendingDelete: Set<Tool.ID>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [Tool] {
        model.inventory.tools
            .filter { ownership.admits(quantity: $0.quantity) }
            .filter { tool in
                switch filter {
                case .all: true
                case .endMills: [.flatEndMill, .faceMill].contains(tool.kind)
                case .ball: [.ballEndMill, .bullNoseEndMill].contains(tool.kind)
                case .holes: [.drill, .spotDrill, .threadMill].contains(tool.kind)
                case .chamfer: [.chamferMill, .engraver].contains(tool.kind)
                case .attention: (model.worstIssue(for: tool, machine: app.machine) ?? .info) > .info
                }
            }
            .filter { search.isEmpty || "\($0.name) \($0.vendor) \($0.partNumber) \($0.intendedFor)".localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { tool in IssueDot(severity: model.worstIssue(for: tool, machine: app.machine)) }
                .width(22)
            TableColumn("Tool", value: \.name) { tool in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(tool.name)
                            if tool.requiresSpecificationReview {
                                Text("Needs specs").font(.caption.weight(.medium))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(.quaternary))
                            }
                            if tool.quantity <= 0 {
                                Text("Not owned").font(.caption.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.warning.opacity(0.25)))
                            }
                        }
                        Text(tool.isSuggestion ? tool.notes.replacingOccurrences(of: "Not in your inventory: Coastline suggests it. ", with: "")
                             : tool.intendedFor.isEmpty ? tool.kind.title : tool.intendedFor)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: tool.kind.symbol).foregroundStyle(Theme.accent)
                }
            }
            .width(min: 220, ideal: 300)
            TableColumn("⌀", value: \.diameter) { Text($0.diameter > 0 && $0.diameter.isFinite ? Length.describe($0.diameter) : "—").monospacedDigit() }
                .width(min: 90, ideal: 120)
            TableColumn("Flutes", value: \.flutes) { Text($0.flutes > 0 ? String($0.flutes) : "—").monospacedDigit() }
                .width(50)
            TableColumn("Stick-out", value: \.stickout) { Text($0.stickout > 0 && $0.stickout.isFinite ? "\(Length.mm($0.stickout)) mm" : "—").monospacedDigit() }
                .width(min: 70, ideal: 80)
            TableColumn("Coating") { Text($0.coating.title).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80)
            TableColumn("Qty", value: \.quantity) { Text("\($0.quantity)").monospacedDigit() }
                .width(40)
            TableColumn("Wear") { tool in
                if tool.hasConfirmedPreviewGeometry {
                    let s = ToolLife.status(tool, material: MaterialLibrary.material(id: "al-6061") ?? MaterialLibrary.all[0])
                    HStack(spacing: 4) {
                        Gauge(value: min(s.used, 1)) { Text("Wear") }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .labelsHidden()
                            .tint(s.wornOut ? Theme.danger : s.replaceSoon ? Theme.warning : Theme.ok)
                        // Not colour alone: a warning sign when it's time to replace it.
                        if s.wornOut || s.replaceSoon {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                                .foregroundStyle(s.wornOut ? Theme.danger : Theme.warning)
                        }
                    }
                    .help("\(Int(s.minutes)) of about \(Int(s.lifeMinutes)) cutting minutes (recorded jobs)" + (s.wornOut ? " · worn out" : s.replaceSoon ? " · replace soon" : ""))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Wear")
                    .accessibilityValue("\(Int((s.used * 100).rounded())) percent used" + (s.wornOut ? ", worn out" : s.replaceSoon ? ", replace soon" : ""))
                } else {
                    Text("—").foregroundStyle(.secondary).help("Confirm tool specifications to show estimated wear")
                }
            }
            .width(min: 50, ideal: 70)
        }
        .contextMenu(forSelectionType: Tool.ID.self) { ids in
            if ids.contains(where: { id in model.inventory.tools.first { $0.id == id }.map { $0.quantity <= 0 } == true }) {
                Button("Mark as Owned") {
                    model.update { inv in
                        for k in inv.tools.indices where ids.contains(inv.tools[k].id) && inv.tools[k].quantity <= 0 {
                            inv.tools[k].quantity = 1
                        }
                    }
                }
                Divider()
            }
            Button("Duplicate") { ids.forEach { id in model.duplicate(id, in: \.tools) { $0.id = UUID(); $0.name += " copy" } } }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = ids }
        }
        .onDeleteCommand { if !selection.isEmpty { pendingDelete = selection } }
        .confirmingDelete($pendingDelete, name: { ids in
            DeleteName.of(model.inventory.tools.filter { ids.contains($0.id) }.map(\.name), noun: "tool")
        }) { ids in
            model.remove(ids, from: \.tools)
            selection.subtract(ids)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                FilterChips(options: ToolFilter.allCases.map { ($0, $0.title) }, selection: $filter)
                Spacer()
                OwnershipPicker(selection: $ownership)
                Text("\(rows.count) of \(model.inventory.tools.count)").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        // A floating glass card rather than a safe-area inset: wrapped text inside the
        // table's inset feeds back into the split view's min size and loops layout.
        .overlay(alignment: .bottom) {
            if model.showStarterBanner {
                StarterBanner().frame(maxWidth: 680).padding(20)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .searchable(text: $search, prompt: "Search tools, vendors, part numbers")
        .navigationTitle("Tools")
        .toolbar {
            ToolbarItemGroup {
                ResourceLibraryActions(scope: .tools, selectedToolIDs: selection) {
                    ownership = .both
                    filter = .all
                    search = ""
                }
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button("Add Tool", systemImage: "plus") { addTool() }
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = selection }
                    .disabled(selection.isEmpty)
                    .help("Delete the selected tools (⌫)")
            }
        }
        .inspector(isPresented: Bindable(app).showInspector) {
            Group {
                if selection.count == 1, let id = selection.first, let binding = model.binding(\.tools, id: id) {
                    ToolInspector(tool: binding)
                } else {
                    NothingSelected(what: "Tool")
                }
            }
            .panelEdge(.leading).inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .onAppear {
            // Opened for one tool (a Machinability finding): show it whatever the filters hid.
            if let id = app.toolToShow {
                app.toolToShow = nil
                (ownership, filter, search) = (.both, .all, "")
                selection = [id]
                app.showInspector = true
            } else if selection.isEmpty, let first = rows.first { selection = [first.id] }
        }
    }

    private func addTool() {
        let tool = Tool(name: "New 1/8\" flat end mill", kind: .flatEndMill, diameter: 3.175, shankDiameter: 3.175,
                        flutes: 3, fluteLength: 9.5, stickout: 19, overallLength: 38.1)
        model.add(tool, to: \.tools)
        selection = [tool.id]
        filter = .all
        ownership = .owned
        search = ""
        app.showInspector = true
    }
}

struct ToolInspector: View {
    @Environment(AppModel.self) private var app
    @Binding var tool: Tool
    @Environment(InventoryModel.self) private var model
    @State private var specificationError: String?

    var body: some View {
        Form {
            if tool.hasConfirmedPreviewGeometry {
                Section {
                    PreviewCard(itemID: tool.id, key: tool.inventoryPreviewKey, name: tool.name,
                                    build: { [tool] d in
                                        // Lean it like a product shot: tip toward the viewer, shank away.
                                        let lean = simd_float4x4(simd_quatf(angle: .pi * 0.42, axis: simd_normalize(SIMD3<Float>(1, -1, 0))))
                                        return tool.sceneMeshes(device: d, id: "item").map { $0.transform = lean; return $0 }
                                    }) {
                            ToolProfileView(tool: tool)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Drag to orbit · Pinch to zoom · Double-click to fit")
                }
            } else if !tool.requiresSpecificationReview {
                Section {
                    Label("Complete specifications to preview this tool", systemImage: "cube.transparent")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if tool.requiresSpecificationReview {
                Section("Specifications") {
                    if missingSpecifications.isEmpty {
                        Text("Values entered. Confirm them against the tool or its specification sheet.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Still needed") {
                            Text(missingSpecifications.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Confirm Specifications", systemImage: "checkmark.circle") { confirmSpecifications() }
                }
            }
            Section("Tool") {
                TextField("Name", text: $tool.name)
                Picker("Type", selection: $tool.kind) {
                    ForEach(Tool.Kind.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                TextField("Vendor", text: $tool.vendor)
                TextField("Part number", text: $tool.partNumber)
                TextField("Intended for", text: $tool.intendedFor, prompt: Text("e.g. Aluminium, brass"))
                if let url = URL(string: tool.productLink), !tool.productLink.isEmpty {
                    Link(destination: url) { Label("Product Page", systemImage: "safari") }
                }
            }
            Section("Geometry") {
                NumberField(title: "Diameter", value: $tool.diameter)
                NumberField(title: "Shank diameter", value: $tool.shankDiameter)
                LabeledContent("Flutes") {
                    Stepper(tool.flutes > 0 ? String(tool.flutes) : "—", value: $tool.flutes, in: (tool.flutes == 0 ? 0 : 1) ... 8)
                        .monospacedDigit().accessibilityLabel("Flute count")
                }
                NumberField(title: "Flute length", value: $tool.fluteLength)
                NumberField(title: "Stick-out", value: $tool.stickout, help: "From the collet nut to the tip")
                NumberField(title: "Overall length", value: $tool.overallLength)
                if tool.kind == .bullNoseEndMill {
                    NumberField(title: "Corner radius", value: $tool.cornerRadius)
                }
                if [.chamferMill, .engraver, .drill, .spotDrill].contains(tool.kind) || tool.unconfirmedSpecifications?.contains("Point angle") == true {
                    OptionalNumberField(title: tool.kind == .drill || tool.kind == .spotDrill || tool.unconfirmedSpecifications?.contains("Point angle") == true ? "Point angle" : "Half angle",
                                        value: $tool.angle, unit: "°")
                    NumberField(title: "Tip diameter", value: $tool.tipDiameter)
                }
            }
            Section("Material") {
                Picker("Tool material", selection: $tool.toolMaterial) {
                    ForEach(Tool.ToolMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Coating", selection: $tool.coating) {
                    ForEach(Tool.Coating.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Ownership") {
                QuantityField(quantity: $tool.quantity)
                Picker("Condition", selection: $tool.condition) {
                    ForEach(Tool.Condition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                OptionalNumberField(title: "Price each", value: $tool.unitCost)
                TextField("Notes", text: $tool.notes, axis: .vertical).lineLimit(2 ... 5)
                if !tool.source.isEmpty {
                    LabeledContent("Source", value: tool.source).foregroundStyle(.secondary)
                }
            }
            if !tool.requiresSpecificationReview {
                IssuesSection(issues: model.issues(for: tool, machine: app.machine))
            }
            if !tool.presets.isEmpty {
                Section {
                    ForEach(tool.presets, id: \.self) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.name).font(.callout.weight(.medium))
                            Text("\(Int(p.rpm)) RPM · feed \(Int(p.feed)) · plunge \(Int(p.plungeFeed)) mm/min")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if let d = p.stepdown, let o = p.stepover {
                                Text("stepdown \(Length.mm(d)) · stepover \(Length.mm(o)) mm")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Library presets")
                } footer: {
                    Text("For reference. Coastline computes its own feeds per material and operation.")
                }
            }
        }
        .formStyle(.grouped)
        .darkPanel()
        .scrollEdgeEffectStyle(.soft, for: .all)
        .alert("Specifications Need Attention", isPresented: Binding(get: { specificationError != nil }, set: { if !$0 { specificationError = nil } })) {
            Button("OK") { specificationError = nil }
        } message: { Text(specificationError ?? "") }
    }

    private var missingSpecifications: [String] {
        (tool.unconfirmedSpecifications ?? []).filter { field in
            switch field {
            case "Shank diameter": !positive(tool.shankDiameter)
            case "Flute count": tool.flutes <= 0
            case "Flute length": !positive(tool.fluteLength)
            case "Stick-out": !positive(tool.stickout)
            case "Overall length": !positive(tool.overallLength)
            case "Point angle": !positive(tool.angle ?? 0)
            case "Coating": tool.coating == .unspecified
            case "Tool material": tool.toolMaterial == .unspecified
            default: true
            }
        }
    }

    private func positive(_ value: Double) -> Bool { value.isFinite && value > 0 }

    private func confirmSpecifications() {
        var confirmed = tool
        confirmed.unconfirmedSpecifications = nil
        var issues = ResourceLibraryValidation.issues(for: confirmed)
        if confirmed.coating == .unspecified, issues.isEmpty { issues.append("Choose the tool's coating, or Uncoated if it has none.") }
        if tool.unconfirmedSpecifications?.contains("Point angle") == true, !positive(confirmed.angle ?? 0) {
            issues.append("Enter the tool's positive point angle.")
        }
        guard issues.isEmpty else { specificationError = issues.joined(separator: "\n"); return }
        tool = confirmed
        specificationError = nil
    }
}

private extension Tool {
    var hasConfirmedPreviewGeometry: Bool {
        !requiresSpecificationReview && ResourceLibraryValidation.issues(for: self).isEmpty
    }
}

/// Shown after the first launch: the starter inventory needs the user's confirmation.
struct StarterBanner: View {
    @Environment(InventoryModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassCard(tint: Theme.accent) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Starter inventory").font(.headline)
                    Text("Coastline filled your inventory from the maker's tool libraries and your dimensions model. Set each quantity to what you actually own; the planner only uses items with a quantity above 0.")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                Spacer(minLength: 0)
                Button("Got It") { withAnimation(reduceMotion ? nil : .default) { model.showStarterBanner = false } }
                    .plainGlassButton()
            }
        }
    }
}
