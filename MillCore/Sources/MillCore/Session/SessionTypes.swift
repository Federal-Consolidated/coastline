import Foundation

/// Where a `MillSession` connects.
public enum MillPort: Hashable, Sendable {
    case device(MillDevice)
    /// `MockGRBL`, for trying the Control page without a machine.
    case simulated

    public var label: String {
        switch self {
        case .device(let d): d.path.replacingOccurrences(of: "/dev/", with: "")
        case .simulated: "Simulated Mill"
        }
    }

    public var isSimulated: Bool { self == .simulated }
}

public enum MillLink: Equatable, Sendable {
    case disconnected
    /// The port is open; waiting for the controller to finish its restart and answer the queries.
    case connecting
    case connected
}

/// The travel the session allows, per axis, in machine coordinates (mm, all negative on a machine).
public struct MillEnvelope: Equatable, Sendable {
    public var x: ClosedRange<Double>
    public var y: ClosedRange<Double>
    public var z: ClosedRange<Double>

    public subscript(axis: Axis) -> ClosedRange<Double> {
        switch axis {
        case .x: x
        case .y: y
        case .z: z
        }
    }

    /// From `$130`–`$132` (travel) and `$27` (pull-off): `-travel + m … -m`, `m = max(0.5, $27)`.
    /// GRBL's own soft limit is `-travel … 0`; this stays a pull-off inside both ends.
    static func from(_ settings: MillSettings) -> MillEnvelope? {
        let v = settings.values
        guard let tx = v[130], let ty = v[131], let tz = v[132], tx > 1, ty > 1, tz > 1 else { return nil }
        let m = max(0.5, v[27] ?? 0.5)
        return MillEnvelope(x: (-tx + m)...(-m), y: (-ty + m)...(-m), z: (-tz + m)...(-m))
    }
}

public struct MillOffset: Equatable, Sendable, Identifiable {
    /// `G54`…`G59`, `G28`, `G30`, `G92`.
    public var name: String
    public var point: Point3
    public var id: String { name }
}

public struct MillConsoleLine: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable {
        /// A line sent to the controller.
        case sent
        /// A line from the controller.
        case received
        /// A real-time byte (`!`, `~`, 0x85, 0x18).
        case realtime
        /// Something the session did or noticed.
        case note
        case error
    }

    public let id: Int
    public let time: Date
    public let kind: Kind
    public let text: String
}

/// Why a motion request was refused. `text` is shown to the operator as is.
public enum MillRefusal: Error, Equatable, Sendable {
    case notConnected
    case silent
    case statusStale
    case settings(String)
    case needsReset
    case notHomed
    case homing
    case busy
    case wrongState(String)
    case limitSwitch
    case atLimit
    case blocked(String)

    public var text: String {
        switch self {
        case .notConnected: "Connect to the machine first."
        case .silent: "No reply from the machine. The E-stop may be pressed: turn the red knob clockwise."
        case .statusStale: "Waiting for a status report from the machine."
        case .settings(let why): why
        case .needsReset: "The machine stopped with an alarm. Press Stop to reset it, then home."
        case .notHomed: "Home the machine first."
        case .homing: "Homing is in progress."
        case .busy: "Wait for the last command to finish."
        case .wrongState(let state): "Not possible while the machine is in \(state)."
        case .limitSwitch: "A limit switch is pressed."
        case .atLimit: "The axis is at the end of its travel."
        case .blocked(let why): why
        }
    }
}

/// What the operator may start now. `nil` means allowed.
public struct MillGates: Equatable, Sendable {
    public var home: MillRefusal? = .notConnected
    public var jog: MillRefusal? = .notConnected
    public var resume: MillRefusal? = .notConnected
    public var console: MillRefusal? = .notConnected
    /// Running a program: the same rules as a jog.
    public var run: MillRefusal? = .notConnected
    /// Work offsets, the active work offset and starting the spindle: the same rules as a jog
    /// (a homed, idle machine), though nothing moves.
    public var setup: MillRefusal? = .notConnected

    public init() {}
}

/// Feed, rapid and spindle overrides, in percent.
public struct MillOverrides: Equatable, Sendable {
    public var feed = 100
    public var rapid = 100
    public var spindle = 100
    /// The controller reported them (`Ov:` in its status). Otherwise they are what Coastline
    /// sent since the last restart (the machine's firmware does not report them).
    public var reported = false

    public init() {}
}

/// GRBL 1.1's real-time override commands. They are single bytes, so they act at once, also
/// while a program runs.
public enum MillOverride: CaseIterable, Sendable {
    case feedReset, feedPlus10, feedMinus10, feedPlus1, feedMinus1
    case rapid100, rapid50, rapid25
    case spindleReset, spindlePlus10, spindleMinus10, spindlePlus1, spindleMinus1

    public var byte: UInt8 {
        switch self {
        case .feedReset: 0x90
        case .feedPlus10: 0x91
        case .feedMinus10: 0x92
        case .feedPlus1: 0x93
        case .feedMinus1: 0x94
        case .rapid100: 0x95
        case .rapid50: 0x96
        case .rapid25: 0x97
        case .spindleReset: 0x99
        case .spindlePlus10: 0x9A
        case .spindleMinus10: 0x9B
        case .spindlePlus1: 0x9C
        case .spindleMinus1: 0x9D
        }
    }

