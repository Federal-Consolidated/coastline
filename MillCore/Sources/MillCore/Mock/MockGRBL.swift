import Foundation

/// A simulated controller (the machine's grbl fork 1.1g) behind the `SerialTransport` interface.
/// Used by the self-tests and by the app's "simulated mill" mode.
///
/// Lines are queued in a 128-byte receive buffer, as on the real controller, and acknowledged
/// when the host polls (`readAvailable`), `linesPerPoll` at a time. `maxRxUsed`/`overflowed`
/// let tests verify the host's character-counting flow control.
public final class MockGRBL: SerialTransport, @unchecked Sendable {
    public struct Options: Sendable {
        public var startLocked = false
        /// Lines acknowledged per host poll (1 = slow controller, large = instant).
        public var linesPerPoll = Int.max
        /// Return `"error:N"` (or any reply) for a line instead of `ok`.
        public var replyOverride: (@Sendable (String) -> String?)?
        /// Probe result: `nil` → ALARM:5 (no contact).
        public var probeContactZ: Double? = -10
        /// A simulated part: the first probe along an axis and direction finds a face half way
        /// along its move (probing programs expect the contact inside the move); later probes that
        /// way touch the same face when they reach it, so probed offsets agree as on a real part.
        /// Off: `probeContactZ`.
        public var probeFaces = false
        public var softLimitTravel = Point3(x: 86, y: 241.5, z: 78.5)
        public var firmwareInfo = "[grbl:1.1g XY:3A PCB:3B YMD:20240318]"  // a real machine sends no VFD field
        /// Jogs take time (at their feed, without acceleration) and report Jog, as on the machine;
        /// 0x85 and `!` cancel them where they are. Off: a jog arrives at once.
        public var timedJogs = false
        /// Add `Ov:` to the status (stock grbl does; the machine's firmware does not).
        public var reportsOverrides = false
        public init() {}
    }

    public static let rxBufferSize = 128

