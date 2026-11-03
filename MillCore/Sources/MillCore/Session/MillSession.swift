import Foundation

/// A live connection to a machine, for Coastline's Control page.
///
/// One I/O thread owns the port: it is the only reader, sends one line at a time, waits for its
/// `ok`, and polls `?` every 250 ms. Feed hold, resume, jog cancel and soft reset do not go
/// through it: they are written on their own queue, so they are never refused or delayed while
/// the port is open. Motion (home, jog, console moves) starts only from a request, and only if
/// the gates allow it both when it is asked for and again just before the line is sent.
///
/// Rules from the real machine (grbl 1.1g XY:3A): opening the port restarts the board (banner after
/// about 2 s), it boots in Alarm and must be homed; `$H` runs 3–8 s with no status at all; an
/// E-stop makes the controller completely silent.
public final class MillSession: @unchecked Sendable {
    public static let pollInterval: TimeInterval = 0.25
    /// No bytes for this long (outside homing) means the E-stop is pressed or the power is off.
    public static let silenceLimit: TimeInterval = 2.0
    /// A status report older than this cannot be used to start motion.
    public static let freshStatus: TimeInterval = 0.5
    /// `$H` gets this long before the session gives up and resets the controller.
    public static let homingLimit: TimeInterval = 60
    public static let jogFeeds: [Double] = [100, 300, 1000, 2000]
    public static let jogSteps: [Double] = [0.01, 0.1, 1, 10]
    /// Hold-to-jog: each `$J` is this many seconds of motion, and about two of them stay
    /// planned ahead of the machine, so it runs smoothly and stops within one when let go.
    public static let holdSegment: TimeInterval = 0.25
    /// Hold-to-jog stops (0x85) when the app has not renewed the hold for this long: a hung
    /// app or a lost key-up cannot leave the machine jogging.
    public static let holdTimeout: TimeInterval = 0.4

    /// Plugged-in mills (USB IDs 2341:0043 and 1A86:7523).
    public static func availablePorts() -> [MillDevice] { PortFinder.availableMills() }

    // Shared with other threads.
    private let published = Locked(MillSnapshot())
    private let inbox = Locked([Request]())
    private let consoleStore = Locked(Console())
    private let link = Locked<Link?>(nil)
    private let holdControl = Locked(HoldControl())
    private let overrideState = Locked(MillOverrides())
    private let wake = DispatchSemaphore(value: 0)
    private let realtimeQueue = DispatchQueue(label: "coastline.mill.realtime", qos: .userInteractive)

    public init() {}

    // MARK: Public API

    public var snapshot: MillSnapshot { published.current }

    /// Console lines with an id greater than `id`.
    public func console(after id: Int) -> [MillConsoleLine] {
        consoleStore.withLock { c in c.lines.filter { $0.id > id } }
    }

    public func clearConsole() { consoleStore.withLock { $0.lines.removeAll() } }

    /// Opens the port and starts the I/O thread. Opening restarts the controller.
    public func connect(_ port: MillPort) {
        switch port {
        case .device(let device): connect(port, transport: POSIXSerialPort(path: device.path))
        case .simulated:
            var options = MockGRBL.Options()
            options.startLocked = true
            options.softLimitTravel = Point3(x: 86.5, y: 241.5, z: 78.5)
            options.probeFaces = true
            options.timedJogs = true
            connect(port, transport: MockGRBL(options: options))
        }
    }