    public var label: String {
        switch self {
        case .feedReset: "feed 100%"
        case .feedPlus10: "feed +10%"
        case .feedMinus10: "feed −10%"
        case .feedPlus1: "feed +1%"
        case .feedMinus1: "feed −1%"
        case .rapid100: "rapid 100%"
        case .rapid50: "rapid 50%"
        case .rapid25: "rapid 25%"
        case .spindleReset: "spindle 100%"
        case .spindlePlus10: "spindle +10%"
        case .spindleMinus10: "spindle −10%"
        case .spindlePlus1: "spindle +1%"
        case .spindleMinus1: "spindle −1%"
        }
    }

    /// The overrides after this command, within GRBL's limits (feed and spindle 10–200%).
    public func applied(to o: MillOverrides) -> MillOverrides {
        var o = o
        let clamp = { (v: Int) in min(max(v, 10), 200) }
        switch self {
        case .feedReset: o.feed = 100
        case .feedPlus10: o.feed = clamp(o.feed + 10)
        case .feedMinus10: o.feed = clamp(o.feed - 10)
        case .feedPlus1: o.feed = clamp(o.feed + 1)
        case .feedMinus1: o.feed = clamp(o.feed - 1)
        case .rapid100: o.rapid = 100
        case .rapid50: o.rapid = 50
        case .rapid25: o.rapid = 25
        case .spindleReset: o.spindle = 100
        case .spindlePlus10: o.spindle = clamp(o.spindle + 10)
        case .spindleMinus10: o.spindle = clamp(o.spindle - 10)
        case .spindlePlus1: o.spindle = clamp(o.spindle + 1)
        case .spindleMinus1: o.spindle = clamp(o.spindle - 1)
        }
        return o
    }
}

/// A program the session is running or has run.
public struct MillProgramStatus: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case running
        /// Every line was acknowledged and the machine is Idle again.
        case completed
        case failed(String)
        /// Stopped by Stop, a reset, a restart or a disconnect.
        case stopped
    }

    public var name: String
    public var total: Int
    /// Lines the controller has acknowledged.
    public var done = 0
    public var startedAt = Date()
    public var finishedAt: Date?
    public var outcome = Outcome.running

    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

public struct JogRequest: Equatable, Sendable {
    public var axis: Axis
    /// Signed distance in mm. The session shortens it to stay inside the envelope.
    public var distance: Double
    /// mm/min. Capped by `$110`–`$112`.
    public var feed: Double

    public init(axis: Axis, distance: Double, feed: Double) {
        self.axis = axis
        self.distance = distance
        self.feed = feed
    }
}

/// Everything the Control page shows, copied out of the session's I/O thread.
public struct MillSnapshot: Equatable, Sendable {
    /// Goes up by one each time something changes.
    public var revision = 0
    public var link = MillLink.disconnected
    public var port: MillPort?
    /// `Grbl 1.1g [help:'$']`.
    public var banner: String?
    /// The `$I` line, e.g. `[grbl:1.1g XY:3A PCB:3B YMD:20240318]`.
    public var firmware: String?
    public var settings = MillSettings()
    public var status: RealTimeStatus?
    public var statusTime: Date?
    /// The last `W:` work offset (the machine sends it about every tenth report).
    public var workOffset: Point3?
    /// `$G`, e.g. `G0 G54 G17 G21 G90 G94 M5 M9 T0 F0 S0`.
    public var parserState: String?
    public var activeWCS = 54
    public var offsets: [MillOffset] = []
    public var envelope: MillEnvelope?
    /// Where `$H` must end, from `$23`, `$27` and `$130`–`$132`.
    public var homeTarget: Point3?
    /// True only after `$H` in this controller boot ended at `homeTarget`.
    public var homed = false
    public var homingSince: Date?
    /// The controller sent its "home or unlock" message and has not been homed since.
    public var locked = false
    /// An alarm stopped the controller: it needs a soft reset before anything else.
    public var needsReset = false
    /// No bytes from the controller for 2 s (outside homing).
    public var silentSince: Date?
    /// How many times the controller restarted (banner) since connect.
    public var restarts = 0
    public var lastError: String?
    public var lastAlarm: String?
    public var program: MillProgramStatus?
    public var gates = MillGates()
    public var overrides = MillOverrides()
    /// A hold-to-jog is running: the session streams short jogs while the operator holds.
    public var holding = false

    public init() {}

    public var state: String { status?.state ?? "—" }
    public var isOpen: Bool { link != .disconnected }
    public var isMoving: Bool {
        ["Run", "Jog", "Home"].contains(status?.state ?? "") || homingSince != nil || program?.outcome == .running
    }
    public var workPosition: Point3? {
        guard let status, let workOffset else { return nil }
        return status.machinePosition - workOffset
    }

    /// The stored offset of `G54`…`G59` (from the last `$#`).
    public func offset(wcs: Int) -> Point3? { offsets.first { $0.name == "G\(wcs)" }?.point }

    /// The spindle as the controller last reported it (`$G`): `M3`, `M4` or `M5`, and `S`.
    public var spindle: (mode: String, rpm: Double)? {
        guard let words = parserState?.split(separator: " "),
              let mode = words.first(where: { ["M3", "M4", "M5"].contains($0) }) else { return nil }
        let rpm = words.first { $0.hasPrefix("S") }.flatMap { Double($0.dropFirst()) } ?? 0
        return (String(mode), rpm)
    }
}