    /// `$$` of a real machine (grbl 1.1g XY:3A, YMD 20240318).
    static let standardSettings: [(Int, Double, String)] = [
        (0, 10, "stepPulse"), (1, 100, "idleDelay"), (2, 0, "stepMask"), (3, 0, "dirMask"), (4, 0, "stepEn"),
        (5, 1, "limLVL"), (6, 0, "prbLVL"), (10, 127, "statMask"), (11, 0.02, "jncDev"), (12, 0.002, "arcTol"),
        (13, 0, "Inch"), (20, 1, "softLim"), (21, 1, "hardLim"), (22, 1, "homeEn"), (23, 1, "homeDirMask"),
        (24, 30, "homeFine"), (25, 2000, "homeSeek"), (26, 1, "homeDelay"), (27, 0.5, "homePulloff"),
        (30, 8500, "rpmMax"), (31, 1360, "rpmMin"),
        (100, 400, "x:stp/mm"), (101, 400, "y:stp/mm"), (102, 400, "z:stp/mm"),
        (110, 2540, "x:mm/min"), (111, 3100, "y:mm/min"), (112, 3100, "z:mm/min"),
        (120, 500, "x:mm/s^2"), (121, 500, "y:mm/s^2"), (122, 500, "z:mm/s^2"),
        (130, 86.5, "x:mm"), (131, 241.5, "y:mm"), (132, 78.5, "z:mm"),
    ]
    static let integerSettings: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 10, 13, 20, 21, 22, 23, 26, 30, 31]

    private struct State {
        var open = false
        var output: [UInt8] = []
        var partialLine: [UInt8] = []
        var rxQueue: [String] = []
        var rxUsed = 0
        var maxRxUsed = 0
        var overflowed = false
        var silent = false
        var alarm = false
        var hold = false
        var position = Point3(x: -86, y: -0.5, z: -0.5)
        var offsets: [Int: Point3] = Dictionary(uniqueKeysWithValues: (54...59).map { ($0, Point3.zero) })
        var wcs = 54
        /// `probeFaces`: the machine coordinate of each face found ("X+", "Z-"…).
        var faces: [String: Double] = [:]
        var absolute = true
        var inches = false
        var spindle = "M5"
        var rpm = 0.0
        var overrides = MillOverrides()
        /// `timedJogs`: queued jog targets (machine coordinates) and feeds, run one after another
        /// from `jogFrom`, the first started at `jogStart`.
        var jogs: [(target: Point3, feed: Double)] = []
        var jogFrom = Point3()
        var jogStart: TimeInterval = 0
        var received: [String] = []
        var realtime: [UInt8] = []
        var pendingAtArrival: [String: Int] = [:]
        var statusCount = 0
        /// Opening the port resets the Arduino; the banner appears after a short boot delay.
        var bootAt: TimeInterval?
    }

    public var options: Options
    private let state = Locked(State())

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Test hooks

    /// Every complete line received, in order (as sent, without newline).
    public var receivedLines: [String] { state.withLock { $0.received } }
    /// Real-time bytes received.
    public var realtimeBytes: [UInt8] { state.withLock { $0.realtime } }
    public var maxRxUsed: Int { state.withLock { $0.maxRxUsed } }
    public var overflowed: Bool { state.withLock { $0.overflowed } }
    public var position: Point3 { state.withLock { s in Self.advance(&s); return s.position } }
    /// The overrides the simulated controller applies.
    public var overrides: MillOverrides { state.withLock { $0.overrides } }
    /// The spindle as `$G` reports it (`M3`, `M4`, `M5`) and its `S`.
    public var spindle: (mode: String, rpm: Double) { state.withLock { ($0.spindle, $0.rpm) } }
    /// Simulates the hardware e-stop: the controller stops answering.
    public var silent: Bool {
        get { state.withLock { $0.silent } }
        set { state.withLock { $0.silent = newValue } }
    }
    public func setOffset(_ wcs: Int, _ point: Point3) { state.withLock { $0.offsets[wcs] = point } }
    public func offset(_ wcs: Int) -> Point3 { state.withLock { $0.offsets[wcs] ?? .zero } }
    public func setPosition(_ point: Point3) { state.withLock { $0.position = point } }
    /// How many lines were still queued (unacknowledged) when `line` arrived (first occurrence).
    public func pendingLines(whenReceived line: String) -> Int? { state.withLock { $0.pendingAtArrival[line] } }

    // MARK: SerialTransport

    public var isOpen: Bool { state.withLock { $0.open } }

    public func open() throws {
        state.withLock { s in
            s.open = true
            s.output.removeAll()
            s.rxQueue.removeAll()
            s.rxUsed = 0
            s.bootAt = monotonicNow() + 0.2
        }
    }

    public func close() { state.withLock { $0.open = false } }

    public func write(_ bytes: [UInt8]) throws {
        guard isOpen else { throw MillError(.failedWrite) }
        for byte in bytes { receive(byte) }
    }

    public func readAvailable() -> [UInt8] {
        let shouldBoot: Bool = state.withLock { s in
            guard let at = s.bootAt, monotonicNow() >= at else { return false }
            s.bootAt = nil
            return true
        }
        if shouldBoot { boot() }
        process(limit: options.linesPerPoll)
        return state.withLock { s in
            defer { s.output.removeAll() }
            return s.output
        }
    }

    // MARK: Controller behaviour

    private func emit(_ line: String) {
        state.withLock { s in
            guard !s.silent else { return }
            s.output.append(contentsOf: Array((line + "\r\n").utf8))
        }
    }

    private func boot() {
        state.withLock { s in
            s.rxQueue.removeAll()
            s.rxUsed = 0
            s.hold = false
            s.alarm = options.startLocked
            Self.advance(&s)
            s.jogs.removeAll()
            s.overrides = MillOverrides()
            s.spindle = "M5"
        }
        emit("")
        emit("Grbl 1.1g [help:'$']")
        if options.startLocked { emit("[MSG:$H/$X]") }
    }

    private func receive(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "?"):
            state.withLock { $0.realtime.append(byte) }
            emit(statusReport())
        case UInt8(ascii: "!"):
            // A feed hold during a jog cancels the jog (GRBL 1.1).
            state.withLock { s in
                s.realtime.append(byte)
                if Self.cancelJogs(&s) == false { s.hold = true }
            }
        case UInt8(ascii: "~"):
            state.withLock { $0.realtime.append(byte); $0.hold = false }
        case 0x18:
            state.withLock { $0.realtime.append(byte) }
            boot()
        case 0x85:
            state.withLock { s in
                s.realtime.append(byte)
                _ = Self.cancelJogs(&s)
            }
        case UInt8(ascii: "|"):
            state.withLock { $0.realtime.append(byte) }
        case 0x80...0xFF:
            // Real-time commands: overrides act, the rest are ignored (never part of a line).
            state.withLock { s in
                s.realtime.append(byte)
                if let command = MillOverride.allCases.first(where: { $0.byte == byte }) { s.overrides = command.applied(to: s.overrides) }
            }
        case UInt8(ascii: "\n"):
            state.withLock { s in
                let line = String(decoding: s.partialLine, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
                s.partialLine.removeAll()
                s.received.append(line)
                if s.pendingAtArrival[line] == nil { s.pendingAtArrival[line] = s.rxQueue.count }
                s.rxUsed += line.utf8.count + 1
                s.maxRxUsed = max(s.maxRxUsed, s.rxUsed)
                if s.rxUsed > Self.rxBufferSize { s.overflowed = true }
                s.rxQueue.append(line)
            }
        default:
            state.withLock { $0.partialLine.append(byte) }
        }
    }

    private func process(limit: Int) {
        var handled = 0
        while handled < limit {
            let next: String? = state.withLock { s in
                Self.advance(&s)
                guard !s.silent, !s.hold, let first = s.rxQueue.first else { return nil }
                // Other lines wait for the jogs to finish; more jogs queue behind them.
                if !s.jogs.isEmpty, !first.uppercased().hasPrefix("$J=") { return nil }
                let line = s.rxQueue.removeFirst()
                s.rxUsed -= line.utf8.count + 1
                return line
            }
            guard let line = next else { return }
            execute(line)
            handled += 1
        }
    }

    func statusReport() -> String {
        let reportsOverrides = options.reportsOverrides
        return state.withLock { s in
            Self.advance(&s)
            s.statusCount += 1
            let state = s.alarm ? "Alarm" : (s.hold ? "Hold:0" : (s.jogs.isEmpty ? "Idle" : "Jog"))
            let p = s.position
            let w = s.offsets[s.wcs] ?? .zero
            let fmt = { (v: Double) in String(format: "%.3f", v) }
            var report = "<\(state)|M:\(fmt(p.x)),\(fmt(p.y)),\(fmt(p.z))|B:15,\(Self.rxBufferSize - s.rxUsed)|L:0|0000"
            // Like GRBL, only include the work offset every few reports.
            if s.statusCount % 3 == 1 { report += "|W:\(fmt(w.x)),\(fmt(w.y)),\(fmt(w.z))" }
            if reportsOverrides, s.statusCount % 3 == 2 { report += "|Ov:\(s.overrides.feed),\(s.overrides.rapid),\(s.overrides.spindle)" }
            return report + ">"
        }
    }

    /// `timedJogs`: moves the machine along its queued jogs to where it is now.
    private static func advance(_ s: inout State) {
        let now = monotonicNow()
        while let jog = s.jogs.first {
            let d = jog.target - s.jogFrom
            let length = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
            let duration = jog.feed > 0 ? length / (jog.feed / 60) : 0
            let t = now - s.jogStart
            guard t < duration else {
                s.position = jog.target
                s.jogFrom = jog.target
                s.jogStart += duration
                s.jogs.removeFirst()
                continue
            }
            let f = t / duration
            s.position = Point3(x: s.jogFrom.x + d.x * f, y: s.jogFrom.y + d.y * f, z: s.jogFrom.z + d.z * f)
            return
        }
    }

    /// Stops the queued jogs where the machine is. False if there were none.
    private static func cancelJogs(_ s: inout State) -> Bool {
        advance(&s)
        guard !s.jogs.isEmpty else { return false }
        s.jogs.removeAll()
        return true
    }

    private func execute(_ raw: String) {
        let line = raw.filter { !$0.isWhitespace }.uppercased()
        if let reply = options.replyOverride?(raw) {
            emit(reply)
            return
        }
        if line.isEmpty { emit("ok"); return }

        if line.hasPrefix("$") {
            executeSystem(line)
            return
        }
        if state.withLock({ $0.alarm }) {
            emit("error:9")
            return
        }
        executeGCode(line)
    }

    private func executeSystem(_ line: String) {
        switch line {
        case "$$":
            // The real machine dump: every setting, with its name after the value.
            let t = options.softLimitTravel
            for (k, v, name) in Self.standardSettings {
                let value = [130: t.x, 131: t.y, 132: t.z][k] ?? v
                let text = Self.integerSettings.contains(k) ? String(Int(value)) : String(format: "%.3f", value)
                emit("$\(k)=\(text) (\(name))")
            }
            emit("ok")
        case "$#":
            let offsets = state.withLock { $0.offsets }
            for n in 54...59 {
                let p = offsets[n] ?? .zero
                emit(String(format: "[G%d:%.3f,%.3f,%.3f]", n, p.x, p.y, p.z))
            }
            emit("[G28:0.000,0.000,0.000]")
            emit("[G30:0.000,0.000,0.000]")
            emit("[G92:0.000,0.000,0.000]")
            emit("[TLO:0.000]")
            emit("[PRB:0.000,0.000,0.000:0]")
            emit("ok")
        case "$G":
            let (wcs, absolute, inches, spindle, rpm) = state.withLock { ($0.wcs, $0.absolute, $0.inches, $0.spindle, $0.rpm) }
            emit("[GC:G0 G\(wcs) G17 \(inches ? "G20" : "G21") \(absolute ? "G90" : "G91") G94 \(spindle) M9 T0 F0 S\(Int(rpm))]")
            emit("ok")
        case "$I":
            emit(options.firmwareInfo)
            emit("ok")
        case "$X":
            state.withLock { $0.alarm = false }
            emit("[MSG:Caution: Unlocked]")
            emit("ok")
        case "$H", "$HZ", "$HX", "$HY":
            state.withLock { s in
                s.alarm = false
                if line == "$H" { s.position = Point3(x: -86, y: -0.5, z: -0.5) }
                if line == "$HZ" { s.position.z = -0.5 }
                if line == "$HX" { s.position.x = -86 }
            }
            emit("ok")
        default:
            if line.hasPrefix("$J=") {
                jog(String(line.dropFirst(3)))
            } else if line.hasPrefix("$RST") {
                if line == "$RST=#" { state.withLock { s in for k in s.offsets.keys { s.offsets[k] = .zero } } }
                emit("ok")
            } else {
                emit("ok")
            }
        }
    }

    private func words(_ line: String) -> [(Character, Double)] {
        var result: [(Character, Double)] = []
        var letter: Character?
        var number = ""
        func flush() {
            if let l = letter, let v = Double(number) { result.append((l, v)) }
        }
        for c in line {
            if c.isLetter {
                flush()
                letter = c
                number = ""
            } else {
                number.append(c)
            }
        }
        flush()
        return result
    }

    /// `$J=`: relative unless it has G90 (work) or G53 (machine). Outside the travel: error:15.
    private func jog(_ body: String) {
        let w = words(body)
        let timed = options.timedJogs
        let travel = options.softLimitTravel
        let reply: String = state.withLock { s in
            Self.advance(&s)
            let g = w.filter { $0.0 == "G" }.map(\.1)
            let scale = g.contains(20) ? 25.4 : 1
            let start = s.jogs.last?.target ?? s.position
            var target = start
            for (letter, value) in w {
                guard let axis = Axis(letter: letter) else { continue }
                if g.contains(53) { target[axis] = value * scale }
                else if g.contains(90) { target[axis] = value * scale + (s.offsets[s.wcs] ?? .zero)[axis] }
                else { target[axis] += value * scale }
            }
            if target.x > 1e-6 || target.y > 1e-6 || target.z > 1e-6
                || target.x < -travel.x - 1e-6 || target.y < -travel.y - 1e-6 || target.z < -travel.z - 1e-6 {
                return "error:15"
            }
            guard timed else {
                s.position = target
                return "ok"
            }
            if s.jogs.isEmpty {
                s.jogFrom = s.position
                s.jogStart = monotonicNow()
            }
            s.jogs.append((target, w.last { $0.0 == "F" }?.1 ?? 1000))
            return "ok"
        }
        emit(reply)
    }

    private func executeGCode(_ line: String) {
        let w = words(line)
        let gCodes = w.filter { $0.0 == "G" }.map(\.1)
        let probe = gCodes.first { abs($0 - 38.2) < 0.01 || abs($0 - 38.3) < 0.01 }
        let travel = options.softLimitTravel
        let contactZ = options.probeContactZ
        let faces = options.probeFaces
        let replies: [String] = state.withLock { s in
            var machineCoordinates = false
            for (letter, value) in w where letter == "M" || letter == "S" {
                switch (letter, value) {
                case ("M", 3): s.spindle = "M3"
                case ("M", 4): s.spindle = "M4"
                case ("M", 5): s.spindle = "M5"
                case ("S", _): s.rpm = value
                default: break
                }
            }
            for g in gCodes {
                switch g {
                case 20: s.inches = true
                case 21: s.inches = false
                case 90: s.absolute = true
                case 91: s.absolute = false
                case 53: machineCoordinates = true
                case 54...59: s.wcs = Int(g)
                default: break
                }
            }
            let scale = s.inches ? 25.4 : 1
            if gCodes.contains(10) {
                // G10 L2 Pn: the offset itself. G10 L20 Pn: the offset that makes the current position the value.
                guard let p = w.first(where: { $0.0 == "P" })?.1, (1...6).contains(Int(p)) else { return ["error:3"] }
                let l = w.first { $0.0 == "L" }?.1 ?? 2
                let n = 53 + Int(p)
                var point = s.offsets[n] ?? .zero
                for (letter, value) in w {
                    guard let axis = Axis(letter: letter) else { continue }
                    point[axis] = l == 20 ? s.position[axis] - value * scale : value * scale
                }
                s.offsets[n] = point
                return ["ok"]
            }
            let offset = machineCoordinates ? .zero : (s.offsets[s.wcs] ?? .zero)
            var target = s.position
            for (letter, value) in w {
                guard let axis = Axis(letter: letter) else { continue }
                // G53 is a machine position in G90 and G91 alike (as in GRBL).
                target[axis] = s.absolute || machineCoordinates ? value * scale + offset[axis] : s.position[axis] + value * scale
            }
            // Soft limits ($20=1): a target outside 0 … -travel is refused with ALARM:2, as GRBL does.
            let limits = (x: travel.x, y: travel.y, z: travel.z)
            if target.x > 1e-6 || target.y > 1e-6 || target.z > 1e-6
                || target.x < -limits.x - 1e-6 || target.y < -limits.y - 1e-6 || target.z < -limits.z - 1e-6 {
                s.alarm = true
                return ["ALARM:2"]
            }
            guard let probe else {
                s.position = target
                return ["ok"]
            }
            let start = s.position
            guard let contactZ else {
                // G38.3: no contact is not an alarm; the report says so (`:0`). G38.2 alarms.
                if abs(probe - 38.3) < 0.01 {
                    s.position = target
                    return [String(format: "[PRB:%.3f,%.3f,%.3f:0]", target.x, target.y, target.z), "ok"]
                }
                s.alarm = true
                return ["ALARM:5"]
            }
            // Contact: a face of the simulated part (`probeFaces`), at `probeContactZ` for a Z probe
            // that passes it, else 2 mm along the move (half way on a shorter one).
            let d = Point3(x: target.x - start.x, y: target.y - start.y, z: target.z - start.z)
            let length = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
            var contact = target
            let moving = Axis.allCases.filter { d[$0] != 0 }
            if faces, moving.count == 1, let axis = moving.first {
                let key = axis.rawValue + (d[axis] > 0 ? "+" : "-")
                let low = min(start[axis], target[axis]), high = max(start[axis], target[axis])
                if let face = s.faces[key], low <= face, face <= high {
                    contact[axis] = face
                } else {
                    contact[axis] = start[axis] + d[axis] / 2
                    s.faces[key] = contact[axis]
                }
            } else if d.x == 0, d.y == 0, min(start.z, target.z) <= contactZ, contactZ <= max(start.z, target.z) {
                contact.z = contactZ
            } else if length > 0 {
                let f = min(2, length / 2) / length
                contact = Point3(x: start.x + d.x * f, y: start.y + d.y * f, z: start.z + d.z * f)
            }
            s.position = contact
            return [String(format: "[PRB:%.3f,%.3f,%.3f:1]", contact.x, contact.y, contact.z), "ok"]
        }
        replies.forEach(emit)
    }
}
