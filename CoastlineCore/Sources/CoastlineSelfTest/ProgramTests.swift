import MillCore
import CoastlineCore
import Foundation
import simd

/// Both programs follow the same path (mm), move for move.
private func samePath(_ a: GCodeReader.Program, _ b: GCodeReader.Program, tolerance: Double = 0.0001) throws {
    try expectEqual(a.moves.count, b.moves.count)
    for (m, n) in zip(a.moves, b.moves) {
        guard m.role == n.role, m.motion == n.motion, simd_distance(m.position, n.position) <= tolerance,
              abs(m.i - n.i) <= tolerance, abs(m.j - n.j) <= tolerance, abs(m.feed - n.feed) <= 0.001 else {
            throw TestFailure(description: "moves differ: \(m) vs \(n)")
        }
    }
}

let programTests: [TestCase] = [
    TestCase(name: "readerFollowsUnitsModesAndArcs") {
        let p = GCodeReader.read("""
        G90 G94 G17
        G20
        M3 S8000
        G0 X0.1 Y-1 (start)
        Z0.25
        G1 Z-0.05 F24.
        G2 X0.3 Y-1 I0.1 J0
        G3 X0.1 Y-1 R0.1
        G91 G1 X-0.1 F10
        G90 G21 G53 G0 Z-1.
        G4 P0.5
        M30
        """)
        try expect(p.usesInches)
        try expectEqual(p.moves.count, 6)
        try expectEqual(p.machineMoves, 1)
        try expectEqual(p.dwell, 0.5)
        try expectEqual(p.spindleSpeeds, [8000])
        let arc = p.moves[3]
        try expectEqual(arc.motion, .arcCW)
        try expect(abs(arc.x - 7.62) < 1e-9 && abs(arc.i - 2.54) < 1e-9)
        try expect(abs(arc.feed - 609.6) < 1e-9, "24 in/min")
        let r = p.moves[4]  // R arc from X0.3 back to X0.1, CCW, radius 0.1 in
        try expect(abs((r.x - r.i - 0) - 7.62) < 1e-6 || abs(r.i + 2.54) < 1e-6, "centre half way: \(r)")
        try expect(abs(p.moves[5].x - 0) < 1e-9, "G91 X-0.1 from X0.1")
        try expect(p.issues.isEmpty, "\(p.issues)")
    },

    TestCase(name: "readerKeepsProbingAndMacrosApart") {
        let p = GCodeReader.read("""
        G21 G90 G55
        G38.3 Z-25 F30 (probe Z)
        G10 L20 P2 Z0
        M100 G56XG57XG55X (midpoint)
        G0 G90 G53 Z-1.
        """)
        try expectEqual(p.probes, 1)
        try expectEqual(p.offsetWrites, 1)
        try expectEqual(p.macros, [100])
        try expectEqual(p.workOffsets, [55])
        try expectEqual(p.moves.count, 1)
        try expectEqual(p.moves[0].role, .plunge)
        try expect(p.issues.isEmpty, "\(p.issues)")
    },


    TestCase(name: "optionsPickSetupsAndSteps") {
        var job = ProgramJob(id: "t", title: "Two setups", summary: "")
        func choice(_ id: String) -> ProgramJob.Choice { ProgramJob.Choice(id: id, title: id) }
        func when(_ option: String, _ values: [String]) -> [ProgramJob.Condition] { [ProgramJob.Condition(option: option, oneOf: values)] }
        func run(_ id: String, _ program: String, _ conditions: [ProgramJob.Condition] = []) -> ProgramJob.Step {
            ProgramJob.Step(id: id, kind: .run, title: id, program: program, when: conditions)
        }
        job.options = [
            ProgramJob.Option(id: "start", title: "Start", choices: [choice("full"), choice("second")], defaultChoice: "full"),
            ProgramJob.Option(id: "size", title: "Size", choices: [choice("small"), choice("large")], defaultChoice: "small",
                              when: when("start", ["full"])),
        ]
        job.setups = [
            ProgramJob.Setup(id: "one", title: "One", summary: "", when: when("start", ["full"]), steps: [
                run("a", "pa"), run("b-small", "pb", when("size", ["small"])), run("b-large", "pc", when("size", ["large"])),
            ]),
            ProgramJob.Setup(id: "two", title: "Two", summary: "", steps: [run("c", "pd")]),
        ]
        func programs(_ chosen: [String: String]) -> [String] { job.plan(chosen).flatMap(\.steps).compactMap(\.program) }
        try expectEqual(programs([:]), ["pa", "pb", "pd"])
        try expectEqual(programs(["size": "large"]), ["pa", "pc", "pd"])
        try expectEqual(programs(["start": "second"]), ["pd"])
        try expectEqual(job.setup(running: "pc", ["size": "large"])?.id, "one")
        try expect(job.setup(running: "pc", [:]) == nil, "not run with the default size")
    },

    // Checks any job folder before it ships: COASTLINE_JOB=/path/to/job scripts/selftest.sh Program
    TestCase(name: "jobFolderIsReady") {
        guard let path = ProcessInfo.processInfo.environment["COASTLINE_JOB"] else { throw Skip(reason: "set COASTLINE_JOB to a job folder") }
        let folder = URL(fileURLWithPath: path)
        let job = try ProgramJob.load(folder)
        try expectEqual(job.problems(in: folder), [])
        for option in job.options {
            for c in option.choices { try expect(!job.plan([option.id: c.id]).isEmpty, "\(option.id)=\(c.id) runs nothing") }
        }
        for p in job.programs {
            let read = GCodeReader.read(try String(contentsOf: folder.appendingPathComponent(p.file), encoding: .utf8))
            try expect(!read.usesInches, "\(p.file) still uses inches")
            try expect(read.issues.isEmpty, "\(p.file): \(read.issues)")
            try expect(read.spindleSpeeds.allSatisfy { $0 <= MachineProfile.standard.spindleRPM.upperBound }, "\(p.file) spindle \(read.spindleSpeeds)")
        }
    },

    TestCase(name: "jobRunsOnTheSimulatedMill") {
        // Every choice of the job's options, its programs in order, as the runner sends them.
        guard let path = ProcessInfo.processInfo.environment["COASTLINE_JOB"] else { throw Skip(reason: "set COASTLINE_JOB to a job folder") }
        let folder = URL(fileURLWithPath: path)
        let job = try ProgramJob.load(folder)
        var combinations: [[String: String]] = [[:]]
        for option in job.options {
            combinations = combinations.flatMap { c in option.choices.map { c.merging([option.id: $0.id]) { $1 } } }
        }
        var plans: Set<[String]> = []
        for chosen in combinations.map(job.choices) {
            let programs = job.plan(chosen).flatMap(\.steps).filter { $0.kind == .run }.compactMap { job.program($0.program) }
            guard plans.insert(programs.map(\.id)).inserted else { continue }
            let session = MillSession()
            defer { session.disconnect() }
            session.connect(.simulated)
            let ready = Date().addingTimeInterval(10)
            while session.snapshot.gates.home != nil, Date() < ready { usleep(20_000) }
            for (k, program) in programs.enumerated() {
                let lines = try String(contentsOf: folder.appendingPathComponent(program.file), encoding: .utf8).components(separatedBy: "\n")
                let name = "\(k + 1) \(program.id)"
                if let refusal = session.runJob(name, lines: lines) {
                    throw TestFailure(description: "\(chosen) \(program.id) refused: \(refusal.text)")
                }
                let end = Date().addingTimeInterval(900)
                while Date() < end {
                    if let p = session.snapshot.program, p.name == name, p.outcome != .running { break }
                    usleep(20_000)
                }
                guard let p = session.snapshot.program, p.name == name, p.outcome == .completed else {
                    let log = session.console(after: 0).map(\.text).suffix(8).joined(separator: " | ")
                    throw TestFailure(description: "\(chosen) \(program.id): \(session.snapshot.program?.outcome as Any) — \(log)")
                }
            }
        }
        try expect(!plans.isEmpty)
        print("      \(plans.count) different runs, all completed")
    },


]
