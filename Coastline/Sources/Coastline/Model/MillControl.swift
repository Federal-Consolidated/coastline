import AppKit
import MillCore
import Foundation
import Observation

/// The app's link to the machine: owns the `MillSession` (which does all the I/O on its own
/// thread) and copies its snapshot and console to the main actor ten times a second.
@MainActor @Observable
final class MillControl {
    enum PortChoice: Hashable {
        case automatic
        case simulated
        case device(String)
    }

    private(set) var snapshot = MillSnapshot()
    private(set) var console: [MillConsoleLine] = []
    private(set) var ports: [MillDevice] = []
    var portChoice: PortChoice {
        didSet { saveChoice() }
    }
    /// Connect by itself when the machine is plugged in (once per plug-in: after Disconnect or a
    /// failed connect it waits until the machine is unplugged and plugged in again). Connecting
    /// moves nothing.
    var autoConnect = UserDefaults.standard.object(forKey: "millAutoConnect") as? Bool ?? true {
        didSet {
            if ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil { UserDefaults.standard.set(autoConnect, forKey: "millAutoConnect") }
        }
    }
    var jogStep = 1.0
    var jogFeed = 1000.0
    /// Hold-to-jog: the pad and keys move while held.
    var jogHold = false {
        didSet { if jogHold != oldValue { endHold() } }
    }
    /// The jog the operator holds now (a button or a key, in hold-to-jog).
    private(set) var heldJog: HeldJog?
    /// Off by default, and off again after anything that makes the position doubtful. Also arms
    /// Go To.
    var allowJog = false {
        didSet {
            if oldValue && !allowJog {
                heldJog = nil
                holdStartedAt = nil
                session.jogCancel()
            }
        }
    }
    /// The last refused request, shown under the motion controls.
    var message: String?
    /// The Home confirmation sheet (opened from the page, the toolbar or the Machine menu).
    var showHomeConfirm = false
    /// The test program waiting for the operator's confirmation.
    var programToConfirm: SavedTestProgram?
    var showProgramLibrary = false
    private(set) var programs: TestProgramLibrary = {
        guard let data = UserDefaults.standard.data(forKey: "millTestPrograms"),
              let saved = try? JSONDecoder().decode(TestProgramLibrary.self, from: data) else {
            return TestProgramLibrary()
        }
        return saved
    }()
    /// The go-to waiting for the operator's confirmation.
    var goTo: GoToRequest?
    /// The spindle speed for Spindle On (RPM).
    var spindleRPM = 5000.0
    var showSpindleConfirm = false
    /// Console is a separate utility sheet, leaving the control inspector available.
    var showConsole = false
    /// The last work-offset change, for Undo.
    private(set) var offsetUndo: OffsetChange?

    // Coarse flags for the Machine menu: set only when they change, because menus redraw on
    // every change of what they read and the snapshot changes four times a second.
    private(set) var isPortOpen = false
    private(set) var canHome = false
    private(set) var canResume = false
    private(set) var canRun = false

    @ObservationIgnored private let session = MillSession()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastConsoleID = 0
    @ObservationIgnored private var terminateSignal: DispatchSourceSignal?
    @ObservationIgnored private var lastScan = Date.distantPast
    @ObservationIgnored private var holdStartedAt: Date?
    /// Ports not to connect to by themselves until they are unplugged: connected once already
    /// (the operator may have disconnected), or the connect failed.
    @ObservationIgnored private var autoSkip: Set<String> = []

    init() {
        switch UserDefaults.standard.string(forKey: "millPort") ?? "auto" {
        case "auto": portChoice = .automatic
        case "sim": portChoice = .simulated
        case let path: portChoice = .device(path)
        }
        refreshPorts()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // `kill` (SIGTERM) quits like ⌘Q, so a moving machine is stopped first (see `shutdown`).
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        terminateSignal = source
        if ProcessInfo.processInfo.environment["COASTLINE_DEV"] == "1" {
            connectSimulator()
        }
    }

    var isOpen: Bool { snapshot.isOpen }
    var isSimulated: Bool { snapshot.port?.isSimulated ?? false }

