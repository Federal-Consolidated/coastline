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
