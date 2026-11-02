import MillCore
import SwiftUI

/// Connect to the machine, watch its state live, home it, jog it (buttons or keys), set work
/// zero, go to positions, run the spindle and override feeds. The console is in the inspector.
struct ControlPage: View {
    @Environment(AppModel.self) private var app

    private var mill: MillControl { app.mill }
    private var s: MillSnapshot { mill.snapshot }

    var body: some View {
        @Bindable var mill = mill
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "cable.connector").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.machine.name).font(.title2.weight(.semibold))
                        Text(subtitle).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if mill.isSimulated { Badge(text: "Simulated", color: Theme.accent, symbol: "desktopcomputer") }
                    Badge(text: mill.stateWord, color: stateColor, symbol: stateSymbol)
                    if mill.isOpen {
                        Button("Disconnect", systemImage: "cable.connector.slash") { mill.disconnect() }
                            .plainGlassButton()
                    } else {
                        Button("Connect", systemImage: "cable.connector") { mill.connect() }
                            .buttonStyle(.glassProminent)
                    }
                }
                .controlSize(.large)
                .padding(.vertical, 4)
                NextStepRow()
                if let program = s.program { ProgramProgress(program: program) }
            }

            AttentionSection()
            MotionSection()
            PositionSection()
            SpindleSection()
            OverridesSection()
            TestProgramsSection()
            ConnectionSection()
            if s.isOpen { ControllerSection() }
        }
        .formStyle(.grouped)
        .background(JogKeys(mill: mill))
        .darkPanel()
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle("Control")
        .navigationSubtitle(mill.stateWord)
        .inspector(isPresented: Bindable(app).showInspector) {
            MillConsole()
                .panelEdge(.leading)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
        }
    }

    private var subtitle: String {
        guard let port = s.port else { return "Not connected" }
        let firmware = s.firmware.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
        return [port.label, firmware].compactMap { $0 }.joined(separator: " · ")
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

// MARK: - Connection

private struct ConnectionSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var mill = app.mill
        let open = mill.isOpen
        Section {
            Picker("Port", selection: $mill.portChoice) {
                Text("Automatic").tag(MillControl.PortChoice.automatic)
                ForEach(mill.ports) { port in
                    Text(port.path.replacingOccurrences(of: "/dev/", with: "")).tag(MillControl.PortChoice.device(port.path))
                }
                if case .device(let path) = mill.portChoice, !mill.ports.contains(where: { $0.path == path }) {
                    Text("\(path) (not plugged in)").tag(mill.portChoice)
                }
                Divider()
                Text("Simulated Mill").tag(MillControl.PortChoice.simulated)
            }
            .disabled(open)
            if !open {
                Button("Refresh Ports", systemImage: "arrow.clockwise") { mill.refreshPorts() }
                    .plainGlassButton()
                    .help("Look again for a plugged-in machine")
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Connecting restarts the controller, so home the machine after every connect. Coastline never moves the machine until you press Home or a jog button.")
        }
    }
}

// MARK: - Attention

