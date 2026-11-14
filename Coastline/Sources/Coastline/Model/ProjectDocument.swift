import AppKit
import CoastlineCore
import Foundation
import UniformTypeIdentifiers

/// A Coastline job saved as a `.coastline` file (JSON): the part file it uses, the stock, how
/// the part sits in it, the sides and tabs, the operations and the tuning, and the generated
/// programs and toolpaths when they were made (`results`, SavedResults.swift): the job then opens
/// ready, with nothing generated again.
struct ProjectFile: Codable, Equatable {
    var version = 1
    var partPath: String?
    var setup: Setup
    var stockID: UUID?
    /// The stock itself, so the job opens after the bar was used up.
    var stock: StockItem?
    var twoSided: Bool
    var twoSidedChosen: Bool
    var holdWithTabs: Bool
    var tabs: HoldingTabs
    var webThickness: Double
    var operations: [Operation]
    var tuning: Tuning
    /// Missing in old projects means the explicit legacy desktop assignment.
    /// New saves include the full definition and its geometry fingerprints.
    var machine: PlanningMachineReference? = nil
    var resources: JobResourceSnapshot? = nil
    /// Only in saved files (snapshots for undo leave it out).
    var results: SavedResults? = nil
}

extension UTType {
    /// `.coastline` (JSON inside). Declared by extension: there's no Info.plist entry yet.
    static let coastlineProject = UTType(filenameExtension: "coastline", conformingTo: .json) ?? .json
}

extension AppModel {
    /// Everything that makes the job, as it is now.
    var projectSnapshot: ProjectFile {
        ProjectFile(partPath: part?.url.path, setup: setup, stockID: stockID, stock: stock, twoSided: twoSided, twoSidedChosen: twoSidedChosen,
                    holdWithTabs: holdWithTabs, tabs: tabs, webThickness: webThickness, operations: operations, tuning: tuning,
                    machine: planningMachineReference, resources: savedResourceSnapshot)
    }

    /// Puts a snapshot back (undo, redo, opening a file). The part is imported again only when
    /// it's a different file.
    @discardableResult
    func apply(_ p: ProjectFile) async -> Bool {
        restoringProject = true
        defer { restoringProject = false; lastSnapshot = projectSnapshot }
        do {
            try await restorePlanningMachine(p.machine ?? .legacy)
        } catch {
            errorMessage = "Couldn't restore this job's machine: \(error.localizedDescription)"
            return false
        }
        // Even identical setup fields can belong to a different saved job. Its cached
        // results are restored explicitly below, after their machine assignment matches.
        clearToolpathResults()
        if let path = p.partPath, path != part?.url.path, FileManager.default.fileExists(atPath: path) {
            await importPart(URL(fileURLWithPath: path))
        }
        jobResources = p.resources ?? JobResourceSnapshot(stock: p.stock,
            tools: (p.results?.programs ?? []).map(\.tool) + (p.results?.prepPrograms ?? []).map(\.tool))
        if let s = p.resources?.stock ?? p.stock { stockSnapshot = s }
        // Older files have no copy: take it from the inventory while it's still there.
        if p.resources?.stock == nil && p.stock == nil, let id = p.stockID, let s = stockLookup(id) { stockSnapshot = s }
        stockID = p.stockID
        setup = p.setup
        twoSided = p.twoSided
        twoSidedChosen = p.twoSidedChosen
        holdWithTabs = p.holdWithTabs
        tabs = p.tabs
        webThickness = p.webThickness
        operations = p.operations
        tuning = p.tuning
        if p.results == nil { await reloadSavedLibraryGeometry() }
        return true
    }

    // MARK: Undo

