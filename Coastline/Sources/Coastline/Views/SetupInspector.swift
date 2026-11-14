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
            case .holding: HoldingInspector()
            case .prep: PrepInspector()
            case .clampKit: JobSetupsInspector()
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
    /// Which stage it serves: the part and stock, or the clamp kit's workholding.
    enum Scope { case partStock, part, stock, clampKit }
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
                // No stock, stock the part doesn't fit, or stock that needs milling down first:
                // a bar you can buy that goes straight into the clamp kit is worth showing.
                if model.part != nil, model.stock == nil || model.stockOptions().first(where: { $0.axes == model.setup.stockAxes })
                    .map({ !$0.workable || $0.prepHeight != nil || $0.viaShoulders }) ?? true {
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

            if scope == .clampKit {
                Section {
                    LabeledContent("Method", value: model.holdingPath.title)
                    Button("Change Workholding…") { model.enter(.holding) }
                }
            }
            if scope == .clampKit, let stock = model.stock, let p = model.clampPlacement(stockSize: model.setup.stockSize(stock)) {
                Section {
                    LabeledContent("Fixture", value: "Clamp kit ×\(p.clamps.count), across both T-slots")
                    if model.setup.shoulders == nil {
                        ClampCountPicker(stockWidth: model.setup.stockSize(stock).y)
                    }
                    LabeledContent("Stock sits", value: p.seat.description)
                    NumberField(title: "Face past the jaws", value: $model.setup.clampProtrusion,
                                tip: "How far the stock face sticks out past the clamp's front. More keeps the collet nut clear of the jaws; less grips more of the stock.")
                    if let auto = model.autoProtrusion {
                        Label("The toolpaths cut deep near the clamped edges, so the face stands out **\(Length.mm(auto)) mm** past the jaws (parallels behind it): no tool, shank or collet nut reaches the clamps. The jaws still hold \(Length.mm(model.setup.stockSize(stock).z - auto)) mm of the stock.",
                              systemImage: "shield.lefthalf.filled")
                            .font(.caption).foregroundStyle(Theme.accent)
                    }
                    HStack {
                        Toggle("Soft jaws", isOn: $model.setup.clampSoftJaw)
                        let soft = UniversalClamp.onJaw(softJaw: true), bare = UniversalClamp.onJaw(softJaw: false)
                        InfoTip(text: "The blocks under the two top screws. Off: the screws press the stock directly, so stock up to \(Length.mm(UniversalClamp.onJaw(softJaw: false).upperBound)) mm tall fits instead of \(Length.mm(UniversalClamp.onJaw.upperBound)) mm. "
                                + (model.setup.shoulders != nil ? "With shoulders the soft jaws grip \(Length.mm(soft.lowerBound))–\(Length.mm(soft.upperBound)) mm, so the ends are milled deeper; without them up to \(Length.mm(bare.upperBound)) mm. The stock prep follows this choice. " : "")
                                + UniversalClamp.noSoftJawDisclaimer)
                    }
                    LabeledContent("Parallels behind", value: p.parallels > 0.05 ? "\(Length.mm(p.parallels)) mm" : "none")
                    if case .kitClamp(let i) = model.bedSelection {
                        NumberField(title: "Clamp \(i + 1) along the T-slots", value: Binding(get: { model.kitClampShift(i) }, set: { model.setKitClampShift(i, $0) }),
                                    tip: "Slides the clamp in its T-slots from where Coastline put it (12 mm in from the stock's end). Its jaw must stay under the stock; the toolpaths are checked against it again.")
                    }
                    if !model.setup.kitClampShift.isEmpty {
                        Button("Clamps Back Where Coastline Put Them", systemImage: "arrow.uturn.backward") { model.setup.kitClampShift = [] }
                    }
                    if let sh = model.setup.shoulders {
                        let raw = model.setup.rawStockSize(stock)
                        Label(sh.height < raw.x - 0.01
                              ? "Held by its shoulders: the clamps grip the \(Length.mm(sh.length)) mm ends, milled down to \(Length.mm(sh.height)) mm on the bed first. The full-height middle carries the part."
                              : "The clamps grip the bar's two ends only: the part can reach its top and bottom edges.",
                              systemImage: "square.split.1x2")
                            .font(.caption)
                    } else if p.seat.kind == .tooTall || model.setup.downsizeHeight != nil {
                        StockAdviceView(stock: stock)
                    }
                } header: {
                    HStack {
                        Text("Workholding")
                        InfoTip(text: "Press on a universal clamp in the 3D view to slide it along the T-slots, or on the stock and drag it toward the spindle to stand it out further. The orange strips are what the jaws hold: never cut. "
                                + UniversalClamp.capacity(softJaw: model.setup.clampSoftJaw) + " Each clamp bolts into both T-slots; the soft jaw presses the stock's top edge, and parallels behind it push the face out past the jaws, clear of the tool and collet nut.")
                    }
                }
            }

            if scope == .clampKit {
                ProbingMethodSection()
            }
            if scope == .clampKit, model.setup.shoulders != nil {
                ShoulderSection()  // what the clamps grip: set here, the stock prep follows
            }
            if scope == .partStock, model.part != nil, model.stock != nil {
                PlacementSection()
                IssuesSection(issues: model.setupIssues)
            }
            if scope == .clampKit, model.part != nil && model.stock != nil {
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
            if scope == .clampKit {
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


/// Keep stock-finding choices beside the setup that uses them, as well as in Settings.
/// This is the shared clamp-kit preference; excluded setups retain manual edge finding.
struct ProbingMethodSection: View {
    @Environment(AppModel.self) private var model
    @Bindable private var settings = AppSettings.shared

    private var unavailable: String? {
        if !model.setup.usesClampKit {
            return model.setup.holding == .custom
                ? "Electronic probing needs verified electrical isolation. Use the edge finder and paper with this custom fixture."
                : "The bed's clamps and stops are not electrically isolated. Use the edge finder and paper for this setup."
        }
        if let material = model.stock?.material, [.wax, .plastic, .printedResin].contains(material.family) {
            return "\(material.name) does not conduct electricity. Use the edge finder and paper for this stock."
        }
        return nil
    }

    var body: some View {
        Section {
            if model.setup.planFromFixtureLibrary {
                LabeledContent("Method", value: "Fixture datum · manual verification")
                Text("For each setup, establish X0 Y0 at the defined stock-face centre and Z0 at the original face. Use the fixture's locating datum and account for material already removed. The guided job stops for this verification at every re-clamping.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let unavailable {
                LabeledContent("Method", value: "Edge finder and paper")
                Label(unavailable, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Method", selection: $settings.clampKitProbing) {
                    ForEach(AppSettings.ClampKitProbing.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityLabel("Stock probing method")
                .disabled(model.isGenerating)
                Text(settings.clampKitProbing == .electrical
                     ? "The tool finds edges and the face with G38.2. Connect the probe wire to conductive stock in the insulated clamp kit; the guided job walks through each contact."
                     : "Find X and Y with the spinning edge finder, then touch off Z with paper. The guided job walks through each step.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Work zero")
        } footer: {
            if unavailable == nil && !model.setup.planFromFixtureLibrary {
                Text("Saved as the preference for clamp-kit jobs. Used when exporting or running the guided setup.")
            }
        }
    }
}


/// What limits machining this part as set up: the same findings, highlights and ways forward
/// as the Plan step (MachinabilitySection), under this inspector's own heading.
struct AnalysisSection: View {
    var body: some View { MachinabilitySection(title: "Analysis") }
}

/// What to do when the stock doesn't fit the clamp kit: turn it, use other stock, buy stock
/// that fits, or mill it down first on the side clamps (with an honest warning).
struct StockAdviceView: View {
    let stock: StockItem
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        if let part = model.part {
            let (lo, hi) = model.setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
            let size = hi - lo
            let tool = OperationPlanner.usableTools(inventory.inventory, machine: model.machine).filter { $0.kind == .flatEndMill && $0.diameter <= 6.36 }
                .max { $0.diameter < $1.diameter }
            let margin = (tool?.diameter ?? 6.35) + 3
            let depth = size.z + model.setup.topAllowance + 1
            let ideal = StockAdvice.idealSize(part: size, twoSided: model.twoSided, topAllowance: model.setup.topAllowance,
                                              toolDiameter: tool?.diameter ?? 6.35)
            let raw = model.setup.rawStockSize(stock)
            VStack(alignment: .leading, spacing: 8) {
                Label("Stock that fits the kit for this part: about \(Length.mm(ideal.x)) mm tall × \(Length.mm(ideal.y)) long × \(Length.mm(ideal.z)) thick.",
                      systemImage: "shippingbox")
                if let axes = StockAdvice.turnToFit(stock: stock, part: size, margin: margin, depth: depth), axes != model.setup.stockAxes {
                    Button("Turn the Stock to Fit", systemImage: "rotate.3d") { model.setup.stockAxes = axes; model.setup.downsizeHeight = nil }
                        .plainGlassButton()
                }
                let others = inventory.inventory.stock.filter { s in
                    s.id != stock.id && s.quantity > 0 && s.materialID == stock.materialID
                        && StockAdvice.turnToFit(stock: s, part: size, margin: margin, depth: depth) != nil
                }
                ForEach(others) { s in
                    Button("Use \(s.sizeDescription) from Your Inventory", systemImage: "cube") {
                        model.useStock(s)
                        if let axes = StockAdvice.turnToFit(stock: s, part: size, margin: margin, depth: depth) { model.setup.stockAxes = axes }
                        model.setup.downsizeHeight = nil
                    }
                    .plainGlassButton()
                }
                let jaw = UniversalClamp.onJaw(softJaw: model.setup.clampSoftJaw)
                if !model.setup.clampSoftJaw || raw.x > UniversalClamp.onJaw(softJaw: false).upperBound {
                } else if raw.x > jaw.upperBound {
                    Label("Without the soft jaws this stock fits as it is (up to \(Length.mm(UniversalClamp.onJaw(softJaw: false).upperBound)) mm), with less clamping force.",
                          systemImage: "lightbulb")
                }
                if model.prepAuto {
                    Label("Planned automatically: the stock didn't fit the clamp kit as oriented.", systemImage: "wand.and.stars").foregroundStyle(Theme.accent)
                }
                if ideal.x <= jaw.upperBound, raw.x > jaw.upperBound {
                    let target = min(max(ideal.x, jaw.lowerBound), jaw.upperBound - 0.5).rounded(.down)
                    let est = StockAdvice.downsize(stock: raw, target: target, tool: tool, material: stock.material, machine: model.machine)
                    Toggle(stock.finish == .sawn ? "Square it and mill it down to \(Length.mm(target)) mm first" : "Mill it down to \(Length.mm(target)) mm first", isOn: Binding(
                        get: { model.setup.downsizeHeight != nil },
                        set: { model.setup.downsizeHeight = $0 ? target : nil; if !$0 { model.previewMillDown = false } }))
                    let plan = model.flatPrepPlan
                    let sawText = plan?.sawLength.map { " You saw a \(Length.mm($0)) mm piece off first;" } ?? ""
                    let ends = plan?.faceEnds == true ? " its sawn ends are faced square," : ""
                    let rounds = (plan?.rounds ?? 1) > 1 ? " in \(plan!.rounds) rounds" : ""
                    Label("Flat on the squaring stop with two 3\" C-clamps.\(sawText)\(ends) then the long edge is milled down\(rounds), removing \(Length.mm(est.volume / 1000)) cm³\(est.minutes.map { ", about \(AppModel.duration($0 * 60)) of cutting" } ?? ""). Buying stock about \(Length.mm(target)) × \(Length.mm(raw.y)) × \(Length.mm(raw.z)) mm is usually cheaper and quicker.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                    if model.setup.downsizeHeight != nil {
                        Toggle("Show the mill-down setup", isOn: Binding(get: { model.previewMillDown }, set: { model.previewMillDown = $0 }))
                    }
                } else if ideal.x > jaw.upperBound {
                    // Room around the part is set by the roughing tool: a smaller one may make it fit.
                    let small = OperationPlanner.usableTools(inventory.inventory, machine: model.machine).filter { $0.kind == .flatEndMill && $0.diameter >= 1.5 }
                        .min { $0.diameter < $1.diameter }
                    if let small, let fit = Optional(StockAdvice.idealSize(part: size, twoSided: model.twoSided, topAllowance: model.setup.topAllowance,
                                                                          toolDiameter: small.diameter)),
                       fit.x <= jaw.upperBound {
                        Label("With the \(small.name) roughing (less room needed around the part), stock about \(Length.mm(fit.x)) × \(Length.mm(fit.y)) × \(Length.mm(fit.z)) mm fits the kit. Slower roughing, but no milling down.",
                              systemImage: "lightbulb")
                    } else {
                        Label("In this orientation the part is too tall for the clamp kit (\(Length.mm(jaw.upperBound)) mm). Turn the part on the Orientation section, or hold it on the side clamps.",
                              systemImage: "xmark.octagon").foregroundStyle(Theme.danger)
                    }
                }
            }
            .font(.callout)
        }
    }
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
            let most = model.maxCopies
            Stepper(value: Binding(get: { model.setup.copies }, set: { v in var s = model.setup; s.copies = min(max(v, 1), max(most, 1)); model.setup = model.placementLimited(s) }),
                    in: 1...max(most, 1)) {
                LabeledContent("Copies in this bar", value: most > 1 ? "\(model.setup.copies) of up to \(most)" : "1 (no room for more)")
            }
            .help("Batching: the same part side by side along the bar, each with its own frame and tabs. The toolpaths are repeated for each copy; facing runs once.")
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

/// One universal clamp or two: Coastline's suggestion (from the stock's width), overridable.
private struct ClampCountPicker: View {
    @Environment(AppModel.self) private var model
    let stockWidth: Double

    var body: some View {
        let suggested = UniversalClamp.suggestedCount(stockWidth: stockWidth)
        HStack {
            Picker("Clamps", selection: Binding(
                get: { model.setup.kitClampCount ?? 0 },
                set: { n in
                    // The slides were for the old clamps: start again from where Coastline puts them.
                    var s = model.setup
                    s.kitClampShift = []
                    s.kitClampCount = n == 0 ? nil : n
                    model.setup = s
                })) {
                Text("Automatic (\(suggested.count == 1 ? "one" : "two"))").tag(0)
                Text("One").tag(1)
                Text("Two").tag(2).disabled(stockWidth < UniversalClamp.twoClampMinWidth)
            }
            InfoTip(text: suggested.why + " Two clamps need at least \(Length.mm(UniversalClamp.twoClampMinWidth)) mm of stock; one holding more than \(Length.mm(UniversalClamp.singleClampWarnWidth)) mm is warned about. Changing this plans the toolpaths again, since the clamps' strips are kept out of the cut.")
        }
    }
}

/// Standard bar sizes you can buy that the part fits in the clamp kit (StockCatalog).
private struct StandardStockSuggestions: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        let fits = model.standardStockThatFits(in: inventory.inventory)
        if !fits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Standard sizes that go straight into the clamp kit").font(.callout.weight(.semibold))
                ForEach(fits) { s in
                    Button("\(s.material?.name ?? "Stock") · \(s.sizeDescription)", systemImage: "cart") { model.useStock(s) }
                        .plainGlassButton()
                        .help(s.notes.replacingOccurrences(of: "Not in your inventory: a standard size. ", with: ""))
                }
            }
        }
    }
}
