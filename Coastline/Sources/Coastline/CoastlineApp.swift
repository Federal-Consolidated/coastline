import simd
import AppKit
import CoastlineCore
import SwiftUI
import Viewport

@main
struct CoastlineApp: App {
    @State private var model = AppModel()
    @State private var inventory = InventoryModel()

    init() {
        // `swift run` starts a bare executable; make it a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        AppSettings.shared.apply()
    }

    var body: some Scene {
        WindowGroup(ProcessInfo.processInfo.environment["COASTLINE_DEV"] == "1" ? "Coastline · Debug" : "Coastline") {
            ContentView()
                .containerBackground(Theme.windowBackground, for: .window)
                .environment(model)
                .environment(inventory)
                .tint(Theme.accent)
                .frame(minWidth: 1040, minHeight: 640)
                .task {
                    model.stockLookup = { [inventory] id in inventory.inventory.stock.first { $0.id == id } }
                    model.toolLookup = { [inventory] id in inventory.inventory.tools.first { $0.id == id } }
                    model.fixtureLookup = { [inventory] id in inventory.inventory.fixtures.first { $0.id == id } }
                    model.inventoryLookup = { [inventory] in inventory.inventory }
                    await model.restoreDevelopmentSession()
                    await Automation.runIfRequested(model, inventory)
                }
                // A .coastline file double-clicked in Finder (the packaged app declares the type).
                .onOpenURL { url in
                    guard url.pathExtension == "coastline" else { return }
                    Task { await model.openProject(url); model.page = .workspace }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.saveDevelopmentSession()
                    model.mill.shutdown()
                    inventory.saveNow()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openProjectInteractively() }.keyboardShortcut("o")
                Divider()
                Menu("Open Recent") {
                    ForEach(AppModel.recentProjects, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { Task { await model.openProject(url) } }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveProjectInteractively() }.keyboardShortcut("s")
                Button("Save As…") { model.saveProjectInteractively(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoName.map { "Undo \($0)" } ?? "Undo") { model.undoAnywhere() }.keyboardShortcut("z")
                Button(model.redoName.map { "Redo \($0)" } ?? "Redo") { model.redoAnywhere() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                EmptyView()
            }
            CommandGroup(after: .sidebar) {
                // ⌘1…⌘9 for the first nine pages (a key is one character).
                ForEach(Array(SidebarItem.allCases.enumerated()).filter { $0.element != .materials }, id: \.element) { index, item in
                    if index < 9 {
                        Button(item.title) { model.page = item }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else {
                        Button(item.title) { model.page = item }
                    }
                }
            }
            // Toolpaths (⌘G, ⌘.), Playback (Space, arrows, ⌘[ ⌘]) and View ▸ Measure (M).
            CoastlineCommands(model: model, inventory: inventory)
            MachineCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(inventory)
                .tint(Theme.accent)
        }
    }
}

/// Scripted runs for checks without screen access (like the sender's DebugAutomation), e.g.
/// `COASTLINE_SCRIPT="page tools; wait 1; wsnap /tmp/tools.png; quit"`.
/// - `snap` renders the 3D viewport off screen (Metal).
/// - `wsnap` captures the whole window through the window server, Liquid Glass included.
/// Set `COASTLINE_INVENTORY=/tmp/x.json` so automation doesn't touch the real inventory.
@MainActor
enum Automation {
    static func runIfRequested(_ model: AppModel, _ inventory: InventoryModel) async {
        guard let script = ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] else { return }
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered, so logs survive a killed run
        for command in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "import": await model.importPart(URL(fileURLWithPath: arg))
            case "stress": model.loadStressToolpath(count: Int(arg) ?? 1_000_000)
            case "view": if let v = OrbitCamera.StandardView(rawValue: arg) { model.setView(v) }
            case "section": model.sectionOn = arg != "off"
            case "zoom": model.renderer.camera.zoom(by: Float(arg) ?? 1)
            case "page": if let p = SidebarItem(rawValue: arg == "jobs" ? "projects" : arg) { model.page = p }  // "jobs": the old page
            case "mill": millCommand(model.mill, arg)  // Simulated Mill only: "mill sim", "mill home", "mill jog y -10"
            case "jobselect": model.jobs.selection = model.jobs.entries.first { $0.job.id == arg }?.folder  // "jobselect my-job": by job id
            case "jobpreview": await jobPreviewCommand(model, arg)  // "jobpreview mill-well": the selected job's program
            case "jobstart", "jobsim", "jobnext", "jobback", "jobrun", "jobair", "jobstatus": await jobCommand(model, parts[0])
            case "addthread":  // "addthread M3 [depth]": a thread milling operation, as the menu adds it
                var op = Operation(kind: .thread)
                model.prepareThread(&op, inventory: inventory.inventory)
                let words = arg.split(separator: " ").map(String.init)
                if let name = words.first, let spec = ThreadSpec.named(name) {
                    op.thread = ThreadMilling(spec: name, depth: words.count > 1 ? Double(words[1]) : nil)
                    op.toolID = inventory.inventory.tools.filter { $0.kind == .threadMill && spec.canBeCut(by: $0) }
                        .min { ($0.quantity > 0 ? 0 : 1, -$0.fluteLength) < ($1.quantity > 0 ? 0 : 1, -$1.fluteLength) }?.id
                }
                model.operations.append(op)
                print("addthread \(op.thread?.spec ?? "-") tool \(op.toolID.flatMap { id in inventory.inventory.tools.first { $0.id == id }?.name } ?? "none") holes \(model.features?.holes.map(\.diameter) ?? [])")
            case "texture":  // "texture barleycorn 10": a texture of that pattern and size at the face's centre
                let words = arg.split(separator: " ").map(String.init)
                var op = Operation(kind: .engrave)
                var e = Engraving(text: "", depth: 0.08)
                var t = Texture.preset(words.first.flatMap { Texture.Pattern(rawValue: $0) } ?? .barleycorn)
                if words.count > 1, let w = Double(words[1]) { t.width = w; t.height = w * 0.6 }
                e.texture = t
                op.engraving = e
                op.toolID = OperationPlanner.usableTools(inventory.inventory, machine: model.machine)
                    .filter { [.engraver, .chamferMill, .ballEndMill, .flatEndMill].contains($0.kind) && $0.diameter <= 3.2 }
                    .min { ($0.kind == .engraver ? 0 : 1, $0.diameter) < ($1.kind == .engraver ? 0 : 1, $1.diameter) }?.id
                model.justAddedOperation = op.id
                model.operations.append(op)
                print("texture \(t.pattern) lines \(t.lines().count) tool \(inventory.inventory.tools.first { $0.id == op.toolID }?.name ?? "none") title \(op.title)")
            case "toolspin":  // the tool mesh's turn now, and what's playing
                let t = model.renderer.scene.mesh("tool")?.transform
                let angle = t.map { atan2(Double($0.columns.0.y), Double($0.columns.0.x)) * 180 / .pi } ?? .nan
                let e = model.timeline.entries.isEmpty ? nil : model.timeline.entries[min(max(model.timeline.index(at: model.playhead), 0), model.timeline.entries.count - 1)]
                print("toolspin playing \(model.isPlaying) angle \(Int(angle)) spin \(model.toolSpin) playhead \(String(format: "%.1f", model.playhead)) program \(e.map { "\($0.program)" } ?? "-") tool \(model.currentTool?.name ?? "-")")
            case "projectspick": model.projectsPick = arg  // before "page projects": what it selects
            case "stock":  // "stock 0" = first stock item in the inventory
                let items = inventory.inventory.stock
                if let i = Int(arg), items.indices.contains(i) { model.useStock(items[i]) }
            case "machine": if let m = MachineDisplay(rawValue: arg) { model.machineDisplay = m }
            case "sweep": model.sweepTravel(duration: Double(arg) ?? 4)
            case "realistic": model.realistic = arg != "off"
            case "guards": model.showChipGuards = arg != "off"
            case "stockview": if let d = StockDisplay(rawValue: arg) { model.stockDisplay = d }
            case "isolate": model.isolateWork = arg != "off"
            case "plans":
                await model.findPlans(inventory: inventory.inventory)
                print("sides twoSided=\(model.twoSided) chosen=\(model.twoSidedChosen) splitZ=\(model.splitZ.map { String($0) } ?? "-") topAllowance=\(model.setup.topAllowance)")
                for c in model.planOptions {
                    print("plan \(c.name) minutes=\(Int(c.minutes)) finish=\(Int(c.finish)) risk=\(c.risk) ops=\(c.operations.map { $0.kind.rawValue + ($0.pocketsOnly == true ? "(pockets)" : "") }) needs=\(c.needsTools.map(\.name)) remedies=\(c.remedies.map(\.title))")
                    for r in c.reasons where r.hasPrefix("Risk") || r.contains("pockets") { print("   \(r)") }
                }
            case "useplan":
                // "mid": Find the Best Plan's middle tier. Plans with a tool to buy first when
                // there are any (they're better, or they wouldn't be offered); among those the
                // Balanced one, else the middle one by time (of two, the finer).
                var name = arg == "recommended" ? (model.recommendedPlan ?? "") : arg
                if arg == "mid" || arg == "owned" {
                    // "owned": only plans with the tools you have (the first-cut coupon).
                    let buy = model.planOptions.filter { !$0.needsTools.isEmpty }
                    let have = model.planOptions.filter(\.needsTools.isEmpty)
                    let pool = (arg == "owned" ? have : buy.isEmpty ? model.planOptions : buy).sorted { $0.minutes < $1.minutes }
                    name = (pool.first { $0.name.hasPrefix("Balanced") } ?? (pool.isEmpty ? nil : pool[pool.count / 2]))?.name ?? ""
                }
                if let c = model.planOptions.first(where: { $0.name == name }) { model.usePlan(c); print("using plan \(c.name) to buy \(model.jobToolsToBuy.map(\.name))") }
            case "paths": model.pathsVisible = arg != "off"
            case "workarea": model.showWorkArea = arg != "off"
            case "cutface": model.showCutFace = arg != "off"
            case "simdebug":
                for id in ["simstock", "simstock.back"] {
                    guard let m = model.renderer.scene.mesh(id) else { print("simdebug \(id) none"); continue }
                    var out: [String] = []
                    m.updateVertices { v in
                        for i in [0, 5000, 40000, 120000] where i * 6 + 5 < v.count {
                            out.append(String(format: "[z %.2f n %.2f %.2f %.2f]", v[i * 6 + 2], v[i * 6 + 3], v[i * 6 + 4], v[i * 6 + 5]))
                        }
                    }
                    print("simdebug \(id) visible \(m.isVisible) \(out.joined(separator: " ")) transform \(m.transform.columns.0) \(m.transform.columns.2)")
                }
            case "tabmoves":
                // Per operation on side B: the lowest cutting move whose tool covers a tab centre.
                if let r = model.result(forSide: 1) {
                    for (k, path) in r.paths.enumerated() where k < r.planned.count {
                        let rad = r.planned[k].tool.diameter / 2
                        var lowest = Double.infinity, count = 0
                        var roles: [String: Int] = [:]
                        for m in path.moves where m.role != .rapid {
                            for t in model.placedTabs where simd_distance(SIMD2(m.x, m.y), t.centre) < rad + 0.5 {
                                lowest = min(lowest, m.z); count += 1
                                if m.z < -15.3 { roles["\(m.role)", default: 0] += 1 }
                            }
                        }
                        print("  low roles \(roles)")
                        print("tabmoves \(r.planned[k].operation.kind.title) \(r.planned[k].tool.name.prefix(14)): \(count) moves over tabs, lowest z \(lowest.isFinite ? String(format: "%.2f", lowest) : "-")")
                    }
                }
            case "travelscan":
                // Every move of the clamping on screen in machine coordinates: anything outside the travel.
                if let r = model.result(forSide: model.viewSide) {
                    let e = model.machine.machineEnvelope
                    var worst: (String, SIMD3<Double>)? = nil, count = 0, total = 0
                    for (k, path) in r.paths.enumerated() where k < r.planned.count {
                        guard let toM = model.machineMapper(stickout: r.planned[k].tool.stickout) else { continue }
                        for m in path.moves {
                            total += 1
                            let q = toM(m.position)
                            if !(e.x.contains(q.x) && e.y.contains(q.y) && e.z.contains(q.z)) {
                                count += 1
                                if worst == nil { worst = ("\(r.planned[k].operation.kind.title) \(m.role) work \(String(format: "%.2f %.2f %.2f", m.x, m.y, m.z))", q) }
                            }
                        }
                    }
                    print("travelscan side \(model.viewSide): \(count) of \(total) moves outside" + (worst.map { " · first: \($0.0) → machine \(String(format: "%.2f %.2f %.2f", $0.1.x, $0.1.y, $0.1.z))" } ?? ""))
                } else { print("travelscan side \(model.viewSide): no result") }
            case "tabcheck":
                // The final side's heights along each tab, from the part outward (top, back).
                if let hm = model.heightmap {
                    for t in model.placedTabs {
                        var row: [String] = []
                        for k in stride(from: 0.0, through: 22.0, by: 2.0) {
                            let p = t.centre + t.normal * k
                            let c = Int(((p.x - hm.origin.x) / hm.cell).rounded()), r = Int(((p.y - hm.origin.y) / hm.cell).rounded())
                            guard c >= 0, r >= 0, c < hm.cols, r < hm.rows else { continue }
                            let i = r * hm.cols + c
                            row.append(String(format: "%+.0f:%.2f/%.2f", k, hm.heights[i], model.simBack?[i] ?? -99))
                        }
                        print("tab at \(t.centre) " + row.joined(separator: " "))
                    }
                }
            case "thumb":  // "thumb /tmp/t.png": the project icon as it would be saved
                if let img = model.projectThumbnail(), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: arg)); print("thumb written \(arg)")
                } else { print("thumb none") }
            case "dumpprogram":  // "dumpprogram 3 /tmp/p3.nc": that program's G-code as posted
                let p = arg.split(separator: " ", maxSplits: 1).map(String.init)
                if p.count == 2, let n = Int(p[0]), model.programs.indices.contains(n - 1) {
                    try? model.programs[n - 1].gcode.write(toFile: p[1], atomically: true, encoding: .utf8); print("dumped program \(n)")
                }
            case "stage":  // "stage machining": the workflow stage, as the stage bar sets it
                let stages: [String: JobStage] = ["part": .partStock, "stock": .stock, "setups": .setups, "planning": .planning, "machining": .machining, "review": .review]
                if let s = stages[arg] { model.enter(s); print("stage \(model.stage) canVisit \(model.canVisit(s))") }
            case "shot":  // "shot /tmp/s.png": the workspace as it is shown (camera and visibility untouched)
                do { try model.renderer.snapshot(width: 1200, height: 800, to: URL(fileURLWithPath: arg)); print("shot written \(arg)") }
                catch { print("shot failed: \(error)") }
            case "showside":  // "showside 3": that side's setup in the workspace, framed
                model.show(side: Int(arg) ?? 0); model.focusWork()
                let fixtures = model.renderer.scene.meshes.filter { $0.id.hasPrefix("fixture.") && $0.isVisible }.map(\.id)
                print("showside \(model.viewSide) stock \(model.displayStockSize.map { "\($0)" } ?? "-") fixture \(model.displayedJobFixture?.name ?? "-") meshes \(fixtures)")
            case "setupstep":  // "setupstep 2": the plan's second setup, as at the machine
                if let plan = model.libraryWorkholdingPlan, let n = Int(arg), plan.steps.indices.contains(n - 1) {
                    let step = plan.steps[n - 1]
                    model.inspectLibraryStep(step)
                    let fixtures = model.renderer.scene.meshes.filter { $0.id.hasPrefix("fixture.") && $0.isVisible }.map(\.id)
                    print("setupstep \(n) side \(step.side) fixture \(step.fixture.name) stock \(model.displayStockSize.map { "\($0)" } ?? "-") meshes \(fixtures)")
                } else { print("setupstep none (\(model.libraryWorkholdingPlan?.steps.count ?? 0) steps)") }
            case "movestep":  // "movestep 3 -1": the plan's third setup one earlier
                let p = arg.split(separator: " ").compactMap { Int($0) }
                if p.count == 2, let plan = model.libraryWorkholdingPlan, plan.steps.indices.contains(p[0] - 1) {
                    model.moveLibraryStep(plan.steps[p[0] - 1].id, by: p[1])
                    print("movestep order \(model.libraryWorkholdingPlan?.steps.map { "\($0.number):\($0.side)" } ?? []) note \(model.stepOrderNote ?? "-")")
                }
            case "coverageselect":  // "coverageselect 5": click that setup in the Setups list
                if let c = model.planCoverage, let s = c.setups.first(where: { $0.number == Int(arg) }) {
                    model.selectCoverage(s)
                    let fixtures = model.renderer.scene.meshes.filter { $0.id.hasPrefix("fixture.") && $0.isVisible }.map(\.id)
                    print("coverageselect \(s.number) side \(model.viewSide) stock \(model.displayStockSize.map { "\($0)" } ?? "-") fixture \(model.displayedJobFixture?.name ?? "-") meshes \(fixtures) status \(model.status)")
                }
            case "coverage":  // the setups the part check proposes, and what each cuts
                if let c = model.planCoverage {
                    for s in c.setups { print("coverage setup \(s.number) \(s.side) toolpaths=\(s.toolpaths) faces=\(s.faces.count) \(s.titles.prefix(3)) note=\(s.note ?? "-")") }
                } else { print("coverage none") }
            case "optimes":  // simulated minutes per operation, both sides, longest first
                var rows: [(String, Double)] = []
                for r in model.sideResults {
                    for (k, path) in r.paths.enumerated() where k < r.planned.count {
                        let p = r.planned[k]
                        rows.append(("side \(r.side) \(p.operation.title)\(p.operation.pocketsOnly == true ? " (pockets)" : "") · \(p.tool.name.prefix(24)) · \(path.moves.count) moves", TimeEstimate.seconds([path], machine: model.machine) / 60))
                    }
                }
                for (name, m) in rows.sorted(by: { $0.1 > $1.1 }) { print(String(format: "optimes %6.1f min  ", m) + name) }
            case "edgemoves":  // cutting moves near the stock's X edges, per operation (side on screen)
                if let r = model.result(forSide: model.viewSide), let st = model.stock {
                    let hx = model.setup.stockSize(st).x / 2
                    print("edgemoves stock half \(hx)")
                    for (k, path) in r.paths.enumerated() where k < r.planned.count {
                        let rad = r.planned[k].tool.diameter / 2
                        let reach = path.moves.filter { $0.role != .rapid && abs($0.x) + rad >= hx - 0.05 }
                        guard !reach.isEmpty else { continue }
                        print("  \(r.planned[k].operation.title) \(r.planned[k].tool.name.prefix(12)): \(reach.count) moves reach the edge, max |x| \(String(format: "%.2f", reach.map { abs($0.x) }.max() ?? 0)), z \(String(format: "%.2f…%.2f", reach.map(\.z).min() ?? 0, reach.map(\.z).max() ?? 0))")
                    }
                }
            case "loose": print("loose pieces \(model.loosePieces) walls \(model.renderer.scene.mesh("simstock.walls") != nil ? "yes" : "no")")
            case "mesh":  // "mesh stock": colour, material and visibility of a scene mesh
                if let m = model.renderer.scene.mesh(arg) {
                    print("mesh \(arg) color=\(m.color) visible=\(m.isVisible) material=\(m.material) realistic=\(model.renderer.realistic) display=\(model.stockDisplay)")
                } else { print("mesh \(arg) missing") }
            case "measure": model.measuring = arg != "off"
            case "fit": model.focusWork()
            case "tab": model.enter(arg == "machining" ? .machining : .partStock)
            case "stagebar": if let st = JobStage.allCases.first(where: { "\($0)" == arg }) { model.enter(st) }
            case "suggest": await suggestCommand(model, inventory)
            case "generate": await generateCommand(model, inventory)
            case "generatebg":  // start generating and go on (background generation)
                Task { @MainActor in await generateCommand(model, inventory) }
                try? await Task.sleep(for: .milliseconds(300))
            case "waitgen":  // until the background generation ends
                while model.isGenerating { try? await Task.sleep(for: .milliseconds(500)) }
                try? await Task.sleep(for: .seconds(1))
            case "genstate":
                print("genstate \(model.status) | sides shown \(model.sideResults.map { $0.planned.count }) timeline \(Int(model.timeline.duration)) s playhead \(Int(model.playhead)) playing \(model.isPlaying) | failed \(model.failedOperationCount)")
            case "scrollto": model.inspectorScrollTarget = arg
            case "tuner": if let p = Tuning.Preset(rawValue: arg) { model.tuning = .preset(p) }
            case "export":
                let dir = URL(fileURLWithPath: arg)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                do { print("exported", try model.exportPrograms(to: dir).map(\.lastPathComponent)) } catch { print("export failed: \(error)") }
            case "orbit":
                let d = arg.split(separator: " ").compactMap { Float($0) }
                if d.count == 2 { model.renderer.camera.orbit(dx: d[0], dy: d[1]) }
            case "perspective": model.perspective = arg != "off"
            case "twosided": model.twoSided = arg != "off"; model.twoSidedChosen = true
            case "holdtabs": model.holdWithTabs = arg != "off"; print("hold with tabs \(model.holdWithTabs)")
            case "side": model.viewSide = Int(arg) ?? 0
            case "analysis":
                if let a = model.analysis {
                    print("analysis corner=\(a.minCornerRadius ?? -1) concave=\(a.minConcaveRadius ?? -1) undercut=\(a.undercutArea) tris=\(a.undercutTriangles.count / 9) thin=\(a.thinnestWall ?? -1) undercutMesh=\(model.renderer.scene.mesh("undercuts") != nil)")
                } else { print("analysis none") }
                // Machinability: "analysis <finding id>" also selects that finding (its highlight).
                if let findings = model.dfmFindings(inventory: inventory.inventory) {
                    if !arg.isEmpty { model.selectFinding(findings.first { $0.id == arg }) }
                    print("dfm " + findings.map { "\($0.id):\($0.category)" }.joined(separator: " "))
                    print("dfm selected \(model.selectedFindingID ?? "-") highlight \(model.renderer.scene.mesh("dfm.highlight") != nil) access \(model.analysis?.access.map { "faces \($0.faces.count) regions \($0.regions.count) floors \($0.floors.count) holes \($0.holes.count) tris \($0.triangles.count / 9)" } ?? "none")")
                } else { print("dfm checking\(model.analysisFailed ? " (failed)" : "")") }
            case "seek": model.seek((Double(arg) ?? 0.5) * model.timeline.duration)  // fraction of the job
            case "cancelafter":  // "cancelafter 8": cancel the next generation after 8 s
                let delay = Double(arg) ?? 5
                Task { @MainActor in try? await Task.sleep(for: .seconds(delay)); model.cancelGenerationNow() }
            case "scale": model.setup.partScale = Double(arg) ?? 1
            case "jog":  // "jog -40 -120 -30": machine coordinates
                let v = arg.split(separator: " ").compactMap { Double($0) }
                model.jogOpen = true
                if v.count == 3 { model.jog(to: SIMD3(v[0], v[1], v[2])) }
            case "saveproject": try? model.saveProject(to: URL(fileURLWithPath: arg)); print("saved \(arg)")
            case "openproject":
                let t0 = Date()
                await model.openProject(URL(fileURLWithPath: arg))
                print("opened \(arg) in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s scale \(model.setup.partScale) programs \(model.programs.count) passed \(model.programs.allSatisfy(\.report.passed)) timeline \(Int(model.timeline.duration)) s status \(model.status)")
            case "undo": await model.undo(); print("undo scale \(model.setup.partScale) canUndo \(model.canUndo)")
            case "undoname": print("undoname \(model.undoName ?? "-") | redoname \(model.redoName ?? "-")")
            case "redo": await model.redo(); print("redo scale \(model.setup.partScale)")
            case "recordjob":  // "recordjob chatter": record the generated job in the (test) journal
                if var e = model.draftJournalEntry() {
                    e.chatter = arg == "chatter"
                    var notes: [String] = []
                    inventory.update { inv in notes = JobJournal.record(e, into: &inv) }
                    model.journal.add(e, tools: inventory.inventory.tools)
                    print("recorded \(e.partName) \(String(format: "%.1f", e.cuttingMinutes)) min, remnant \(e.remnantLength.map { "\($0)" } ?? "-"); \(notes) journal \(model.journal.entries.count) learned \(model.journal.learning.factors)")
                    let worn = inventory.inventory.tools.filter { $0.cuttingMinutes > 0 }.map { "\($0.name.prefix(14)) \(Int($0.cuttingMinutes)) min" }
                    print("tool wear \(worn) stock \(inventory.inventory.stock.map { "\($0.sizeDescription) remnant \($0.isRemnant)" })")
                } else { print("recordjob: nothing generated") }
            case "engrave", "engraveprobe":  // "engrave LOVE": text at the face's centre, finest tool; engraveprobe: following the probed face
                var op = Operation(kind: .engrave)
                op.engraving = Engraving(text: arg, height: 3, depth: 0.15)
                if parts.first == "engraveprobe" { op.engraving?.probeSurface = true }
                op.toolID = OperationPlanner.usableTools(inventory.inventory, machine: model.machine)
                    .filter { [.engraver, .chamferMill, .flatEndMill, .ballEndMill].contains($0.kind) && $0.diameter <= 3.2 }
                    .min { $0.diameter < $1.diameter }?.id
                model.operations.append(op)
                print("engrave \(arg) tool \(inventory.inventory.tools.first { $0.id == op.toolID }?.name ?? "none") size \(op.engraving!.size)")
            case "print":
                print("measure=\(model.measurePoints.map { $0.info?.summary ?? "pending" }) distance=\(model.measuredDistance.map { Length.mm($0) } ?? "-") issues=\(model.setupIssues.map(\.message))")
                print("page=\(model.page) status=\(model.status) tools=\(inventory.inventory.tools.count) stock=\(inventory.inventory.stock.count) error=\(inventory.lastError ?? "-")")
            case "accent": if let a = AppSettings.Accent(rawValue: arg) { AppSettings.shared.accent = a }
            case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
            case "quit":  // a sheet on top would hold the app open
                try? await Task.sleep(for: .milliseconds(300))
                NSApplication.shared.terminate(nil)
            default: print("unknown automation command: \(command)")
            }
        }
    }
}

