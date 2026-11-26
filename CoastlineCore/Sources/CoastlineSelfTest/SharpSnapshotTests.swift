import CoastlineCore
import Foundation
import simd

/// Raster passes of a tool along X at heights z, stepping `step` in Y.
private func raster(z: Double, step: Double, r: Double, rc: Double, y0: Double = -8, y1: Double = 8) -> [CutSegment] {
    stride(from: y0, through: y1, by: step).map { y in CutSegment(a: SIMD3(-10, y, z), b: SIMD3(10, y, z), r: r, rc: rc) }
}

let sharpSnapshotTests: [TestCase] = [
    TestCase(name: "ballCuspsComeOutAtTheirAnalyticHeight") {
        // A 3 mm ball (r 1.5) in passes 0.4 mm apart: cusps h = r − √(r² − (s/2)²) ≈ 13.4 µm.
        let r = 1.5, s = 0.4, cusp = r - (r * r - s * s / 4).squareRoot()
        let segs = raster(z: -1, step: s, r: r, rc: r)
        let start = Heightmap(stockMin: SIMD3(-12, -10, -5), stockMax: SIMD3(12, 10, 0))
        let hm = SharpSim.sharpen(segs, start: start, coarse: nil, region: SIMD2(-2, -2), SIMD2(2, 2), cell: 0.002)!
        let peak = Double(hm.heights.max()!) - -1, low = Double(hm.heights.min()!) - -1
        try expect(abs(peak - cusp) < 0.002 && abs(low) < 1e-6, "cusp \(peak * 1000) µm, analytic \(cusp * 1000)")
        // The exact readout between two passes is the analytic cusp to well under a µm.
        let mid = SharpSim.exactHeight(at: SIMD2(0, -8 + s * 10 + s / 2), segments: segs, start: 0, bottom: -5)
        try expect(abs(mid - (-1 + cusp)) < 1e-6, "\(mid)")
        // The playback grid (250 000 cells over a stock) can't see it.
        try expect(Heightmap(stockMin: SIMD3(-25, -20, -5), stockMax: SIMD3(25, 20, 0), maxCells: 250_000).cell > 0.05)
    },
    TestCase(name: "cullingKeepsTheSameSurface") {
        // Three roughing levels, then a finishing raster: the levels above don't shape the result.
        let rough = [-0.5, -1.0, -1.5].flatMap { raster(z: $0, step: 2, r: 3.175, rc: 0) }
        let finish = raster(z: -2, step: 0.3, r: 1.5, rc: 1.5)
        let segs = rough + finish
        var coarse = Heightmap(stockMin: SIMD3(-12, -10, -5), stockMax: SIMD3(12, 10, 0))
        let start = coarse
        for s in segs { coarse.cut(from: s.a, to: s.b, radius: s.r, cornerRadius: s.rc) }
        let kept = SharpSim.cull(segs, coarse: coarse, region: SIMD2(-3, -3), SIMD2(3, 3))
        try expect(kept.count < segs.count - 20, "culled \(segs.count - kept.count) of \(segs.count)")
        let all = SharpSim.sharpen(segs, start: start, coarse: nil, region: SIMD2(-3, -3), SIMD2(3, 3), cell: 0.01)!
        let fast = SharpSim.sharpen(segs, start: start, coarse: coarse, region: SIMD2(-3, -3), SIMD2(3, 3), cell: 0.01)!
        try expectEqual(all.heights, fast.heights, "culled and full runs agree")
    },
    TestCase(name: "theExactEnvelopeOfARampAndABullNose") {
        let ramp = CutSegment(a: SIMD3(0, 0, 0), b: SIMD3(10, 0, -1), r: 3, rc: 1)
        for p in [SIMD2(5.0, 2.5), SIMD2(12.0, 1.0), SIMD2(-2.0, 0.5), SIMD2(3.0, -2.9)] {
            // Brute force over t.
            var best = Double.infinity
            for k in 0...200_000 {
                let t = Double(k) / 200_000, q = SIMD2(10 * t, 0.0), d = simd_length(p - q)
                guard d <= 3 else { continue }
                var z = -t
                if d > 2 { let u = d - 2; z += 1 - (1 - u * u).squareRoot() }
                best = min(best, z)
            }
            let e = SharpSim.envelope(ramp, at: p)
            try expect(e != nil && abs(e! - best) < 1e-6, "at \(p): \(e ?? .nan) vs \(best)")
        }
        try expect(SharpSim.envelope(ramp, at: SIMD2(5, 3.2)) == nil, "out of reach")
        let segs = raster(z: -1, step: 0.4, r: 1.5, rc: 1.5)
        let line = SharpSim.exactProfile(from: SIMD2(0, -2), to: SIMD2(0, 2), count: 41, segments: segs, start: { _ in 0 }, bottom: -5)
        for (i, h) in line.enumerated() {
            let one = SharpSim.exactHeight(at: SIMD2(0, -2 + 0.1 * Double(i)), segments: segs, start: 0, bottom: -5)
            try expect(abs(h - one) < 1e-12, "profile point \(i)")
        }
    },
    TestCase(name: "snapshotsStoreToTheMicronAndExportClosedMeshes") {
        let segs = raster(z: -1, step: 0.4, r: 1.5, rc: 1.5)
        let start = Heightmap(stockMin: SIMD3(-12, -10, -5), stockMax: SIMD3(12, 10, 0))
        let hm = SharpSim.sharpen(segs, start: start, coarse: nil, region: SIMD2(-2, -2), SIMD2(2, 2), cell: 0.01)!
        let data = SharpSim.encode(hm)
        let back = SharpSim.decode(data, cols: hm.cols, rows: hm.rows)!
        try expect(zip(back, hm.heights).allSatisfy { abs($0 - $1) <= 0.00051 }, "µm quantisation")
        try expect(data.count < hm.heights.count * 4 / 3, "compresses: \(data.count) bytes for \(hm.heights.count) cells")
        // Closed: every edge belongs to exactly two triangles.
        let m = SharpSim.mesh(hm, stride: 7)
        var edges: [UInt64: Int] = [:]
        for t in m.triangles {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] { edges[UInt64(min(a, b)) << 32 | UInt64(max(a, b)), default: 0] += 1 }
        }
        try expect(edges.values.allSatisfy { $0 == 2 }, "watertight: \(edges.values.filter { $0 != 2 }.count) open edges")
        let stl = SharpSim.stl(m, name: "test")
        try expectEqual(stl.count, 84 + 50 * m.triangles.count)
    },
]
