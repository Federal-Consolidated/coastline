import Foundation
@testable import MillCore

/// Renews a hold for `seconds`, as the app does while the operator holds.
private func hold(_ session: MillSession, for seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        session.renewHold()
        usleep(50_000)
    }
}

private func jogLines(_ mock: MockGRBL) -> [String] { mock.receivedLines.filter { $0.hasPrefix("$J=") } }

/// Real-time bytes other than status polls.
private func commandBytes(_ mock: MockGRBL) -> [UInt8] { mock.realtimeBytes.filter { $0 != UInt8(ascii: "?") } }

let manualControlTests: [TestCase] = [
    TestCase(name: "holdJogMovesWhileHeldAndStopsWhenLetGo") {
        let mock = millMock(timedJogs: true)
        let session = try homed(mock)
        defer { session.disconnect() }
        try expect(session.startHold(.y, direction: -1, feed: 1200) == nil)  // 20 mm/s
        hold(session, for: 0.8)
        try expect(session.snapshot.holding)
        let moved = mock.position.y
        try expect(moved < -8 && moved > -20, "moved to \(moved) in 0.8 s")
        session.endHold()
        let letGo = mock.position.y
        try waitFor(session, "idle") { $0.state == "Idle" && !$0.holding }
        try expect(abs(mock.position.y - letGo) < 0.5, "stopped at \(mock.position.y), let go at \(letGo)")
        let sent = jogLines(mock).count
        usleep(300_000)
        try expectEqual(jogLines(mock).count, sent, "no jog after letting go")
        try expectEqual(commandBytes(mock).last, 0x85)
        // Every jog is short: 0.25 s of motion at most.
        for line in jogLines(mock) {
            let mm = Double(line.split(separator: "Y").last?.split(separator: " ").first ?? "") ?? .nan
            try expect(abs(mm) <= 1200.0 / 60 * MillSession.holdSegment + 0.001, line)
        }
        try expect(session.snapshot.lastError == nil, session.snapshot.lastError ?? "")
    },

    TestCase(name: "holdJogStopsWhenTheAppStopsRenewing") {
        let mock = millMock(timedJogs: true)
        let session = try homed(mock)
        defer { session.disconnect() }
        try expect(session.startHold(.y, direction: -1, feed: 600) == nil)  // 10 mm/s, never renewed
        try waitFor(session, "dead man", timeout: 2) { !$0.holding && $0.lastError?.contains("stopped confirming") == true }
        try waitFor(session, "idle") { $0.state == "Idle" }
        try expect(mock.position.y > -0.5 - 7, "went to \(mock.position.y)")
        try expectEqual(commandBytes(mock).last, 0x85)
    },

    TestCase(name: "holdJogStopsAtTheEndOfTheTravel") {
        let mock = millMock(timedJogs: true)
        let session = try homed(mock)
        defer { session.disconnect() }
        // At home Y is at the top of its travel: nothing to do that way.
        try expect(session.startHold(.y, direction: 1, feed: 1000) == nil)
        try waitFor(session, "refused") { !$0.holding && $0.lastError?.contains("end of its travel") == true }
        try expect(jogLines(mock).isEmpty)

        mock.setPosition(Point3(x: -86, y: -236, z: -0.5))
        try waitFor(session, "status") { abs(($0.status?.machinePosition.y ?? 0) + 236) < 0.001 }
        try expect(session.startHold(.y, direction: -1, feed: 2000) == nil)
        hold(session, for: 0.9)
        try waitFor(session, "at the end") { $0.state == "Idle" }
        try expect(abs(mock.position.y + 241) < 0.002, "stopped at \(mock.position.y)")
        try expect(session.snapshot.lastAlarm == nil && session.snapshot.lastError == nil, session.snapshot.lastError ?? "")
        session.endHold()
    },

    TestCase(name: "stopEndsAHoldEvenIfTheAppKeepsRenewing") {
        let mock = millMock(timedJogs: true)
        let session = try homed(mock)
        defer { session.disconnect() }
        try expect(session.startHold(.z, direction: -1, feed: 600) == nil)
        hold(session, for: 0.4)
        session.stop()
        try waitFor(session, "idle") { $0.state == "Idle" && !$0.holding }
        let sent = jogLines(mock).count, stoppedAt = mock.position
        hold(session, for: 0.4)  // renewing an ended hold does not start it again
        try expectEqual(jogLines(mock).count, sent)
        try expectEqual(mock.position, stoppedAt)
        try expectEqual(session.snapshot.restarts, 0, "a jog is cancelled, not reset")
        try expect(session.snapshot.homed)
    },

    TestCase(name: "holdJogNeedsHoming") {
        let mock = millMock(timedJogs: true)
        let session = try connected(mock)
        defer { session.disconnect() }
        try waitFor(session, "status") { $0.status != nil }
        try expectEqual(session.startHold(.y, direction: -1, feed: 1000), .notHomed)
        usleep(200_000)
        try expect(jogLines(mock).isEmpty)
    },

    TestCase(name: "workOffsetsZeroSetUndoAndSelect") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        mock.setPosition(Point3(x: -40, y: -100, z: -20))
        try waitFor(session, "status") { abs(($0.status?.machinePosition.y ?? 0) + 100) < 0.001 }
        try expect(session.setWorkPosition([.x: 0, .y: 0], wcs: 54) == nil)
        try waitFor(session, "zeroed") { $0.offset(wcs: 54) == Point3(x: -40, y: -100, z: 0) }
        try expectEqual(mock.offset(54), Point3(x: -40, y: -100, z: 0))
        let work = try session.snapshot.workPosition.unwrapped()
        try expect(abs(work.x) < 1e-9 && abs(work.y) < 1e-9 && abs(work.z + 20) < 1e-9, "\(work)")

        try expect(session.setWorkPosition([.z: 5], wcs: 54) == nil)  // this position is Z 5
        try waitFor(session, "set") { $0.offset(wcs: 54)?.z == -25 }
        try expect(session.setOffset(Point3(x: -40, y: -100, z: 0), wcs: 54) == nil)  // undo
        try waitFor(session, "undone") { $0.offset(wcs: 54) == Point3(x: -40, y: -100, z: 0) }

        try expect(session.selectWCS(55) == nil)
        try waitFor(session, "G55") { $0.activeWCS == 55 && $0.workOffset == .zero }
        try expect(session.selectWCS(53) != nil)
        try expect(session.setWorkPosition([:], wcs: 54) != nil)
        try expect(mock.receivedLines.contains("G10L20P1X0.000Y0.000"))
    },

    TestCase(name: "workOffsetsNeedAHomedIdleMachine") {
        let mock = millMock()
        let session = try connected(mock)
        defer { session.disconnect() }
        try waitFor(session, "status") { $0.status != nil }
        try expectEqual(session.setWorkPosition([.x: 0], wcs: 54), .notHomed)
        try expectEqual(session.selectWCS(55), .notHomed)
        try expectEqual(session.spindleOn(rpm: 5000), .notHomed)
        usleep(200_000)
        try expect(!mock.receivedLines.contains { $0.hasPrefix("G10") || $0.hasPrefix("M3") || $0 == "G55" })
    },

    TestCase(name: "consoleOffsetChangesAreReadBack") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        try expect(session.send(console: "G10 L20 P2 X0") == nil)
        try waitFor(session, "G55 read back") { $0.offset(wcs: 55)?.x == -86 }
        try expect(session.send(console: "G55") == nil)
        try waitFor(session, "G55 active") { $0.activeWCS == 55 && $0.workOffset?.x == -86 }
    },

    TestCase(name: "spindleOnInsideItsRangeAndOff") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        try expect(session.spindleOn(rpm: 9000) != nil)  // above $30
        try expect(session.spindleOn(rpm: 500) != nil)  // below $31
        try expect(session.spindleOn(rpm: 5000) == nil)
        try waitFor(session, "on") { $0.spindle?.mode == "M3" && $0.spindle?.rpm == 5000 }
        try expect(mock.receivedLines.contains("M3S5000"))
        try expect(session.spindleOff() == nil)
        try waitFor(session, "off") { $0.spindle?.mode == "M5" }
        try expectEqual(mock.spindle.mode, "M5")
    },

    TestCase(name: "overridesAreRealTimeAndTracked") {
        let mock = millMock()
        let session = try connected(mock)
        defer { session.disconnect() }
        for o: MillOverride in [.feedPlus10, .feedPlus10, .feedMinus1, .rapid25, .spindleMinus10] { session.override(o) }
        try waitFor(session, "tracked") { $0.overrides.feed == 119 && $0.overrides.rapid == 25 && $0.overrides.spindle == 90 }
        try expect(!session.snapshot.overrides.reported)
        usleep(100_000)
        try expectEqual(mock.overrides.feed, 119)
        try expectEqual(commandBytes(mock), [0x91, 0x91, 0x94, 0x97, 0x9B])
        for _ in 0..<12 { session.override(.feedPlus10) }
        try waitFor(session, "clamped") { $0.overrides.feed == 200 }
        session.softReset()
        try waitFor(session, "restart") { $0.restarts == 1 && $0.overrides == MillOverrides() }
    },

    TestCase(name: "reportedOverridesWin") {
        var options = MockGRBL.Options()
        options.startLocked = true
        options.softLimitTravel = Point3(x: 86.5, y: 241.5, z: 78.5)
        options.reportsOverrides = true
        let mock = MockGRBL(options: options)
        let session = try connected(mock)
        defer { session.disconnect() }
        session.override(.spindlePlus10)
        try waitFor(session, "reported") { $0.overrides.reported && $0.overrides.spindle == 110 && $0.overrides.feed == 100 }
    },

    TestCase(name: "goToLines") {
        let e = try MillEnvelope.from(realSettings).unwrapped()
        let work = Point3(x: -40, y: -100, z: -20)
        try expectEqual(GoTo.lines(x: 0, y: 0, z: nil, frame: .work, workOffset: work, envelope: e, retractFirst: true).get(),
                        ["G21", "G90", "G53G0Z-0.500", "G53G0X-40.000Y-100.000"])
        try expectEqual(GoTo.lines(x: 0, y: 0, z: 5, frame: .work, workOffset: work, envelope: e, retractFirst: true).get(),
                        ["G21", "G90", "G53G0Z-0.500", "G53G0X-40.000Y-100.000", "G53G0Z-15.000"])
        try expectEqual(GoTo.lines(x: -10, y: -20, z: -30, frame: .machine, workOffset: nil, envelope: e, retractFirst: false).get(),
                        ["G21", "G90", "G53G0X-10.000Y-20.000Z-30.000"])
        try expectEqual(GoTo.lines(x: nil, y: nil, z: -0.5, frame: .machine, workOffset: nil, envelope: e, retractFirst: true).get(),
                        ["G21", "G90", "G53G0Z-0.500"])
        for bad in [GoTo.lines(x: nil, y: -300, z: nil, frame: .machine, workOffset: nil, envelope: e, retractFirst: true),
                    GoTo.lines(x: 0, y: nil, z: nil, frame: .work, workOffset: nil, envelope: e, retractFirst: true),
                    GoTo.lines(x: nil, y: nil, z: nil, frame: .machine, workOffset: nil, envelope: e, retractFirst: true),
                    GoTo.lines(x: 50, y: nil, z: nil, frame: .work, workOffset: work, envelope: e, retractFirst: false)] {
            if case .success(let lines) = bad { throw TestFailure(description: "accepted \(lines)") }
        }
    },

    TestCase(name: "goToRunsAsACheckedProgram") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        try expect(session.setWorkPosition([.x: 0, .y: 0, .z: 0], wcs: 54) == nil)  // work zero at home
        try waitFor(session, "zeroed") { $0.offset(wcs: 54) == Point3(x: -86, y: -0.5, z: -0.5) && $0.gates.run == nil }
        let lines = try GoTo.lines(x: 30, y: -50, z: -10, frame: .work, workOffset: session.snapshot.workOffset,
                                   envelope: session.snapshot.envelope.unwrapped(), retractFirst: true).get()
        try expect(session.run("Go to", lines: lines) == nil)
        try waitFor(session, "arrived") { $0.program?.name == "Go to" && $0.program?.outcome == .completed }
        try expectEqual(mock.position, Point3(x: -56, y: -50.5, z: -10.5))
    },
]
