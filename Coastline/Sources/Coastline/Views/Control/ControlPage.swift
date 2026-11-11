import MillCore
import SwiftUI

/// The machine is the main view; compact native controls live in the inspector.
struct ControlPage: View {
    @Environment(AppModel.self) private var app

    private var mill: MillControl { app.mill }
    private var s: MillSnapshot { mill.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            HStack(spacing: 10) {
                Label(probeState, systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(s.status?.probeTripped == true ? Theme.warning : Color.secondary)
                    .frame(width: 125, alignment: .leading)
                    .help("The probe input reports contact, not whether the cable is plugged in.")
                ScrollView(.vertical) {
                    Text(notice ?? "Machine status and setup messages appear here.")
                        .font(.callout)
                        .foregroundStyle(notice == nil ? Color.secondary : Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 36)
                Button(s.homingSince != nil ? "Homing…" : "Home", systemImage: "house") { mill.requestHome() }
                    .controlSize(.small)
                    .disabled(s.gates.home != nil)
                    .help(mill.isSimulated ? "Home the digital machine" : "Home the machine before jogging or setting work zero")
                if s.needsReset {
                    Button("Reset", systemImage: "arrow.counterclockwise") { mill.softReset() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.panelBackground)
            .help(notice ?? "Machine status")
            Divider()
            if let program = s.program {
                ProgramProgress(program: program)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Theme.panelBackground)
                Divider()
            }
            ControlMachineView()
        }
        .background(JogKeys(mill: mill))
        .background(Theme.windowBackground)
        .navigationTitle("Machine Control")
        .navigationSubtitle(mill.stateWord)
        .inspector(isPresented: Bindable(app).showInspector) {
            ControlInspector()
                .environment(app)
                .panelEdge(.leading)
                .inspectorColumnWidth(min: 300, ideal: 320, max: 380)
        }
        .sheet(isPresented: Bindable(mill).showConsole) {
            VStack(spacing: 0) {
                MillConsole()
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { mill.showConsole = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
            .environment(app)
            .background(Theme.panelBackground)
            .frame(minWidth: 560, idealWidth: 700, minHeight: 360, idealHeight: 480)
        }
        .onChange(of: mill.showConsole) {
            if mill.showConsole { mill.endHold() }
        }
        .onDisappear {
            mill.endHold()
            mill.allowJog = false
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Button("Guided Mode", systemImage: "list.bullet.clipboard") { app.openGuidedMode() }
                .help(app.jobs.run == nil ? "Open projects and guided jobs" : "Return to the current guided job")
            Button("Workspace", systemImage: "cube.transparent") { app.page = .workspace }
                .help("Return to the part setup and toolpaths")
            Divider().frame(height: 18)
            Text(app.controlMachine.name).font(.callout.weight(.medium)).lineLimit(1)
            if mill.isSimulated {
                Label("Simulated", systemImage: "desktopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Badge(text: mill.stateWord, color: stateColor, symbol: stateSymbol)
            if s.homed {
                Text("Homed").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if mill.isOpen {
                Button("Disconnect", systemImage: "cable.connector.slash") { mill.disconnect() }
            } else {
                Button("Connect", systemImage: "cable.connector") { mill.connect() }
                Button("Digital Machine", systemImage: "desktopcomputer") { mill.connectSimulator() }
                    .help("Open a simulated controller to practice homing, jogging and work offsets without hardware")
            }
            Button("Console", systemImage: "terminal") { mill.showConsole = true }
                .labelStyle(.iconOnly)
                .help("Open the machine console")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panelBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var notice: String? {
        if s.silentSince != nil { return MillRefusal.silent.text }
        if s.needsReset { return "Reset the controller, then home the machine." }
        if let alarm = s.lastAlarm { return alarm }
        if case .settings(let why)? = s.gates.home { return why }
        if let error = s.lastError { return error }
        if let message = mill.message { return message }
        if s.status?.probeTripped == true { return "Probe contact detected. Release the contact before continuing." }
        if s.homingSince != nil { return "Homing the machine…" }
        if s.link == .connected, !s.homed { return "Home the machine before jogging." }
        if let why = s.gates.jog, s.isOpen, mill.heldJog == nil { return why.text }
        return nil
    }

    private var probeState: String {
        guard s.isOpen, let status = s.status else { return "Probe: —" }
        return status.probeTripped ? "Probe: Contact" : "Probe: Open"
    }

    private var stateColor: Color {
        switch mill.stateWord {
        case "Idle": Theme.ok
        case "Alarm", "No reply": Theme.danger
        case "Hold", "Door": Theme.warning
        case "Run", "Jog", "Home", "Homing": Theme.accent
        default: .secondary
        }
    }

    private var stateSymbol: String {
        switch mill.stateWord {
        case "Idle": "checkmark.circle.fill"
        case "Alarm", "No reply": "xmark.octagon.fill"
        case "Hold", "Door": "pause.circle.fill"
        case "Run", "Jog", "Home", "Homing": "arrow.triangle.2.circlepath"
        default: "circle.dashed"
        }
    }
}

/// Go to work zero, the home position, the tool-change position or a typed position. Each
/// opens the confirmation sheet, which shows the moves.
struct GoToMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let mill = app.mill
        let s = mill.snapshot
        Menu("Go To", systemImage: "location") {
            Button("Work Zero (X Y)") { mill.goTo = .workZero }
            Button("Home Position") { mill.goTo = .home(s) }
                .disabled(s.homeTarget == nil)
            Button("Tool-Change Position") { mill.goTo = .toolChange(app.controlMachine.toolChangeMoves) }
            Divider()
            Button("Position…") { mill.goTo = .position(s) }
        }
        .help("Rapid moves to a place, the spindle out first. Unlock jogging first")
    }
}


private struct ProgramProgress: View {
    let program: MillProgramStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(program.name).font(.callout.weight(.semibold))
                Spacer()
                Text(state).font(.caption).foregroundStyle(color)
            }
            ProgressView(value: program.fraction)
                .tint(color)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let end = program.finishedAt ?? context.date
                Text(String(format: "Line %d of %d · %.0f s", program.done, program.total, end.timeIntervalSince(program.startedAt)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var state: String {
        switch program.outcome {
        case .running: "Running"
        case .completed: "Done"
        case .failed(let why): "Stopped: \(why)"
        case .stopped: "Stopped"
        }
    }

    private var color: Color {
        switch program.outcome {
        case .running: Theme.accent
        case .completed: Theme.ok
        case .failed: Theme.danger
        case .stopped: Theme.warning
        }
    }
}

/// Shows the exact checked code before starting a saved motion check or setup program.
struct RunConfirmSheet: View {
    @Environment(AppModel.self) private var app
    let program: SavedTestProgram
    let run: () -> Bool
    /// Numbered as the code check counts, so "Line n" in a refusal can be found. A long file
    /// shows its start; the whole program is checked and sent.
    private let preview: String
    @Environment(\.dismiss) private var dismiss
    @State private var clear = false

    init(program: SavedTestProgram, run: @escaping () -> Bool) {
        self.program = program
        self.run = run
        let lines = program.lines
        let shown = lines.prefix(400).enumerated().map { "\($0.offset + 1)\t\($0.element)" }.joined(separator: "\n")
        preview = lines.count > 400 ? shown + "\n… \(lines.count - 400) more lines" : shown
    }

    var body: some View {
        let check = app.mill.check(program)
        VStack(alignment: .leading, spacing: 14) {
            Label("Run \(program.title)?", systemImage: "play.circle.fill").font(.headline)
            if !program.detail.isEmpty {
                Text(program.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text(program.kind == .motionCheck ? "Spindle-off motion check" : "Setup program: may probe, change work offsets and run the spindle")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
            switch check {
            case .failure(let why):
                Label(why.text, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.warning)
            case .success:
                Label(program.kind == .motionCheck ? "Code and machine travel checked" : "Setup code checked; work moves use controller soft limits", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = app.mill.message {
                Text(message).font(.caption).foregroundStyle(Theme.warning)
            }
            Text("Feed Hold pauses it, Stop ends it. The red E-stop is always the first stop.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("The machine is clear, the tool does not touch anything, and I can reach the E-stop.", isOn: $clear)
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") {
                    if run() { dismiss() }
                }
                .buttonStyle(.glassProminent)
                .disabled(!clear || (try? check.get()) == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}


// MARK: - Home confirmation

struct HomeConfirmSheet: View {
    let home: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var clear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Home the machine?", systemImage: "house.fill").font(.headline)
            Text("All three axes move to their limit switches: Z first, then X and Y. It takes up to 10 seconds, and the machine does not answer while it homes.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("The table and the spindle path are clear, the tool does not touch anything, and I can reach the E-stop.", isOn: $clear)
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Home") {
                    home()
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(!clear)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
