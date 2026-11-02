import MillCore
import CoastlineCore
import SwiftUI

/// A job running on the machine: the steps on the left (done, current, to come), the current
/// step as a card. Each program runs only from its button; Feed Hold and Stop are in the
/// card while it runs and in the toolbar on every page.
struct JobRunner: View {
    @Environment(AppModel.self) private var app
    let entry: JobsModel.Entry

    var body: some View {
        let jobs = app.jobs
        if let run = jobs.run {
            HStack(spacing: 0) {
                StepList(entry: entry, run: run)
                    .frame(width: 250)
                Hairline()
                ScrollView {
                    Group {
                        if let item = run.current {
                            RunStepCard(entry: entry, item: item, number: run.index + 1, of: run.items.count)
                        } else if run.index < 0 {
                            RequirementsCard(entry: entry)
                        } else {
                            FinishedCard(entry: entry)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Theme.panelBackground)
        }
    }
}

private struct StepList: View {
    @Environment(AppModel.self) private var app
    let entry: JobsModel.Entry
    let run: JobsModel.Run

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(run.items.enumerated()), id: \.element.id) { k, item in
                    if k == 0 || run.items[k - 1].setup.id != item.setup.id {
                        Text(item.setup.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, k == 0 ? 0 : 8)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: run.done.contains(item.id) ? "checkmark.circle.fill" : (k == run.index ? "arrow.right.circle.fill" : "circle"))
                            .foregroundStyle(run.done.contains(item.id) ? Theme.ok : (k == run.index ? Theme.accent : .secondary))
                        Text(item.step.title).font(.callout.weight(k == run.index ? .semibold : .regular)).lineLimit(2)
                    }
                    .id(item.id)
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: run.index) { _, _ in
                if let id = run.current?.id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

private struct RequirementsCard: View {
    @Environment(AppModel.self) private var app
    let entry: JobsModel.Entry
    @State private var ticked: Set<String> = []

    var body: some View {
        let job = entry.job
        let simulated = app.jobs.run?.simulated == true
        VStack(alignment: .leading, spacing: 14) {
            Label("Before You Start", systemImage: "checklist").font(.title3.weight(.semibold))
            if simulated {
                SimulationNote()
                Text("On the machine, each of these must be true:").foregroundStyle(.secondary)
            } else {
                Text("Tick each one. The job starts when all are true.").foregroundStyle(.secondary)
            }
            ForEach(job.requirements, id: \.self) { r in
                Toggle(r, isOn: Binding(get: { ticked.contains(r) }, set: { if $0 { ticked.insert(r) } else { ticked.remove(r) } }))
                    .toggleStyle(.checkbox)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(choices).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("End Job") { app.jobs.endRun() }.plainGlassButton()
                Spacer()
                Button("Start", systemImage: "play.fill") { app.jobs.next() }
                    .buttonStyle(.glassProminent)
                    .disabled(!simulated && ticked.count < job.requirements.count)
            }
            .controlSize(.large)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var choices: String {
        let job = entry.job, chosen = app.jobs.run?.choices ?? [:]
        return job.options.filter { job.applies($0.when, chosen) }.compactMap { o in
            o.choices.first { $0.id == chosen[o.id] }.map { "\(o.title): \($0.title)" }
        }.joined(separator: " · ")
    }
}

private struct FinishedCard: View {
    @Environment(AppModel.self) private var app
    let entry: JobsModel.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Job Complete", systemImage: "checkmark.seal.fill").font(.title3.weight(.semibold)).foregroundStyle(Theme.ok)
            Text("\(entry.job.title) is done. Vacuum the chips; never use compressed air on the machine.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back") { app.jobs.back() }.plainGlassButton()
                Spacer()
                Button("Close the Job") { app.jobs.endRun() }.buttonStyle(.glassProminent)
            }
            .controlSize(.large)
        }
        .padding(16)
        .glassEffect(.regular.tint(Theme.ok.opacity(0.12)), in: .rect(cornerRadius: 18))
    }
}

private struct RunStepCard: View {
    @Environment(AppModel.self) private var app
    let entry: JobsModel.Entry
    let item: JobsModel.Run.Item
    let number: Int
    let of: Int
    @State private var clear = false

    var body: some View {
        let step = item.step, job = entry.job
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(item.setup.title) · step \(number) of \(of)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if app.jobs.run?.simulated == true { Badge(text: "Simulation", symbol: "play.circle") }
            }
            Label(step.title, systemImage: symbol).font(.title3.weight(.semibold))
            if let caution = step.caution {
                Label(caution, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if let text = step.text { Text(text).fixedSize(horizontal: false, vertical: true) }
            if !step.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(step.items.enumerated()), id: \.offset) { k, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(k + 1)").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.accent)
                                .frame(width: 18, alignment: .trailing)
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if step.kind == .toolChange, let tool = job.tool(step.tool) {
                ToolCard(tool: tool)
            }
            if step.kind == .run, let program = job.program(step.program) {
                ProgramRunPanel(entry: entry, item: item, program: program, clear: $clear)
            } else {
                HStack {
                    Button("Back") { app.jobs.back() }.plainGlassButton()
                    Spacer()
                    Button("Done", systemImage: "checkmark") { app.jobs.next() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onChange(of: item.id) { _, _ in clear = false }
    }

    private var symbol: String {
        switch item.step.kind {
        case .instruction: "text.alignleft"
        case .toolChange: "wrench.adjustable"
        case .mount: "square.stack.3d.up"
        case .measure: "ruler"
        case .run:
            switch entry.job.program(item.step.program)?.purpose {
            case .probe: "scope"
            case .cut: "point.topleft.down.to.point.bottomright.curvepath"
            case .warmup: "fanblades"
            default: "arrow.up.and.down.and.arrow.left.and.right"
            }
        }
    }
}

private struct ToolCard: View {
    let tool: ProgramJob.ToolSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(tool.name) · Ø\(String(format: "%.3f", tool.diameter)) mm", systemImage: "wrench.and.screwdriver.fill")
                .font(.headline)
            Text("Collet \(tool.collet)").foregroundStyle(.secondary)
            if let fitting = tool.fitting { Text(fitting).fixedSize(horizontal: false, vertical: true) }
            if let note = tool.note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Theme.accent.opacity(0.15)), in: .rect(cornerRadius: 14))
    }
}

/// The run step: what the machine must be, the clear-machine check, Run (or Air Cut / Cut),
/// then the progress, Feed Hold / Resume / Stop, and the result.
private struct ProgramRunPanel: View {
    @Environment(AppModel.self) private var app
    let entry: JobsModel.Entry
    let item: JobsModel.Run.Item
    let program: ProgramJob.ProgramFile
    @Binding var clear: Bool

    var body: some View {
        let jobs = app.jobs, mill = app.mill
        let status = jobs.status(mill)
        let running = status?.outcome == .running
        let done = jobs.run?.done.contains(item.id) == true
        let simulated = jobs.run?.simulated == true
        VStack(alignment: .leading, spacing: 10) {
            if let read = jobs.cached(entry, program.id) {
                Text(summary(read)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if simulated, mill.isOpen, !mill.isSimulated {
                Label("A machine is connected. Disconnect it to simulate.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            } else if simulated, !mill.isOpen {
                HStack {
                    Label("The Simulated Mill is not running.", systemImage: "play.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Start the Simulated Mill") { mill.connectSimulator() }.plainGlassButton()
                }
            } else if !mill.isOpen {
                HStack {
                    Label("Connect to the machine to run this step.", systemImage: "cable.connector.slash").foregroundStyle(Theme.warning)
                    Spacer()
                    Button("Connect") { mill.connect() }.plainGlassButton()
                }
            }
            if let status {
                ProgressView(value: status.fraction).tint(color(status.outcome))
                HStack {
                    Text(state(status)).font(.callout).foregroundStyle(color(status.outcome))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        Text(String(format: "line %d of %d · %.0f s", status.done, status.total,
                                    (status.finishedAt ?? context.date).timeIntervalSince(status.startedAt)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if simulated, let f = jobs.animation {
                ProgressView(value: f) { Text("Drawing the toolpath in the 3D view…").font(.caption) }
                    .tint(Theme.accent)
            }
            if program.purpose == .probe, status?.outcome == .completed {
                ProbeResult(offsets: mill.snapshot.offsets, used: jobs.cached(entry, program.id)?.workOffsets ?? [])
            }
            if running {
                HStack(spacing: 10) {
                    Button("Feed Hold", systemImage: "pause.fill") { mill.feedHold() }.buttonStyle(.glass).tint(Theme.warning)
                    Button("Resume", systemImage: "play.fill") { mill.resume() }.plainGlassButton()
                        .disabled(mill.snapshot.gates.resume != nil)
                    Button("Stop", systemImage: "stop.fill") { mill.stop() }.buttonStyle(.glass).tint(Theme.danger)
                    Spacer()
                }
                .controlSize(.large)
            } else {
                if !done, !simulated {
                    Toggle("The machine is clear, the chip cover is on, and I can reach the E-stop.", isOn: $clear)
                        .toggleStyle(.checkbox)
                }
                if let why = gate, !done {
                    Text(why).font(.caption).foregroundStyle(.secondary)
                }
                if let message = mill.message, status == nil || status?.outcome != .completed {
                    Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warning)
                }
                HStack(spacing: 10) {
                    Button("Back") { app.jobs.back() }.plainGlassButton()
                    Spacer()
                    if done {
                        Button("Next", systemImage: "arrow.right") { app.jobs.next() }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        if !simulated, jobs.offersAirCut(entry, program.id) {
                            Button("Air Cut", systemImage: "cloud") { start(airCut: true) }
                                .plainGlassButton()
                                .disabled(!clear || gate != nil)
                                .help("The whole program 10 mm above the work with the spindle off")
                        }
                        Button(simulated ? "Simulate" : (program.purpose == .cut ? "Cut" : "Run"), systemImage: "play.fill") { start(airCut: false) }
                            .buttonStyle(.glassProminent)
                            .disabled((!simulated && !clear) || gate != nil || (simulated && !mill.isSimulated))
                    }
                }
                .controlSize(.large)
            }
        }
        .onChange(of: status?.outcome) { _, outcome in
            if let outcome, outcome != .running { jobs.programFinished(outcome) }
        }
        .task(id: item.id) { await jobs.load(entry, program.id) }
    }

    /// Why the program can't start now (from the session's gates), or nil.
    private var gate: String? {
        let s = app.mill.snapshot
        guard s.isOpen else { return nil }
        let refusal = firstLineIsHome ? s.gates.home : s.gates.run
        return refusal?.text
    }

    private var firstLineIsHome: Bool {
        (try? String(contentsOf: entry.folder.appendingPathComponent(program.file), encoding: .utf8))?
            .split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("(") }?
            .trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("$H") ?? false
    }

    private func start(airCut: Bool) {
        clear = false
        Task { await app.jobs.runCurrent(on: app.mill, airCut: airCut) }
    }

    private func summary(_ read: GCodeReader.Program) -> String {
        var parts = ["\(read.moves.count.formatted()) moves"]
        if program.purpose == .cut { parts.append("about \(max(1, Int(app.jobs.minutes(read).rounded()))) min") }
        if read.probes > 0 { parts.append("\(read.probes) probe moves") }
        if !read.macros.isEmpty { parts.append(read.macros.sorted().map { "M\($0)" }.joined(separator: " ") + " by Coastline") }
        return parts.joined(separator: " · ")
    }

    private func state(_ s: MillProgramStatus) -> String {
        switch s.outcome {
        case .running: s.name.hasSuffix("air cut") ? "Air cut running…" : "Running…"
        case .completed: s.name.hasSuffix("air cut") ? "Air cut done. Check the moves, then Cut." : (app.jobs.run?.simulated == true ? "Done on the Simulated Mill." : "Done.")
        case .failed(let why): "Stopped: \(why)"
        case .stopped: "Stopped."
        }
    }

    private func color(_ outcome: MillProgramStatus.Outcome) -> Color {
        switch outcome {
        case .running: Theme.accent
        case .completed: Theme.ok
        case .failed: Theme.danger
        case .stopped: Theme.warning
        }
    }
}

/// What a simulated run is, at the start of one.
private struct SimulationNote: View {
    var body: some View {
        Label("Simulation: no machine moves. Each program runs on the Simulated Mill and draws in the 3D view. Its probes touch a simulated part, so the work offsets are not the real ones.",
              systemImage: "play.circle")
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(Theme.accent.opacity(0.12)), in: .rect(cornerRadius: 12))
    }
}

/// The work offsets the probe program set (those it selects; G54 if it names none).
private struct ProbeResult: View {
    let offsets: [MillOffset]
    let used: Set<Int>

    var body: some View {
        ForEach((used.isEmpty ? [54] : used.sorted()), id: \.self) { n in
            if let o = offsets.first(where: { $0.name == "G\(n)" }) {
                Label(String(format: "Work zero (G%d, machine): X %.3f  Y %.3f  Z %.3f", n, o.point.x, o.point.y, o.point.z),
                      systemImage: "scope")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Theme.ok)
            }
        }
    }
}
