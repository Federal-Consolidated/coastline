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

private func position(_ mock: MockGRBL, _ session: MillSession, at point: Point3) throws {
    mock.setPosition(point)
    try waitFor(session, "position") { $0.status?.machinePosition == point && $0.gates.jog == nil }
}

private func jogWord(_ line: String, _ letter: String) -> Double? {
    line.split(separator: " ").first { $0.hasPrefix(letter) }.flatMap { Double($0.dropFirst()) }
}

/// Pauses the I/O thread at deterministic boundaries without blocking real-time writes.
private final class JogPauseTransport: SerialTransport, @unchecked Sendable {
    let mock = millMock(timedJogs: true)
    let readPaused = DispatchSemaphore(value: 0)
    let resumeRead = DispatchSemaphore(value: 0)
    let jogPaused = DispatchSemaphore(value: 0)
    let resumeJog = DispatchSemaphore(value: 0)
    let pauseRead = Locked(false)
    let pauseJog = Locked(false)
    let events = Locked([String]())

    var isOpen: Bool { mock.isOpen }
    func open() throws { try mock.open() }
    func close() { mock.close() }
    func write(_ bytes: [UInt8]) throws {
        let line = String(decoding: bytes, as: UTF8.self)
        if line.hasPrefix("$J="), pauseJog.withLock({ flag in defer { flag = false }; return flag }) {
            jogPaused.signal()
            _ = resumeJog.wait(timeout: .now() + 3)
        }
        if line.hasPrefix("$J=") { events.withLock { $0.append("jog") } }
        if bytes == [0x85] { events.withLock { $0.append("cancel") } }
        if bytes == [UInt8(ascii: "!")] { events.withLock { $0.append("hold") } }
        try mock.write(bytes)
    }
    func readAvailable() -> [UInt8] {
        if pauseRead.withLock({ flag in defer { flag = false }; return flag }) {
            readPaused.signal()
            _ = resumeRead.wait(timeout: .now() + 3)
        }
        return mock.readAvailable()
    }
}

private func homedTransport(_ transport: JogPauseTransport) throws -> MillSession {
    let session = MillSession()
    session.connect(.simulated, transport: transport)
    try waitFor(session, "transport ready") { $0.link == .connected && $0.gates.home == nil }
    try expect(session.home() == nil)
    try waitFor(session, "transport homed") { $0.homed && $0.gates.jog == nil }
    try position(transport.mock, session, at: Point3(x: -40, y: -100, z: -20))
    return session
}

private func cancellingQueuedJog(feedHold: Bool) throws {
    let transport = JogPauseTransport()
    let session = try homedTransport(transport)
    defer { transport.resumeRead.signal(); session.disconnect() }
    let before = transport.mock.position
    transport.pauseRead.current = true
    try expect(transport.readPaused.wait(timeout: .now() + 1) == .success)
    try expect(session.jog(JogRequest(x: 5, y: -5, feed: 600)) == nil)
    if feedHold { session.feedHold() } else { session.jogCancel() }
    transport.resumeRead.signal()
    if feedHold {
        try waitFor(session, "hold before resume") { $0.gates.resume == nil }
        try expect(session.resume() == nil)
    }
    try waitFor(session, "cancelled queued jog idle") { $0.state == "Idle" }
    usleep(350_000)
    try expect(jogLines(transport.mock).isEmpty, "an old step escaped cancellation")
    try expectEqual(transport.mock.position, before)
}

private func cancellingJogDuringWrite(feedHold: Bool) throws {
    let transport = JogPauseTransport()
    let session = try homedTransport(transport)
    defer { transport.resumeJog.signal(); session.disconnect() }
    let before = transport.mock.position
    transport.pauseJog.current = true
    try expect(session.jog(JogRequest(x: 5, y: -5, feed: 600)) == nil)
    try expect(transport.jogPaused.wait(timeout: .now() + 1) == .success)
    if feedHold { session.feedHold() } else { session.jogCancel() }
    // The real-time byte arrives before the interrupted old line is written.
    let expected = feedHold ? "hold" : "cancel"
    try waitFor(session, "immediate real-time cancellation") { _ in transport.events.current.contains(expected) }
    transport.resumeJog.signal()
    try waitFor(session, "I/O cancellation after the old write") { _ in
        let events = transport.events.current
        guard let sent = events.lastIndex(of: "jog"), let cancelled = events.lastIndex(of: "cancel") else { return false }
        return cancelled > sent
    }
    if feedHold {
        try waitFor(session, "held after pending jog") { $0.gates.resume == nil }
        try expect(session.resume() == nil)
    }
    try waitFor(session, "cancelled old jog idle") { $0.state == "Idle" }
    let stopped = transport.mock.position
    try expect(hypot(stopped.x - before.x, stopped.y - before.y) < 0.5)
    usleep(350_000)
    try expectEqual(transport.mock.position, stopped)
    try expectEqual(jogLines(transport.mock).count, 1)
}