private struct AttentionSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let items = Self.items(app.mill.snapshot)
        if !items.isEmpty {
            Section("Attention") {
                ForEach(items, id: \.text) { item in
                    Label(item.text, systemImage: item.symbol)
                        .foregroundStyle(item.color)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private struct Item {
        var text: String
        var symbol: String
        var color: Color
    }

    private static func items(_ s: MillSnapshot) -> [Item] {
        guard s.isOpen else {
            return s.lastError.map { [Item(text: $0, symbol: "xmark.octagon.fill", color: Theme.danger)] } ?? []
        }
        var items: [Item] = []
        if s.silentSince != nil {
            items.append(Item(text: MillRefusal.silent.text, symbol: "xmark.octagon.fill", color: Theme.danger))
        }
        if let alarm = s.lastAlarm { items.append(Item(text: alarm, symbol: "xmark.octagon.fill", color: Theme.danger)) }
        if s.needsReset { items.append(Item(text: MillRefusal.needsReset.text, symbol: "arrow.counterclockwise.circle.fill", color: Theme.danger)) }
        if let status = s.status, status.limitX || status.limitY || status.limitZ {
            items.append(Item(text: "A limit switch is pressed. Do not move the machine until you know why.",
                              symbol: "exclamationmark.triangle.fill", color: Theme.danger))
        }
        if case .settings(let why)? = s.gates.home { items.append(Item(text: why, symbol: "gearshape.fill", color: Theme.danger)) }
        if let error = s.lastError { items.append(Item(text: error, symbol: "exclamationmark.triangle.fill", color: Theme.warning)) }
        if s.link == .connected, s.silentSince == nil, !s.homed, s.homingSince == nil, !s.needsReset {
            items.append(Item(text: s.locked ? "The machine is locked until you home it." : "Home the machine before you jog.",
                              symbol: "house.circle.fill", color: Theme.warning))
        }
        if s.status?.probeTripped == true {
            items.append(Item(text: "The probe circuit is closed (P). Check the probe clip before you probe or edge-find.",
                              symbol: "bolt.horizontal.circle.fill", color: Theme.warning))
        }
        return items
    }
}

// MARK: - Position

private struct PositionSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.mill.snapshot
        let stale = s.statusTime.map { Date().timeIntervalSince($0) > 1 } ?? true
        Section {
            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Machine").font(.caption).foregroundStyle(.secondary)
                    Text("Work (G\(s.activeWCS))").font(.caption).foregroundStyle(.secondary)
                    Text("Free travel −/+").font(.caption).foregroundStyle(.secondary)
                    Text("")
                }
                ForEach(MillCore.Axis.allCases, id: \.self) { axis in
                    GridRow {
                        HStack(spacing: 6) {
                            Text(axis.rawValue).font(.headline)
                            Text(axisName(axis)).font(.caption).foregroundStyle(.secondary)
                        }
                        .gridColumnAlignment(.leading)
                        value(s.status?.machinePosition[axis])
                        value(s.workPosition?[axis])
                        Text(freeTravel(s, axis)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button("Zero \(axis.rawValue)") { app.mill.zero([axis]) }
                            .plainGlassButton()
                            .disabled(s.gates.setup != nil)
                            .help("Make the work \(axis.rawValue) here 0 in G\(s.activeWCS) (G10 L20)")
                    }
                }
            }
            .foregroundStyle(stale ? .secondary : .primary)
            .padding(.vertical, 2)
            WorkZeroRow()
        } header: {
            Text("Position and Work Zero")
        } footer: {
            Text(footer(s, stale: stale))
        }
    }

    private func value(_ v: Double?) -> some View {
        Text(v.map { String(format: "%.3f", $0) } ?? "—")
            .font(.title3.weight(.semibold).monospacedDigit())
    }

    private func axisName(_ axis: MillCore.Axis) -> String {
        switch axis {
        case .x: "table up/down"
        case .y: "gantry left/right"
        case .z: "spindle in/out"
        }
    }

    private func freeTravel(_ s: MillSnapshot, _ axis: MillCore.Axis) -> String {
        guard let p = s.status?.machinePosition[axis], let range = s.envelope?[axis] else { return "" }
        return String(format: "%.1f / %.1f", max(0, p - range.lowerBound), max(0, range.upperBound - p))
    }

    private func footer(_ s: MillSnapshot, stale: Bool) -> String {
        var parts = [s.homed ? "Homed." : "Not homed: the position is not known."]
        if stale { parts.append("Waiting for a status report.") }
        parts.append("Machine coordinates are negative from home (X homes at its low end).")
        parts.append("Zero and Set change the selected work offset; the controller keeps it after a restart. A job's probing programs set their own offsets.")
        return parts.joined(separator: " ")
    }
}

// MARK: - Motion

