import CoastlineCore
import Foundation
import simd

/// What the tool tip can reach in a setup's work frame: the machine's travel, seen from where
/// the fixture puts the stock. X and Y hold for every tool; how deep a tool reaches (Z) follows
/// from its stick-out, because the spindle sits higher by that much for the same tip.
struct SetupReach {
    var x: ClosedRange<Double>
    var y: ClosedRange<Double>
    /// The machine Z of work zero with a bare spindle nose.
    var originZ: Double
    var envelope: AxisBox

    /// The deepest work Z a tool with this stick-out reaches.
    func zFloor(stickout: Double) -> Double { envelope.z.lowerBound - originZ - stickout }
    /// The highest work Z it reaches (the spindle fully back).
    func zCeiling(stickout: Double) -> Double { envelope.z.upperBound - originZ - stickout }
}

extension AppModel {
    /// The reach in a setup whose stock is `stockSize` (that setup's frame), from the fixtures
    /// fitted to that stock (the plan picks among them later; where they differ, the smaller
    /// reach holds) or, for a custom fixture, from where it stands the stock. nil: not known.
    func reachInSetup(candidates: [LibraryWorkholdingPlanner.Candidate], stockSize s: SIMD3<Double>) -> SetupReach? {
        var origins = candidates.compactMap { c -> SIMD3<Double>? in
            guard let p = c.fixture.planning, simd_distance(SIMD3(p.stockSize.x, p.stockSize.y, p.stockSize.z), s) < 0.1 else { return nil }
            return c.machineOrigin
        }
        if origins.isEmpty, setup.holding == .custom, let o = machineOrigin(stickout: 0) { origins = [o] }
        guard !origins.isEmpty else { return nil }
        let e = machine.machineEnvelope
        var x = -Double.infinity...Double.infinity, y = x
        var originZ = -Double.infinity
        for o in origins {
            x = max(x.lowerBound, e.x.lowerBound - o.x)...min(x.upperBound, e.x.upperBound - o.x)
            y = max(y.lowerBound, e.y.lowerBound - o.y)...min(y.upperBound, e.y.upperBound - o.y)
            originZ = max(originZ, o.z)  // the highest work zero: the least depth
        }
        guard x.lowerBound < x.upperBound, y.lowerBound < y.upperBound else { return nil }
        if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
            print("reach for stock \(s): x \(x) y \(y) origin z \(originZ) from \(origins.count) fixture(s)")
        }
        return SetupReach(x: x, y: y, originZ: originZ, envelope: e)
    }

    /// Each operation kept to the depth its tool reaches in this setup (what lies deeper is
    /// another setup's, from the other side), with a plan note; an operation wholly out of
    /// reach is left out.
    func withinReach(_ planned: [EngineClient.PlannedOperation], reach: SetupReach, stockDepth: Double, setupName: String) -> [EngineClient.PlannedOperation] {
        var noted = Set<UUID>()
        var faceNoted = false
        return planned.compactMap { p in
            // The face itself out of reach (the stock stands too far toward the spindle for the
            // spindle to back off above it): nothing here can be cut in this setup.
            let ceiling = reach.zCeiling(stickout: p.tool.stickout)
            if ceiling < p.zTop + 3 {
                if !faceNoted {
                    faceNoted = true
                    planNotes.append("\(setupName): standing this way the stock face is \(Length.mm(p.zTop + 3 - ceiling)) mm beyond the spindle's Z travel, so this setup is left out; its features stay for another setup.")
                }
                if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil { print("reach drop \(setupName) \(p.operation.title): ceiling \(String(format: "%.1f", ceiling))") }
                return nil
            }
            // The deepest the tool goes: the Z travel, and its own stick-out (deeper, the collet
            // nut meets the stock face; the engine checks the real cavity, this keeps the plan
            // from making metres of path it will then reject).
            let travelFloor = reach.zFloor(stickout: p.tool.stickout) + 0.05
            let nutFloor = -(p.tool.stickout - 1.05)
            let floor = max(travelFloor, nutFloor)
            // Deeper than the stock is of no concern (the tool never goes there).
            guard floor > -stockDepth + 0.01 else { return p }
            let wanted = p.zMin ?? -stockDepth
            guard wanted < floor - 1e-6 else { return p }
            var q = p
            q.zMin = floor
            let why = nutFloor > travelFloor ? "its collet nut would meet the stock" : "the machine's Z travel"
            if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
                print("reach cap \(setupName) \(p.operation.title) \(p.tool.name.prefix(18)): zMin \(String(format: "%.1f", wanted)) → \(String(format: "%.1f", floor)) (origin z \(String(format: "%.1f", reach.originZ)))")
            }
            let note = "\(setupName): the \(p.tool.name) reaches \(Length.mm(-floor)) mm deep at most (\(Length.mm(p.tool.stickout)) mm stick-out: \(why))"
            if q.zTop <= floor + 1e-6 {
                if noted.insert(p.tool.id).inserted { planNotes.append(note + ": \(p.operation.title) is left to the other setups.") }
                return nil
            }
            if noted.insert(p.tool.id).inserted { planNotes.append(note + "; what lies deeper is left to the other setups.") }
            return q
        }
    }
}