    /// Called from the job's properties when they change: changes within 0.6 s are one step.
    func noteProjectChange() {
        guard !restoringProject else { return }
        let now = Date()
        if now.timeIntervalSince(lastChangeAt) > 0.6, let before = lastSnapshot, before != projectSnapshot {
            undoHistory.append(before)
            if undoHistory.count > 100 { undoHistory.removeFirst() }
            redoHistory = []
        }
        lastChangeAt = now
        lastSnapshot = projectSnapshot
        projectDirty = true
    }

    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }

    /// What the next undo / redo would change, in words ("part placement", "a C-clamp").
    var undoName: String? { undoHistory.last.map { Self.describeChange(from: $0, to: projectSnapshot) } }
    var redoName: String? { redoHistory.last.map { Self.describeChange(from: projectSnapshot, to: $0) } }

    /// The fields that differ between two snapshots, named for people.
    static func describeChange(from a: ProjectFile, to b: ProjectFile) -> String {
        var names: [String] = []
        func add(_ n: String) { if !names.contains(n) { names.append(n) } }
        if (a.machine ?? .legacy) != (b.machine ?? .legacy) { add("the machine") }
        if a.resources != b.resources { add("job resources") }
        if a.partPath != b.partPath { add("the part") }
        if a.stockID != b.stockID || a.stock != b.stock { add("the stock") }
        if a.twoSided != b.twoSided || a.twoSidedChosen != b.twoSidedChosen { add("one or two sides") }
        if a.holdWithTabs != b.holdWithTabs || a.tabs != b.tabs || a.webThickness != b.webThickness { add("the holding tabs") }
        if a.tuning != b.tuning { add("quality ↔ time") }
        if a.operations != b.operations {
            if b.operations.count > a.operations.count, let new = b.operations.first(where: { op in !a.operations.contains { $0.id == op.id } }) {
                add("adding \(new.kind.title)")
            } else if b.operations.count < a.operations.count, let gone = a.operations.first(where: { op in !b.operations.contains { $0.id == op.id } }) {
                add("removing \(gone.kind.title)")
            } else if let k = a.operations.indices.first(where: { a.operations[$0] != b.operations[$0] }) {
                add(a.operations[k].id == b.operations[k].id ? "\(b.operations[k].kind.title) settings" : "the operation order")
            } else {
                add("the operations")
            }
        }
        if a.setup != b.setup {
            let enc = JSONEncoder()
            let da = (try? enc.encode(a.setup)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            let db = (try? enc.encode(b.setup)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            for key in Set(da.keys).union(db.keys).sorted() {
                let va = da[key].map { $0 as AnyObject }, vb = db[key].map { $0 as AnyObject }
                if let va, let vb, va.isEqual(vb) { continue }
                if va == nil && vb == nil { continue }
                add(Self.setupFieldNames[key] ?? key.camelCaseWords)
            }
        }
        if names.isEmpty { return "the last change" }
        return names.count > 2 ? "\(names[0]), \(names[1]) and more" : names.joined(separator: " and ")
    }

    static let setupFieldNames: [String: String] = [
        "facing": "the part's orientation", "spin": "the part's orientation", "stockAxes": "the stock's orientation",
        "topAllowance": "the part's height in the stock", "partOffsetX": "the part's placement", "partOffsetY": "the part's placement",
        "clampProtrusion": "the stand-out", "downsizeHeight": "the stock prep", "prepLength": "the stock prep",
        "partScale": "the part's scale", "prepOverrides": "a clamping on the bed", "prepFaceEnd": "the stock prep",
        "prepRounds": "the stock prep", "onBed": "the holding", "bedJobOverride": "a clamping on the bed",
        "shoulders": "the shoulders", "kitClampShift": "a kit clamp", "kitClampCount": "the clamp count", "copies": "the copies",
        "clampSoftJaw": "the soft jaws", "flipped": "the flip", "holding": "the holding", "customFixture": "the custom fixture",
    ]

    /// ⌘Z: typing in a text field is undone there first (the field's own undo), otherwise the
    /// project steps back.
    func undoAnywhere() {
        if let um = Self.editingUndoManager, um.canUndo { um.undo(); return }
        Task { await undo() }
    }

    func redoAnywhere() {
        if let um = Self.editingUndoManager, um.canRedo { um.redo(); return }
        Task { await redo() }
    }

    private static var editingUndoManager: UndoManager? {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable else { return nil }
        return tv.undoManager
    }

    func undo() async {
        guard let previous = undoHistory.popLast() else { return }
        let current = projectSnapshot
        guard await apply(previous) else { undoHistory.append(previous); return }
        redoHistory.append(current)
        status = "Undone"
    }

    func redo() async {
        guard let next = redoHistory.popLast() else { return }
        let current = projectSnapshot
        guard await apply(next) else { redoHistory.append(next); return }
        undoHistory.append(current)
        status = "Redone"
    }

    // MARK: Files

    func saveProject(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var file = projectSnapshot
        file.results = savedResults
        try enc.encode(file).write(to: url, options: .atomic)
        // Finder shows the part itself (isometric) as the project's icon. Set after every
        // save: the atomic write replaces the file and its icon with it.
        if let icon = projectThumbnail() { NSWorkspace.shared.setIcon(icon, forFile: url.path, options: []) }
        projectURL = url
        projectDirty = false
        Self.addRecent(url)
        status = "Saved \(url.lastPathComponent)"
    }

    func openProject(_ url: URL) async {
        do {
            var p = try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: url))
            // Moved together (a renamed folder, another Mac): the part next to the project.
            if let path = p.partPath, !FileManager.default.fileExists(atPath: path) {
                let beside = url.deletingLastPathComponent().appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                if FileManager.default.fileExists(atPath: beside.path) {
                    p.partPath = beside.path
                } else {
                    errorMessage = "The part file isn't there any more: \(path)"
                }
            }
            guard await apply(p) else { return }
            undoHistory = []
            redoHistory = []
            projectURL = url
            projectDirty = false
            Self.addRecent(url)
            adoptMissingItems(p)
            if let r = p.results, part != nil, (r.machine ?? .legacy) == planningMachineReference {
                enter(.machining)
                restore(r)
            } else {
                enter(hasPrep ? .prep : .partStock)
                status = p.results == nil ? "Opened \(url.lastPathComponent)" : "Opened \(url.lastPathComponent) · Regenerate toolpaths for this machine"
            }
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// What the project uses that this inventory hasn't got (another Mac, a bar used up): its
    /// own copies of the tools (from the saved programs) and the bar join as Not owned, so the
    /// operations have their tools and the stock picker shows the bar.
    func adoptMissingItems(_ p: ProjectFile) {
        var tools: [Tool] = []
        for t in (p.resources?.tools ?? []) + (p.results?.programs ?? []).map(\.tool) + (p.results?.prepPrograms ?? []).map(\.tool)
            where toolLookup(t.id) == nil && !tools.contains(where: { $0.id == t.id }) {
            var copy = t
            copy.quantity = 0
            copy.source = ToolCatalog.source
            tools.append(copy)
        }
        var stock: [StockItem] = []
        if let s = p.stock, stockLookup(s.id) == nil {
            var copy = s
            copy.quantity = 0
            copy.supplier = StockCatalog.source
            stock.append(copy)
        }
        if !tools.isEmpty || !stock.isEmpty { addToInventory(tools, stock) }
    }

    func saveProjectInteractively(as saveAs: Bool = false) {
        if !saveAs, let url = projectURL {
            do { try saveProject(to: url) } catch { errorMessage = "Couldn't save: \(error.localizedDescription)" }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.coastlineProject]
        panel.nameFieldStringValue = (part?.url.deletingPathExtension().lastPathComponent ?? "Job") + ".coastline"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try saveProject(to: url) } catch { errorMessage = "Couldn't save: \(error.localizedDescription)" }
    }

    func openProjectInteractively() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.coastlineProject, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openProject(url) }
    }

    static var recentProjects: [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func addRecent(_ url: URL) {
        guard ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil else { return }
        var list = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: "recentProjects")
    }
}

extension String {
    /// "partOffsetX" → "part offset x".
    var camelCaseWords: String {
        var out = ""
        for c in self {
            if c.isUppercase, !out.isEmpty { out += " " }
            out += c.lowercased()
        }
        return out
    }
}
