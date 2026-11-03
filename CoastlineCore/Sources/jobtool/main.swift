import simd
import CoastlineCore
import Foundation

// jobtool import <package.dd|.crproj> <job folder>
// Converts every program for the machine (checked to follow the same path) and writes job.json.

let args = Array(CommandLine.arguments.dropFirst())
// jobtool bounds <file.step>: the model's size and box, read through the geometry engine.
if args.count == 2, args[0] == "bounds" {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let url = URL(fileURLWithPath: args[1])
    let mesh = url.pathExtension.lowercased() == "stl"
        ? try STLReader.read(url) : try await EngineClient.development(repoRoot: root).importPart(url)
    print("size \(mesh.size)  min \(mesh.boundsMin)  max \(mesh.boundsMax)  faces \(mesh.faceCount)  exact \(mesh.exact)")
    exit(0)
}
// jobtool info <file.nc>: what the reader finds in a program.
if args.count == 2, args[0] == "info" {
    let read = GCodeReader.read(try String(contentsOfFile: args[1], encoding: .utf8))
    print("moves \(read.moves.count)  cut box \(read.cutMin.map { "\($0)" } ?? "-") … \(read.cutMax.map { "\($0)" } ?? "-")  issues \(read.issues.count)")
    exit(0)
}
// jobtool section <file.step> <x|y|z> <value>: the closed loops where the plane cuts the model,
// with their boxes (holes show as small loops inside the outline).
if args.count == 4, args[0] == "section", let axis = ["x": 0, "y": 1, "z": 2][args[2]], let value = Double(args[3]) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let mesh = try await EngineClient.development(repoRoot: root).importPart(URL(fileURLWithPath: args[1]))
    let v = mesh.vertices.map(Double.init)
    func p(_ i: UInt32) -> [Double] { [v[Int(i) * 3], v[Int(i) * 3 + 1], v[Int(i) * 3 + 2]] }
    // Welds coincident vertices (the tessellation repeats them per face) so loops close.
    func key(_ q: [Double]) -> String { q.map { String(format: "%.4f", $0) }.joined(separator: ",") }
    var next: [String: [String]] = [:], points: [String: [Double]] = [:]
    for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
        let tri = (0..<3).map { p(mesh.indices[t + $0]) }
        var cut: [[Double]] = []
        for (a, b) in [(0, 1), (1, 2), (2, 0)] {
            let (pa, pb) = key(tri[a]) < key(tri[b]) ? (tri[a], tri[b]) : (tri[b], tri[a])
            let da = pa[axis] - value, db = pb[axis] - value
            if (da < 0) != (db < 0), da != db {
                let f = da / (da - db)
                cut.append((0..<3).map { pa[$0] + (pb[$0] - pa[$0]) * f })
            }
        }
        guard cut.count == 2 else { continue }
        let ka = key(cut[0]), kb = key(cut[1])
        points[ka] = cut[0]; points[kb] = cut[1]
        next[ka, default: []].append(kb); next[kb, default: []].append(ka)
    }
    var seen = Set<String>(), loops: [[[Double]]] = []
    for start in next.keys where !seen.contains(start) {
        var loop: [[Double]] = [], k = start, prev = ""
        while !seen.contains(k) {
            seen.insert(k); loop.append(points[k]!)
            guard let n = next[k]?.first(where: { $0 != prev && !seen.contains($0) }) ?? next[k]?.first(where: { $0 != prev }) else { break }
            prev = k; k = n
        }
        if loop.count > 3 { loops.append(loop) }
    }
    let others = [0, 1, 2].filter { $0 != axis }
    let names = ["x", "y", "z"]
    for loop in loops.sorted(by: { $0.count > $1.count }).prefix(12) {
        let a = loop.map { $0[others[0]] }, b = loop.map { $0[others[1]] }
        print(String(format: "loop %4d pts  %@ %8.3f … %8.3f   %@ %8.3f … %8.3f   (%.2f × %.2f)", loop.count,
                     names[others[0]], a.min()!, a.max()!, names[others[1]], b.min()!, b.max()!, a.max()! - a.min()!, b.max()! - b.min()!))
        // JOBTOOL_POINTS=1: the outline itself, one point per line (profiles of slots, steps…).
        if ProcessInfo.processInfo.environment["JOBTOOL_POINTS"] != nil {
            for (x, y) in zip(a, b) { print(String(format: "    %9.3f %9.3f", x, y)) }
        }
    }
    exit(0)
}
// jobtool cutcheck <job folder> <program id> [option=choice …]: what the program's tool sweeps,
// checked against the setup's part model (gouges, rapids through the part).
if args.count >= 3, args[0] == "cutcheck" {
    let folder = URL(fileURLWithPath: args[1])
    let job = try ProgramJob.load(folder)
    var chosen = job.choices()
    for a in args.dropFirst(3) { let kv = a.split(separator: "="); if kv.count == 2 { chosen[String(kv[0])] = String(kv[1]) } }
    guard let program = job.program(args[2]), let setup = job.setup(running: program.id, chosen) else { print("no such program in this plan"); exit(2) }
    let read = GCodeReader.read(try String(contentsOf: folder.appendingPathComponent(program.file), encoding: .utf8))
    guard let spec = job.tool(program.tool) else { print("the program has no tool"); exit(2) }
    let tool = ToolShape(spec, stickout: setup.machine?.stickout ?? 30)
    var part: (vertices: [Float], indices: [UInt32])?
    if let model = job.models.first(where: { $0.role == .part }), let placement = setup.placements[model.id] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let mesh = try await EngineClient.development(repoRoot: root).importPart(folder.appendingPathComponent(model.file))
        var v = mesh.vertices
        for k in stride(from: 0, to: v.count - 2, by: 3) {
            let q = placement.apply((Double(v[k]), Double(v[k + 1]), Double(v[k + 2])))
            (v[k], v[k + 1], v[k + 2]) = (Float(q.0), Float(q.1), Float(q.2))
        }
        part = (v, mesh.indices)
    }
    if ProcessInfo.processInfo.environment["JOBTOOL_RAPIDS"] != nil {
        for (k, m) in read.moves.enumerated() where k > 0 && m.role == .rapid && !read.unknownStart.contains(k) && !read.probeMoves.contains(k) {
            let a = read.start(of: k)!, b = m.position
            if min(a.z, b.z) < 0 { print(String(format: "  rapid line %d: (%.2f %.2f %.2f) → (%.2f %.2f %.2f)", read.lineOfMove[k], a.x, a.y, a.z, b.x, b.y, b.z)) }
        }
    }
    let start = Date()
    guard let r = CutCheck.run(read, tool: tool, part: part) else { print("nothing to check"); exit(1) }
    print(String(format: "%@ · %@ %@ Ø%.2f · %d moves (%d probe, %d with unknown start) · %.1f s", program.id, spec.name, tool.kind.rawValue,
                 spec.diameter, read.moves.count, read.probeMoves.count, read.unknownStart.count, Date().timeIntervalSince(start)))
    print(String(format: "removed (inside the part's box) %.1f mm³ · gouge %.2f mm³ · rapids through the part %.2f mm³",
                 r.removed.volume, r.gougeVolume, r.rapidHitVolume))
    for (name, grid) in [("gouge", r.gouge), ("rapid", r.rapidHits)] {
        guard let grid, grid.volume > 0 else { continue }
        var lo = SIMD3<Double>(repeating: 1e9), hi = -lo
        for row in 0..<grid.rows { for col in 0..<grid.cols { for s in grid.spans[row * grid.cols + col] {
            let c = grid.centre(col, row)
            lo = simd_min(lo, SIMD3(c.x, c.y, Double(s.x))); hi = simd_max(hi, SIMD3(c.x, c.y, Double(s.y)))
        } } }
        print(String(format: "  %@ box X %.2f…%.2f  Y %.2f…%.2f  Z %.2f…%.2f", name, lo.x, hi.x, lo.y, hi.y, lo.z, hi.z))
    }
    exit(0)
}
guard args.count == 3, args[0] == "import" else {
    print("usage: jobtool import <package.dd> <job folder>")
    exit(2)
}
do {
    let report = try PackageImport.run(URL(fileURLWithPath: args[1]), into: URL(fileURLWithPath: args[2]))
    for note in report.notes { print("  \(note)") }
    print("\(report.job.options.first?.choices.count ?? 0) jobs, \(report.job.programs.count) programs → \(args[2])")
} catch {
    print("import failed: \(error)")
    exit(1)
}
