import CoastlineCore
import Foundation
import simd

/// A closed box mesh (12 triangles, outward winding).
private func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> (vertices: [Float], indices: [UInt32]) {
    let c = (0..<8).map { i in SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z) }
    let faces: [[UInt32]] = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
    return (c.flatMap { [$0.x, $0.y, $0.z] }, faces.flatMap { [$0[0], $0[1], $0[2], $0[0], $0[2], $0[3]] })
}

let dexelTests: [TestCase] = [
    TestCase(name: "flatToolSweepsASlot") {
        var g = DexelGrid(min: SIMD2(-10, -10), max: SIMD2(30, 10), cell: 0.1)
        let tool = ToolShape(kind: .flat, radius: 2, length: 3)
        g.sweep(from: SIMD3(0, 0, -1), to: SIMD3(20, 0, -1), tool: tool)
        // A 20 mm slot, 4 wide, with round ends, 3 tall (tip at -1, tool up to +2).
        let expected = (20 * 4 + Double.pi * 4) * 3
        try expect(abs(g.volume - expected) / expected < 0.02, "volume \(g.volume) vs \(expected)")
        let mid = g.spans[g.rows / 2 * g.cols + g.cols / 2]
        try expect(mid.count == 1 && abs(mid[0].x + 1) < 1e-4 && abs(mid[0].y - 2) < 1e-4, "\(mid)")
        try expect(!g.mesh().indices.isEmpty)
    },

    TestCase(name: "discCutsOnlyUnderTheShank") {
        var g = DexelGrid(min: SIMD2(-10, -10), max: SIMD2(10, 10), cell: 0.1)
        let disc = ToolShape(kind: .disc, radius: 7.72, length: 20, discThickness: 3.02, shankRadius: 3.175)
        g.sweep(from: SIMD3(0, 0, -5.56), to: SIMD3(0, 0, -5.56), tool: disc)
        let at = { (x: Double) in g.spans[g.rows / 2 * g.cols + Int(((x - g.origin.x) / g.cell).rounded())] }
        try expect(abs(at(0)[0].y - 14.44) < 1e-3, "shank to the top: \(at(0))")
        try expect(abs(at(6)[0].x + 5.56) < 1e-3 && abs(at(6)[0].y + 2.54) < 1e-3, "disc only: \(at(6))")
        try expect(at(8).isEmpty)
    },

    TestCase(name: "cutCheckFindsAGougeAndARapidHit") {
        let part = box(SIMD3(0, 0, -10), SIMD3(10, 10, 0))
        let tool = ToolShape(kind: .flat, radius: 1, length: 10)
        // Beside the part, then into it; a rapid through its corner.
        let clean = GCodeReader.read("G21 G90\nG0 X-3 Y5 Z5\nG1 Z-5 F100\nY8\n")
        let gouging = GCodeReader.read("G21 G90\nG0 X-3 Y5 Z5\nG1 Z-5 F100\nX2\n")
        let crashing = GCodeReader.read("G21 G90\nG0 X-3 Y5 Z-2\nG0 X12\n")
        let a = try CutCheck.run(clean, tool: tool, part: part).unwrapped()
        try expect(a.gougeVolume < 0.01 && a.rapidHitVolume < 0.01, "clean: \(a.gougeVolume) \(a.rapidHitVolume)")
        let b = try CutCheck.run(gouging, tool: tool, part: part).unwrapped()
        try expect(b.gougeVolume > 15, "gouge \(b.gougeVolume)")  // ~3 × 2 × 5 mm plus the round end
        let c = try CutCheck.run(crashing, tool: tool, part: part).unwrapped()
        try expect(c.rapidHitVolume > 35 && c.rapidHitVolume < 45, "10 × 2 × 2 mm: rapid \(c.rapidHitVolume)")
    },
]

private struct Missing: Error {}
private extension Optional {
    func unwrapped() throws -> Wrapped {
        guard let value = self else { throw Missing() }
        return value
    }
}