    func connect(_ port: MillPort, transport: SerialTransport) {
        guard link.current == nil else { return }
        let session = Link(port: port, transport: transport)
        link.current = session
        inbox.current = []
        published.withLock { s in
            let revision = s.revision
            s = MillSnapshot()
            s.revision = revision + 1
            s.link = .connecting
            s.port = port
        }
        note("Connecting to \(port.label). The controller restarts when the port opens.")
        let thread = Thread { [weak self] in self?.run(session) }
        thread.name = "coastline.mill.io"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stops motion first if the machine moves, then closes the port.
    public func disconnect() {
        _ = dropHold()
        guard let session = link.current else { return }
        let close: @Sendable () -> Void = { [wake] in
            session.stopRequested.current = true
            wake.signal()
        }
        if snapshot.isMoving {
            stop()
            // The stop bytes go out on this queue first; close after the stop has had time to act.
            realtimeQueue.asyncAfter(deadline: .now() + 1.5, execute: close)
        } else {
            close()
        }
    }

    /// For app quit: stops any motion before returning (there is no time for the delayed close),
    /// then closes the port.
    public func shutdown() {
        _ = dropHold()
        guard let session = link.current else { return }
        if snapshot.isMoving {
            stop()
            realtimeQueue.sync {}  // the stop bytes are written
            usleep(400_000)
            if snapshot.isMoving {
                softReset()
                realtimeQueue.sync {}
            }
        }
        session.stopRequested.current = true
        wake.signal()
    }

    /// Sends `$H`. The operator must have confirmed that the machine is clear.
    @discardableResult public func home() -> MillRefusal? {
        if let refusal = snapshot.gates.home { return refusal }
        post(.home)
        return nil
    }

    /// A relative jog, shortened to stay inside the envelope.
    @discardableResult public func jog(_ request: JogRequest) -> MillRefusal? {
        if let refusal = snapshot.gates.jog { return refusal }
        post(.jog(request))
        return nil
    }

    /// Runs a program after checking it (see `ProgramCheck`) from the current machine position.
    /// The operator must have confirmed that the machine is clear.
    @discardableResult public func run(_ name: String, lines: [String]) -> MillRefusal? {
        let s = snapshot
        if let refusal = s.gates.run { return refusal }
        guard let start = s.status?.machinePosition, let envelope = s.envelope else { return .statusStale }
        switch ProgramCheck.clean(lines, start: start, envelope: envelope) {
        case .failure(let refusal): return refusal
        case .success(let cleaned):
            post(.program(name, cleaned, homesFirst: false))
            return nil
        }
    }

    /// Runs one program of a guided job (see `JobProgramCheck`): arcs, probing, work offsets,
    /// the spindle, `$H`, M100 and M101 are allowed. A program that starts with `$H` may start from
    /// Alarm; any other needs a homed, idle machine. The operator must have confirmed the step.
    @discardableResult public func runJob(_ name: String, lines: [String]) -> MillRefusal? {
        let s = snapshot
        guard let envelope = s.envelope else { return s.isOpen ? .statusStale : .notConnected }
        switch JobProgramCheck.clean(lines, settings: s.settings, envelope: envelope) {
        case .failure(let refusal): return refusal
        case .success(let program):
            if let refusal = program.startsWithHome ? s.gates.home : s.gates.run { return refusal }
            post(.program(name, program.lines, homesFirst: program.startsWithHome))
            return nil
        }
    }

    /// A line typed in the console. Settings changes and resets are blocked; moves need homing.
    @discardableResult public func send(console text: String) -> MillRefusal? {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        switch line {
        case "?": return realtime(UInt8(ascii: "?"), "?") ? nil : .notConnected
        case "!": feedHold(); return nil
        case "~": return resume()
        default: break
        }
        if let refusal = snapshot.gates.console { return refusal }
        let upper = line.uppercased().replacingOccurrences(of: " ", with: "")
        if upper == "$H" { return home() }
        if let why = Self.blockedConsoleReason(upper) { return .blocked(why) }
        if Self.isMotion(upper) {
            if let refusal = snapshot.gates.jog { return refusal }
        }
        post(.console(line))
        return nil
    }

    /// `!`: always sent while the port is open.
    public func feedHold() {
        _ = dropHold()
        _ = realtime(UInt8(ascii: "!"), "! feed hold")
    }

    /// `~`, only from Hold or Door.
    @discardableResult public func resume() -> MillRefusal? {
        if let refusal = snapshot.gates.resume { return refusal }
        _ = realtime(UInt8(ascii: "~"), "~ resume")
        return nil
    }

    /// 0x85: always sent while the port is open.
    public func jogCancel() {
        _ = dropHold()
        _ = realtime(0x85, "0x85 jog cancel")
    }

    /// 0x18: always sent while the port is open. The controller restarts; home again after it.
    public func softReset() {
        _ = dropHold()
        if realtime(0x18, "0x18 soft reset") { post(.resetSent) }
    }

    /// Stops whatever moves, the gentlest way that is safe:
    /// a jog is cancelled (0x85) and keeps the position; a program is held (`!`) before the reset
    /// so the position is not lost; homing and everything else get a soft reset at once.
    public func stop() {
        _ = dropHold()
        let s = snapshot
        let state = s.status?.state ?? ""
        if s.homingSince != nil || state == "Home" {
            softReset()
        } else if state == "Jog" {
            jogCancel()
            realtimeQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.snapshot.isMoving else { return }
                self.softReset()
            }
        } else if state == "Run" || state.hasPrefix("Hold:1") {
            feedHold()
            realtimeQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.softReset() }
        } else {
            softReset()
        }
    }

    // MARK: Hold to jog

    /// Starts a hold-to-jog: the axis moves toward `direction` (its sign) at `feed` until
    /// `endHold`, the end of the travel, or `holdTimeout` without `renewHold`. Same gates as a jog.
    @discardableResult public func startHold(_ axis: Axis, direction: Double, feed: Double) -> MillRefusal? {
        // In Jog (the last jog still stopping) the hold waits for Idle.
        if let refusal = snapshot.gates.jog, refusal != .wrongState("Jog") { return refusal }
        holdControl.withLock { h in
            h.generation += 1
            h.request = JogRequest(axis: axis, distance: direction < 0 ? -1 : 1, feed: feed)
            h.renewed = monotonicNow()
        }
        wake.signal()
        return nil
    }

    /// Keeps a hold going: call it at least every 0.1 s while the operator holds.
    public func renewHold() {
        holdControl.withLock { h in if h.request != nil { h.renewed = monotonicNow() } }
    }

    /// The operator let go: the jog is cancelled at once.
    public func endHold() {
        if dropHold() { _ = realtime(0x85, "0x85 jog cancel") }
    }

    /// Ends the hold for the I/O thread, which then sends its own jog cancel after its last
    /// `$J`. True if a hold was active.
    private func dropHold() -> Bool {
        let was = holdControl.withLock { h -> Bool in
            defer { h.request = nil }
            return h.request != nil
        }
        if was { wake.signal() }
        return was
    }

    // MARK: Work offsets, the spindle and overrides

    /// `G10 L20`: the current position becomes these work coordinates in `wcs` (54…59).
    @discardableResult public func setWorkPosition(_ values: [Axis: Double], wcs: Int) -> MillRefusal? {
        guard (54...59).contains(wcs), !values.isEmpty, values.values.allSatisfy(\.isFinite) else {
            return .blocked("Choose G54 to G59 and at least one axis.")
        }
        let words = Axis.allCases.compactMap { axis in values[axis].map { String(format: "%@%.3f", axis.rawValue, $0) } }
        return setup("G10L20P\(wcs - 53)" + words.joined())
    }

    /// `G10 L2`: writes the offset of `wcs` itself (to undo a change).
    @discardableResult public func setOffset(_ point: Point3, wcs: Int) -> MillRefusal? {
        guard (54...59).contains(wcs) else { return .blocked("Choose G54 to G59.") }
        return setup(String(format: "G10L2P%dX%.3fY%.3fZ%.3f", wcs - 53, point.x, point.y, point.z))
    }

    /// `G54`…`G59`: the work offset that moves, programs and the position display use.
    @discardableResult public func selectWCS(_ wcs: Int) -> MillRefusal? {
        guard (54...59).contains(wcs) else { return .blocked("Choose G54 to G59.") }
        return setup("G\(wcs)")
    }

    /// `M3 S…`: the spindle on, forward, at a speed inside `$31`…`$30`.
    @discardableResult public func spindleOn(rpm: Double) -> MillRefusal? {
        let v = snapshot.settings.values
        let low = v[31] ?? 0, high = v[30] ?? 0
        guard high > 0, rpm.isFinite, rpm >= low, rpm <= high else {
            return .blocked(String(format: "Choose a speed from %.0f to %.0f RPM.", low, high))
        }
        return setup(String(format: "M3S%.0f", rpm))
    }

    /// `M5`: allowed whenever a console line is.
    @discardableResult public func spindleOff() -> MillRefusal? {
        if let refusal = snapshot.gates.console { return refusal }
        post(.console("M5"))
        return nil
    }

    private func setup(_ line: String) -> MillRefusal? {
        if let refusal = snapshot.gates.setup { return refusal }
        post(.setup(line))
        return nil
    }

    /// A feed, rapid or spindle override (a real-time byte): always sent while the port is open.
    public func override(_ command: MillOverride) {
        guard realtime(command.byte, String(format: "0x%02X %@", command.byte, command.label)) else { return }
        overrideState.withLock { $0 = command.applied(to: $0) }
    }

    // MARK: Console rules

    /// Console lines Coastline does not send: they change settings, startup lines or offsets in bulk.
    static func blockedConsoleReason(_ upper: String) -> String? {
        if upper.hasPrefix("$RST") { return "Restoring defaults or clearing offsets is blocked in Coastline." }
        if upper.hasPrefix("$N") && upper.contains("=") { return "Changing the startup lines is blocked in Coastline." }
        if upper.range(of: #"^\$\d+="#, options: .regularExpression) != nil {
            return "Changing controller settings is blocked in Coastline."
        }
        if upper.hasPrefix("$I=") { return "Changing the build info is blocked in Coastline." }
        if upper.hasPrefix("$L") { return "Use Auto-Level on the Control page." }
        if upper.hasPrefix("$H") { return "Home all axes with $H or the Home button." }
        return nil
    }

    /// Lines that can move an axis: jogs and G-code with axis words or a motion code.
    static func isMotion(_ upper: String) -> Bool {
        if upper.hasPrefix("$J=") { return true }
        if upper.hasPrefix("$") { return false }
        let code = upper.replacingOccurrences(of: #"\(.*?\)|;.*"#, with: "", options: .regularExpression)
        return code.range(of: #"[XYZ][-+.0-9]|G0*(0|1|2|3|28|30|38\.\d)(?![0-9.])"#, options: .regularExpression) != nil
    }

    // MARK: Requests and the real-time path

    private enum Request: Sendable {
        case home
        case jog(JogRequest)
        case console(String)
        /// Work offsets, the active work offset, the spindle on.
        case setup(String)
        case program(String, [String], homesFirst: Bool)
        case resetSent
    }

    private final class Link: @unchecked Sendable {
        let port: MillPort
        let transport: SerialTransport
        let stopRequested = Locked(false)

        init(port: MillPort, transport: SerialTransport) {
            self.port = port
            self.transport = transport
        }
    }

    private struct Console {
        var lines: [MillConsoleLine] = []
        var nextID = 1

        mutating func add(_ kind: MillConsoleLine.Kind, _ text: String) {
            lines.append(MillConsoleLine(id: nextID, time: Date(), kind: kind, text: text))
            nextID += 1
            if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
        }
    }

    private func post(_ request: Request) {
        inbox.withLock { $0.append(request) }
        wake.signal()
    }

    /// Writes one real-time byte on its own queue. Returns false if no port is open.
    private func realtime(_ byte: UInt8, _ label: String) -> Bool {
        guard let session = link.current, session.transport.isOpen else { return false }
        if byte != UInt8(ascii: "?") { log(.realtime, label) }
        realtimeQueue.async {
            do { try session.transport.write([byte]) } catch { self.log(.error, "Could not send \(label): \(error)") }
        }
        return true
    }

    private func log(_ kind: MillConsoleLine.Kind, _ text: String) {
        consoleStore.withLock { $0.add(kind, text) }
    }

    private func note(_ text: String) { log(.note, text) }

    // MARK: I/O thread

    private enum Phase { case waitingForBanner, bootMessages, probing, ready }

    private enum PendingKind { case query, home, jog, holdJog, console, setup, program, macro }

    /// The operator's hold-to-jog, shared with the I/O thread. No request: not holding.
    private struct HoldControl {
        var request: JogRequest?
        var generation = 0
        var renewed: TimeInterval = 0
    }

    /// A hold-to-jog on the I/O thread.
    private struct IOHold {
        var generation: Int
        var request: JogRequest
        /// Where the jogs sent so far end (machine coordinates); nil before the first.
        var target: Double?
    }

    private struct ProgramRun {
        var lines: [String]
        var next = 0
        /// An M100 in progress: its call, the step reached, and the midpoint it wrote.
        var macro: M100.Call?
        var macroStep = 0
        var midpoint = 0.0
        /// An M101 in progress: G4 P0, then `$#` and the check.
        var check: M101.Call?
        /// The line sent last was `$H`: wait for the home check before going on.
        var homing = false
    }

    private struct Pending {
        var line: String
        var kind: PendingKind
        var deadline: TimeInterval
        var replies: [String] = []
    }

    /// State owned by the I/O thread only.
    private struct IOState {
        var s = MillSnapshot()
        var phase = Phase.waitingForBanner
        var phaseDeadline: TimeInterval = 0
        var partial: [UInt8] = []
        var lastRx: TimeInterval = 0
        var lastPoll: TimeInterval = 0
        var pollPausedUntil: TimeInterval = 0
        var statusMono: TimeInterval = 0
        var pending: Pending?
        var queue: [(String, PendingKind)] = []
        var homingStarted: TimeInterval?
        var checkHomeOnNextStatus = false
        var program: ProgramRun?
        var lastPortCheck: TimeInterval = 0
        var hold: IOHold?
        var lastHoldGeneration = 0
    }

    private func run(_ session: Link) {
        var io = IOState()
        io.s = published.current
        do {
            try session.transport.open()
        } catch {
            log(.error, "Could not open \(session.port.label): \(error)")
            finish(session, &io, lastError: "Could not open \(session.port.label). Is another program using it?")
            return
        }
        let start = monotonicNow()
        io.lastRx = start
        io.phaseDeadline = start + 4.0

        while !session.stopRequested.current {
            let now = monotonicNow()
            for request in inbox.withLock({ r -> [Request] in defer { r.removeAll() }; return r }) {
                handle(request, &io, session, now)
            }
            if !session.transport.isOpen {
                log(.error, "The port closed.")
                finish(session, &io, lastError: "The connection to the machine was lost.")
                return
            }
            let bytes = session.transport.readAvailable()
            if !bytes.isEmpty {
                io.lastRx = now
                if io.s.silentSince != nil {
                    io.s.silentSince = nil
                    note("The machine answers again.")
                }
                for line in split(bytes, &io.partial) { handle(line: line, &io, session, now) }
            }
            tick(&io, session, now)
            if case .device(let device) = session.port, now - io.lastPortCheck > 1 {
                io.lastPortCheck = now
                if !PortFinder.availableMills().contains(where: { $0.path == device.path }) {
                    finish(session, &io, lastError: "The machine was unplugged.")
                    return
                }
            }
            publish(&io, now)
            // While a program streams, answer each `ok` at once: short segments need ~50 lines/s.
            _ = wake.wait(timeout: .now() + .milliseconds(io.program != nil ? 1 : 10))
        }
        finish(session, &io, lastError: nil)
    }

    private func finish(_ session: Link, _ io: inout IOState, lastError: String?) {
        session.transport.close()
        if link.current === session { link.current = nil }
        holdControl.withLock { $0.request = nil }
        var s = io.s
        s.link = .disconnected
        s.holding = false
        s.homed = false
        s.homingSince = nil
        s.silentSince = nil
        s.gates = MillGates()
        if s.program?.outcome == .running {
            s.program?.outcome = .stopped
            s.program?.finishedAt = Date()
        }
        if let lastError { s.lastError = lastError }
        s.revision = published.current.revision + 1
        published.current = s
        note(lastError ?? "Disconnected.")
    }

    private func split(_ bytes: [UInt8], _ partial: inout [UInt8]) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                let text = String(decoding: partial, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
                partial.removeAll()
            } else if byte != UInt8(ascii: "\r") {
                partial.append(byte)
            }
        }
        return lines
    }

    private func write(_ text: String, _ session: Link) {
        do { try session.transport.write(Array((text + "\n").utf8)) } catch { log(.error, "Could not send \(text): \(error)") }
    }

    private func handle(_ request: Request, _ io: inout IOState, _ session: Link, _ now: TimeInterval) {
        switch request {
        case .home: io.queue.append(("$H", .home))
        case .jog(let jog):
            // The target is worked out just before the line is sent, from a fresh status.
            io.queue.append((Self.encode(jog), .jog))
        case .console(let line): io.queue.append((line, .console))
        case .setup(let line): io.queue.append((line, .setup))
        case .program(let name, let lines, let homesFirst):
            io.s.gates = gates(io, now)
            if let refusal = homesFirst ? io.s.gates.home : io.s.gates.run {
                refuse(name, refusal)
                return
            }
            io.program = ProgramRun(lines: lines)
            io.s.program = MillProgramStatus(name: name, total: lines.count)
            io.s.lastError = nil
            note("Running \(name): \(lines.count) lines.")
        case .resetSent:
            endProgram(&io, .stopped)
            clearHoldIO(&io)
            overrideState.current = MillOverrides()
            io.s.homed = false
            io.s.homingSince = nil
            io.homingStarted = nil
            io.pending = nil
            io.queue.removeAll()
            io.pollPausedUntil = now + 0.25
            io.lastRx = now
        }
    }

    // A queued jog keeps its request until send time: "JOG <axis> <distance> <feed>".
    private static func encode(_ jog: JogRequest) -> String { "JOG \(jog.axis.rawValue) \(jog.distance) \(jog.feed)" }

    private func handle(line: String, _ io: inout IOState, _ session: Link, _ now: TimeInterval) {
        let isStatus = line.hasPrefix("<") && line.hasSuffix(">")
        if !isStatus { log(.received, line) }

        if line.range(of: #"^Grbl \d+\.\d+"#, options: .regularExpression) != nil {
            io.s.banner = line
            if io.phase != .ready {
                io.phase = .bootMessages
            } else {
                // A banner after connect: the controller restarted (soft reset, E-stop release, brown-out).
                io.s.restarts += 1
                io.s.homed = false
                io.s.homingSince = nil
                io.homingStarted = nil
                io.s.needsReset = false
                io.s.locked = false
                if let pending = io.pending { note("\(pending.line) was cancelled by the restart.") }
                endProgram(&io, .stopped)
                clearHoldIO(&io)
                overrideState.current = MillOverrides()
                io.pending = nil
                io.queue.removeAll()
                for q in ["$$", "$I", "$#", "$G"] { io.queue.append((q, .query)) }
                note("The controller restarted. Home the machine again.")
            }
            return
        }
        if GRBLProtocol.isLockMessage(line) {
            io.s.locked = true
            return
        }
        if line.hasPrefix("[MSG:Reset") {
            io.s.needsReset = true
            return
        }
        if isStatus {
            handleStatus(line, &io, session, now)
            return
        }
        if line.hasPrefix("ALARM:") {
            let code = Int(line.dropFirst(6)) ?? -1
            io.s.lastAlarm = "ALARM:\(code) — \(MillingError.alarmCodes[code] ?? "Unknown alarm.")"
            io.s.needsReset = true
            io.s.homed = false
            io.s.homingSince = nil
            io.homingStarted = nil
            io.pending = nil
            io.queue.removeAll { $0.1 != .query }
            clearHoldIO(&io)
            log(.error, io.s.lastAlarm!)
            endProgram(&io, .failed(io.s.lastAlarm!))
            return
        }
        if line.hasPrefix("error:") {
            let code = Int(line.dropFirst(6)) ?? -1
            let text = MillingError.errorCodes[code].map { "\($0.0): \($0.1)" } ?? "Unknown error."
            let source = io.pending?.line ?? "a command"
            io.s.lastError = "\(source) — error:\(code) \(text)"
            log(.error, io.s.lastError!)
            if io.pending?.kind == .home { io.s.homingSince = nil; io.homingStarted = nil }
            if io.pending?.kind == .holdJog { endHoldIO(&io, session, nil) }
            if io.pending?.kind == .program || io.pending?.kind == .macro {
                // Stop sending and hold what is already in the planner; Stop clears it, Resume runs it out.
                write("!", session, realtime: true)
                log(.realtime, "! feed hold after the error")
                endProgram(&io, .failed(io.s.lastError!))
            }
            io.pending = nil
            return
        }
        // Only the reply to a probe move: `$#` also lists the last probe (`[PRB:…:0]` before any).
        if line.hasPrefix("[PRB:"), line.hasSuffix(":0]"), io.program != nil, io.pending?.kind == .program,
           io.pending?.line.contains("G38") == true {
            // G38.3 ends without an alarm when nothing was touched; the next line would set the
            // work offset at the end of the probe move. Stop here, and stop the spindle.
            let why = "The probe did not touch the part. Check the probe cable (the green LED must be off), the chips, and that the part conducts."
            io.s.lastError = why
            log(.error, why)
            endProgram(&io, .failed(why))
            io.pending = nil
            io.queue.append(("M5", .console))
            return
        }
        if line == "ok" || ["0k", "1k", "2k", "3k"].contains(line) || GRBLProtocol.isHexOK(line) {
            guard let pending = io.pending else { return }
            io.pending = nil
            complete(pending, &io, session, now)
            return
        }
        io.pending?.replies.append(line)
    }

    private func handleStatus(_ line: String, _ io: inout IOState, _ session: Link, _ now: TimeInterval) {
        let unit = io.s.settings.reportUnit
        guard let status = (try? RealTimeStatus.parse(line, wcs: io.s.activeWCS, reportUnit: unit, parserUnits: 21, distanceMode: 90))
            ?? (try? RealTimeStatus.parseV0(line, wcs: io.s.activeWCS, reportUnit: unit, parserUnits: 21, distanceMode: 90))
        else {
            log(.received, line)
            return
        }
        io.s.status = status
        io.s.statusTime = Date()
        io.statusMono = now
        if let offset = status.workOffset { io.s.workOffset = offset }
        if let overrides = status.overrides { overrideState.current = overrides }
        if io.phase == .probing {
            startQueries(&io)
        } else if io.s.settings.isEmpty, io.pending == nil, io.queue.isEmpty {
            for q in ["$$", "$I", "$#", "$G"] { io.queue.append((q, .query)) }
        }
        if io.checkHomeOnNextStatus {
            // The first report after `ok` decides: Idle at the home position, or no homing.
            io.checkHomeOnNextStatus = false
            if status.state == "Idle", let target = io.s.homeTarget,
               Axis.allCases.allSatisfy({ abs(status.machinePosition[$0] - target[$0]) <= 0.1 }) {
                io.s.homed = true
                io.s.locked = false
                note(String(format: "Homed in %.1f s.", now - (io.homingStarted ?? now)))
            } else {
                io.s.lastError = "Homing ended in \(status.state) at \(Self.format(status.machinePosition)), not Idle at the home position \(io.s.homeTarget.map(Self.format) ?? "?"). Jog stays off."
                log(.error, io.s.lastError!)
            }
            io.homingStarted = nil
        }
    }

    private func complete(_ pending: Pending, _ io: inout IOState, _ session: Link, _ now: TimeInterval) {
        switch pending.kind {
        case .query: parseQuery(pending, &io)
        case .home:
            io.s.homingSince = nil
            io.checkHomeOnNextStatus = true
            io.lastPoll = 0  // ask for a status now
            if io.program != nil { io.s.program?.done += 1 }
        case .program:
            io.s.program?.done += 1
            if pending.line == "$#" {
                io.s.offsets = pending.replies.compactMap(Self.parseOffset)
                updateWorkOffset(&io)
            }
        case .macro: macroStep(pending, &io, session, now)
        case .console, .setup: refresh(after: pending.line, &io)
        case .jog, .holdJog: break
        }
    }

    private func parseQuery(_ pending: Pending, _ io: inout IOState) {
        switch pending.line {
        case "$$":
            var settings = MillSettings()
            for line in pending.replies {
                if let (n, v) = GRBLProtocol.parseSetting(line) { settings.update(n, v) }
            }
            io.s.settings = settings
            io.s.envelope = MillEnvelope.from(settings)
            io.s.homeTarget = Self.homeTarget(settings)
        case "$I":
            io.s.firmware = pending.replies.first { $0.hasPrefix("[") }
        case "$#":
            io.s.offsets = pending.replies.compactMap(Self.parseOffset)
            updateWorkOffset(&io)
        case "$G":
            if let line = pending.replies.first(where: { $0.hasPrefix("[GC:") }) {
                let words = line.dropFirst(4).dropLast().split(separator: " ").map(String.init)
                io.s.parserState = words.joined(separator: " ")
                if let wcs = words.first(where: { $0.range(of: #"^G5[4-9]$"#, options: .regularExpression) != nil }) {
                    io.s.activeWCS = Int(wcs.dropFirst()) ?? 54
                }
                updateWorkOffset(&io)
            }
        default: break
        }
    }

    /// After a line that changes the offsets, the active work offset or the spindle, reads
    /// them back (`$#`, `$G`), so the position display and the Control page are current.
    private func refresh(after line: String, _ io: inout IOState) {
        let code = line.uppercased().replacingOccurrences(of: #"\(.*?\)|;.*|\s"#, with: "", options: .regularExpression)
        guard !code.hasPrefix("$") else { return }
        if code.range(of: #"G10|G92"#, options: .regularExpression) != nil, !io.queue.contains(where: { $0.0 == "$#" }) {
            io.queue.append(("$#", .query))
        }
        if code.range(of: #"G5[4-9](?![0-9.])|M[345](?![0-9])|S[0-9.]"#, options: .regularExpression) != nil,
           !io.queue.contains(where: { $0.0 == "$G" }) {
            io.queue.append(("$G", .query))
        }
    }

    /// The work offset the status reports (`W:`), worked out from `$#` at once: the active
    /// `G54`…`G59` plus `G92`. The machine sends `W:` only in about every tenth report.
    private func updateWorkOffset(_ io: inout IOState) {
        guard let base = io.s.offset(wcs: io.s.activeWCS) else { return }
        io.s.workOffset = base + (io.s.offsets.first { $0.name == "G92" }?.point ?? .zero)
    }

    private func startQueries(_ io: inout IOState) {
        io.phase = .ready
        io.s.link = .connected
        for q in ["$$", "$I", "$#", "$G"] { io.queue.append((q, .query)) }
    }

    private func tick(_ io: inout IOState, _ session: Link, _ now: TimeInterval) {
        switch io.phase {
        case .waitingForBanner:
            if now > io.phaseDeadline {
                // No restart banner (some boards do not reset on open): ask once.
                io.phase = .probing
                io.phaseDeadline = now + 1.0
                write("?", session, realtime: true)
            }
            return
        case .probing:
            if now > io.phaseDeadline {
                io.phase = .ready
                io.s.link = .connected
                io.s.silentSince = Date()
                note("No reply from the machine. The E-stop may be pressed: turn the red knob clockwise.")
            }
            return
        case .bootMessages:
            if now - io.lastRx > 0.3 { startQueries(&io) }
            return
        case .ready:
            break
        }

        // The machine sends nothing while it homes: no polls and no silence check until `ok`.
        let homing = io.pending?.kind == .home
        if let started = io.homingStarted, homing, now - started > Self.homingLimit {
            log(.error, "No reply during homing. The controller was reset.")
            io.s.lastError = "Homing did not finish in \(Int(Self.homingLimit)) s. The controller was reset."
            write("\u{18}", session, realtime: true)
            handle(.resetSent, &io, session, now)
        }
        if !homing, io.s.silentSince == nil, now - io.lastRx > Self.silenceLimit {
            io.s.silentSince = Date()
            io.s.homed = false
            if io.s.status?.state == "Jog" { writeByte(0x85, session) }
            log(.error, "No reply from the machine for 2 s. The E-stop may be pressed: turn the red knob clockwise.")
        }

        let interval = io.s.silentSince != nil ? 1.0 : (io.hold != nil ? 0.1 : Self.pollInterval)
        if !homing, now >= io.pollPausedUntil, now - io.lastPoll >= interval {
            io.lastPoll = now
            write("?", session, realtime: true)
        }

        if let pending = io.pending, now > pending.deadline, pending.kind != .home {
            log(.error, "No reply to \(pending.line).")
            if pending.kind == .program || pending.kind == .macro {
                write("!", session, realtime: true)
                endProgram(&io, .failed("No reply to \(pending.line). Feed hold is on: press Stop."))
            }
            io.pending = nil
        }
        holdTick(&io, session, now)
        if io.pending == nil, !io.queue.isEmpty {
            let (line, kind) = io.queue.removeFirst()
            send(line, kind, &io, session, now)
        } else if io.pending == nil, var program = io.program, !io.checkHomeOnNextStatus {
            if program.homing {
                // `$H` in the program: go on only from the home position.
                guard io.s.homed else {
                    endProgram(&io, .failed(io.s.lastError ?? "Homing did not end at the home position."))
                    return
                }
                program.homing = false
            }
            if program.macro != nil || program.check != nil {
                io.program = program
                return  // the macro's next line goes out when the last one is answered
            }
            if program.next < program.lines.count {
                let line = program.lines[program.next]
                program.next += 1
                if line == "$H" {
                    program.homing = true
                    io.program = program
                    io.homingStarted = now
                    io.s.homingSince = Date()
                    io.s.homed = false
                    log(.sent, line)
                    write(line, session)
                    io.pending = Pending(line: line, kind: .home, deadline: now + Self.homingLimit + 5)
                    return
                }
                if let call = M101.parse(line) {
                    // Coastline's M101: wait for the moves to finish, read the offsets, compare them.
                    program.check = call
                    program.macroStep = 0
                    io.program = program
                    log(.note, String(format: "M101: %@ %@ must agree within %.3f mm.", call.offsets.map { "G\($0)" }.joined(separator: ", "), call.axis.rawValue, call.tolerance))
                    sendMacro("G4P0", &io, session, now)
                    return
                }
                if let call = M100.parse(line) {
                    // Coastline's M100: wait for the moves to finish (G4 P0), read the offsets,
                    // write the midpoint, read them again to check it.
                    program.macro = call
                    program.macroStep = 0
                    io.program = program
                    log(.note, "M100: the midpoint of G\(call.a.wcs) \(call.a.axis.rawValue) and G\(call.b.wcs) \(call.b.axis.rawValue) into G\(call.destination.wcs) \(call.destination.axis.rawValue).")
                    sendMacro("G4P0", &io, session, now)
                    return
                }
                io.program = program
                log(.sent, line)
                write(line, session)
                io.pending = Pending(line: line, kind: .program, deadline: now + 30)
            } else if io.s.status?.state == "Idle", now - io.statusMono < Self.freshStatus {
                endProgram(&io, .completed)
                // The offsets, work offset and spindle the program left, for the operator.
                io.queue += [("$#", .query), ("$G", .query)]
            }
        }
    }

    private func write(_ text: String, _ session: Link, realtime: Bool) {
        do { try session.transport.write(Array(text.utf8)) } catch { log(.error, "Could not send \(text): \(error)") }
    }

    /// One byte as is (`"\u{85}".utf8` would be two bytes).
    private func writeByte(_ byte: UInt8, _ session: Link) {
        do { try session.transport.write([byte]) } catch { log(.error, String(format: "Could not send 0x%02X: %@", byte, "\(error)")) }
    }

    /// Hold-to-jog on the I/O thread: starts, keeps and ends the operator's hold, and keeps
    /// about two short jogs planned ahead of the machine (GRBL runs queued `$J` lines back to
    /// back). Every way out sends a jog cancel from this thread, after its last `$J`.
    private func holdTick(_ io: inout IOState, _ session: Link, _ now: TimeInterval) {
        let shared = holdControl.current
        if let hold = io.hold, shared.request == nil || shared.generation != hold.generation {
            endHoldIO(&io, session, nil)  // let go, or a new hold
        }
        guard let request = shared.request else { return }
        if io.hold == nil {
            guard shared.generation != io.lastHoldGeneration else { return }  // this hold already ended
            io.lastHoldGeneration = shared.generation
            io.hold = IOHold(generation: shared.generation, request: request)
            io.s.holding = true
            io.s.lastError = nil
        }
        guard var hold = io.hold else { return }
        if now - shared.renewed > Self.holdTimeout {
            return endHoldIO(&io, session, "the app stopped confirming the hold.")
        }
        guard io.pending == nil, io.queue.isEmpty else { return }
        io.s.gates = gates(io, now)
        // The jog gate, but Jog is expected: the machine is in Jog once the first `$J` moves.
        // Before the first, Jog is the end of the last jog: wait for Idle.
        if let refusal = io.s.gates.jog {
            guard refusal == .wrongState("Jog") else { return endHoldIO(&io, session, refusal.text) }
            if hold.target == nil { return }
        }
        guard let mpos = io.s.status?.machinePosition, let envelope = io.s.envelope else { return }
        let axis = request.axis, sign = request.distance < 0 ? -1.0 : 1.0
        let index = Axis.allCases.firstIndex(of: axis)!
        let feed = min(request.feed, io.s.settings.values[110 + index] ?? request.feed)
        let segment = max(0.01, feed / 60 * Self.holdSegment)
        let planned = hold.target ?? mpos[axis]
        guard (planned - mpos[axis]) * sign < 2 * segment else { return }  // enough planned ahead
        let range = envelope[axis]
        let next = min(max(planned + sign * segment, range.lowerBound), range.upperBound)
        let delta = ((next - planned) * 1000).rounded() / 1000
        guard abs(delta) >= 0.001 else {
            // At the end of the travel: the machine stops there and waits for the operator to let go.
            if hold.target == nil { endHoldIO(&io, session, MillRefusal.atLimit.text) }
            return
        }
        let current = holdControl.current
        guard current.request != nil, current.generation == hold.generation else { return }
        let text = String(format: "$J=G21 G91 %@%.3f F%.0f", axis.rawValue, delta, feed)
        log(.sent, text)
        write(text, session)
        io.pending = Pending(line: text, kind: .holdJog, deadline: now + 3)
        hold.target = planned + delta
        io.hold = hold
    }

    /// Ends the hold on the I/O thread and cancels what it planned. `why`: it was not let go.
    private func endHoldIO(_ io: inout IOState, _ session: Link, _ why: String?) {
        guard let hold = io.hold else { return }
        io.hold = nil
        io.s.holding = false
        holdControl.withLock { h in if h.generation == hold.generation { h.request = nil } }
        if hold.target != nil {
            writeByte(0x85, session)
            log(.realtime, "0x85 jog cancel (end of the hold)")
        }
        if let why {
            io.s.lastError = "Hold-to-jog stopped: \(why)"
            log(.error, io.s.lastError!)
        }
    }

    /// After a restart, an alarm or a reset the controller has no jog left: only forget the hold.
    private func clearHoldIO(_ io: inout IOState) {
        guard let hold = io.hold else { return }
        io.hold = nil
        io.s.holding = false
        holdControl.withLock { h in if h.generation == hold.generation { h.request = nil } }
    }

    /// Sends a queued line after checking the gates again with the freshest state (fail closed).
    private func send(_ line: String, _ kind: PendingKind, _ io: inout IOState, _ session: Link, _ now: TimeInterval) {
        io.s.gates = gates(io, now)
        var text = line
        switch kind {
        case .query, .program, .macro: break
        case .home:
            if let refusal = io.s.gates.home { refuse("Home", refusal); return }
            io.homingStarted = now
            io.s.homingSince = Date()
            io.s.homed = false
            io.s.lastError = nil
            io.s.lastAlarm = nil
        case .jog:
            if let refusal = io.s.gates.jog { refuse("Jog", refusal); return }
            guard let jog = Self.decode(line), let mpos = io.s.status?.machinePosition, let envelope = io.s.envelope else { return }
            let range = envelope[jog.axis]
            let target = min(max(mpos[jog.axis] + jog.distance, range.lowerBound), range.upperBound)
            let delta = target - mpos[jog.axis]
            guard abs(delta) >= 0.001 else { refuse("Jog", .atLimit); return }
            let index = Axis.allCases.firstIndex(of: jog.axis)!
            let feed = min(jog.feed, io.s.settings.values[110 + index] ?? jog.feed)
            text = String(format: "$J=G21 G91 %@%.3f F%.0f", jog.axis.rawValue, delta, feed)
            io.s.lastError = nil
        case .console:
            let upper = line.uppercased().replacingOccurrences(of: " ", with: "")
            if let refusal = io.s.gates.console { refuse(line, refusal); return }
            if Self.isMotion(upper), let refusal = io.s.gates.jog { refuse(line, refusal); return }
        case .setup:
            if let refusal = io.s.gates.setup { refuse(line, refusal); return }
            io.s.lastError = nil
        case .holdJog: break
        }
        log(.sent, text)
        write(text, session)
        let timeout: TimeInterval = kind == .home ? Self.homingLimit + 5 : (kind == .console ? 30 : 3)
        io.pending = Pending(line: text, kind: kind, deadline: now + timeout)
    }

    private func sendMacro(_ line: String, _ io: inout IOState, _ session: Link, _ now: TimeInterval) {
        log(.sent, line)
        write(line, session)
        io.pending = Pending(line: line, kind: .macro, deadline: now + 60)
    }

    /// One answered line of an M100: G4 P0 → `$#` → G10 L2 → `$#` (check).
    private func macroStep(_ pending: Pending, _ io: inout IOState, _ session: Link, _ now: TimeInterval) {
        if let check = io.program?.check { return checkStep(check, pending, &io, session, now) }
        guard var program = io.program, let call = program.macro else { return }
        func fail(_ why: String) {
            io.s.lastError = "M100: \(why)"
            log(.error, io.s.lastError!)
            endProgram(&io, .failed(io.s.lastError!))
        }
        switch program.macroStep {
        case 0:
            program.macroStep = 1
            io.program = program
            sendMacro("$#", &io, session, now)
        case 1:
            let offsets = pending.replies.compactMap(Self.parseOffset)
            io.s.offsets = offsets
            guard let a = M100.value(offsets, call.a), let b = M100.value(offsets, call.b) else {
                return fail("the controller did not report G\(call.a.wcs) and G\(call.b.wcs).")
            }
            program.midpoint = (a + b) / 2
            program.macroStep = 2
            io.program = program
            sendMacro(String(format: "G10L2P%d%@%.3f", call.destination.wcs - 53, call.destination.axis.rawValue, program.midpoint), &io, session, now)
        case 2:
            program.macroStep = 3
            io.program = program
            sendMacro("$#", &io, session, now)
        default:
            let offsets = pending.replies.compactMap(Self.parseOffset)
            io.s.offsets = offsets
            // `$#` shows 3 decimals: the stored value must round to the midpoint and lie between the two.
            guard let got = M100.value(offsets, call.destination), let a = M100.value(offsets, call.a),
                  let b = M100.value(offsets, call.b) else { return fail("the offsets could not be read back.") }
            guard abs(got - program.midpoint) <= 0.0015, got >= min(a, b) - 0.0015, got <= max(a, b) + 0.0015 else {
                return fail(String(format: "G%d %@ is %.3f, expected %.3f.", call.destination.wcs, call.destination.axis.rawValue, got, program.midpoint))
            }
            note(String(format: "M100: G%d %@ = %.3f (between %.3f and %.3f).", call.destination.wcs, call.destination.axis.rawValue, got, a, b))
            program.macro = nil
            io.program = program
            io.s.program?.done += 1
        }
    }

    /// One answered line of an M101: G4 P0 → `$#` → compare.
    private func checkStep(_ call: M101.Call, _ pending: Pending, _ io: inout IOState, _ session: Link, _ now: TimeInterval) {
        guard var program = io.program else { return }
        if program.macroStep == 0 {
            program.macroStep = 1
            io.program = program
            return sendMacro("$#", &io, session, now)
        }
        let offsets = pending.replies.compactMap(Self.parseOffset)
        io.s.offsets = offsets
        if let why = M101.problem(call, offsets) {
            io.s.lastError = "M101: \(why)"
            log(.error, io.s.lastError!)
            endProgram(&io, .failed(io.s.lastError!))
            io.queue.append(("M5", .console))
            return
        }
        note(String(format: "M101: %@ %@ agree within %.3f mm.", call.offsets.map { "G\($0)" }.joined(separator: ", "), call.axis.rawValue, call.tolerance))
        program.check = nil
        io.program = program
        io.s.program?.done += 1
    }

    private func endProgram(_ io: inout IOState, _ outcome: MillProgramStatus.Outcome) {
        guard io.program != nil else { return }
        io.program = nil
        io.s.program?.outcome = outcome
        io.s.program?.finishedAt = Date()
        switch outcome {
        case .completed:
            let seconds = io.s.program.map { Date().timeIntervalSince($0.startedAt) } ?? 0
            note(String(format: "%@ finished in %.1f s.", io.s.program?.name ?? "The program", seconds))
        case .stopped: note("\(io.s.program?.name ?? "The program") was stopped.")
        case .failed, .running: break
        }
    }

    private func refuse(_ what: String, _ refusal: MillRefusal) {
        log(.error, "\(what) was not sent: \(refusal.text)")
    }

    private static func decode(_ line: String) -> JogRequest? {
        let parts = line.split(separator: " ")
        guard parts.count == 4, parts[0] == "JOG", let axis = Axis(letter: parts[1].first ?? " "),
              let distance = Double(parts[2]), let feed = Double(parts[3]) else { return nil }
        return JogRequest(axis: axis, distance: distance, feed: feed)
    }

    // MARK: Gates

    private func gates(_ io: IOState, _ now: TimeInterval) -> MillGates {
        var g = MillGates()
        guard io.phase == .ready, io.s.link == .connected else { return g }
        let s = io.s
        let fresh = s.status != nil && now - io.statusMono <= Self.freshStatus
        let state = s.status?.state ?? ""
        let limit = s.status.map { $0.limitX || $0.limitY || $0.limitZ } ?? false
        let lineBusy = (io.pending.map { $0.kind != .query } ?? false) || io.program != nil
        let settings = Self.settingsProblem(s.settings)

        func common() -> MillRefusal? {
            if s.silentSince != nil { return .silent }
            if io.pending?.kind == .home || io.checkHomeOnNextStatus { return .homing }
            if s.needsReset { return .needsReset }
            if !fresh { return .statusStale }
            if let settings { return .settings(settings) }
            if limit { return .limitSwitch }
            if lineBusy { return .busy }
            return nil
        }
        g.home = common() ?? (["Alarm", "Idle"].contains(state) ? nil : .wrongState(state))
        g.jog = common() ?? (!s.homed ? .notHomed : (state == "Idle" ? nil : .wrongState(state)))
        g.run = g.jog
        g.setup = g.jog
        if s.silentSince != nil { g.resume = .silent }
        else { g.resume = (state.hasPrefix("Hold") || state.hasPrefix("Door")) ? nil : .wrongState(state) }
        if s.silentSince != nil { g.console = .silent }
        else if s.homingSince != nil { g.console = .homing }
        else if io.program != nil { g.console = .busy }
        else { g.console = nil }
        return g
    }

    /// Motion needs mm reports, soft limits, hard limits, homing and a full travel/rate table.
    static func settingsProblem(_ settings: MillSettings) -> String? {
        let v = settings.values
        guard !v.isEmpty else { return "The controller settings ($$) were not read." }
        if v[13] != 0 { return "The controller reports inches ($13=1). Coastline needs $13=0." }
        if v[20] != 1 { return "Soft limits are off ($20=0). Coastline needs them on." }
        if v[22] != 1 { return "Homing is off ($22=0). Coastline needs it on." }
        for n in [110, 111, 112, 130, 131, 132] where (v[n] ?? 0) <= 0 {
            return "Setting $\(n) is missing."
        }
        return nil
    }

    /// Per axis: `-$13n + $27` if the axis homes to its negative end (bit set in `$23`), else `-$27`.
    static func homeTarget(_ settings: MillSettings) -> Point3? {
        let v = settings.values
        guard let mask = v[23], let pulloff = v[27], let tx = v[130], let ty = v[131], let tz = v[132] else { return nil }
        let bits = Int(mask)
        func axis(_ bit: Int, _ travel: Double) -> Double { bits & (1 << bit) != 0 ? -travel + pulloff : -pulloff }
        return Point3(x: axis(0, tx), y: axis(1, ty), z: axis(2, tz))
    }

    static func parseOffset(_ line: String) -> MillOffset? {
        guard line.hasPrefix("[G"), let colon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[line.index(after: line.startIndex)..<colon])
        let numbers = line[line.index(after: colon)...].dropLast().split(separator: ",").prefix(3).compactMap { Double($0) }
        guard numbers.count == 3 else { return nil }
        return MillOffset(name: name, point: Point3(x: numbers[0], y: numbers[1], z: numbers[2]))
    }

    static func format(_ p: Point3) -> String { String(format: "X%.3f Y%.3f Z%.3f", p.x, p.y, p.z) }

    // MARK: Publishing

    private func publish(_ io: inout IOState, _ now: TimeInterval) {
        io.s.gates = gates(io, now)
        io.s.overrides = overrideState.current
        let current = published.current
        var next = io.s
        next.revision = current.revision
        guard next != current else { return }
        next.revision = current.revision + 1
        io.s.revision = next.revision
        published.current = next
    }
}
