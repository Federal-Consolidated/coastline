import CoastlineCore
import SwiftUI
import Viewport
import simd

/// The workspace inspector: Setup and Machining tabs.
struct WorkspaceInspector: View {
    @Environment(AppModel.self) private var model
    @State private var toolbarInset: CGFloat = 0

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
        VStack(spacing: 0) {
            if model.fixturePlacement != nil {
                FixturePlacementInspector()
            } else {
            StageBar()
            StageHeader()
            Divider()
            Group {
            switch model.stage {
            case .partStock: SetupInspector(scope: .part)
            case .stock: SetupInspector(scope: .stock)
            case .planning: JobPlanInspector()
            case .setups: JobSetupsInspector()
            case .machining: MachiningInspector()
            case .review: ReviewInspector()
            }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .clipped()
            }
        }
        .padding(.top, toolbarInset)
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(ToolbarContentInset(top: $toolbarInset))
        .background(Theme.panelBackground)
    }
}

/// The part, the stock and how they sit in the machine.
struct SetupInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    /// Which stage it serves: the part and stock, or the setups.
    enum Scope { case partStock, part, stock, setups }
    var scope: Scope = .partStock
    /// A stock being made from the Stock picker ("New Stock…", "Duplicate This One…").
    @State private var draftStock: StockItem?
    /// The stock being edited in place ("Edit This Stock…").
    @State private var editingStock: StockItem?
    private static let newStockTag = UUID(uuidString: "00000000-0000-4000-8000-00000000A001")!
    private static let duplicateStockTag = UUID(uuidString: "00000000-0000-4000-8000-00000000A002")!
    private static let editStockTag = UUID(uuidString: "00000000-0000-4000-8000-00000000A003")!

    var body: some View {
        @Bindable var model = model
        Form {
            if scope == .partStock || scope == .part, let part = model.part {
                Section("Part") {
                    LabeledContent("File", value: part.fileName)
                    let k = model.setup.partScale
                    LabeledContent("Size", value: "\(Length.mm(part.size.x * k)) × \(Length.mm(part.size.y * k)) × \(Length.mm(part.size.z * k)) mm" + (abs(k - 1) > 1e-9 ? " (scaled)" : ""))
                    HStack {
                        Text("Scale")
                        InfoTip(text: "Machines the part smaller (or bigger) than modelled, the same in every direction, e.g. to fit the stock you have. 100 % is as designed.")
                        Spacer()
                        TextField("Scale", value: Binding(get: { model.setup.partScale * 100 }, set: { model.setup.partScale = min(max($0 / 100, 0.05), 10) }),
                                  format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .frame(width: 60).multilineTextAlignment(.trailing)
                        Text("%").foregroundStyle(.secondary)
                        if let fit = model.scaleToFitStock {
                            Button("Fit") { model.setup.partScale = fit }
                                .help("The largest scale at which the part fits inside the stock. Workholding is checked separately.")
                        }
                    }
                    ForEach(part.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.callout)
                    }
                }
                Section("Next") {
                    Text("Choose stock from your library. Coastline will then propose machining and workholding together; orientation and work zero are reviewed in Setups.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Choose Stock", systemImage: "chevron.right") { model.enter(.stock) }
                        .buttonStyle(.glassProminent)
                }
            }

            if scope == .partStock || scope == .stock {
            OwnedStockSuggestions()
            Section {
                Picker("Stock", selection: Binding(get: { model.stockID }, set: { id in
                    if id == Self.newStockTag {
                        draftStock = StockItem(materialID: model.stock?.materialID ?? "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20)
                    } else if id == Self.duplicateStockTag, let s = model.stock {
                        var copy = s
                        copy.id = UUID()
                        copy.isRemnant = false
                        if copy.isSuggestion { copy.supplier = "" }  // a copy is the user's own stock
                        draftStock = copy
                    } else if id == Self.editStockTag, let s = model.stock {
                        editingStock = s
                    } else if let item = inventory.inventory.stock.first(where: { $0.id == id }) {
                        model.useGuidedStock(item, inventory: inventory.inventory)
                    } else {
                        model.stockID = nil
                    }
                })) {
                    Text("None").tag(StockItem.ID?.none)
                    let owned = inventory.inventory.stock.filter { !$0.isSuggestion }
                    let standard = inventory.inventory.stock.filter(\.isSuggestion)
                    Section("Your Stock") {
                        ForEach(owned) { s in
                            Text("\(s.material?.name ?? "?") · \(s.sizeDescription)").tag(Optional(s.id))
                        }
                    }
                    if !standard.isEmpty {
                        Section("Standard Sizes to Buy (Not Owned)") {
                            ForEach(standard) { s in
                                Text("\(s.material?.name ?? "?") · \(s.sizeDescription)").tag(Optional(s.id))
                            }
                        }
                    }
                    Divider()
                    if model.stock != nil { Text("Edit This Stock…").tag(Optional(Self.editStockTag)) }
                    Text("New Stock…").tag(Optional(Self.newStockTag))
                    if model.stock != nil { Text("Duplicate This One…").tag(Optional(Self.duplicateStockTag)) }
                }
                .sheet(item: $draftStock) { draft in
                    NewStockSheet(draft: draft) { added in
                        inventory.update { $0.stock.append(added) }
                        model.useGuidedStock(inventory.inventory.resolvedStock(added), inventory: inventory.inventory)
                    }
                }
                .sheet(item: $editingStock) { item in
                    NewStockSheet(draft: item, actionTitle: "Save & Use") { edited in
                        inventory.update { inv in
                            if let k = inv.stock.firstIndex(where: { $0.id == edited.id }) { inv.stock[k] = edited }
                        }
                        model.stockEdited(edited)
                    }
                }
                // No stock, or stock the part doesn't fit: a bar you can buy that fits is worth showing.
                if model.part != nil, model.stock == nil || model.stockOptions().first(where: { $0.axes == model.setup.stockAxes })
                    .map({ !$0.workable }) ?? true {
                    StandardStockSuggestions()
                }
                if let stock = model.stock, (model.stockLookup(stock.id)?.quantity ?? 0) <= 0 {
                    HStack {
                        Label("This stock is not marked as owned.", systemImage: "cart")
                            .font(.callout).foregroundStyle(Theme.warning)
                        Spacer()
                        Button("I Have It Now") { inventory.markStockOwned([stock.id]) }
                            .controlSize(.small)
                    }
                }
                if let stock = model.stock {
                    let raw = model.setup.rawStockSize(stock)
                    LabeledContent("Size", value: "\(Length.mm(raw.x)) × \(Length.mm(raw.y)) × \(Length.mm(raw.z)) mm as bought")
                    let fit = model.stockOptions().first { $0.axes == model.setup.stockAxes }
                    Label(fit?.workable == true ? "The part fits inside the stock" : (fit?.reason.map { "Doesn't fit: \($0)" } ?? "Doesn't fit"),
                          systemImage: fit?.workable == true ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(fit?.workable == true ? Theme.ok : Theme.danger)
                    let options = model.stockOptions()
                    if !options.isEmpty {
                        Menu {
                            ForEach(options) { o in
                                Button {
                                    model.useStockAxes(o.axes)
                                } label: {
                                    Label(o.summary, systemImage: o.axes == model.setup.stockAxes ? "checkmark" : (o.workable ? "cube" : "xmark"))
                                }
                                .disabled(!o.workable)
                            }
                        } label: {
                            Label(options.first { $0.axes == model.setup.stockAxes }?.summary ?? "How it sits", systemImage: "rotate.3d")
                                .lineLimit(2)
                        }
                        .help("Which stock dimension runs along each work axis. Any orientation that contains the part can be chosen; workholding is assessed separately.")
                    }

                }
            } header: {
                HStack {
                    Text("Stock")
                    InfoTip(text: "Choose the material and blank you actually have. This step checks that the part fits. Workholding, machining allowance and work zero are reviewed together in Setups.")
                }
            }
            }

            if scope == .stock, model.stock != nil {
                Section {
                    Button("Plan with My Library", systemImage: "sparkles") { model.enter(.planning) }
                        .buttonStyle(.glassProminent)
                        .disabled(model.status(.stock).state != .done)
                }
            }


            if scope == .partStock, model.part != nil, model.stock != nil {
                PlacementSection()
                IssuesSection(issues: model.setupIssues)
            }
            if scope == .setups, model.part != nil && model.stock != nil {
                Section {
                    Toggle("Machine both sides", isOn: Binding(get: { model.twoSided }, set: { model.twoSided = $0; model.twoSidedChosen = true }))
                    if !model.twoSided, let a = model.analysis, AppModel.backHasShape(a) {
                        Label("The back has shape (red). From one side it stays uncut.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                    if !model.twoSided, let excess = model.oneSidedThroughExcess {
                        Picker("Free the part", selection: $model.holdWithTabs) {
                            Text("Cut through, on tabs").tag(true)
                            Text("Leave it on the bar").tag(false)
                        }
                        if model.holdWithTabs {
                            Stepper("Tabs: \(model.tabs.count) (in mirrored pairs)", value: $model.tabs.count, in: 2 ... 8, step: 2)
                            NumberField(title: "Tab width", value: $model.tabs.width)
                            NumberField(title: "Tab height", value: $model.tabs.height)
                            Text(excess > 0.05
                                 ? "The bar is \(Length.mm(excess)) mm thicker than the part: the part goes to the back of the bar and the extra comes off the face (Placement follows when you generate)."
                                 : "The bar is as thick as the part: the outline cuts right through it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.twoSided, let split = model.splitZ {
                        LabeledContent("Split at", value: "Z\(Length.mm(split)) mm (the widest section)")
                        Picker("Hold the part with", selection: $model.holdWithTabs) {
                            Text("Tabs").tag(true)
                            Text("Web").tag(false)
                        }
                        if model.holdWithTabs {
                            Stepper("Tabs: \(model.tabs.count) (in mirrored pairs)", value: $model.tabs.count, in: 2 ... 8, step: 2)
                            NumberField(title: "Tab width", value: $model.tabs.width)
                            NumberField(title: "Tab height", value: $model.tabs.height)
                            Button("Suggest for This Material", systemImage: "wand.and.stars") {
                                if let part = model.part {
                                    let (lo, hi) = model.setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
                                    model.tabs = HoldingTabs.suggested(material: model.stock?.material, partSize: hi - lo)
                                }
                            }
                            .plainGlassButton()
                        } else {
                            NumberField(title: "Web between sides", value: $model.webThickness)
                        }
                    }
                } header: {
                    Text("Sides")
                } footer: {
                    Text(model.twoSided
                         ? (model.holdWithTabs
                            ? "Side A is cut down to the split. Then you turn the stock front-to-back and side B cuts through from the back, leaving small tabs: the part floats in the frame on them until you cut it free and file the stubs."
                            : "Side A is cut down to the split; then you turn the stock front-to-back and side B is cut from the back. A thin web keeps the part in the frame until you saw it free.")
                         : (model.analysis.map(AppModel.backHasShape) == false
                            ? (model.cutsThroughWithTabs
                               ? "The back is flat, so one side is enough: the outline is cut right through from the front and the part hangs on small tabs until you saw them, like a two-sided part. Two sides is still an option."
                               : "The back is flat, so one side is enough. The part stays joined to the back of the bar: saw it off after. Two sides is still an option.")
                            : "Turn this on for parts with surfaces facing away from the spindle (shown red), like most jewellery."))
                }
            }
            if scope == .setups {
                AnalysisSection()
            }

        }
        .formStyle(.grouped)
        .darkPanel()
        .scrollEdgeEffectStyle(.soft, for: .all)
        .overlay {
            if model.part == nil && model.stock == nil {
                ContentUnavailableView("No Part", systemImage: "cube.transparent",
                                       description: Text("Import a part, then choose stock from your inventory."))
            }
        }
    }
}


/// What limits machining this part as set up: the same findings, highlights and ways forward
/// as the Plan step (MachinabilitySection), under this inspector's own heading.
struct AnalysisSection: View {
    var body: some View { MachinabilitySection(title: "Analysis") }
}

/// Where the part sits in the stock (stage 1): numbers and snaps; the gumball in 3D does the same.
struct PlacementSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            NumberField(title: "Up / down (X)", value: Binding(get: { model.setup.partOffsetX }, set: { v in var s = model.setup; s.partOffsetX = v; model.setup = model.placementLimited(s) }))
            NumberField(title: "Left / right (Y)", value: Binding(get: { model.setup.partOffsetY }, set: { v in var s = model.setup; s.partOffsetY = v; model.setup = model.placementLimited(s) }))
            NumberField(title: "Below the face (Z)", value: Binding(get: { model.setup.topAllowance }, set: { v in var s = model.setup; s.topAllowance = v; model.setup = model.placementLimited(s) }),
                        tip: "Stock above the part's top. Zero keeps the existing face and skips automatic facing. More pushes the part toward the back of the stock.")
            HStack(spacing: 6) {
                snap("Centre", "dot.squareshape", .centre)
                snap("To the face", "arrow.up.to.line", .face)
                snap("To the back", "arrow.down.to.line", .back)
            }
            HStack(spacing: 6) {
                snap("Up", "arrow.up", .top)
                snap("Down", "arrow.down", .bottom)
                snap("Left", "arrow.left", .left)
                snap("Right", "arrow.right", .right)
            }
        } header: {
            HStack {
                Text("Placement in the stock")
                InfoTip(text: "Drag the part in 3D, enter an offset, or snap it to a stock face. Zero allowance is valid for a face that stays as supplied. Grip and fixture clearance depend on your choice in Holding.")
            }
        }
    }

    private func snap(_ title: String, _ symbol: String, _ s: AppModel.PlacementSnap) -> some View {
        Button { model.snapPart(s) } label: { Label(title, systemImage: symbol).labelStyle(.titleAndIcon).font(.caption) }
            .buttonStyle(.bordered).controlSize(.small)
    }
}

/// A new stock from the Stock picker: size, material and the rest, then added to the inventory
/// and used straight away.
struct NewStockSheet: View {
    @State var draft: StockItem
    var actionTitle = "Add & Use"
    var onAdd: (StockItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            StockInspector(stock: $draft)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) { onAdd(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.sizeX <= 0 || draft.sizeY <= 0 || (draft.shape != .roundBar && draft.sizeZ <= 0))
            }
            .padding(16)
        }
        .frame(width: 440, height: 640)
    }
}

/// Standard bar sizes you can buy that the part fits in (StockCatalog).
private struct StandardStockSuggestions: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        let fits = model.standardStockThatFits(in: inventory.inventory)
        if !fits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Standard sizes this part fits in").font(.callout.weight(.semibold))
                ForEach(fits) { s in
                    Button("\(s.material?.name ?? "Stock") · \(s.sizeDescription)", systemImage: "cart") { model.useStock(s) }
                        .plainGlassButton()
                        .help(s.notes.replacingOccurrences(of: "Not in your inventory: a standard size. ", with: ""))
                }
            }
        }
    }
}
