import CoastlineCore
import SwiftUI
import Viewport

/// Program jobs: guided jobs around G-code that already exists (an old .dd job, another CAM
/// program's output, your own). The list on the left, the job's options, tools and setups on the
/// right, and the selected program's toolpath in the inspector.
struct JobsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var jobs = app.jobs
        HSplitView {
            List(selection: $jobs.selection) {
                let presets = jobs.entries.filter(\.preset)
                if !presets.isEmpty {
                    Section("Presets") {
                        ForEach(presets) { entry in
                            JobRow(job: entry.job).tag(entry.folder)
                        }
                    }
                }
                Section("Your Jobs") {
                    let own = jobs.entries.filter { !$0.preset }
                    if own.isEmpty {
                        Text("Jobs you add, make from your own G-code or import from a .dd file show here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(own) { entry in
                        JobRow(job: entry.job).tag(entry.folder)
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.folder]) }
                                Divider()
                                Button("Delete", role: .destructive) { jobs.delete(entry) }
                            }
                    }
                }
            }
            .frame(minWidth: 200, idealWidth: 260, maxWidth: 380)

            Group {
                if let entry = jobs.selected {
                    // The 3D view stays on top while the steps scroll: it replaces the old photos.
                    VSplitView {
                        JobPreview()
                            .frame(minHeight: 200, idealHeight: 340, maxHeight: .infinity)
                        Group {
                            if jobs.run?.folder == entry.folder {
                                JobRunner(entry: entry)
                            } else {
                                JobDetail(entry: entry)
                            }
                        }
                        .frame(minHeight: 240)
                    }
                    .task(id: entry.folder) { await jobs.loadModels(entry) }
                } else {
                    ContentUnavailableView("No Job", systemImage: "list.bullet.clipboard",
                                           description: Text("Choose a job, or make one from your own G-code."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .darkPanel()
        .navigationTitle("Jobs")
        .toolbar {
            ToolbarItemGroup {
                Button("Add Job…", systemImage: "folder.badge.plus") { jobs.chooseJobFolder() }
                    .help("Add a job folder (job.json, programs, models)")
                Button("New Job from G-code…", systemImage: "doc.badge.plus") { jobs.showNewJob = true }
                    .help("Make a guided job around your own G-code files")
                Button("Import .dd Job…", systemImage: "square.and.arrow.down") { jobs.chooseDDFile() }
                    .help("Turn a .dd job package into a Coastline job")
            }
            ToolbarSpacer(.fixed)
        }
        .sheet(isPresented: $jobs.showNewJob) {
            NewJobSheet().environment(app).tint(Theme.accent)
        }
        .overlay(alignment: .bottom) {
            if let error = jobs.lastError {
                ErrorBanner(text: error, shape: .capsule) { jobs.lastError = nil }.padding(20)
            }
        }
    }
}

private struct JobRow: View {
    let job: ProgramJob

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(job.title).font(.callout.weight(.semibold)).lineLimit(2)
            Text("\(job.setups.count) setups · \(job.programs.count) programs").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

private struct JobDetail: View {
    @Environment(AppModel.self) private var app
    let entry: JobsModel.Entry

    var body: some View {
        let jobs = app.jobs
        let job = entry.job
        let chosen = jobs.chosen(job)
        let problems = job.problems(in: entry.folder)
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "list.bullet.clipboard.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.title).font(.title2.weight(.semibold))
                        Text(job.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            ForEach(job.machines, id: \.self) { Badge(text: $0, color: Theme.accent, symbol: "gearshape.2") }
                            if let material = job.material { Badge(text: material, symbol: "cube") }
                        }
                        .padding(.top, 2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Start Job", systemImage: "play.fill") { jobs.startRun(entry) }
                            .buttonStyle(.glassProminent)
                            .help("Run this job on the machine, step by step, with the options chosen below")
                        Button("Simulate", systemImage: "play.circle") {
                            jobs.startRun(entry, simulated: true)
                            app.mill.connectSimulator()
                        }
                        .plainGlassButton()
                        .disabled(app.mill.isOpen && !app.mill.isSimulated)
                        .help(app.mill.isOpen && !app.mill.isSimulated
                              ? "A machine is connected. Disconnect it to simulate."
                              : "Go through the job without a machine: every program runs on the Simulated Mill and draws in the 3D view")
                    }
                    .controlSize(.large)
                    .disabled(!problems.isEmpty || jobs.run != nil)
                }
                .padding(.vertical, 4)
                ForEach(problems, id: \.self) { p in
                    Label(p, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                }
            }

            if !job.requirements.isEmpty {
                Section("Before You Start") {
                    ForEach(job.requirements, id: \.self) { r in
                        Label(r, systemImage: "checkmark.circle").fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            let options = job.options.filter { job.applies($0.when, chosen) }
            if !options.isEmpty {
                Section("Options") {
                    ForEach(options) { option in
                        Picker(option.title, selection: Binding(get: { chosen[option.id] ?? option.defaultChoice },
                                                                set: { jobs.choose(job, option.id, $0) })) {
                            ForEach(option.choices) { Text($0.title).tag($0.id) }
                        }
                        if let detail = option.choices.first(where: { $0.id == chosen[option.id] })?.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !job.tools.isEmpty {
                Section("Tools") {
                    ForEach(job.tools) { tool in
                        LabeledContent {
                            Text("Ø\(String(format: "%.3f", tool.diameter)) mm · collet \(tool.collet)").monospacedDigit()
                        } label: {
                            Label(tool.name, systemImage: tool.kind == "Drill" ? "line.diagonal" : "wrench.and.screwdriver")
                        }
                    }
                }
            }

            ForEach(Array(job.plan(chosen).enumerated()), id: \.element.setup.id) { _, item in
                Section {
                    ForEach(Array(item.steps.enumerated()), id: \.element.id) { n, step in
                        StepRow(entry: entry, step: step, number: n + 1)
                    }
                } header: {
                    Text(item.setup.title)
                } footer: {
                    if !item.setup.summary.isEmpty { Text(item.setup.summary) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct StepRow: View {
    @Environment(AppModel.self) private var app
    let entry: JobsModel.Entry
    let step: ProgramJob.Step
    let number: Int

    var body: some View {
        let job = entry.job
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color).frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(number). \(step.title)").font(.callout.weight(.semibold))
                if let caution = step.caution {
                    Label(caution, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
                if let text = step.text {
                    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !step.items.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(step.items.enumerated()), id: \.offset) { k, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(k + 1).").font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
                                Text(item).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if step.kind == .toolChange, let tool = job.tool(step.tool) {
                    Text("\(tool.name) in the \(tool.collet) collet. \(tool.fitting ?? "")")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let note = tool.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                if step.kind == .run, let program = job.program(step.program) {
                    ProgramLine(entry: entry, program: program)
                }

            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var program: ProgramJob.ProgramFile? { entry.job.program(step.program) }

    private var symbol: String {
        switch step.kind {
        case .instruction: "text.alignleft"
        case .toolChange: "wrench.adjustable"
        case .mount: "square.stack.3d.up"
        case .measure: "ruler"
        case .run:
            switch program?.purpose {
            case .probe: "scope"
            case .cut: "point.topleft.down.to.point.bottomright.curvepath"
            case .warmup: "fanblades"
            default: "arrow.up.and.down.and.arrow.left.and.right"
            }
        }
    }

    private var color: Color {
        switch step.kind {
        case .run: program?.purpose == .cut ? Theme.accent : (program?.purpose == .probe ? Theme.warning : .secondary)
        case .toolChange, .mount: Theme.accent
        default: .secondary
        }
    }
}

/// "36,953 moves · about 14 min · converted from inches", and the Preview button.
private struct ProgramLine: View {
    @Environment(AppModel.self) private var app
    let entry: JobsModel.Entry
    let program: ProgramJob.ProgramFile

    var body: some View {
        let jobs = app.jobs
        let read = jobs.cached(entry, program.id)
        HStack(spacing: 8) {
            Text(summary(read)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button("Show", systemImage: "eye") {
                jobs.show(entry, program.id)
                Task { await jobs.load(entry, program.id) }
            }
            .controlSize(.small)
            .plainGlassButton()
            .help("Show this program's toolpath in the 3D view")
        }
        .task(id: jobs.key(entry, program.id)) { await jobs.load(entry, program.id) }
    }

    private func summary(_ read: GCodeReader.Program?) -> String {
        var parts = [(program.file as NSString).lastPathComponent]
        if let read {
            parts.append("\(read.moves.count.formatted()) moves")
            if program.purpose == .cut { parts.append("about \(max(1, Int(app.jobs.minutes(read).rounded()))) min") }
        }
        if program.changes.contains(where: { $0.contains("inches") }) { parts.append("converted from inches") }
        return parts.joined(separator: " · ")
    }
}