private struct MotionSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var mill = app.mill
        let s = mill.snapshot
        Section {
            HStack(spacing: 10) {
                Button("Home…", systemImage: "house") { mill.showHomeConfirm = true }
                    .buttonStyle(.glassProminent)
                    .disabled(s.gates.home != nil)
                    .help("Move all three axes to their limit switches ($H)")
                if s.homingSince != nil {
                    ProgressView().controlSize(.small)
                    Text("Homing…").font(.callout).foregroundStyle(.secondary)
                } else if let why = s.gates.home {
                    Text(s.isOpen ? why.text : "Connect first.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("All three axes move to their limit switches.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Toggle("Allow Jog", isOn: $mill.allowJog)
                .disabled(!s.homed)
                .help("Arms the jog buttons, the jog keys and Go To. Turns off by itself after an alarm, a restart, a stop, silence or a disconnect")

            Picker("Step", selection: Binding<Double?>(get: { mill.jogHold ? nil : mill.jogStep }, set: { step in
                mill.endHold()
                if let step { mill.jogStep = step }
                mill.jogHold = step == nil
            })) {
                Text("Hold").tag(Double?.none)
                ForEach(MillSession.jogSteps, id: \.self) { Text(stepText($0)).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .help("Hold: the axis moves while you hold a jog button or key. A distance: one step per click or key press")
            Picker("Feed", selection: $mill.jogFeed) {
                ForEach(MillSession.jogFeeds, id: \.self) { Text("\(Int($0)) mm/min").tag($0) }
            }
            .pickerStyle(.segmented)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                // Directions as in the original software's JogDirection for this machine family: X− raises the table.
                jogRow(.x, "Table", minus: ("Up", "arrow.up"), plus: ("Down", "arrow.down"), keys: "↑ ↓")
                jogRow(.y, "Gantry", minus: ("Left", "arrow.left"), plus: ("Right", "arrow.right"), keys: "← →")
                jogRow(.z, "Spindle", minus: ("In", "arrow.down.right"), plus: ("Out", "arrow.up.left"), keys: "Page Up/Down, ⇧↑ ⇧↓")
            }
            // In hold-to-jog the machine is in Jog while a button is held: keep the buttons live.
            .disabled(!mill.allowJog || (s.gates.jog != nil && mill.heldJog == nil))

            if mill.allowJog, let why = s.gates.jog, mill.heldJog == nil {
                Text(why.text).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                GoToMenu()
                    .fixedSize()
                    .disabled(!mill.allowJog || s.gates.run != nil)
                Spacer()
            }
            HStack(spacing: 10) {
                Button("Feed Hold", systemImage: "pause.fill") { mill.feedHold() }
                    .buttonStyle(.glass).tint(Theme.warning)
                    .disabled(!s.isOpen)
                Button("Resume", systemImage: "play.fill") { mill.resume() }
                    .plainGlassButton()
                    .disabled(s.gates.resume != nil)
                Button("Stop", systemImage: "stop.fill") { mill.stop() }
                    .buttonStyle(.glass).tint(Theme.danger)
                    .disabled(!s.isOpen)
                    .help("Cancel a jog, or hold and reset the controller (⇧⌘.)")
                Spacer()
            }
            .controlSize(.large)
        } header: {
            Text("Motion")
        } footer: {
            Text("Jogs stop 0.5 mm inside each end of travel. The keys work on this page while Allow Jog is on and no text field is being typed in. With Hold, the axis stops when you let go, when the window loses focus, or if Coastline stops answering. Feed Hold and Stop always work while the port is open; the red E-stop on the machine is always the first stop.")
        }
    }

    private func stepText(_ step: Double) -> String {
        step < 1 ? String(format: "%g mm", step) : "\(Int(step)) mm"
    }

    @ViewBuilder
    private func jogRow(_ axis: MillCore.Axis, _ name: String, minus: (String, String), plus: (String, String), keys: String) -> some View {
        GridRow {
            Text("\(axis.rawValue)  \(name)").font(.callout.weight(.semibold)).frame(width: 90, alignment: .leading)
            JogButton(axis: axis, direction: -1, title: "\(axis.rawValue)− \(minus.0)", symbol: minus.1,
                      spoken: "Jog \(axis.rawValue) minus, \(minus.0.lowercased())")
            JogButton(axis: axis, direction: 1, title: "\(axis.rawValue)+ \(plus.0)", symbol: plus.1,
                      spoken: "Jog \(axis.rawValue) plus, \(plus.0.lowercased())")
            Text(keys).font(.caption).foregroundStyle(.secondary)
                .help("Keyboard: \(keys)")
        }
    }
}

/// A jog button: one step per click, or in hold-to-jog, motion while it is pressed.
private struct JogButton: View {
    let axis: MillCore.Axis
    let direction: Double
    let title: String
    let symbol: String
    let spoken: String
    @Environment(AppModel.self) private var app
    @Environment(\.isEnabled) private var isEnabled
    @State private var pressed = false

    var body: some View {
        let mill = app.mill
        if mill.jogHold {
            let held = mill.heldJog == HeldJog(axis: axis, direction: direction)
            Label(title, systemImage: symbol)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .glassEffect(held ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: .capsule)
                .contentShape(.capsule)
                .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity, perform: {}, onPressingChanged: { down in
                    guard isEnabled || !down else { return }
                    pressed = down
                    if down { mill.startHold(axis, direction) } else { mill.endHold() }
                })
                .onDisappear { if pressed { mill.endHold() } }
                .accessibilityElement()
                .accessibilityLabel(spoken)
                .accessibilityHint("Hold to move; let go to stop")
        } else {
            Button { mill.jog(axis, direction) } label: { Label(title, systemImage: symbol) }
                .plainGlassButton()
                .accessibilityLabel(spoken)
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
            Button("Tool-Change Position") { mill.goTo = .toolChange(app.machine.toolChangeMoves) }
            Divider()
            Button("Position…") { mill.goTo = .position(s) }
        }
        .help("Rapid moves to a place, the spindle out first. Needs Allow Jog")
    }
}

// MARK: - Controller

private struct ControllerSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.mill.snapshot
        Section("Controller") {
            if let status = s.status {
                LabeledContent("State", value: status.state)
                LabeledContent("Buffer", value: "\(status.freePlannerBlocks) blocks, \(status.freeRxBytes) bytes free")
                LabeledContent("Pins") {
                    HStack(spacing: 10) {
                        pin("Probe", status.probeTripped)
                        pin("X", status.limitX)
                        pin("Y", status.limitY)
                        pin("Z", status.limitZ)
                    }
                }
                if let feed = status.feedRate {
                    LabeledContent("Feed / spindle", value: "\(feed) mm/min · \(status.spindleSpeed ?? 0) RPM")
                }
            }
            if let parser = s.parserState { LabeledContent("Modes ($G)", value: parser) }
            if !s.offsets.isEmpty {
                DisclosureGroup("Work offsets ($#)") {
                    ForEach(s.offsets.filter { $0.name.hasPrefix("G5") }) { o in
                        LabeledContent(o.name, value: String(format: "X%.3f  Y%.3f  Z%.3f", o.point.x, o.point.y, o.point.z))
                            .font(.callout.monospacedDigit())
                    }
                }
            }
            if let banner = s.banner { LabeledContent("Firmware", value: banner) }
            if s.restarts > 0 { LabeledContent("Restarts since connect", value: "\(s.restarts)") }
        }
    }

    private func pin(_ name: String, _ on: Bool) -> some View {
        Label(name, systemImage: on ? "circle.fill" : "circle")
            .foregroundStyle(on ? Theme.warning : .secondary)
            .accessibilityLabel("\(name) \(on ? "closed" : "open")")
    }
}

