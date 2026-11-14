import AppKit
import CoastlineCore
import SwiftUI

/// Projects: one list for both kinds. A planned project (a `.coastline` file: Coastline makes
/// the toolpaths from a CAD part) opens in the Workspace; a G-code project (a job around G-code
/// that already exists) shows its steps here and runs from here. Presets first (the examples
/// and the preset jobs), then your own (saved, imported or made from G-code), then the Job
/// Journal: what ran, how it went, what you measured. Import… and Export… share either kind as
/// one .zip.
struct ProjectsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    @State private var selection: ProjectsItem?
    @State private var recents: [URL] = []
    /// The journal entry waiting for Delete to be confirmed.
    @State private var pendingDelete: JournalEntry?

    enum ProjectsItem: Hashable {
        case firstCut
        case project(URL)
        case example(String)
        /// A G-code project: its job folder.
        case job(URL)
        case journal(JournalEntry.ID)
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                Section("Getting Started") {
                    ProjectRow(title: "First Cut on the Machine", detail: firstCutProgress, icon: NSImage(systemSymbolName: "checklist", accessibilityDescription: nil))
                        .tag(ProjectsItem.firstCut)
                }
                Section("Presets") {
                    ForEach(ExamplePart.all) { ex in
                        ProjectRow(title: ex.title, detail: ex.shows.joined(separator: " · "), icon: NSImage(contentsOf: ex.thumbnailURL))
                            .tag(ProjectsItem.example(ex.id))
                            .contextMenu {
                                Button("Open") { openExample(ex) }
                                Button("Export…") { model.exportProjectInteractively(ex.projectURL) }
                                    .disabled(!FileManager.default.fileExists(atPath: ex.projectURL.path))
                            }
                    }
                    ForEach(model.jobs.entries.filter(\.preset)) { entry in
                        jobRow(entry)
                    }
                }
                Section("Your Projects") {
                    let own = model.jobs.entries.filter { !$0.preset }
                    if recents.isEmpty && own.isEmpty {
                        Text("Projects you save, import or make from G-code show here. Import… takes a shared .zip, a .coastline file, an older .dd or .crproj job, a job folder or G-code files.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(recents, id: \.self) { url in
                        ProjectRow(title: url.deletingPathExtension().lastPathComponent,
                                   detail: (["Planned in Coastline"] + [modified(url).map { $0.formatted(date: .abbreviated, time: .shortened) }].compactMap { $0 })
                                       .joined(separator: " · "),
                                   icon: NSWorkspace.shared.icon(forFile: url.path))
                            .tag(ProjectsItem.project(url))
                            .contextMenu {
                                Button("Open") { open(url) }
                                Button("Export…") { model.exportProjectInteractively(url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Divider()
                                Button("Remove from the List") { removeRecent(url) }
                            }
                    }
                    ForEach(own) { entry in
                        jobRow(entry)
                    }
                }
                Section("Job Journal") {
                    if model.journal.entries.isEmpty {
                        Text("No jobs yet. After a job has run, record it from the Review stage: what you measured, how it went, photos.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.journal.entries) { e in
                        JournalRow(entry: e)
                            .tag(ProjectsItem.journal(e.id))
                            .contextMenu { Button("Delete…", role: .destructive) { pendingDelete = e } }
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 340, maxWidth: 460)
            .contextMenu(forSelectionType: ProjectsItem.self) { _ in } primaryAction: { items in
                guard let item = items.first else { return }
                switch item {
                case .project(let url): open(url)
                case .example(let id): if let ex = ExamplePart.all.first(where: { $0.id == id }) { openExample(ex) }
                case .job, .journal, .firstCut: break
                }
            }
            .onDeleteCommand {
                if case .journal(let id) = selection { pendingDelete = model.journal.entries.first { $0.id == id } }
            }
            .confirmationDialog("Delete the journal entry for \(pendingDelete?.partName ?? "this job")?",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { e in
                Button("Delete", role: .destructive) {
                    if selection == .journal(e.id) { selection = nil }
                    model.journal.remove(e.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its measurements and notes go with it. This can't be undone.")
            }
            Group {
                switch selection {
                case .firstCut:
                    FirstCutView()
                case .project(let url):
                    ProjectDetail(url: url, title: url.deletingPathExtension().lastPathComponent, summary: nil,
                                  icon: NSWorkspace.shared.icon(forFile: url.path)) { open(url) }
                        .id(url)
                case .example(let id):
                    if let ex = ExamplePart.all.first(where: { $0.id == id }) {
                        ProjectDetail(url: FileManager.default.fileExists(atPath: ex.projectURL.path) ? ex.projectURL : nil, title: ex.title,
                                      summary: ex.summary, icon: NSImage(contentsOf: ex.thumbnailURL)) { openExample(ex) }
                            .id(id)
                    }
                case .job(let folder):
                    if let entry = model.jobs.entries.first(where: { $0.folder == folder }) {
                        JobPane(entry: entry)
                    }
                case .journal(let id):
                    if let e = model.journal.entries.first(where: { $0.id == id }) {
                        JournalDetail(entry: e)
                    }
                case nil:
                    ContentUnavailableView("No Project Selected", systemImage: "folder",
                                           description: Text("Pick a project to see what's in it, or a job from the journal. Import… adds a project someone shared with you."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .darkPanel()
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItemGroup {
                Button("Import…", systemImage: "square.and.arrow.down") { model.importProjectsInteractively() }
                    .help("Add a project: a shared .zip, a .coastline file, an older .dd or .crproj job, a job folder or G-code files (⇧⌘O)")
                Button("Export…", systemImage: "square.and.arrow.up") { exportSelection() }
                    .disabled(!canExport)
                    .help("Save the selected project as one .zip file to share")
            }
            ToolbarSpacer(.fixed)
        }
        .sheet(isPresented: Bindable(model.jobs).showNewJob) {
            NewJobSheet().environment(model).tint(Theme.accent)
        }
        .overlay(alignment: .bottom) {
            if let error = model.jobs.lastError {
                ErrorBanner(text: error, shape: .capsule) { model.jobs.lastError = nil }.padding(20)
            }
        }
        .onAppear {
            reloadRecents()
            takePick()
        }
        .onChange(of: model.projectsPick) { takePick() }
        .onChange(of: model.projectURL) { reloadRecents() }
        .onChange(of: selection) {
            // The job preview and runner follow the job selected here.
            if case .job(let folder) = selection { model.jobs.selection = folder }
        }
    }

    /// A G-code project's row, with its menu.
    private func jobRow(_ entry: JobsModel.Entry) -> some View {
        ProjectRow(title: entry.job.title,
                   detail: "From G-code · \(entry.job.programs.count) program\(entry.job.programs.count == 1 ? "" : "s")",
                   icon: NSImage(systemSymbolName: "list.bullet.clipboard", accessibilityDescription: nil))
            .tag(ProjectsItem.job(entry.folder))
            .contextMenu {
                Button("Export…") { model.exportJobInteractively(entry) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.folder]) }
                if !entry.preset {
                    Divider()
                    Button("Delete", role: .destructive) {
                        if selection == .job(entry.folder) { selection = nil }
                        model.jobs.delete(entry)
                    }
                }
            }
    }

    /// "firstCut", "project:<path>", "job:<folder>": from an import, a link or a script.
    private func takePick() {
        guard let pick = model.projectsPick else { return }
        model.projectsPick = nil
        reloadRecents()
        if pick == "firstCut" { selection = .firstCut }
        else if pick.hasPrefix("project:") { selection = .project(URL(fileURLWithPath: String(pick.dropFirst(8)))) }
        else if pick.hasPrefix("job:") { selection = .job(URL(fileURLWithPath: String(pick.dropFirst(4)))) }
    }

    private var canExport: Bool {
        switch selection {
        case .project, .job: true
        case .example(let id): ExamplePart.all.first { $0.id == id }.map { FileManager.default.fileExists(atPath: $0.projectURL.path) } ?? false
        default: false
        }
    }

    private func exportSelection() {
        switch selection {
        case .project(let url): model.exportProjectInteractively(url)
        case .example(let id): if let ex = ExamplePart.all.first(where: { $0.id == id }) { model.exportProjectInteractively(ex.projectURL) }
        case .job(let folder): if let entry = model.jobs.entries.first(where: { $0.folder == folder }) { model.exportJobInteractively(entry) }
        default: break
        }
    }

    @AppStorage("firstCutDone") private var firstCutDone = ""

    private var firstCutProgress: String {
        let n = firstCutDone.split(separator: ",").count
        return n == 0 ? "Stage by stage: air cut, wax, POM, aluminium" : "\(n) of \(FirstCut.stages.count) stages done"
    }

    private var examplePaths: Set<String> { Set(ExamplePart.all.map(\.projectURL.path)) }

    /// The examples have their own section.
    private func reloadRecents() {
        recents = AppModel.recentProjects.filter { !examplePaths.contains($0.path) }
    }

    private func removeRecent(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        list.removeAll { $0 == url.path }
        UserDefaults.standard.set(list, forKey: "recentProjects")
        if selection == .project(url) { selection = nil }
        reloadRecents()
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func open(_ url: URL) {
        model.page = .workspace
        Task { await model.openProject(url) }
    }

    private func openExample(_ ex: ExamplePart) {
        model.page = .workspace
        Task { await model.openExample(ex, inventory: inventory) }
    }
}

private struct ProjectRow: View {
    let title: String
    let detail: String?
    let icon: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon { Image(nsImage: icon).resizable().scaledToFit() } else { Image(systemName: "doc").foregroundStyle(.secondary) }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct JournalRow: View {
    let entry: JournalEntry
    @Environment(InventoryModel.self) private var inventory

    private var materialName: String {
        if let material = entry.materialSnapshot, material.id == entry.materialID { return material.name }
        return inventory.inventory.material(id: entry.materialID)?.name ?? entry.materialID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: entry.outcome == .good ? "checkmark.seal.fill" : entry.outcome == .scrapped ? "xmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(entry.outcome == .good ? Theme.ok : entry.outcome == .scrapped ? Theme.danger : Theme.warning)
                    .accessibilityLabel(entry.outcome.title)
                Text(entry.partName).font(.headline)
                if entry.copies > 1 { Text("×\(entry.copies)").foregroundStyle(.secondary) }
            }
            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(materialName) · \(AppModel.duration(entry.cuttingMinutes * 60))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// What's in a project file, read without opening it.
private struct ProjectSummary: Sendable {
    var part: String?
    var stock: String?
    var sides: String
    var operations: Int
    var programs: Int
    var seconds: Double
    var tools: [String]
    var holding: String

    static func load(_ url: URL) -> ProjectSummary? {
        guard let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(ProjectFile.self, from: data) else { return nil }
        let programs = (p.results?.prepPrograms ?? []) + (p.results?.programs ?? [])
        var tools: [String] = []
        for t in programs.map(\.tool.name) where !tools.contains(t) { tools.append(t) }
        let material = p.stock?.material?.name
        return ProjectSummary(
            part: p.partPath.map { URL(fileURLWithPath: $0).lastPathComponent },
            stock: p.stock.map { [material, $0.sizeDescription].compactMap { $0 }.joined(separator: " ") },
            sides: p.twoSided ? "Two sides (A and B)" + (p.setup.holding == .custom ? "" : p.holdWithTabs ? ", held by tabs" : ", full web") : "One side",
            operations: p.operations.count, programs: programs.count, seconds: programs.reduce(0) { $0 + $1.seconds },
            tools: tools,
            holding: p.setup.holding == .custom ? p.setup.customFixture.name : p.setup.onBed ? "On the bed (C-clamps)" : !(p.results?.prepPrograms.isEmpty ?? true) ? "Squared on the bed first, then the clamp kit" : "Clamp kit")
    }
}

private struct ProjectDetail: View {
    let url: URL?
    let title: String
    let summary: String?
    let icon: NSImage?
    let open: () -> Void
    @State private var info: ProjectSummary?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    if let icon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 96, height: 96).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.title2.weight(.semibold))
                        if let summary { Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        Button("Open", systemImage: "arrow.forward.circle", action: open)
                            .buttonStyle(.glassProminent)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }
            if let info {
                Section("Job") {
                    if let part = info.part { LabeledContent("Part", value: part) }
                    if let stock = info.stock { LabeledContent("Stock", value: stock) }
                    LabeledContent("Holding", value: info.holding)
                    LabeledContent("Sides", value: info.sides)
                    LabeledContent("Operations", value: "\(info.operations)")
                }
                if info.programs > 0 {
                    Section {
                        LabeledContent("Programs", value: "\(info.programs)")
                        LabeledContent("Machining", value: AppModel.duration(info.seconds))
                        LabeledContent("Tools") {
                            Text(info.tools.joined(separator: "\n")).multilineTextAlignment(.trailing)
                        }
                    } header: {
                        Text("Toolpaths")
                    } footer: {
                        Text("Saved with the project: it opens ready, nothing is generated again.")
                    }
                }
            } else if loaded, url != nil {
                Section { Text("This project file couldn't be read.").foregroundStyle(.secondary) }
            }
            if let url {
                Section {
                    LabeledContent("File", value: url.path(percentEncoded: false))
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
        }
        .formStyle(.grouped)
        .darkPanel()
        .task {
            guard let url else { loaded = true; return }
            info = await Task.detached(priority: .userInitiated) { ProjectSummary.load(url) }.value
            loaded = true
        }
    }
}
