import CoastlineCore
import MillCore
import SwiftUI

// MARK: - Work zero

/// Under the position grid: the active work offset (G54…G59), Zero All, Set… and Undo.
struct WorkZeroRow: View {
    @Environment(AppModel.self) private var app
    @State private var setting = false

    var body: some View {
        let mill = app.mill
        let s = mill.snapshot
        let blocked = s.gates.setup != nil
        HStack(spacing: 10) {
            Picker("Work offset", selection: Binding(get: { s.activeWCS }, set: { mill.selectWCS($0) })) {
                ForEach(54...59, id: \.self) { Text("G\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(blocked)
            .help("The work offset that moves, programs and the Work column use (G54…G59)")
            Spacer()
            if let undo = mill.offsetUndo {
                Button("Undo", systemImage: "arrow.uturn.backward") { mill.undoOffset() }
                    .plainGlassButton()
                    .disabled(blocked)
                    .help(String(format: "Undo %@: put G%d back to X%.3f Y%.3f Z%.3f", undo.what, undo.wcs, undo.before.x, undo.before.y, undo.before.z))
                    .accessibilityLabel("Undo \(undo.what)")
            }
            Button("Set…") { setting = true }
                .plainGlassButton()
                .disabled(blocked)
                .help("Type the work coordinates of the current position")
                .popover(isPresented: $setting, arrowEdge: .bottom) { SetWorkPopover() }
            Button("Zero All") { mill.zero(MillCore.Axis.allCases) }
                .buttonStyle(.glassProminent)
                .disabled(blocked)
                .help("Make the current position X0 Y0 Z0 in G\(s.activeWCS)")
        }
        if s.isOpen, let why = s.gates.setup, why != .notConnected {
            Text(why.text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Typed work coordinates for the current position (G10 L20). Blank axes keep their offset.
struct SetWorkPopover: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var x: Double?
    @State private var y: Double?
    @State private var z: Double?

    var body: some View {
        let mill = app.mill
        let values = Dictionary(uniqueKeysWithValues: [(MillCore.Axis.x, x), (.y, y), (.z, z)].compactMap { a, v in v.map { (a, $0) } })
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("This position in G\(mill.snapshot.activeWCS) is").font(.headline)
                Spacer()
                UnitsPicker()
            }
            OptionalNumberField(title: "X", value: $x, unit: "mm")
            OptionalNumberField(title: "Y", value: $y, unit: "mm")
            OptionalNumberField(title: "Z", value: $z, unit: "mm")
            Text("Blank: that axis keeps its offset.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set") {
                    mill.setWork(values, "Set " + values.keys.map(\.rawValue).sorted().joined(separator: " "))
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(values.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Spindle

struct SpindleSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var mill = app.mill
        let s = mill.snapshot
        let low = s.settings.values[31] ?? 0, high = s.settings.values[30] ?? 0
        Section {
            LabeledContent("Now", value: state(s))
            HStack(spacing: 10) {
                Text("Speed")
                TextField("Speed", value: $mill.spindleRPM, format: .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("RPM").foregroundStyle(.secondary)
                Stepper("Speed", value: $mill.spindleRPM, in: max(low, 0)...max(high, low, 1), step: 500)
                    .labelsHidden()
                Spacer()
                Button("Start…", systemImage: "play.fill") { mill.showSpindleConfirm = true }
                    .buttonStyle(.glassProminent)
                    .disabled(s.gates.setup != nil)
                    .help("M3: forward, the cutting direction")
                Button("Stop", systemImage: "stop.fill") { mill.spindleOff() }
                    .buttonStyle(.glass).tint(Theme.danger)
                    .disabled(s.gates.console != nil)
                    .help("M5")
            }
            if s.isOpen, let why = s.gates.setup, why != .notConnected {
                Text(why.text).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Spindle")
        } footer: {
            Text(high > 0 ? String(format: "%.0f–%.0f RPM ($31–$30). ", low, high) + note : note)
        }
    }

    private var note: String {
        "The state is what the controller reported last ($G). Stop, Soft Reset and the E-stop also stop the spindle."
    }

    private func state(_ s: MillSnapshot) -> String {
        guard s.isOpen, let spindle = s.spindle else { return "—" }
        switch spindle.mode {
        case "M3": return String(format: "On, forward, %.0f RPM", spindle.rpm)
        case "M4": return String(format: "On, reverse, %.0f RPM", spindle.rpm)
        default: return "Off"
        }
    }
}

/// Confirms Spindle Start, like the Home sheet.
struct SpindleConfirmSheet: View {
    let rpm: Double
    let start: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var clear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(String(format: "Start the spindle at %.0f RPM?", rpm), systemImage: "fanblades.fill").font(.headline)
            Text("M3: forward, the cutting direction. The spindle runs until you press Stop.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Toggle("The tool is tight in the collet, nothing touches it, and I can reach the E-stop.", isOn: $clear)
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    start()
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

// MARK: - Overrides

struct OverridesSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let mill = app.mill
        let s = mill.snapshot
        let o = s.overrides
        Section {
            row("Feed", o.feed, minus10: .feedMinus10, minus1: .feedMinus1, reset: .feedReset, plus1: .feedPlus1, plus10: .feedPlus10)
            LabeledContent("Rapid") {
                Picker("Rapid", selection: Binding(get: { o.rapid }, set: { value in
                    mill.override(value == 25 ? .rapid25 : value == 50 ? .rapid50 : .rapid100)
                })) {
                    Text("25%").tag(25)
                    Text("50%").tag(50)
                    Text("100%").tag(100)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            row("Spindle", o.spindle, minus10: .spindleMinus10, minus1: .spindleMinus1, reset: .spindleReset, plus1: .spindlePlus1, plus10: .spindlePlus10)
        } header: {
            Text("Overrides")
        } footer: {
            Text(o.reported
                 ? "As the controller reports them. They act at once, also while a program runs."
                 : "They act at once, also while a program runs. The machine does not report them: these are what Coastline sent since the last restart, and a restart sets them back to 100%.")
        }
        .disabled(!s.isOpen)
    }

    private func row(_ name: String, _ value: Int, minus10: MillOverride, minus1: MillOverride, reset: MillOverride,
                     plus1: MillOverride, plus10: MillOverride) -> some View {
        let mill = app.mill
        return LabeledContent(name) {
            HStack(spacing: 6) {
                Button("−10") { mill.override(minus10) }.help("\(name) −10%")
                Button("−1") { mill.override(minus1) }.help("\(name) −1%")
                Text("\(value)%")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(value == 100 ? .primary : Theme.warning)
                    .frame(width: 52)
                Button("+1") { mill.override(plus1) }.help("\(name) +1%")
                Button("+10") { mill.override(plus10) }.help("\(name) +10%")
                Button("100%") { mill.override(reset) }.help("\(name) back to 100%")
            }
            .plainGlassButton()
        }
    }
}

// MARK: - Go To

/// Confirms a go-to: the target (editable, unless the moves are fixed) and the moves it makes.
struct GoToSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var request: GoToRequest

    var body: some View {
        let mill = app.mill
        let s = mill.snapshot
        let plan = mill.lines(for: request)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(request.title, systemImage: "location.fill").font(.headline)
                Spacer()
                UnitsPicker()
            }
            if request.fixedLines == nil {
                Picker("Coordinates", selection: $request.frame) {
                    Text("Work (G\(s.activeWCS))").tag(GoTo.Frame.work)
                    Text("Machine").tag(GoTo.Frame.machine)
                }
                .pickerStyle(.segmented)
                OptionalNumberField(title: "X  table", value: $request.x, unit: "mm")
                OptionalNumberField(title: "Y  gantry", value: $request.y, unit: "mm")
                OptionalNumberField(title: "Z  spindle", value: $request.z, unit: "mm")
                Toggle("Spindle out first, then X and Y, then Z", isOn: $request.retractFirst)
                Text("Blank: that axis does not move.").font(.caption).foregroundStyle(.secondary)
            }
            GroupBox {
                switch plan {
                case .success(let lines):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.compactMap(Self.describe).enumerated()), id: \.offset) { i, text in
                            Text("\(i + 1). \(text)").font(.callout)
                        }
                        Text("G-code (mm): " + lines.joined(separator: "  ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .failure(let why):
                    Label(why.text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Rapid moves (G0). Feed Hold pauses them, Stop ends them. The red E-stop is always the first stop.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !mill.allowJog {
                Text("Unlock jogging first.").font(.caption).foregroundStyle(Theme.warning)
            } else if let why = s.gates.run {
                Text(why.text).font(.caption).foregroundStyle(Theme.warning)
            } else if let message = mill.message {
                Text(message).font(.caption).foregroundStyle(Theme.warning)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go") {
                    if mill.go(request) { dismiss() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!mill.allowJog || s.gates.run != nil || (try? plan.get()) == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// One move in words: "Spindle off", "Rapid to machine X −40.000 Y −100.000".
    private static func describe(_ line: String) -> String? {
        if line == "M5" { return "Spindle off" }
        guard line.contains("G53") else { return nil }
        let units = AppSettings.shared.units
        let words = line.matches(of: /([XYZ])(-?[0-9.]+)/).map {
            "\($0.output.1) \(units.format(Double($0.output.2) ?? 0))"
        }
        return "Rapid to machine " + words.joined(separator: " ") + " " + units.symbol
    }
}

extension GoToRequest {
    static var workZero: GoToRequest { GoToRequest(title: "Go to work zero", x: 0, y: 0) }

    static func home(_ s: MillSnapshot) -> GoToRequest? {
        s.homeTarget.map { GoToRequest(title: "Go to the home position", x: $0.x, y: $0.y, z: $0.z, frame: .machine) }
    }

    /// The machine profile's tool-change moves without their `$H` (the machine is homed), the
    /// spindle off first.
    static func toolChange(_ moves: [String]) -> GoToRequest {
        GoToRequest(title: "Go to the tool-change position",
                    fixedLines: ["G21", "G90", "M5"] + moves.filter { $0.uppercased().replacingOccurrences(of: " ", with: "") != "$H" })
    }

    /// A typed position, starting from where the machine is.
    static func position(_ s: MillSnapshot) -> GoToRequest {
        let round = { (v: Double) in (v * 1000).rounded() / 1000 }
        let w = s.workPosition
        return GoToRequest(title: "Go to a position", x: w.map { round($0.x) }, y: w.map { round($0.y) }, z: w.map { round($0.z) })
    }
}