// MARK: - Test programs

private struct TestProgramsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let mill = app.mill
        let s = mill.snapshot
        Section {
            ForEach(TestProgram.allCases) { program in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "music.note").font(.title3).foregroundStyle(Theme.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(program.title).font(.callout.weight(.semibold))
                        Text(program.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Run…", systemImage: "play.fill") { mill.programToConfirm = program }
                        .buttonStyle(.glassProminent)
                        .disabled(s.gates.run != nil)
                        .help(s.gates.run.map { $0.text } ?? "Run \(program.title)")
                }
            }
            if s.isOpen, s.program?.outcome != .running, let why = s.gates.run {
                Text(why.text).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Test Programs")
        } footer: {
            Text("Short programs to check the machine. Coastline checks every line before it runs: only simple moves, and every position inside the travel.")
        }
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

/// Confirms a test program, like the Home sheet.
struct RunConfirmSheet: View {
    let program: TestProgram
    let run: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var clear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Run \(program.title)?", systemImage: "play.circle.fill").font(.headline)
            Text(program.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
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
                    run()
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(!clear)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Next step

/// One line at the top that says what to do now, with the button for it.
private struct NextStepRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let mill = app.mill
        let s = mill.snapshot
        HStack(spacing: 12) {
            Image(systemName: symbol(s)).font(.title2).foregroundStyle(color(s))
            VStack(alignment: .leading, spacing: 2) {
                Text(title(s)).font(.headline)
                Text(mill.message ?? detail(s)).font(.callout)
                    .foregroundStyle(mill.message == nil ? .secondary : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action(s)
        }
        .padding(.vertical, 4)
    }

    private func title(_ s: MillSnapshot) -> String {
        switch s.link {
        case .disconnected: return "Next: connect to the machine"
        case .connecting: return "Connecting…"
        case .connected:
            if s.silentSince != nil { return "Release the E-stop" }
            if s.needsReset { return "Next: reset the controller" }
            if s.homingSince != nil { return "Homing…" }
            if !s.homed { return "Next: home the machine" }
            if !app.mill.allowJog { return "Next: turn on jogging" }
            return "Ready"
        }
    }

    private func detail(_ s: MillSnapshot) -> String {
        switch s.link {
        case .disconnected: return "Turn the mill on, release the E-stop, then press Connect. Nothing moves when you connect."
        case .connecting: return "The controller restarts when the port opens. This takes about 2 seconds."
        case .connected:
            if s.silentSince != nil { return "No reply from the machine. Turn the red knob clockwise until it pops up." }
            if s.needsReset { return "An alarm stopped the machine. Press Reset, then home the machine." }
            if s.homingSince != nil { return "All three axes move to their limit switches. Stay at the E-stop." }
            if !s.homed { return "After every connect the machine is locked until it is homed." }
            if !app.mill.allowJog { return "Jogging is off so that a stray click cannot move the machine." }
            return "Jog with the buttons below or the arrow keys. Type commands in the console (Machine ▸ Show Console)."
        }
    }

    private func symbol(_ s: MillSnapshot) -> String {
        switch s.link {
        case .disconnected: return "1.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath.circle.fill"
        case .connected:
            if s.silentSince != nil || s.needsReset { return "exclamationmark.octagon.fill" }
            if !s.homed { return "2.circle.fill" }
            if !app.mill.allowJog { return "3.circle.fill" }
            return "checkmark.circle.fill"
        }
    }

    private func color(_ s: MillSnapshot) -> Color {
        if s.silentSince != nil || s.needsReset { return Theme.danger }
        return s.link == .connected && s.homed && app.mill.allowJog ? Theme.ok : Theme.accent
    }

    @ViewBuilder
    private func action(_ s: MillSnapshot) -> some View {
        let mill = app.mill
        switch s.link {
        case .disconnected:
            Button("Connect", systemImage: "cable.connector") { mill.connect() }.buttonStyle(.glassProminent)
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected:
            if s.silentSince != nil {
                EmptyView()
            } else if s.needsReset {
                Button("Reset", systemImage: "arrow.counterclockwise") { mill.softReset() }.buttonStyle(.glassProminent)
            } else if s.homingSince != nil {
                ProgressView().controlSize(.small)
            } else if !s.homed {
                Button("Home…", systemImage: "house") { mill.showHomeConfirm = true }
                    .buttonStyle(.glassProminent)
                    .disabled(s.gates.home != nil)
            } else if !mill.allowJog {
                Button("Allow Jog", systemImage: "hand.raised") { mill.allowJog = true }.buttonStyle(.glassProminent)
            } else {
                Button("Show Console", systemImage: "terminal") { app.showInspector = true }.plainGlassButton()
            }
        }
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