let manualControlTests: [TestCase] = [
    TestCase(name: "legacyZeroDistanceJogRetainsItsAxisWhenEdited") {
        var request = JogRequest(axis: .y, distance: 0, feed: 100)
        try expectEqual(request.axis, .y)
        request.distance = -2
        try expectEqual(request, JogRequest(y: -2, feed: 100))
        request.axis = .z
        try expectEqual(request, JogRequest(z: -2, feed: 100))
        request.distance = 0
        try expectEqual(request.axis, .z)
        request.distance = 3
        try expectEqual(request, JogRequest(z: 3, feed: 100))
    },
    TestCase(name: "lockCancellationDiscardsQueuedStep") { try cancellingQueuedJog(feedHold: false) },
    TestCase(name: "feedHoldDiscardsQueuedStepEvenAfterResume") { try cancellingQueuedJog(feedHold: true) },
    TestCase(name: "lockCancellationFollowsAJogAlreadyBeingWritten") { try cancellingJogDuringWrite(feedHold: false) },
    TestCase(name: "feedHoldCancelsAJogAlreadyBeingWritten") { try cancellingJogDuringWrite(feedHold: true) },
    TestCase(name: "newStepAfterCancellationCanStillRun") {
        let transport = JogPauseTransport()
        let session = try homedTransport(transport)
        defer { transport.resumeRead.signal(); session.disconnect() }
        transport.pauseRead.current = true
        try expect(transport.readPaused.wait(timeout: .now() + 1) == .success)
        try expect(session.jog(JogRequest(x: 5, y: -5, feed: 600)) == nil)
        session.jogCancel()
        try expect(session.jog(JogRequest(x: -2, y: 3, feed: 600)) == nil)
        transport.resumeRead.signal()
        try waitFor(session, "new step after unlocking") { $0.status?.machinePosition == Point3(x: -42, y: -97, z: -20) }
        try expectEqual(jogLines(transport.mock), ["$J=G21 G91 X-2.000 Y3.000 F600"])
    },
    TestCase(name: "diagonalStepIsOneCoordinatedJog") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        try position(mock, session, at: Point3(x: -40, y: -100, z: -20))
        try expect(session.jog(JogRequest(x: -5, y: 5, feed: 600)) == nil)
        try waitFor(session, "diagonal arrived") { $0.status?.machinePosition == Point3(x: -45, y: -95, z: -20) }
        try expectEqual(jogLines(mock), ["$J=G21 G91 X-5.000 Y5.000 F600"])
    },

    TestCase(name: "diagonalStepStopsBothAxesAtTheFirstBoundary") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        try position(mock, session, at: Point3(x: -1.5, y: -100, z: -20))
        try expect(session.jog(JogRequest(x: 10, y: 20, feed: 600)) == nil)
        try waitFor(session, "clipped diagonal") { $0.status?.machinePosition == Point3(x: -0.5, y: -98, z: -20) && $0.gates.jog == nil }
        try expectEqual(jogLines(mock), ["$J=G21 G91 X1.000 Y2.000 F600"])

        // An outward diagonal at X's boundary must not turn into a pure Y move.
        try expect(session.jog(JogRequest(x: 1, y: 1, feed: 600)) == nil)
        usleep(350_000)
        try expectEqual(jogLines(mock).count, 1)
        try expectEqual(mock.position, Point3(x: -0.5, y: -98, z: -20))
    },

    TestCase(name: "diagonalFeedRespectsEachAxisComponentLimit") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        try position(mock, session, at: Point3(x: -40, y: -100, z: -20))
        try expect(session.jog(JogRequest(x: 10, y: 10, feed: 5000)) == nil)
        try waitFor(session, "feed capped diagonal") { $0.status?.machinePosition == Point3(x: -30, y: -90, z: -20) }
        let line = try jogLines(mock).first.unwrapped()
        let feed = try jogWord(line, "F").unwrapped()
        try expectEqual(feed, 3592) // floor(2540 * sqrt(2)); X's component stays <= $110.
        try expect(feed / sqrt(2) <= 2540)
    },

    TestCase(name: "diagonalHoldUsesPathSpeedAndCancelsOnRelease") {
        let mock = millMock(timedJogs: true)
        let session = try homed(mock)
        defer { session.disconnect() }
        let start = Point3(x: -40, y: -100, z: -20)
        try position(mock, session, at: start)
        try expect(session.startHold(x: 1, y: -1, feed: 1200) == nil)
        hold(session, for: 0.8)
        try expect(session.snapshot.holding)
        let moved = mock.position
        try expect(moved.x > start.x + 5 && moved.y < start.y - 5)
        try expect(abs((moved.x - start.x) + (moved.y - start.y)) < 0.01)
        session.endHold()
        try waitFor(session, "diagonal released") { $0.state == "Idle" && !$0.holding }
        let stopped = mock.position, count = jogLines(mock).count
        usleep(300_000)
        try expectEqual(mock.position, stopped)
        try expectEqual(jogLines(mock).count, count)
        try expectEqual(commandBytes(mock).last, 0x85)
        for line in jogLines(mock) {
            let x = try jogWord(line, "X").unwrapped(), y = try jogWord(line, "Y").unwrapped()
            try expect(abs(x + y) < 0.001, line)
            try expect(hypot(x, y) <= 1200 / 60 * MillSession.holdSegment + 0.001, line)
        }
    },

    TestCase(name: "diagonalHoldDoesNotSlideAlongTheBoundary") {
        let mock = millMock(timedJogs: true)
        let session = try homed(mock)
        defer { session.disconnect() }
        try position(mock, session, at: Point3(x: -85, y: -239, z: -20))
        try expect(session.startHold(x: -1, y: -1, feed: 1200) == nil)
        hold(session, for: 0.7)
        try waitFor(session, "first diagonal boundary") { $0.state == "Idle" }
        try expectEqual(mock.position, Point3(x: -86, y: -240, z: -20))
        try expect(session.snapshot.lastAlarm == nil && session.snapshot.lastError == nil)
        session.endHold()
    },

    TestCase(name: "diagonalHoldWatchdogCancelsBothAxes") {
        let mock = millMock(timedJogs: true)
        let session = try homed(mock)
        defer { session.disconnect() }
        let start = Point3(x: -40, y: -100, z: -20)
        try position(mock, session, at: start)
        try expect(session.startHold(x: 1, y: -1, feed: 600) == nil)
        try waitFor(session, "diagonal dead man", timeout: 2) { !$0.holding && $0.lastError?.contains("stopped confirming") == true }
        try waitFor(session, "diagonal idle") { $0.state == "Idle" }
        let stopped = mock.position
        try expect(hypot(stopped.x - start.x, stopped.y - start.y) < 7)
        try expectEqual(commandBytes(mock).last, 0x85)
        usleep(300_000)
        try expectEqual(mock.position, stopped)
    },

    TestCase(name: "invalidJogVectorsNeverReachTheController") {
        let mock = millMock()
        let session = try homed(mock)
        defer { session.disconnect() }
        for request in [JogRequest(feed: 100), JogRequest(x: .nan, y: 1, feed: 100),
                        JogRequest(x: 1, z: .infinity, feed: 100), JogRequest(y: 1, feed: .infinity),
                        JogRequest(y: 1, feed: 0), JogRequest(y: 1, feed: -100)] {
            try expect(session.jog(request) != nil)
            try expect(session.startHold(x: request.x, y: request.y, z: request.z, feed: request.feed) != nil)
        }
        try expect(session.startHold(.x, direction: 0, feed: 100) != nil)
        try expect(session.startHold(.x, direction: .nan, feed: 100) != nil)
        usleep(300_000)
        try expect(jogLines(mock).isEmpty)
    },

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