    /// A short word for badges and the toolbar: "Idle", "Alarm", "No reply", "Homing"…
    var stateWord: String {
        switch snapshot.link {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting"
        case .connected:
            if snapshot.silentSince != nil { return "No reply" }
            if snapshot.homingSince != nil { return "Homing" }
            return snapshot.status?.state.split(separator: ":").first.map(String.init) ?? "Connected"
        }
    }

    func refreshPorts() { ports = MillSession.availablePorts() }

    func connect() {
        message = nil
        let port: MillPort
        switch portChoice {
        case .simulated: port = .simulated
        case .device(let path):
            refreshPorts()
            guard let device = ports.first(where: { $0.path == path }) else {
                message = "\(path) is not plugged in."
                return
            }
            port = .device(device)
        case .automatic:
            refreshPorts()
            guard ports.count == 1 else {
                message = ports.isEmpty
                    ? "No machine found. Check the USB cable and that the mill is on."
                    : "More than one mill is plugged in. Choose the port."
                return
            }
            port = .device(ports[0])
        }
        if (ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] != nil || ProcessInfo.processInfo.environment["COASTLINE_DEV"] == "1"), !port.isSimulated {
            message = "UI development and scripted runs use Digital Machine only."
            return
        }
        console.removeAll()
        session.clearConsole()
        lastConsoleID = 0
        session.connect(port)
    }

    /// Opens the Simulated Mill for a job simulation, without changing the chosen port. Never
    /// while a machine is connected: a simulation must not drive it.
    func connectSimulator() {
        guard !isOpen else {
            message = isSimulated ? nil : "A machine is connected. Disconnect it to simulate."
            return
        }
        message = nil
        console.removeAll()
        session.clearConsole()
        lastConsoleID = 0
        session.connect(.simulated)
    }

    func disconnect() {
        if case .device(let device)? = snapshot.port { autoSkip.insert(device.path) }  // not again until it is plugged in again
        allowJog = false
        heldJog = nil
        offsetUndo = nil
        session.disconnect()
    }

    /// App quit: stop the machine if it moves, then close the port.
    func shutdown() { session.shutdown() }

    /// Digital homing needs no physical-clearance confirmation.
    func requestHome() {
        if isSimulated { home() } else { showHomeConfirm = true }
    }

    func home() {
        allowJog = false
        report(session.home())
    }

    func jog(_ axis: MillCore.Axis, _ direction: Double) {
        let vector = HeldJog(axis: axis, direction: direction)
        jog(x: vector.x, y: vector.y, z: vector.z)
    }

    /// The pad's physical directions; diagonal axes travel together in one jog.
    func jog(x: Double = 0, y: Double = 0, z: Double = 0) {
        guard allowJog else {
            message = "Unlock jogging first."
            return
        }
        report(session.jog(JogRequest(x: x * jogStep, y: y * jogStep, z: z * jogStep, feed: jogFeed)))
    }

    /// Hold-to-jog: starts when the operator presses a jog button or key.
    func startHold(_ axis: MillCore.Axis, _ direction: Double) {
        let vector = HeldJog(axis: axis, direction: direction)
        startHold(x: vector.x, y: vector.y, z: vector.z)
    }

    func startHold(x: Double = 0, y: Double = 0, z: Double = 0) {
        guard heldJog == nil else { return }
        guard allowJog else {
            message = "Unlock jogging first."
            return
        }
        let refusal = session.startHold(x: x, y: y, z: z, feed: jogFeed)
        report(refusal)
        if refusal == nil {
            heldJog = HeldJog(x: x, y: y, z: z)
            holdStartedAt = Date()
        }
    }

    func isHolding(x: Double = 0, y: Double = 0, z: Double = 0) -> Bool {
        heldJog == HeldJog(x: x, y: y, z: z)
    }

    /// Hold-to-jog: the operator let go (or the window lost the keys). Stops the jog at once.
    func endHold() {
        guard heldJog != nil else { return }
        heldJog = nil
        holdStartedAt = nil
        session.endHold()
    }

    /// Makes the current position these work coordinates (G10 L20) in the active work offset,
    /// and keeps the old offset for Undo. `what` names the change ("Zero X").
    func setWork(_ values: [MillCore.Axis: Double], _ what: String) {
        let wcs = snapshot.activeWCS
        let before = snapshot.offset(wcs: wcs)
        let refusal = session.setWorkPosition(values, wcs: wcs)
        report(refusal)
        if refusal == nil, let before { offsetUndo = OffsetChange(wcs: wcs, before: before, what: what) }
    }

    func zero(_ axes: [MillCore.Axis]) {
        setWork(Dictionary(uniqueKeysWithValues: axes.map { ($0, 0.0) }), "Zero " + axes.map(\.rawValue).joined(separator: " "))
    }

    /// Writes back the offset the last change replaced.
    func undoOffset() {
        guard let change = offsetUndo else { return }
        let refusal = session.setOffset(change.before, wcs: change.wcs)
        report(refusal)
        if refusal == nil { offsetUndo = nil }
    }

    func selectWCS(_ wcs: Int) { report(session.selectWCS(wcs)) }

    func spindleOn() { report(session.spindleOn(rpm: spindleRPM)) }
    func spindleOff() { report(session.spindleOff()) }

    func override(_ command: MillOverride) { session.override(command) }

    /// The lines of a go-to, or why it cannot run.
    func lines(for request: GoToRequest) -> Result<[String], MillRefusal> {
        if let fixed = request.fixedLines { return .success(fixed) }
        guard let envelope = snapshot.envelope else { return .failure(isOpen ? .statusStale : .notConnected) }
        return GoTo.lines(x: request.x, y: request.y, z: request.z, frame: request.frame, workOffset: snapshot.workOffset,
                          envelope: envelope, retractFirst: request.retractFirst)
    }

    /// Runs a confirmed go-to (a checked program, like a test program). Needs jogging unlocked.
    @discardableResult func go(_ request: GoToRequest) -> Bool {
        guard allowJog else {
            message = "Unlock jogging first."
            return false
        }
        switch lines(for: request) {
        case .failure(let refusal):
            report(refusal)
            return false
        case .success(let lines):
            let refusal = session.run(request.title, lines: lines)
            report(refusal)
            return refusal == nil
        }
    }

    /// Saving is available offline; the complete code is checked against the live machine
    /// immediately before running.
    func saveProgram(_ program: SavedTestProgram) {
        guard program.validationMessage == nil else { return }
        programs.save(program)
        savePrograms()
    }

    func removeProgram(_ id: UUID) {
        programs.remove(id: id)
        savePrograms()
    }

    func favoriteProgram(_ id: UUID) {
        programs.toggleFavorite(id: id)
        savePrograms()
    }

    private func savePrograms() {
        guard ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil,
              let data = try? JSONEncoder().encode(programs) else { return }
        UserDefaults.standard.set(data, forKey: "millTestPrograms")
    }

    func check(_ program: SavedTestProgram) -> Result<[String], MillRefusal> {
        if let why = program.validationMessage { return .failure(.blocked(why)) }
        guard let envelope = snapshot.envelope else {
            return .failure(snapshot.isOpen ? .statusStale : .notConnected)
        }
        switch program.kind {
        case .motionCheck:
            if let why = snapshot.gates.run { return .failure(why) }
            guard let start = snapshot.status?.machinePosition else { return .failure(.statusStale) }
            return ProgramCheck.clean(program.lines, start: start, envelope: envelope)
        case .setup:
            return JobProgramCheck.clean(program.lines, settings: snapshot.settings, envelope: envelope).flatMap { checked in
                if let why = checked.startsWithHome ? snapshot.gates.home : snapshot.gates.run { return .failure(why) }
                return .success(checked.lines)
            }
        }
    }

    @discardableResult func run(_ program: SavedTestProgram) -> Bool {
        if let why = program.validationMessage {
            message = why
            return false
        }
        allowJog = false
        let refusal = program.kind == .motionCheck
            ? session.run(program.title, lines: program.lines)
            : session.runJob(program.title, lines: program.lines)
        report(refusal)
        return refusal == nil
    }

    func run(_ program: TestProgram) { run(SavedTestProgram(program)) }

    /// One program of a guided job (a G-code project). Returns false (and sets `message`) if refused.
    @discardableResult func runJob(_ name: String, lines: [String]) -> Bool {
        allowJog = false
        let refusal = session.runJob(name, lines: lines)
        report(refusal)
        return refusal == nil
    }

    func feedHold() {
        heldJog = nil
        session.feedHold()
    }

    func resume() { report(session.resume()) }

    func stop() {
        allowJog = false
        heldJog = nil
        session.stop()
    }

    func softReset() {
        allowJog = false
        heldJog = nil
        session.softReset()
    }

    /// Sends a console line. Returns false (and sets `message`) if it was refused.
    @discardableResult func send(_ line: String) -> Bool {
        let refusal = session.send(console: line)
        report(refusal)
        return refusal == nil
    }

    func clearConsole() {
        console.removeAll()
        session.clearConsole()
    }

    private func report(_ refusal: MillRefusal?) {
        message = refusal?.text
    }

    private func pull() {
        let next = session.snapshot
        if next.revision != snapshot.revision {
            let doubt = !next.homed || next.restarts != snapshot.restarts || next.silentSince != nil
                || next.link != .connected || (next.lastAlarm != nil && next.lastAlarm != snapshot.lastAlarm)
            if doubt { allowJog = false }
            if heldJog != nil, !next.holding,
               snapshot.holding || next.lastError != snapshot.lastError {
                endHold()
            }
            if next.link == .disconnected, snapshot.link != .disconnected { refreshPorts() }
            snapshot = next
            if isPortOpen != next.isOpen { isPortOpen = next.isOpen }
            if canHome != (next.gates.home == nil) { canHome = next.gates.home == nil }
            if canResume != (next.gates.resume == nil) { canResume = next.gates.resume == nil }
            if canRun != (next.gates.run == nil) { canRun = next.gates.run == nil }
        }
        // A hold lasts while it is renewed: if this timer stops (the app hangs), the session
        // cancels the jog by itself.
        if heldJog != nil {
            if !next.holding, let started = holdStartedAt, Date().timeIntervalSince(started) > 0.5 {
                // A hold can be refused at a boundary before an active snapshot is published.
                endHold()
            } else if allowJog, isOpen {
                session.renewHold()
            } else {
                endHold()
            }
        }
        autoConnectIfPluggedIn()
        let lines = session.console(after: lastConsoleID)
        if let last = lines.last {
            lastConsoleID = last.id
            console.append(contentsOf: lines)
            if console.count > 1000 { console.removeFirst(console.count - 1000) }
        }
    }

    /// Once a second while not connected: a machine plugged in (on the chosen port, or the only
    /// one with Automatic) is connected. Never in scripts, never to the Simulated Mill.
    private func autoConnectIfPluggedIn() {
        let now = Date()
        guard now.timeIntervalSince(lastScan) >= 1, ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil,
              ProcessInfo.processInfo.environment["COASTLINE_DEV"] != "1" else { return }
        lastScan = now
        guard !isOpen else { return }
        let found = MillSession.availablePorts()
        if found != ports { ports = found }
        autoSkip.formIntersection(found.map(\.path))  // unplugged: may connect again when it is back
        guard autoConnect else { return }
        let device: MillDevice? = switch portChoice {
        case .automatic: found.count == 1 ? found[0] : nil
        case .device(let path): found.first { $0.path == path }
        case .simulated: nil
        }
        guard let device, !autoSkip.contains(device.path) else { return }
        autoSkip.insert(device.path)  // once per plug-in: a failed connect is not tried again and again
        connect()
    }

    private func saveChoice() {
        guard ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil else { return }
        let value = switch portChoice {
        case .automatic: "auto"
        case .simulated: "sim"
        case .device(let path): path
        }
        UserDefaults.standard.set(value, forKey: "millPort")
    }
}

