import Foundation
@testable import MillCore

private func envelopeSettings(travel: Point3, pullOff: Double? = nil) -> MillSettings {
    var settings = MillSettings()
    settings.update(130, travel.x)
    settings.update(131, travel.y)
    settings.update(132, travel.z)
    if let pullOff { settings.update(27, pullOff) }
    return settings
}

let sessionCoreTests: [TestCase] = [
    TestCase(name: "digitalMachineHomesThroughProductionConnection") {
        let session = MillSession()
        session.connect(.simulated)
        defer { session.disconnect() }
        try waitFor(session, "digital ready") { $0.gates.home == nil }
        try expect(session.home() == nil)
        try waitFor(session, "digital homed", timeout: 8) { $0.homed && $0.homingSince == nil && $0.gates.jog == nil }
    },

    TestCase(name: "envelopeUsesControllerPullOffOrDefaultMargin") {
        let travel = Point3(x: 100, y: 200, z: 80)
        let defaultEnvelope = try MillEnvelope.from(envelopeSettings(travel: travel)).unwrapped()
        try expectEqual(defaultEnvelope.x, -99.5 ... -0.5)
        try expectEqual(defaultEnvelope.y, -199.5 ... -0.5)
        try expectEqual(defaultEnvelope.z, -79.5 ... -0.5)

        let envelope = try MillEnvelope.from(envelopeSettings(travel: travel, pullOff: 2)).unwrapped()
        try expectEqual(envelope.x, -98.0 ... -2.0)
        try expectEqual(envelope.y, -198.0 ... -2.0)
        try expectEqual(envelope.z, -78.0 ... -2.0)
    },

    TestCase(name: "envelopeRejectsPullOffThatInvertsAnyAxis") {
        for travel in [Point3(x: 3, y: 100, z: 100), Point3(x: 100, y: 3, z: 100), Point3(x: 100, y: 100, z: 3)] {
            try expect(MillEnvelope.from(envelopeSettings(travel: travel, pullOff: 2)) == nil,
                       "accepted a 2 mm margin at both ends of \(travel)")
        }
        // Touching margins still form a valid range with exactly one allowed position.
        let touching = try MillEnvelope.from(envelopeSettings(travel: Point3(x: 4, y: 100, z: 100), pullOff: 2)).unwrapped()
        try expectEqual(touching.x, -2.0 ... -2.0)
    },

    TestCase(name: "envelopeRejectsNonfiniteTravelAndPullOff") {
        for invalid in [Double.nan, .infinity, -.infinity] {
            for travel in [Point3(x: invalid, y: 100, z: 100), Point3(x: 100, y: invalid, z: 100), Point3(x: 100, y: 100, z: invalid)] {
                try expect(MillEnvelope.from(envelopeSettings(travel: travel)) == nil)
            }
            try expect(MillEnvelope.from(envelopeSettings(travel: Point3(x: 100, y: 100, z: 100), pullOff: invalid)) == nil)
        }
    },

    TestCase(name: "invalidEnvelopeRefusesMotionAndWorkOffsetChanges") {
        var options = MockGRBL.Options()
        options.replyOverride = { line in
            guard line == "$$" else { return nil }
            // 50 mm at each end exceeds the controller's X and Z travel.
            return (MockGRBL.standardSettings.map { n, value, _ in
                "$\(n)=\(n == 27 ? 50 : value)"
            } + ["ok"]).joined(separator: "\r\n")
        }
        let mock = MockGRBL(options: options)
        let session = MillSession()
        session.connect(.simulated, transport: mock)
        defer { session.disconnect() }
        try waitFor(session, "invalid settings refusal") {
            $0.link == .connected && $0.parserState != nil && $0.status != nil && $0.gates.home != nil
        }
        let snapshot = session.snapshot
        try expect(snapshot.envelope == nil)
        let problem = try MillSession.settingsProblem(snapshot.settings).unwrapped()
        try expect(problem.contains("$130–$132") && problem.contains("$27"), problem)
        let refusal = MillRefusal.settings(problem)
        try expectEqual(snapshot.gates.home, refusal)
        try expectEqual(snapshot.gates.jog, refusal)
        try expectEqual(snapshot.gates.run, refusal)
        try expectEqual(snapshot.gates.setup, refusal)
        try expectEqual(session.home(), refusal)
        try expectEqual(session.jog(JogRequest(axis: .x, distance: 1, feed: 100)), refusal)
        try expectEqual(session.setWorkPosition([.x: 0], wcs: 54), refusal)
        try expect(!mock.receivedLines.contains { $0 == "$H" || $0.hasPrefix("$J=") || $0.hasPrefix("G10") })
    },
]
