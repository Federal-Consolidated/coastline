import AppKit
import MillCore
import SwiftUI

/// Compact machine controls alongside the machine viewport. Values and actions share the
/// app's native controls; the jog pad keeps only the eight spatial targets visible.
struct ControlInspector: View {
    @Environment(AppModel.self) private var app
    @State private var frame = PositionFrame.work
    @State private var settingCoordinates = false
    @State private var spindleExpanded = false
    @State private var overridesExpanded = false
    @State private var diagnosticsExpanded = false

    private enum PositionFrame: String, CaseIterable { case work = "Work", machine = "Machine" }
    private var mill: MillControl { app.mill }
    private var s: MillSnapshot { mill.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                position.padding(16)
                Divider()
                jogging.padding(16)
                Divider()
                setup.padding(16)
                Divider()
                disclosure("Spindle", expanded: $spindleExpanded) { spindle }
                Divider()
                disclosure("Overrides", expanded: $overridesExpanded) { overrides }
                Divider()
                disclosure("Diagnostics", expanded: $diagnosticsExpanded) { diagnostics }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .background(Theme.panelBackground)
        .controlSize(.small)
        .font(.callout)
        .onDisappear { mill.endHold() }
    }

    private var position: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                heading("Position")
                Spacer()
                Text("mm").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Picker("Position coordinates", selection: $frame) {
                    ForEach(PositionFrame.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Picker("Work offset", selection: Binding(get: { s.activeWCS }, set: { mill.selectWCS($0) })) {
                    ForEach(54...59, id: \.self) { Text("G\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(width: 72)
                .disabled(s.gates.setup != nil)
                .help("Choose the work offset used by programs and work coordinates")
            }
            VStack(spacing: 6) {
                ForEach(MillCore.Axis.allCases, id: \.self) { axis in
                    HStack(spacing: 8) {
                        Text(axis.rawValue).foregroundStyle(.secondary).frame(width: 14)
                        Text(coordinate(axis))
                            .font(.system(.body, design: .monospaced))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 26, alignment: .trailing)
                            .padding(.horizontal, 8)
                            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 5))
                            .textSelection(.enabled)
                            .accessibilityLabel("\(frame.rawValue) \(axis.rawValue), \(coordinate(axis)) millimeters")
                        if frame == .work {
                            Button("Zero") { mill.zero([axis]) }
                                .disabled(s.gates.setup != nil)
                                .accessibilityLabel("Zero work \(axis.rawValue) in G\(s.activeWCS)")
                                .help("Make the current work \(axis.rawValue) zero in G\(s.activeWCS)")
                        }
                    }
                }
            }
            if frame == .work {
                HStack {
                    Button("Set coordinates…") { settingCoordinates = true }
                        .buttonStyle(.borderless)
                        .disabled(s.gates.setup != nil)
                        .popover(isPresented: $settingCoordinates, arrowEdge: .leading) {
                            SetWorkPopover().environment(app)
                        }
                    Spacer()
                    if let undo = mill.offsetUndo {
                        Button("Undo", systemImage: "arrow.uturn.backward") { mill.undoOffset() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .disabled(s.gates.setup != nil)
                            .help("Undo \(undo.what)")
                            .accessibilityLabel("Undo \(undo.what)")
                    }
                }
            }
        }
    }

    private func coordinate(_ axis: MillCore.Axis) -> String {
        guard s.isOpen else { return "—" }
        let point = frame == .work ? s.workPosition : s.status?.machinePosition
        return point.map { String(format: "%.3f", $0[axis]) } ?? "—"
    }