extension AppModel {
    /// Where the fixtures fitted to this stock stand above the stock's back, as XY rectangles
    /// in the setup's work frame grown by the collet nut's radius: roughing keeps out of them,
    /// so the tool, its shank and the nut never come down beside a fixture. The footprint
    /// follows the fixture's real shape on the clearance check's own grid, not a bounding box.
    func fixtureKeepOut(candidates: [LibraryWorkholdingPlanner.Candidate], stockSize s: SIMD3<Double>,
                        margin: Double = FixtureClearance.nutRadius + 0.5) -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        var out: [(min: SIMD2<Double>, max: SIMD2<Double>)] = []
        for c in candidates {
            guard let p = c.fixture.planning, simd_distance(SIMD3(p.stockSize.x, p.stockSize.y, p.stockSize.z), s) < 0.1,
                  let f = libraryFixtureFields[fixtureStateKey(c.fixture)] else { continue }
            let floor = Float(-s.z + 0.05)  // anything rising above the stock's back
            var block = [Bool](repeating: false, count: f.nx * f.ny)
            for i in block.indices where f.top[i] > floor { block[i] = true }
            // Row spans merged downward into rectangles.
            var open: [Int: (y0: Int, x1: Int)] = [:]  // span start x → (first row, end x)
            func close(_ x0: Int, _ v: (y0: Int, x1: Int), _ y1: Int) {
                out.append((SIMD2(f.minX + Double(x0) * f.cell - margin, f.minY + Double(v.y0) * f.cell - margin),
                            SIMD2(f.minX + Double(v.x1) * f.cell + margin, f.minY + Double(y1) * f.cell + margin)))
            }
            for y in 0...f.ny {
                var spans: [Int: Int] = [:]
                if y < f.ny {
                    var x = 0
                    while x < f.nx {
                        guard block[y * f.nx + x] else { x += 1; continue }
                        let x0 = x
                        while x < f.nx && block[y * f.nx + x] { x += 1 }
                        spans[x0] = x
                    }
                }
                for (x0, v) in open where spans[x0] != v.x1 { close(x0, v, y); open[x0] = nil }
                for (x0, x1) in spans where open[x0] == nil { open[x0] = (y, x1) }
            }
        }
        if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
            print("fixture keep-out for stock \(s): \(out.count) rects, e.g. \(out.prefix(3).map { "x \(String(format: "%.1f…%.1f", $0.min.x, $0.max.x)) y \(String(format: "%.1f…%.1f", $0.min.y, $0.max.y))" })")
        }
        return out
    }
}

extension AppModel {
    /// The clearance fields of the fixtures fitted to this stock (the setup's work frame).
    func fixtureFields(candidates: [LibraryWorkholdingPlanner.Candidate], stockSize s: SIMD3<Double>) -> [FixtureField] {
        candidates.compactMap { c in
            guard let p = c.fixture.planning, simd_distance(SIMD3(p.stockSize.x, p.stockSize.y, p.stockSize.z), s) < 0.1 else { return nil }
            return libraryFixtureFields[fixtureStateKey(c.fixture)]
        }
    }
}
