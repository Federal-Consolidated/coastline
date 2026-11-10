import simd
import CoastlineCore
import MillCore
import Foundation

private func mockConnection(_ mock: MockGRBL) throws -> MillConnection {
    try MillConnection.connect(device: MillDevice(path: "/dev/mock", serialNumber: "MOCK"), transport: mock, log: MachineLog(),
                               isManualOperation: { false })
}


/// The built job's G-code for a step (what the .crproj export used to hold).
private func gcodeLines(_ built: (jobs: [Job], files: [String: Data]), _ step: Step) throws -> [String] {
    guard let data = built.files[step.gcodePath] else { throw TestFailure(description: "no G-code for \(step.title)") }
    return String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
}

let guidedTests: [TestCase] = [
    TestCase(name: "markdownIsMadeSafeForTheCutcodeFormat") {
        let safe = GuidedJobBuilder.safeMarkdown("Tip: keep it clean\nOK!\n**Bold:** fine\nnormal line")
        let lines = safe.split(separator: "\n").map(String.init)
        try expectEqual(lines[0], "› Tip: keep it clean")
        try expectEqual(lines[1], "OK! ")
        try expectEqual(lines[2], "**Bold:** fine")
    },
    TestCase(name: "airCutLiftsZAndNeverStartsTheSpindle") {
        let g = "G90 G17 G21\nG53 G0 G90 Z-1.\nS0 M3\nG4 P1.\nS5000\nS8000 M3\nG0 X1 Y2 Z3\nG1 Z-1 F100\nG2 X3 Y2 Z-1 I1 J0\nG53 G0 G90 Z-1.\nM5\n"
        let a = AirCut.make(from: g, lift: 10)
        try expect(!a.split(separator: "\n").contains { !$0.hasPrefix("(") && ($0.contains("M3") || $0.hasPrefix("S")) })
        try expect(a.contains("G1 Z9 F100") && a.contains("Z13") && a.contains("G53 G0 G90 Z-1."), a)
    },
    TestCase(name: "guidedProjectReadsBackInThePackageParser") {
        let al = MaterialLibrary.material(id: "al-6061")!
        let tool = Tool(name: "1/4\" flat end mill", kind: .flatEndMill, diameter: 6.35, shankDiameter: 6.35, flutes: 3,
                        fluteLength: 12.7, stickout: 28.575, overallLength: 50.8)
        let stock = StockItem(materialID: "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20)
        let data = FeedsEngine.compute(tool: tool, material: al, kind: .facing)
        let program = FacingProgram.make(width: 80, length: 150, depth: 0.25, tool: tool, data: data, machine: .standard, title: "Test #1")
        let input = GuidedJobBuilder.Input(
            partName: "Pendant", material: al, stock: stock, stockSize: SIMD3(80, 150, 20), setupName: "OP1",
            programs: [.init(tool: tool, gcode: program, operationNames: ["Facing"], minutes: 7)],
            checkpoints: [.init(afterProgram: 0, what: "Stock face flatness", expected: 0, tolerance: 0.02)],
            measuring: [MeasuringTool(name: "Digital caliper", kind: .caliper)], setupImage: Data([0x89, 0x50, 0x4E, 0x47]))
        let project = GuidedJobBuilder.build(input)
        try expectEqual(project.jobs.map(\.title), ["OP1 · Pendant"])
        let job = project.jobs[0]
        try expect(job.steps.count > 20, "\(job.steps.count) steps")
        try expect(job.steps.contains { $0.gcodePath == "Code/set_x_centre.nc" }, "edge finding to centre")
        // Popups loop or skip as designed.
        let air = try unwrap(job.steps.firstIndex { $0.title == "Air Cut First?" })
        try expectEqual(job.steps[air].popupNoStep, "+2")
        try expectEqual(job.steps[air + 2].title, "Cut · Program 1")
        let measure = try unwrap(job.steps.firstIndex { $0.title.hasPrefix("Measure") })
        try expectEqual(job.steps[measure].popupYesStep, "+2")
        try expectEqual(job.steps[measure + 1].goTo, "-1")
        // The programs in the project pass the safety validator.
        let v = GCodeValidator()
        let box = (SIMD3<Double>(-40, -75, -20), SIMD3<Double>(40, 75, 0))
        let cut = try gcodeLines(project, job.steps[air + 2]).joined(separator: "\n")
        try expect(v.validate(cut, context: .init(stockMin: box.0, stockMax: box.1, tool: tool)).passed)
        var ctx = GCodeValidator.Context(stockMin: box.0, stockMax: box.1, tool: tool)
        ctx.airCut = true
        let airG = try gcodeLines(project, job.steps[air + 1]).joined(separator: "\n")
        let r = v.validate(airG, context: ctx)
        try expect(r.passed && r.minZ > 9, "air cut stays above the work: \(r.issues.map(\.message)) minZ \(r.minZ)")
    },
]

let probingMethodTests: [TestCase] = [
]

let feasibilityTests: [TestCase] = [
    TestCase(name: "customHoldingExportDoesNotInventAClampKitOrAssumeTheFlipPosition") {
        let tool = Tool(name: "Flat", kind: .flatEndMill, diameter: 3.175, shankDiameter: 3.175, flutes: 2,
                        fluteLength: 12, stickout: 25, overallLength: 50)
        let stock = StockItem(materialID: "al-6061", sizeX: 60, sizeY: 30, sizeZ: 10)
        var input = GuidedJobBuilder.Input(partName: "Pocket block", material: MaterialLibrary.material(id: "al-6061")!,
            stock: stock, stockSize: SIMD3(30, 60, 10), setupName: "Custom", programs: [
                .init(tool: tool, gcode: "G21 G90\nM5\n", operationNames: ["Pocket"], minutes: 1),
                .init(tool: tool, gcode: "G21 G90\nM5\n", operationNames: ["Back pocket"], minutes: 1, side: 1)],
            checkpoints: [], measuring: [], setupImage: nil)
        var custom = Setup.CustomFixture()
        custom.name = "Test vise"
        custom.notes = "Grip on the uncut lower band."
        custom.height = 12
        input.customHolding = custom
        let project = GuidedJobBuilder.build(input)
        let job = try unwrap(project.jobs.last)
        let mount = try unwrap(job.steps.first { $0.title == "Mount the Stock" }).markdown
        try expect(mount.contains("Test vise") && mount.contains(custom.notes) && mount.contains("not included in collision checks"), mount)
        try expect(!mount.contains("universal clamp") && !mount.contains("lower jaw") && !mount.contains("T-slot"), mount)
        let flip = try unwrap(job.steps.first { $0.title == "Flip the Stock" }).markdown
        try expect(flip.contains("Test vise") && flip.contains("not assumed") && !flip.contains("lower jaw"), flip)
        let done = try unwrap(job.steps.first { $0.title == "Done" }).markdown
        try expect(!done.contains("thin web"), done)
    },
    TestCase(name: "referenceBoresSitInTheFrameOffTheCentreLine") {
        // The wallet: 70 × 101.6 mm in an 80 × 169.5 × 20 bar, the jaws' strips at both ends.
        let strips: [(min: SIMD2<Double>, max: SIMD2<Double>)] = [
            (SIMD2(-70, -114.75), SIMD2(-30, -62.725)), (SIMD2(-70, 62.725), SIMD2(-30, 114.75)),
            (SIMD2(10, -114.75), SIMD2(70, -62.725)), (SIMD2(10, 62.725), SIMD2(70, 114.75)),
        ]
        let plan = try unwrap(ReferenceBores.place(stock: SIMD3(80, 169.5, 20), partMin: SIMD2(-35, -50.8), partMax: SIMD2(35, 50.8),
                                                   clear: 15, keepOut: strips, xReach: -43...43, toolDiameter: 6.35, maxDepth: 26))
        try expectEqual(plan.centresA.count, 2)
        let a = plan.centresA
        try expect(abs(a[0].x - a[1].x) < 1e-9 && abs(a[0].x) >= 4, "off the centre line, same X: \(a)")
        try expect(abs(a[0].y + a[1].y) < 1e-9, "symmetric about the part: \(a)")
        try expect(abs(a[0].y) - 5 >= 50.8 + 15 && abs(a[0].y) + 5 <= 169.5 / 2 - 2, "in the frame: \(a)")
        try expectEqual(plan.depthA, 19)
        try expect(plan.windowDepth > 1 && plan.probeZ < -plan.windowDepth, "the probe touches below the window")
        try expectEqual(plan.centresB[0], SIMD2(a[0].x, -a[0].y))
        // No frame: nothing.
        try expect(ReferenceBores.place(stock: SIMD3(80, 110, 20), partMin: SIMD2(-35, -50.8), partMax: SIMD2(35, 50.8),
                                        clear: 15, toolDiameter: 6.35, maxDepth: 26) == nil)
        // Every line fits GRBL's 79 characters; the M-codes parse in the sender.
        for g in [ReferenceBores.boreProgram(plan, bore: 0, toolDiameter: 6.35, electrical: true), ReferenceBores.zeroProgram(plan),
                  ReferenceBores.topProgram(z: -0.25), ReferenceBores.edgeProgram(axis: "X", toward: 1, store: 2)] {
            for line in g.split(separator: "\n") { try expect(line.count <= 79, "too long: \(line)") }
            _ = GCodeProgram(source: g.components(separatedBy: "\n"))
        }
    },
    TestCase(name: "referenceBoresSetSideBZero") {
        // Side B's bores probed 0.4 mm right and 0.7 mm low of where the rough zero put them:
        // the zero program moves G54 by exactly that, after its checks pass.
        let plan = ReferenceBores.Plan(centresA: [SIMD2(-7, -74), SIMD2(-7, 74)], depthA: 19, thickness: 20)
        let b = plan.centresB
        let origin = Point3(x: -40, y: -120, z: -30)  // the rough G54
        let shift = (x: 0.4, y: -0.7)
        let mock = MockGRBL()
        mock.setOffset(54, origin)
        mock.setOffset(55, Point3(x: origin.x + b[0].x + shift.x, y: origin.y + b[0].y + shift.y, z: 0))
        mock.setOffset(56, Point3(x: origin.x + b[1].x + shift.x, y: origin.y + b[1].y + shift.y, z: 0))
        let c = try mockConnection(mock)
        defer { c.disconnect() }
        let zero = ReferenceBores.zeroProgram(plan).components(separatedBy: "\n").filter { !$0.contains("G0 X") }
        try c.executeProgram(GCodeProgram(source: zero).lines)
        try expect(abs(mock.offset(54).x - (origin.x + shift.x)) < 1e-3 && abs(mock.offset(54).y - (origin.y + shift.y)) < 1e-3,
                   "G54 \(mock.offset(54))")
        // Turned: bore 2 sits 0.3 mm further in X than bore 1 → the step stops.
        mock.setOffset(56, Point3(x: origin.x + b[1].x + shift.x + 0.3, y: origin.y + b[1].y + shift.y, z: 0))
        try expectThrows { try c.executeProgram(GCodeProgram(source: zero).lines) }
    },
    TestCase(name: "threadsPickTheirHolesAndCutters") {
        let m3 = try unwrap(ThreadSpec.named("M3"))
        try expectEqual(m3.tapDrill, 2.5)
        try expect(m3.fits(hole: 2.5) && m3.fits(hole: 2.45) && !m3.fits(hole: 3.0) && !m3.fits(hole: 2.2), "M3 holes")
        try expectEqual(ThreadSpec.likely(forHole: 3.3)?.name, "M4")
        try expectEqual(ThreadSpec.likely(forHole: 4.2)?.name, "M5")
        try expect(ThreadSpec.likely(forHole: 3.4) == nil, "a Ø3.4 clearance hole isn't threaded")
        // The catalog's thread mills: real Harvey items, each cutting its own thread only.
        let mills = ToolCatalog.suggestions.filter { $0.kind == .threadMill }
        try expectEqual(mills.map(\.partNumber), ["890322", "737624", "890326", "890328"])
        let m3mill = try unwrap(mills.first { $0.partNumber == "737624" })
        try expect(m3.canBeCut(by: m3mill), "737624 cuts M3")
        try expect(!(try unwrap(ThreadSpec.named("M4"))).canBeCut(by: m3mill), "but not M4 (its pitch)")
        try expect(!(try unwrap(ThreadSpec.named("M2.5"))).canBeCut(by: m3mill), "nor M2.5 (too big)")
    },
    TestCase(name: "surfaceProbingFollowsTheFace") {
        // A flat engraving 0.15 deep on a face 0.5 below Z0 (faced), in two passes.
        let cuts = [SIMD3(0, -3, -0.575), SIMD3(0, 3, -0.575), SIMD3(0, -3, -0.65), SIMD3(1.5, 3, -0.65), SIMD3(-1.5, 0, -0.65),
                    SIMD3(1.5, -3, -0.65), SIMD3(0, 3, -0.65)]
        let flat = SurfaceProbe.flatFace(cuts: cuts, depth: 0.15)
        try expect(abs((flat.face ?? 99) + 0.5) < 1e-9, "face \(flat)")
        try expect(SurfaceProbe.flatFace(cuts: [SIMD3(0, 0, -0.65), SIMD3(3, 0, -0.95)], depth: 0.15).face == nil, "a dome isn't flat")
        let points = try unwrap(SurfaceProbe.points(cuts: cuts.map { SIMD2($0.x, $0.y) }))
        try expect(points.count >= 3 && points.count <= SurfaceProbe.maxPoints, "\(points)")
        let probe = SurfaceProbe.program(points: points, face: -0.5)
        let engrave = "G90 G17 G21\nG54\nG53 G0 G90 Z-1.\nS8000 M3\nG0 X0 Y-3\nG0 Z3\nG1 Z-0.65 F100\nG1 Y3\nG0 Z3\nG53 G0 G90 Z-1.\nM5"
        let follow = SurfaceProbe.follow(engrave, face: -0.5)
        for line in (probe + follow.text).split(separator: "\n") { try expect(line.count <= 79, "too long: \(line)") }
        try expectEqual(follow.moved.count, engrave.split(separator: "\n", omittingEmptySubsequences: false).count)
        try expect(follow.text.contains("M112") && follow.text.contains("M113") && follow.text.contains("Z-0.15"), follow.text)
        // In the sender (mock mill): Z0 touched off at machine −20; the face is really 0.3 lower than
        // the CAD says (machine −20.8 instead of −20.5). The cut goes 0.15 below what was probed.
        let mock = MockGRBL()
        mock.setOffset(54, Point3(x: -40, y: -120, z: -20))
        mock.options.probeContactZ = -20.8
        let c = try mockConnection(mock)
        defer { c.disconnect() }
        try c.executeProgram(GCodeProgram(source: probe.components(separatedBy: "\n")).lines)
        let before = mock.receivedLines.count
        try c.executeProgram(GCodeProgram(source: follow.text.components(separatedBy: "\n")).lines)
        let sent = mock.receivedLines[before...].filter { $0.contains("G1") && $0.contains("Z") }
        let z = try unwrap(sent.first.flatMap { l in l.range(of: #"Z-?[0-9.]+"#, options: .regularExpression).map { Double(l[$0].dropFirst()) } } ?? nil)
        try expect(abs(z - (-0.8 - 0.15)) < 0.002, "plunge sent as \(sent.first ?? "-") (expected Z-0.95)")
    },
    TestCase(name: "texturesStayInTheirAreaWithTheirSpacing") {
        for p in Texture.Pattern.allCases {
            let t = Texture.preset(p)
            let lines = t.lines()
            try expect(!lines.isEmpty, "\(p): no lines")
            let half = t.size / 2
            for l in lines {
                for q in l {
                    let inside = t.region == .circle ? simd_length(q) <= half.x + 1e-6 : abs(q.x) <= half.x + 1e-6 && abs(q.y) <= half.y + 1e-6
                    try expect(inside, "\(p): \(q) outside \(t.size)")
                }
            }
        }
        // Barleycorn: rings a pitch apart, every other one turned half a lobe.
        let b = Texture.preset(.barleycorn)
        let rings = b.lines().filter { simd_distance($0.first!, $0.last!) < 0.01 }
        try expect(abs(Double(rings.count) - (b.width / 2 - 2.5 * b.amplitude) / b.pitch) <= 2, "\(rings.count) rings")
        // Clous de Paris: two sets of straight grooves at ±45°, a pitch apart.
        let c = Texture.preset(.clousDeParis).lines()
        let dirs = Set(c.map { l -> Int in let d = l.last! - l.first!; return Int((atan2(d.y, d.x) * 180 / .pi).rounded()) })
        try expect(dirs.isSubset(of: [45, -45, 135, -135]) && dirs.count >= 2, "directions \(dirs)")
        // Spiral: one line, a pitch further out every turn.
        let sp = Texture.preset(.spiral).lines()
        try expectEqual(sp.count, 1)
        // As engraving: positioned and turned like text.
        var e = Engraving(text: "", depth: 0.08)
        e.texture = Texture(pattern: .sunburst, width: 10)
        e.x = 3; e.y = -2
        let pts = e.polylines().flatMap { $0 }
        let mid = pts.reduce(SIMD2<Double>.zero, +) / Double(pts.count)
        try expect(simd_distance(mid, SIMD2(3, -2)) < 0.3, "centred on the engraving's position: \(mid)")
        try expectEqual(Operation(kind: .engrave).title, "Engraving")
        var op = Operation(kind: .engrave)
        op.engraving = e
        try expectEqual(op.title, "Texture · Sunburst (soleil)")
    },
    TestCase(name: "toolChangeStopsShortWhereTheJobsClampsAre") {
        // The maker's position, unless the job's clamps are in the way: then the spindle's
        // last move out stops where it keeps clear.
        let plain = GuidedJobBuilder.helperFiles(machine: .standard)["Code/tool_change_position.nc"]!
        try expect(plain.contains("G53 G0 Z-60"), plain)
        let short = GuidedJobBuilder.helperFiles(machine: .standard, toolChangeZ: -28)["Code/tool_change_position.nc"]!
        try expect(short.contains("G53 G0 Z-28") && !short.contains("Z-60") && short.contains("G53 G0 Z-1"), short)
        // And along Y, where the maker's Y would be right beside a clamp.
        let moved = GuidedJobBuilder.helperFiles(machine: .standard, toolChangeZ: nil, toolChangeY: -110)["Code/tool_change_position.nc"]!
        try expect(moved.contains("G53 G0 Y-110") && !moved.contains("Y-58") && moved.contains("G53 G0 Z-60"), moved)
    },
]