struct HeldJog: Equatable {
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0

    init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(axis: MillCore.Axis, direction: Double) {
        x = axis == .x ? direction : 0
        y = axis == .y ? direction : 0
        z = axis == .z ? direction : 0
    }
}

/// A work-offset change that Undo writes back.
struct OffsetChange: Equatable {
    var wcs: Int
    var before: Point3
    /// "Zero X", "Set Z".
    var what: String
}

/// A go-to for the confirmation sheet: a target the operator can edit, or fixed moves.
struct GoToRequest: Identifiable {
    let id = UUID()
    var title: String
    var x: Double?
    var y: Double?
    var z: Double?
    var frame = GoTo.Frame.work
    var retractFirst = true
    /// Fixed moves instead of a target (the machine's tool-change moves).
    var fixedLines: [String]?
}

extension Automation {
    /// Scripted checks with the Simulated Mill (`MillControl.connect` refuses real ports in scripts):
    /// `mill sim`, `mill home`, `mill allowjog`, `mill jog y -10`, `mill send $#`, `mill hold`,
    /// `mill run korobeiniki`, `mill resume`, `mill stop`, `mill disconnect`; hold-to-jog with
    /// `mill press y -1` … `wait 1` … `mill release`; `mill zero xy`, `mill wcs 55`,
    /// `mill undo`, `mill spindle 5000` / `mill spindle off`, `mill ov feed+10`, `mill goto 0 0`.
    static func millCommand(_ mill: MillControl, _ arg: String) {
        let words = arg.split(separator: " ").map(String.init)
        switch words.first {
        case "sim":
            mill.portChoice = .simulated
            mill.connect()
        case "home": mill.home()
        case "allowjog": mill.allowJog = true
        case "jog":
            if words.count == 3, let axis = MillCore.Axis(rawValue: words[1].uppercased()), let mm = Double(words[2]) {
                mill.jogStep = abs(mm)
                mill.jog(axis, mm < 0 ? -1 : 1)
            }
        case "send": mill.send(words.dropFirst().joined(separator: " "))
        case "run": if words.count == 2, let program = TestProgram(rawValue: words[1]) { mill.run(program) }
        case "press":
            if words.count == 3, let axis = MillCore.Axis(rawValue: words[1].uppercased()), let d = Double(words[2]) {
                mill.startHold(axis, d < 0 ? -1 : 1)
            }
        case "release": mill.endHold()
        case "zero": mill.zero(MillCore.Axis.allCases.filter { (words.dropFirst().first ?? "").uppercased().contains($0.rawValue) })
        case "wcs": if words.count == 2, let wcs = Int(words[1]) { mill.selectWCS(wcs) }
        case "undo": mill.undoOffset()
        case "spindle":
            if words.count == 2, let rpm = Double(words[1]) {
                mill.spindleRPM = rpm
                mill.spindleOn()
            } else {
                mill.spindleOff()
            }
        case "ov":
            let names: [String: MillOverride] = ["feed+10": .feedPlus10, "feed-10": .feedMinus10, "feed100": .feedReset,
                                                 "rapid25": .rapid25, "rapid50": .rapid50, "rapid100": .rapid100,
                                                 "spindle+10": .spindlePlus10, "spindle-10": .spindleMinus10, "spindle100": .spindleReset]
            if words.count == 2, let o = names[words[1]] { mill.override(o) }
        case "goto":  // "goto x y [z]": work coordinates, spindle out first
            let v = words.dropFirst().map(Double.init)
            mill.go(GoToRequest(title: "Go to", x: v.first ?? nil, y: v.dropFirst().first ?? nil, z: v.dropFirst(2).first ?? nil))
        case "hold": mill.feedHold()
        case "resume": mill.resume()
        case "stop": mill.stop()
        case "disconnect": mill.disconnect()
        default: break
        }
        let s = mill.snapshot
        print("mill \(arg): \(mill.stateWord) homed=\(s.homed) pos=\(s.status.map { "\($0.machinePosition)" } ?? "-") work=\(s.workPosition.map { "\($0)" } ?? "-") G\(s.activeWCS) spindle=\(s.spindle.map { "\($0.mode) S\(Int($0.rpm))" } ?? "-") ov=\(s.overrides.feed)/\(s.overrides.rapid)/\(s.overrides.spindle) holding=\(s.holding) message=\(mill.message ?? "-") error=\(s.lastError ?? "-")")
    }
}