extension Automation {
    // Async commands live in their own functions: one huge async switch with many awaits
    // tripped a Swift concurrency allocator crash ("freed pointer was not the last allocation").
    static func suggestCommand(_ model: AppModel, _ inventory: InventoryModel) async {
        await model.suggestOperations(inventory: inventory.inventory)
        print("suggest ops=\(model.operations.map(\.kind.rawValue)) notes=\(model.planNotes) error=\(model.errorMessage ?? "-")")
    }

    static func tabHoldCommand(_ model: AppModel) async {
        let held = await model.tabsHold()
        print("tabhold \(held.map { $0.map { $0 ? "holds" : "FLOATS" }.joined(separator: " ") } ?? "no tabs") placed \(model.placedTabs.map { t in "(\(Int(t.centre.x)),\(Int(t.centre.y)) long \(t.extent.map { String(format: "%.1f", $0.length) } ?? "?"))" })")
    }

    static func generateCommand(_ model: AppModel, _ inventory: InventoryModel) async {
        await model.generateToolpaths(inventory: inventory.inventory)
        print("generate status=\(model.status) error=\(model.errorMessage ?? "-")")
        for p in model.programs {
            print("program \(p.index + 1) side \(p.side) \(p.tool.name) passed=\(p.report.passed) lines=\(p.report.lineCount) secs=\(Int(p.seconds)) issues=\(p.report.issues.map(\.message))")
            if let h = p.clearanceHits.first, let r = model.result(forSide: p.side) {
                let moves = zip(r.paths, r.operationProgram).filter { $0.1 == p.index }.flatMap(\.0.moves)
                let k = h.moveIndex
                let around = moves[max(k - 2, 0)...min(k + 1, moves.count - 1)].map { "\($0.role) \($0.motion) (\(String(format: "%.2f %.2f %.2f", $0.x, $0.y, $0.z)))" }
                print("  hit \(h.part) at \(h.position) move \(k): \(around)")
            }
        }
    }
}

/// Window capture through the window server, so Liquid Glass renders (off-screen
/// `cacheDisplay` snapshots don't draw glass). `CGWindowListCreateImage` is looked up at
/// runtime because the SDK marks it unavailable; capturing our own windows needs no permission.
@MainActor
enum WindowSnapshot {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    static func capture(to url: URL) {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.title != "" }) ?? NSApp.windows.first(where: \.isVisible) else {
            print("wsnap: no window")
            return
        }
        let window = main.attachedSheet ?? main  // a sheet on top (start, welcome) is what's on screen
        let rep: NSBitmapImageRep
        // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
        if let createImage, let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
           image.width > 1 {
            rep = NSBitmapImageRep(cgImage: image)
        } else {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: cached)
            rep = cached
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wsnap \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}

extension NSView {
    /// Depth-first search for a subview of a type (automation only).
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for v in subviews {
            if let t = v as? T { return t }
            if let t = v.firstSubview(of: type) { return t }
        }
        return nil
    }
}
