import Foundation
@testable import MillCore

/// `$$` of the user's real machine, as `MillSettings`.
let realSettings: MillSettings = {
    var s = MillSettings()
    for (n, v, _) in MockGRBL.standardSettings { s.update(n, v) }
    return s
}()

func millMock(timedJogs: Bool = false) -> MockGRBL {
    var options = MockGRBL.Options()
    options.startLocked = true
    options.softLimitTravel = Point3(x: 86.5, y: 241.5, z: 78.5)
    options.timedJogs = timedJogs
    return MockGRBL(options: options)
}

/// Waits up to `timeout` seconds for `condition` on the session snapshot.
func waitFor(_ session: MillSession, _ what: String, timeout: TimeInterval = 5,
                     _ condition: (MillSnapshot) -> Bool) throws {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition(session.snapshot) { return }
        usleep(10_000)
    }
    let console = session.console(after: 0).map(\.text).suffix(12).joined(separator: " | ")
    throw TestFailure(description: "timed out waiting for \(what); state \(session.snapshot.state); console: \(console)")
}

func connected(_ mock: MockGRBL) throws -> MillSession {
    let session = MillSession()
    session.connect(.simulated, transport: mock)
    try waitFor(session, "settings") { $0.link == .connected && $0.envelope != nil && $0.parserState != nil }
    return session
}

func homed(_ mock: MockGRBL) throws -> MillSession {
    let session = try connected(mock)
    try waitFor(session, "home gate") { $0.gates.home == nil }
    try expect(session.home() == nil)
    try waitFor(session, "homed") { $0.homed && $0.gates.jog == nil }
    return session
}