    private var jogging: some View {
        @Bindable var mill = mill
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading("Jog")
                Spacer()
                Button {
                    mill.allowJog.toggle()
                } label: {
                    Image(systemName: mill.allowJog ? "lock.open" : "lock")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .background(mill.allowJog ? Theme.accent.opacity(0.18) : Color.clear, in: .rect(cornerRadius: 6))
                .disabled(!s.homed && !mill.allowJog)
                .accessibilityLabel(mill.allowJog ? "Lock jogging" : "Unlock jogging")
                .accessibilityValue(mill.allowJog ? "Unlocked" : "Locked")
                .help(mill.allowJog ? "Lock jogging and stop the current jog" : "Unlock jogging")
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 4) {
                    ForEach(-1...1, id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(-1...1, id: \.self) { column in
                                if row == 0 && column == 0 {
                                    Color.clear.frame(width: 40, height: 30).accessibilityHidden(true)
                                } else {
                                    jogTarget(x: Double(row), y: Double(column), title: Self.direction(row, column))
                                        .frame(width: 40, height: 30)
                                }
                            }
                        }
                    }
                }
                .padding(6)
                .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Table and gantry jog pad")
                Spacer(minLength: 0)
                Divider().frame(height: 104)
                VStack(spacing: 8) {
                    Text("Spindle").font(.caption).foregroundStyle(.secondary)
                    jogTarget(z: -1, title: "Move spindle in", visibleTitle: "In").frame(height: 28)
                    jogTarget(z: 1, title: "Move spindle out", visibleTitle: "Out").frame(height: 28)
                }
                .frame(width: 72)
            }
            .disabled(!mill.allowJog || (s.gates.jog != nil && mill.heldJog == nil))
            HStack(spacing: 8) {
                Text("Mode").foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                Picker("Jog mode", selection: Binding(get: { mill.jogHold }, set: { mill.endHold(); mill.jogHold = $0 })) {
                    Text("Step").tag(false)
                    Text("Hold").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            HStack(spacing: 8) {
                Text("Step").foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                Picker("Jog step in millimeters", selection: $mill.jogStep) {
                    ForEach(MillSession.jogSteps, id: \.self) { step in
                        Text(String(format: "%g", step)).tag(step)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(mill.jogHold)
            }
            HStack(spacing: 8) {
                Text("Feed").foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                Picker("Jog feed", selection: $mill.jogFeed) {
                    ForEach(MillSession.jogFeeds, id: \.self) { Text("\(Int($0)) mm/min").tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

        }
    }

    private func jogTarget(x: Double = 0, y: Double = 0, z: Double = 0, title: String, visibleTitle: String? = nil) -> some View {
        NativeJogTarget(title: visibleTitle, spoken: title, holdMode: mill.jogHold, held: mill.isHolding(x: x, y: y, z: z),
                        step: { mill.jog(x: x, y: y, z: z) },
                        press: { mill.startHold(x: x, y: y, z: z) }, release: { mill.endHold() })
            .help(title + (mill.jogHold ? ". Hold to move; release to stop. Keyboard activation moves one step." : ". One step per click."))
    }

    private static func direction(_ row: Int, _ column: Int) -> String {
        let vertical = row < 0 ? "up" : row > 0 ? "down" : ""
        let horizontal = column < 0 ? "left" : column > 0 ? "right" : ""
        return "Move " + [vertical, horizontal].filter { !$0.isEmpty }.joined(separator: " and ")
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Setup")
            HStack(spacing: 8) {
                GoToMenu()
                    .disabled(!mill.allowJog || s.gates.run != nil)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var spindle: some View {
        @Bindable var mill = mill
        return VStack(alignment: .leading, spacing: 10) {
            LabeledContent("State", value: s.isOpen ? s.spindle.map { $0.mode == "M5" ? "Off" : String(format: "On, %.0f RPM", $0.rpm) } ?? "—" : "—")
            HStack {
                Text("Speed").foregroundStyle(.secondary)
                Spacer()
                TextField("Spindle speed", value: $mill.spindleRPM, format: .number.precision(.fractionLength(0)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                Text("RPM").foregroundStyle(.secondary)
            }
            HStack {
                Button("Start…", systemImage: "play.fill") { mill.showSpindleConfirm = true }
                    .disabled(s.gates.setup != nil)
                Button("Stop", systemImage: "stop.fill") { mill.spindleOff() }
                    .tint(Theme.danger).disabled(s.gates.console != nil)
            }
        }
    }

    private var overrides: some View {
        VStack(spacing: 10) {
            overrideRow("Feed", value: s.overrides.feed, minus: .feedMinus10, minusOne: .feedMinus1,
                        reset: .feedReset, plusOne: .feedPlus1, plus: .feedPlus10)
            HStack {
                Text("Rapid").foregroundStyle(.secondary)
                Spacer()
                Picker("Rapid override", selection: Binding(get: { s.overrides.rapid }, set: { mill.override($0 == 25 ? .rapid25 : $0 == 50 ? .rapid50 : .rapid100) })) {
                    Text("25%").tag(25); Text("50%").tag(50); Text("100%").tag(100)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 174)
            }
            overrideRow("Spindle", value: s.overrides.spindle, minus: .spindleMinus10, minusOne: .spindleMinus1,
                        reset: .spindleReset, plusOne: .spindlePlus1, plus: .spindlePlus10)
        }
        .disabled(!s.isOpen)
    }

    private func overrideRow(_ title: String, value: Int, minus: MillOverride, minusOne: MillOverride,
                             reset: MillOverride, plusOne: MillOverride, plus: MillOverride) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Button("−10") { mill.override(minus) }.accessibilityLabel("\(title) minus ten percent")
            Menu {
                Button("−1%") { mill.override(minusOne) }
                Button("+1%") { mill.override(plusOne) }
                Divider()
                Button("Reset to 100%") { mill.override(reset) }
            } label: { Text("\(value)%").monospacedDigit() }
            .menuStyle(.borderlessButton)
            .frame(width: 48)
            .help("Adjust \(title.lowercased()) by one percent")
            .accessibilityLabel("\(title) override, \(value) percent, fine adjustment")
            Button("+10") { mill.override(plus) }.accessibilityLabel("\(title) plus ten percent")
        }
    }

    private var diagnostics: some View {
        @Bindable var mill = mill
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Port", selection: $mill.portChoice) {
                Text("Automatic").tag(MillControl.PortChoice.automatic)
                ForEach(mill.ports) { port in
                    Text(port.path.replacingOccurrences(of: "/dev/", with: "")).tag(MillControl.PortChoice.device(port.path))
                }
                if case .device(let path) = mill.portChoice, !mill.ports.contains(where: { $0.path == path }) {
                    Text("\(path) (not plugged in)").tag(mill.portChoice)
                }
                Text("Simulated Mill").tag(MillControl.PortChoice.simulated)
            }
            .disabled(s.isOpen)
            Toggle("Connect automatically", isOn: $mill.autoConnect)
            HStack {
                if !s.isOpen {
                    Button("Refresh ports", systemImage: "arrow.clockwise") { mill.refreshPorts() }
                }
                Button("Console…", systemImage: "terminal") { mill.showConsole = true }
            }
            Menu("Test programs…") {
                ForEach(TestProgram.allCases) { program in
                    Button(program.title) { mill.programToConfirm = program }
                }
            }
            .disabled(s.gates.run != nil)
            if let firmware = s.firmware { Text(firmware).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let status = s.status {
                let limits = [status.limitX ? "X" : nil, status.limitY ? "Y" : nil, status.limitZ ? "Z" : nil]
                    .compactMap { $0 }.joined(separator: ", ")
                LabeledContent("Buffer", value: "\(status.freePlannerBlocks) blocks / \(status.freeRxBytes) bytes")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Probe", value: status.probeTripped ? "Closed" : "Open")
                LabeledContent("Limit switches", value: limits.isEmpty ? "Open" : limits)
                if let feed = status.feedRate {
                    LabeledContent("Reported feed", value: "\(feed) mm/min")
                    LabeledContent("Reported spindle", value: "\(status.spindleSpeed ?? 0) RPM")
                }
            }
            if let parser = s.parserState {
                Text(parser).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !s.offsets.isEmpty {
                DisclosureGroup("Work offsets") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(s.offsets.filter { $0.name.hasPrefix("G5") }) { offset in
                            Text(String(format: "%@  %.3f  %.3f  %.3f", offset.name, offset.point.x, offset.point.y, offset.point.z))
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.callout.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }

    private func disclosure<Content: View>(_ title: String, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        let section = content()
        return DisclosureGroup(isExpanded: expanded) {
            section.padding(.top, 12)
        } label: { heading(title) }
        .padding(16)
    }
}

/// NSButton keeps a real focus ring and accessible button behavior. Mouse holding starts
/// immediately and stops on release/exit; keyboard and accessibility activation do one step.
private struct NativeJogTarget: NSViewRepresentable {
    let title: String?
    let spoken: String
    let holdMode: Bool
    let held: Bool
    let step: () -> Void
    let press: () -> Void
    let release: () -> Void
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> JogTargetButton {
        let button = JogTargetButton()
        button.target = button
        button.action = #selector(JogTargetButton.activate)
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.focusRingType = .exterior
        return button
    }

    func updateNSView(_ button: JogTargetButton, context: Context) {
        if !enabled || button.holdMode != holdMode || (button.externalHeld && !held) { button.cancelPress() }
        button.title = title ?? ""
        button.dotOnly = title == nil
        button.isBordered = title != nil
        button.isEnabled = enabled
        button.holdMode = holdMode
        button.externalHeld = held
        button.step = step
        button.press = press
        button.release = release
        button.setAccessibilityLabel(spoken)
        button.setAccessibilityHelp(holdMode ? "Hold with the pointer to move; release to stop. Keyboard activation moves one step." : "Move one step.")
        button.needsDisplay = true
    }

    static func dismantleNSView(_ button: JogTargetButton, coordinator: ()) { button.tearDown() }

    final class JogTargetButton: NSButton {
        var dotOnly = true
        var holdMode = false
        var externalHeld = false
        var step: () -> Void = {}
        var press: () -> Void = {}
        var release: () -> Void = {}
        private var pressing = false
        private var trackingHold = false
        private var hovered = false
        private var tracking: NSTrackingArea?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tearDown()
            guard let window else { return }
            let letGo: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelPress() }
            }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: letGo),
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: letGo),
            ]
        }

        func tearDown() {
            cancelPress()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        override func updateTrackingAreas() {
            if let tracking { removeTrackingArea(tracking) }
            let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(next)
            tracking = next
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovered = false; cancelPress(); needsDisplay = true }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            if holdMode {
                trackingHold = true
                pressing = true
                press()
                defer { cancelPress(); trackingHold = false }
                super.mouseDown(with: event)
            } else {
                super.mouseDown(with: event)
            }
        }

        @objc func activate() {
            // Native tracking invokes the action on mouse-up; the hold already moved.
            if !trackingHold { step() }
        }

        func cancelPress() {
            guard pressing else { return }
            pressing = false
            release()
            highlight(false)
            needsDisplay = true
        }

        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill() }

        override func draw(_ dirtyRect: NSRect) {
            guard dotOnly else { return super.draw(dirtyRect) }
            let active = holdMode ? externalHeld : isHighlighted
            if isEnabled && (hovered || active) {
                let alpha = active ? 0.28 : 0.13
                NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
            }
            (isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2, y: bounds.midY - 2, width: 4, height: 4)).fill()
        }
    }
}
