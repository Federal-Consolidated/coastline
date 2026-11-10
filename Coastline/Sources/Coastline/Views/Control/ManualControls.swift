import CoastlineCore
import MillCore
import SwiftUI

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