let sessionTests: [TestCase] = [
    TestCase(name: "homeTargetAndEnvelopeFromRealSettings") {
        try expectEqual(MillSession.homeTarget(realSettings), Point3(x: -86, y: -0.5, z: -0.5))
        let e = try MillEnvelope.from(realSettings).unwrapped()
        try expectEqual(e.x, -86.0 ... -0.5)
        try expectEqual(e.y, -241.0 ... -0.5)
        try expectEqual(e.z, -78.0 ... -0.5)
        try expect(MillSession.settingsProblem(realSettings) == nil)
    },

    TestCase(name: "consoleRules") {
        for line in ["$RST=*", "$RST=#", "$130=1", "$N0=G0X0", "$I=x", "$L", "$HX"] {
            try expect(MillSession.blockedConsoleReason(line) != nil, line)
        }
        for line in ["$$", "$#", "$G", "$I", "$X", "$N", "G21", "M5", "G54"] {
            try expect(MillSession.blockedConsoleReason(line) == nil, line)
        }
        for line in ["G0X-10", "G1Y-5F100", "$J=G91G21X1F100", "X-3", "G28", "G38.2Z-5F50", "G91G0Z1"] {
            try expect(MillSession.isMotion(line), line)
        }
        for line in ["G21", "G90", "M5", "G54", "G10L20P1X0", "$$", "(MOVE X10)", "G4P1", "M3S8000"] {
            try expect(!MillSession.isMotion(line) || line.hasPrefix("G10"), line)
        }
    },

    TestCase(name: "connectSendsOnlyReadOnlyCommands") {
        let mock = millMock()
        let session = try connected(mock)
        defer { session.disconnect() }
        try waitFor(session, "offsets") { !$0.offsets.isEmpty && $0.firmware != nil }
        try expectEqual(mock.receivedLines, ["$$", "$I", "$#", "$G"])
        try expect(mock.realtimeBytes.allSatisfy { $0 == UInt8(ascii: "?") })
        let s = session.snapshot
        try expect(s.locked)
        try expectEqual(s.banner, "Grbl 1.1g [help:'$']")
        try expectEqual(s.firmware, "[grbl:1.1g XY:3A PCB:3B YMD:20240318]")
        try expectEqual(s.state, "Alarm")
        try expect(!s.homed)
        try expect(s.gates.jog == .notHomed)
    },

    TestCase(name: "homeThenJogIsClampedToTheEnvelope") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        try expectEqual(mock.position, Point3(x: -86, y: -0.5, z: -0.5))
        try expect(!session.snapshot.locked)

        // From home, Y can only go negative and X only positive.
        try expect(session.jog(JogRequest(axis: .y, distance: 10, feed: 300)) == nil)
        try expect(session.jog(JogRequest(axis: .x, distance: -10, feed: 300)) == nil)
        try expect(session.jog(JogRequest(axis: .y, distance: -10, feed: 5000)) == nil)
        try waitFor(session, "jog") { abs(($0.status?.machinePosition.y ?? 0) + 10.5) < 0.001 && $0.gates.jog == nil }
        let jogs = mock.receivedLines.filter { $0.hasPrefix("$J=") }
        try expectEqual(jogs, ["$J=G21 G91 Y-10.000 F3100"])  // feed capped by $111

        try expect(session.jog(JogRequest(axis: .x, distance: 100, feed: 1000)) == nil)
        try waitFor(session, "x to the far end") { abs(($0.status?.machinePosition.x ?? 0) + 0.5) < 0.001 }
        try expectEqual(mock.position.x, -0.5)
    },

    TestCase(name: "jogAndConsoleMovesNeedHoming") {
        let mock = millMock()
        let session = try connected(mock)
        defer { session.disconnect() }
        try waitFor(session, "status") { $0.status != nil }
        try expectEqual(session.jog(JogRequest(axis: .y, distance: -1, feed: 300)), .notHomed)
        try expectEqual(session.send(console: "G0 Y-10"), .notHomed)
        try expect(session.send(console: "$RST=*") != nil)
        try expect(session.send(console: "$#") == nil)
        usleep(300_000)
        try expect(!mock.receivedLines.contains { $0.hasPrefix("$J") || $0.hasPrefix("G0") || $0.hasPrefix("$RST") })
    },

    TestCase(name: "stopAndHoldAreNeverRefused") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        mock.silent = true
        try waitFor(session, "silence", timeout: 4) { $0.silentSince != nil }
        try expectEqual(session.snapshot.gates.jog, .silent)
        try expect(!session.snapshot.homed)
        session.feedHold()
        session.jogCancel()
        session.stop()
        usleep(200_000)
        let bytes = mock.realtimeBytes
        try expect(bytes.contains(UInt8(ascii: "!")) && bytes.contains(0x85) && bytes.contains(0x18))
    },

    TestCase(name: "softResetClearsHomedAndRestartIsDetected") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        session.stop()  // Idle: a soft reset
        try waitFor(session, "restart") { $0.restarts == 1 && $0.locked }
        try expect(!session.snapshot.homed)
        try expectEqual(session.snapshot.gates.jog, .notHomed)
    },

    TestCase(name: "songMatchesTheFilePlayedOnTheRealMill") {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/korobeiniki.nc")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw Skip(reason: "scripts/korobeiniki.nc not present") }
        let envelope = try MillEnvelope.from(realSettings).unwrapped()
        let home = Point3(x: -86, y: -0.5, z: -0.5)
        let fromFile = try ProgramCheck.clean(text.components(separatedBy: "\n"), start: home, envelope: envelope).get()
        let fromCode = try ProgramCheck.clean(TestProgram.korobeiniki.lines, start: home, envelope: envelope).get()
        try expectEqual(fromCode.count, 68)
        try expectEqual(fromCode, fromFile)
    },

    TestCase(name: "programCheckRefusesUnsafeLines") {
        let envelope = try MillEnvelope.from(realSettings).unwrapped()
        let home = Point3(x: -86, y: -0.5, z: -0.5)
        for bad in [["M3 S8000"], ["G91", "G1 Y-300 F100"], ["G90", "G1 Y-10 F100"], ["G91", "G1 X-5 F100"],
                    ["G2 X-10 Y-10 I1 F100"], ["G91", "G53 G1 Y-1 F100"], ["$H"], ["G20"]] {
            if case .success = ProgramCheck.clean(bad, start: home, envelope: envelope) {
                throw TestFailure(description: "accepted \(bad)")
            }
        }
        try expectEqual(try ProgramCheck.clean(["G21 (mm)", "G91", "g1 y-1 f100 ; down"], start: home, envelope: envelope).get(),
                        ["G21", "G91", "G1Y-1F100"])
    },

    TestCase(name: "songRunsOnTheSimulatedMill") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        try expect(session.run(TestProgram.korobeiniki.title, lines: TestProgram.korobeiniki.lines) == nil)
        try waitFor(session, "song done", timeout: 10) { $0.program?.outcome == .completed }
        try expectEqual(session.snapshot.program?.done, 68)
        try expectEqual(mock.position, Point3(x: -86, y: -0.5, z: -0.5))
        try expect(mock.receivedLines.contains("G53G1Y-30.000F1000"))
        try expect(session.snapshot.gates.run == nil)
    },

    TestCase(name: "programNeedsHomingAndAnErrorHolds") {
        var options = MockGRBL.Options()
        options.startLocked = true
        options.softLimitTravel = Point3(x: 86.5, y: 241.5, z: 78.5)
        options.replyOverride = { $0 == "G4P0.5" ? "error:20" : nil }
        let mock = MockGRBL(options: options)
        let session = try connected(mock)
        defer { session.disconnect() }
        try waitFor(session, "status") { $0.status != nil }
        try expectEqual(session.run("song", lines: TestProgram.korobeiniki.lines), .notHomed)
        try expect(session.home() == nil)
        try waitFor(session, "homed") { $0.homed && $0.gates.run == nil }
        try expect(session.run("song", lines: TestProgram.korobeiniki.lines) == nil)
        try waitFor(session, "failure") { if case .failed = $0.program?.outcome { return true } else { return false } }
        try expect(mock.realtimeBytes.contains(UInt8(ascii: "!")))
        try expect(!mock.receivedLines.contains("G91"))  // nothing after the failed line
    },

    TestCase(name: "jobProgramCheck") {
        let envelope = try MillEnvelope.from(realSettings).unwrapped()
        // Every program of a job folder passes (COASTLINE_JOB=/path/to/job), if one is given.
        if let path = ProcessInfo.processInfo.environment["COASTLINE_JOB"] {
            let folder = URL(fileURLWithPath: path).appendingPathComponent("programs")
            for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".nc") {
                let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                if case .failure(let why) = JobProgramCheck.clean(text.components(separatedBy: "\n"), settings: realSettings, envelope: envelope) {
                    throw TestFailure(description: "\(file) refused: \(why.text)")
                }
            }
        }
        let typical = try JobProgramCheck.clean(["G90 G94 G17", "G21", "G40 G91.1", "M3 S8000", "G0 X1.5 Y-2. (comment)", "G1 Z-1. F600",
                                                 "G2 X2 Y-2 I0.25 J0", "G38.3 Z-5 F30", "G10 L20 P2 Z0", "G0 X+0.25",
                                                 "G53 G0 Z-1.", "M5"], settings: realSettings, envelope: envelope).get()
        try expectEqual(typical.lines.count, 12)
        let home = try JobProgramCheck.clean(["$H (home)", "G92.1", "$#", "G10 L20 P2 X0 Y0 Z0"], settings: realSettings, envelope: envelope).get()
        try expect(home.startsWithHome)
        try expectEqual(home.lines, ["$H", "G92.1", "G4P0", "$#", "G10L20P2X0Y0Z0"])
        for bad in [["G20"], ["G28"], ["$X"], ["M6 T1"], ["M3 S9000"], ["G10 L1 P1 R2"], ["G53 G0 X10"], ["M100 G56X G57X"], ["M101 G57 G58 X 0.1"], ["$L"], ["G38.4 Z-5 F20"], ["G49 G0 Z-1"], ["G93"]] {
            if case .success = JobProgramCheck.clean(bad, settings: realSettings, envelope: envelope) {
                throw TestFailure(description: "accepted \(bad)")
            }
        }
        let call = try M100.parse("M100G56XG57XG55X").unwrapped()
        try expect(call.a.wcs == 56 && call.b.wcs == 57 && call.destination.wcs == 55 && call.destination.axis == .x)
    },

    TestCase(name: "jobProgramHomesFirstAndRunsM100") {
        let mock = millMock()
        mock.setOffset(56, Point3(x: -10.001, y: 0, z: 0))
        mock.setOffset(57, Point3(x: -20.000, y: 0, z: 0))
        let session = try connected(mock)
        defer { session.disconnect() }
        try waitFor(session, "home gate") { $0.gates.home == nil }
        try expect(session.runJob("home", lines: ["$H", "G92.1", "G90 G21", "G53 G0 X-1 Y-110"]) == nil)
        try waitFor(session, "home program") { $0.program?.name == "home" && $0.program?.outcome == .completed }
        try expect(session.snapshot.homed)
        try expect(session.runJob("probe", lines: ["G21 G90", "M100 G56XG57XG55X", "G0 X-1"]) == nil)
        try waitFor(session, "M100 program") { $0.program?.name == "probe" && $0.program?.outcome == .completed }
        try expect(abs(mock.offset(55).x + 15.0005) < 0.0011,
                   "G55 X \(mock.offset(55).x): " + session.console(after: 0).map(\.text).suffix(14).joined(separator: " | "))
        try expect(mock.receivedLines.contains("G4P0") && mock.receivedLines.contains { $0.hasPrefix("G10L2P2X-15.00") })
        try expectEqual(session.snapshot.program?.done, 3)
    },

    TestCase(name: "jobProgramRunsM101ToleranceCheck") {
        let call = try M101.parse("M101G57G58G59X0.152").unwrapped()
        try expect(call.offsets == [57, 58, 59] && call.axis == .x && call.tolerance == 0.152)
        try expect(M101.parse("M101G57G58X0.1") == nil && M101.parse("M101G57G58G59X") == nil)
        let mock = millMock()
        mock.setOffset(57, Point3(x: -10.00, y: 0, z: 1.00))
        mock.setOffset(58, Point3(x: -10.10, y: 0, z: 1.05))
        mock.setOffset(59, Point3(x: -10.05, y: 0, z: 1.20))
        let session = try homed(mock)
        defer { session.disconnect() }
        try expect(session.runJob("check", lines: ["G21", "M101 G57 G58 G59 X 0.152", "G0 Z-1"]) == nil)
        try waitFor(session, "M101 pass") { $0.program?.name == "check" && $0.program?.outcome == .completed }
        try expect(mock.receivedLines.contains("G0Z-1"))
        try expect(session.runJob("check2", lines: ["G21", "M101 G57 G58 G59 Z 0.076", "G0 Z-2"]) == nil)
        try waitFor(session, "M101 failure") { if case .failed = $0.program?.outcome { return true } else { return false } }
        usleep(200_000)
        try expect(!mock.receivedLines.contains("G0Z-2"), "the program stopped at the check")
        try expect(session.snapshot.lastError?.contains("out of tolerance") == true, session.snapshot.lastError ?? "no error")
    },

    TestCase(name: "simulatedMillFollowsGRBL") {
        // G53 is a machine position in G91 too; G10 L20 makes the current position the value;
        // the travel is a soft limit; probes along one axis and direction find the same face (half way along the first).
        var options = MockGRBL.Options()
        options.startLocked = true
        options.softLimitTravel = Point3(x: 86.5, y: 241.5, z: 78.5)
        options.probeFaces = true
        let mock = MockGRBL(options: options)
        let session = try homed(mock)
        defer { session.disconnect() }
        try expect(session.runJob("moves", lines: ["G21 G91", "G0 G53 Z-19", "G0 G53 X-40 Y-100", "G10 L20 P2 X1 Y2 Z3",
                                                   "G38.3 Z-10 F30", "G0 Z1", "G38.3 Z-10 F30", "G90 G55 G0 X0"]) == nil)
        try waitFor(session, "moves") { $0.program?.name == "moves" && $0.program?.outcome == .completed }
        try expect(mock.offset(55) == Point3(x: -41, y: -102, z: -22), "\(mock.offset(55))")
        try expect(abs(mock.position.z + 24) < 1e-9, "both probes touch the face 5 mm down: \(mock.position)")
        try expect(abs(mock.position.x + 41) < 1e-9)
        try expect(session.runJob("out", lines: ["G21 G90 G55", "G0 Z-60"]) == nil)
        try waitFor(session, "soft limit") { if case .failed = $0.program?.outcome { return true } else { return false } }
        try expect(session.snapshot.lastAlarm?.hasPrefix("ALARM:2") == true)
        try expect(abs(mock.position.z + 24) < 1e-9, "the machine did not move")
    },

    TestCase(name: "probeThatTouchesNothingStopsTheProgram") {
        var options = MockGRBL.Options()
        options.startLocked = true
        options.softLimitTravel = Point3(x: 86.5, y: 241.5, z: 78.5)
        options.probeContactZ = nil
        let mock = MockGRBL(options: options)
        let session = try homed(mock)
        defer { session.disconnect() }
        try expect(session.runJob("probe", lines: ["G21", "M4 S5000", "G38.3 Z-5 F30", "G10 L20 P2 Z0", "G0 Z1"]) == nil)
        try waitFor(session, "probe failure") { if case .failed = $0.program?.outcome { return true } else { return false } }
        usleep(200_000)
        try expect(!mock.receivedLines.contains("G10L20P2Z0"), "the offset was not written")
        try expectEqual(mock.receivedLines.last { !$0.hasPrefix("$") }, "M5")  // then only read-backs ($G)
        try expect(session.snapshot.lastError?.contains("probe did not touch") == true)
    },

    TestCase(name: "jobProgramNeedsHomingUnlessItHomes") {
        let mock = millMock()
        let session = try connected(mock)
        defer { session.disconnect() }
        try waitFor(session, "status") { $0.status != nil && $0.gates.home == nil }
        try expectEqual(session.runJob("cut", lines: ["G21", "G0 X1"]), .notHomed)
        try expect(session.runJob("bad", lines: ["G20", "G0 X1"]) != nil)
    },

    TestCase(name: "disconnectClosesThePort") {
        let mock = millMock()
        let session = try connected(mock)
        session.disconnect()
        try waitFor(session, "closed") { $0.link == .disconnected }
        try expect(!mock.isOpen)
        try expectEqual(session.snapshot.gates.home, .notConnected)
    },
]

extension Optional {
    func unwrapped(file: StaticString = #fileID, line: UInt = #line) throws -> Wrapped {
        guard let self else { throw TestFailure(description: "\(file):\(line) unexpected nil") }
        return self
    }
}
