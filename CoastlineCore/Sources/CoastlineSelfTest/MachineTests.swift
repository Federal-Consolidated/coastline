import CoastlineCore
import MillCore
import Foundation

let machineTests: [TestCase] = [
    TestCase(name: "envelopeMatchesTheSoftLimitWindow") {
        let m = MachineProfile.standard
        // The sender's soft-limit window for travel (86.5, 241.5, 78.5): X −86…−0.5, Y/Z −travel…−0.5.
        try expectEqual(m.machineEnvelope.x, -(m.travel.x - 0.5) ... -0.5)
        try expectEqual(m.machineEnvelope.y, -m.travel.y ... -0.5)
        try expectEqual(m.machineEnvelope.z, -m.travel.z ... -0.5)
        try expect(m.machineEnvelope.contains(Vec3(-78, -165, -12.8)), "Universal Clamp edge-find start")
        try expect(!m.machineEnvelope.contains(Vec3(0, -100, -10)), "X 0 is past the homing pull-off")
    },
    TestCase(name: "spindleRangeIsTheUsableOne") {
        let m = MachineProfile.standard
        try expect(m.isUsableRPM(1500) && m.isUsableRPM(8000))
        try expect(!m.isUsableRPM(1400), "doesn't spin below 1500")
        try expect(!m.isUsableRPM(8500), "clamped above 8000")
    },
    TestCase(name: "toolChangeMovesAreValidGCode") {
        let program = GCodeProgram(source: MachineProfile.standard.toolChangeMoves)
        try expectEqual(program.lines.first?.isHome, true)
        for line in MachineProfile.standard.toolChangeMoves {
            try expect(line.count <= MachineProfile.standard.maxLineLength)
        }
    },
    TestCase(name: "profileRoundTripsThroughJSON") {
        let data = try JSONEncoder().encode(MachineProfile.standard)
        try expectEqual(try JSONDecoder().decode(MachineProfile.self, from: data), .standard)
    },
    TestCase(name: "toolChangePoseFollowsTheMakersMoves") {
        // $H, Z-1, Y-58, X-1, Z-60: the spindle back first, then over, the table down, the spindle out.
        let w = MachineProfile.standard.toolChangeWaypoints
        try expectEqual(w.count, 4)
        try expect(w[0].z == -1 && w[1].y == -58 && w[2].x == -1 && w[3] == SIMD3(-1, -58, -60), "\(w)")
        try expect(MachineProfile.standard.toolChangePose == SIMD3(-1, -58, -60))
    },
]
