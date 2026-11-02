import CoastlineCore
import SwiftUI
import UniformTypeIdentifiers
import Viewport

/// The 3D view at the top of a job: the shown program's toolpath in its work offset, oriented as
/// on the machine (X up and down, Z toward the spindle), with what Coastline knows about it.
struct JobPreview: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let jobs = app.jobs
        ViewportContainer(renderer: jobs.renderer)
            .overlay(alignment: .bottomLeading) {
                if let entry = jobs.selected, let id = jobs.previewProgram, let program = entry.job.program(id) {
                    ProgramCard(entry: entry, program: program).padding(12)
                } else {
                    Text("Press Show on a program step to see its toolpath here.")
                        .font(.callout).foregroundStyle(.secondary).padding(14)
                }
            }
            .overlay(alignment: .topTrailing) {
                @Bindable var jobs = jobs
                HStack(spacing: 8) {
                    if jobs.cutSummary != nil || jobs.cutChecking {
                        Toggle(isOn: $jobs.showCuts) { Label("Cuts", systemImage: "scissors") }
                            .toggleStyle(.button)
                            .help("Show what the program cuts (light), gouges into the finished part (red) and rapids through it (yellow)")
                    }
                    if let entry = jobs.selected, entry.job.setups.contains(where: { $0.machine != nil }) {
                        Toggle(isOn: $jobs.showMachine) { Label("Machine", systemImage: "cube.transparent") }
                            .toggleStyle(.button)
                            .disabled(!jobs.hasMachine)
                            .help(jobs.hasMachine ? "Show the machine around the part, where this setup has it" : "Loading the machine model…")
                    }
                }
                .padding(12)
            }
            .background(Theme.panelBackground)
    }
}

private struct ProgramCard: View {
    @Environment(AppModel.self) private var app
    let entry: JobsModel.Entry
    let program: ProgramJob.ProgramFile

    var body: some View {
        let jobs = app.jobs
        VStack(alignment: .leading, spacing: 4) {
            Text(program.title).font(.headline)
            if let read = jobs.cached(entry, program.id) {
                Text(facts(read)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if read.machineMoves > 0 {
                    Text("\(read.machineMoves) machine-coordinate move\(read.machineMoves == 1 ? "" : "s") (G53) not drawn.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(read.issues) { issue in
                    Label(issue.message, systemImage: Theme.symbol(issue.severity))
                        .font(.caption).foregroundStyle(Theme.color(issue.severity))
                }
            } else {
                ProgressView().controlSize(.small)
            }
            CutCheckLine(program: program.id)
            ForEach(program.changes, id: \.self) { change in
                Label(change, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func facts(_ read: GCodeReader.Program) -> String {
        var lines = ["\(read.lineCount.formatted()) lines · \(read.moves.count.formatted()) moves"]
        if read.cutLength > 0 { lines.append(String(format: "%.0f mm of feed moves · about %.1f min", read.cutLength, app.jobs.minutes(read))) }
        if let lo = read.cutMin, let hi = read.cutMax {
            lines.append(String(format: "%.2f × %.2f × %.2f mm", hi.x - lo.x, hi.y - lo.y, hi.z - lo.z))
        }
        var more: [String] = []
        if !read.spindleSpeeds.isEmpty { more.append(read.spindleSpeeds.sorted().map { "\(Int($0))" }.joined(separator: "/") + " RPM") }
        if !read.workOffsets.isEmpty { more.append(read.workOffsets.sorted().map { "G\($0)" }.joined(separator: " ")) }
        if read.probes > 0 { more.append("\(read.probes) probe moves") }
        if !read.macros.isEmpty { more.append(read.macros.sorted().map { "M\($0)" }.joined(separator: " ")) }
        if !more.isEmpty { lines.append(more.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }
}

/// The cut check's result for the shown program, in one line.
private struct CutCheckLine: View {
    @Environment(AppModel.self) private var app
    let program: String

    var body: some View {
        let jobs = app.jobs
        if jobs.cutChecking {
            Label("Checking the cuts against the part…", systemImage: "scissors").font(.caption).foregroundStyle(.secondary)
        } else if let s = jobs.cutSummary, s.program == program {
            Label(String(format: "Cuts %.0f mm³ inside the part's box", s.removed), systemImage: "scissors")
                .font(.caption).foregroundStyle(.secondary)
            if s.gouge > 0.5 {
                Label(String(format: "%.0f mm³ cut where the finished model has material (red)", s.gouge), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.danger)
            }
            if s.rapidHits > 0.5 {
                Label(String(format: "Rapid moves pass through %.0f mm³ of the part (yellow)", s.rapidHits), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
            if s.gouge <= 0.5, s.rapidHits <= 0.5 {
                Label("No cut into the finished model", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Theme.ok)
            }
        }
    }
}

/// New Job from G-code: your files, the tool, and the work offset your program uses.
struct NewJobSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var title = ""
    @State private var toolName = "1/4\" end mill"
    @State private var toolKind = "End mill"
    @State private var diameter = 6.35
    @State private var collet = "1/4\""
    @State private var workOffset = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New Job from G-code", systemImage: "doc.badge.plus").font(.headline)
            Text("Coastline adds homing, the tool change, mounting and the work zero, then runs your programs in order with an air cut offered first. Inches are converted to mm and spindle speeds are limited to the machine's 8000 RPM; the path stays the same.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                LabeledContent("Programs") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(files, id: \.self) { Text($0.lastPathComponent).font(.callout.monospaced()) }
                        Button(files.isEmpty ? "Choose Files…" : "Change…") { choose() }
                    }
                }
                TextField("Job name", text: $title)
                TextField("Tool", text: $toolName)
                Picker("Kind", selection: $toolKind) {
                    Text("End mill").tag("End mill")
                    Text("Drill").tag("Drill")
                    Text("Engraver").tag("Engraver")
                }
                LabeledContent("Diameter") {
                    TextField("mm", value: $diameter, format: .number.precision(.fractionLength(0...3)))
                        .multilineTextAlignment(.trailing).frame(width: 90)
                    Text("mm").foregroundStyle(.secondary)
                }
                TextField("Collet", text: $collet)
                Picker("Work offset", selection: $workOffset) {
                    ForEach(54...59, id: \.self) { Text("G\($0)").tag($0) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make Job") {
                    let tool = ProgramJob.ToolSpec(id: "tool", name: toolName, kind: toolKind, diameter: diameter, collet: collet)
                    app.jobs.newJob(files: files, title: title.isEmpty ? (files.first?.deletingPathExtension().lastPathComponent ?? "My Job") : title,
                                    tool: tool, workOffset: workOffset)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(files.isEmpty || diameter <= 0)
            }
        }
        .padding(20)
        .frame(width: 520, height: 600)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose G-code Files"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["nc", "gcode", "ngc", "tap", "txt", "cnc"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            files = panel.urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
            if title.isEmpty { title = files.first?.deletingPathExtension().lastPathComponent ?? "" }
        }
    }
}
