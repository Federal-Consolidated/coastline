import Foundation
import simd

/// A reusable definition for one assembled state of a jig. CAD alone cannot establish
/// grip, load capacity, or an adjustable jaw's position. Those are supplied once by its owner.
public struct FixturePlanningProfile: Codable, Hashable, Sendable {
    public struct Contact: Codable, Hashable, Identifiable, Sendable {
        public enum Normal: String, CaseIterable, Codable, Sendable { case x, y, z }
        public var id = UUID()
        /// Centre and radius of a material patch the fixture needs, in stock work coordinates.
        public var point = Vec3.zero
        public var radius = 1.0
        public var normal: Normal? = nil
        public init(point: Vec3 = .zero, radius: Double = 1) { self.point = point; self.radius = radius }
    }
    public var enabled = false
    /// Assembled stock dimensions in the work frame. Static imports need a matching CAD
    /// arrangement; vetted assemblies derive adjustable positions from their explicit joints.
    public var stockSize = Vec3.zero
    /// Position of stock work zero in the model's original coordinates (mm).
    public var datum = Vec3.zero
    public var facing = Setup.Facing.plusZ
    public var spin = 0
    public var facePastTable = 2.0
    public var allowsRoughing = false
    public var contacts: [Contact] = []
    public var gripDefinitionReviewed = false
    /// Optional so inventories written before editable assembly pieces still decode.
    public var componentPlacements: [ComponentPlacement]? = nil
    public var componentModelSignature: String? = nil
    public var componentLayoutID: String? = nil
    public var workspacePlaced: Bool? = nil
    /// Missing in older files means their static piece placement remains unchanged.
    public var assemblyState: FixtureAssemblyState? = nil

    public struct ComponentPlacement: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        /// Translation and quarter-turn orientation in the imported CAD coordinates.
        public var offset = Vec3.zero
        public var facing = Setup.Facing.plusZ
        public var spin = 0
        public init(id: String) { self.id = id }
    }
    public init() {}

    /// Rotate the assembled fixture about the stock datum in work coordinates.
    public func turned(about axis: Int, quarterTurns: Int) -> Self {
        guard (0...2).contains(axis) else { return self }
        var setup = Setup(); setup.facing = facing; setup.spin = spin
        let turned = setup.turned(about: axis, quarterTurns: quarterTurns)
        var result = self
        result.facing = turned.facing; result.spin = turned.spin
        result.gripDefinitionReviewed = false
        return result
    }

    /// Nudge the fixture in machine/work directions while keeping the stock preview fixed.
    public func moved(inWork delta: Vec3) -> Self {
        guard [delta.x, delta.y, delta.z].allSatisfy(\.isFinite) else { return self }
        var setup = Setup(); setup.facing = facing; setup.spin = spin
        let local = setup.partRotation.transpose * SIMD3(delta.x, delta.y, delta.z)
        var result = self
        result.datum = Vec3(datum.x - local.x, datum.y - local.y, datum.z - local.z)
        result.gripDefinitionReviewed = false
        return result
    }

    public var definitionIssues: [String] {
        var issues: [String] = []
        if !enabled { issues.append("Not enabled for automatic planning.") }
        let values = [stockSize.x, stockSize.y, stockSize.z]
        if values.contains(where: { !$0.isFinite || $0 <= 0 || $0 > 10_000 }) { issues.append("Set the stock dimensions represented by this assembled jig.") }
        if ![datum.x, datum.y, datum.z, facePastTable].allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }) { issues.append("The datum and placement must be finite and within supported modelling coordinates.") }
        if contacts.count < 2 { issues.append("Define at least two grip/support patches.") }
        if contacts.contains(where: { ![$0.point.x, $0.point.y, $0.point.z, $0.radius].allSatisfy(\.isFinite) || $0.radius <= 0 }) {
            issues.append("Grip patches need finite coordinates and a positive radius.")
        }
        if !gripDefinitionReviewed { issues.append("Review the grip/support definition and cutting-load suitability.") }
        if workspacePlaced == true && (componentModelSignature == nil || componentLayoutID == nil) {
            issues.append("Recheck the model for the saved workspace placement.")
        }
        if let pieces = componentPlacements, !pieces.isEmpty {
            if componentModelSignature == nil || componentLayoutID == nil { issues.append("Recheck the assembly model for the saved piece positions.") }
            if Set(pieces.map(\.id)).count != pieces.count || pieces.contains(where: {
                ![$0.offset.x, $0.offset.y, $0.offset.z].allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }) || !(0..<4).contains($0.spin)
            }) { issues.append("The assembly has invalid piece positions.") }
        }
        return issues
    }

    public var modelToWork: simd_double4x4 {
        var s = Setup(); s.facing = facing; s.spin = spin
        let r = s.partRotation
        let t = -(r * SIMD3(datum.x, datum.y, datum.z))
        return simd_double4x4(columns: (SIMD4(r[0], 0), SIMD4(r[1], 0), SIMD4(r[2], 0), SIMD4(t, 1)))
    }
}

public struct LibraryWorkholdingPlan: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Identifiable, Sendable {
        public var id = UUID()
        public var number: Int
        public var side: Int
        public var fixture: Fixture
        public var cutKeys: [String]
        public var operations: [String]
        public var reasons: [String]
        public var modelSignature: String? = nil
        public var reviewed = false
        public init(number: Int, side: Int, fixture: Fixture, cutKeys: [String], operations: [String], reasons: [String],
                    modelSignature: String? = nil) {
            self.number = number; self.side = side; self.fixture = fixture
            self.cutKeys = cutKeys; self.operations = operations; self.reasons = reasons
            self.modelSignature = modelSignature
        }
        public var title: String { "Setup \(number) · \(fixture.name)" }
        public var instructions: String {
            let patches = fixture.planning?.contacts ?? []
            let turn = side >= 2 ? "Turn the stock so its \(SetupSide.words(side)) faces the spindle. " : ""
            let side = side >= 2 ? 0 : side
            let placement: String
            if fixture.assembly?.bookends != nil {
                placement = side == 0
                    ? "Place the stock against the fixed end and locating lip. Slide the bookend bases into position, secure both bases to the table, then advance the side screw to contact. Verify the stock is seated and the mounting hardware is secure. "
                    : "Release the side screw, flip the stock, and reseat it against the fixed end and locating lip. Keep the bases mounted in their reviewed positions, then advance the side screw to contact. Verify seating, secure gripping and the work datum before continuing. "
            } else if fixture.assembly?.clampPair != nil {
                placement = side == 0
                    ? "Lay the stock on the table with its face at the table's front edge. Hook a C-clamp under the table near each end of the stock and tighten both pads onto its top. "
                    : "Loosen both C-clamps, flip the stock, and lay it back with its face at the table's front edge. Tighten both pads onto its top. "
            } else if fixture.assembly?.vise != nil {
                placement = side == 0
                    ? "Bolt the vise to the T-slot. Put the stock on the vise floor against the fixed jaw, with its face sticking out past the jaws as shown, and close the vise. "
                    : "Open the vise, flip the stock, and seat it on the floor against the fixed jaw as before. Close the vise. "
            } else { placement = "Use \(fixture.name). " }
            return turn + placement + fixture.notes + "\n\n"
                + (patches.isEmpty ? "" : "Keep its \(patches.count) defined grip/support patches engaged. ")
                + "Establish X0 Y0 at the stock-face centre and Z0 at its original face; account for material already faced away."
                + (fixture.modelPath == nil
                   ? "\n\nThis fixture has no model yet: no clearance check was made against it. Keep the jaws behind the depth this setup cuts."
                   : "\n\nCutter, shank and holder paths were checked against the placed CAD assembly. Confirm secure gripping, mounting, and material connectivity; geometric contact checks do not prove clamping force or rigidity.")
        }
    }
    public var steps: [Step] = []
    public var issues: [String] = []
    /// True once the user has put the steps in their own order (the planner's order is the side
    /// setups on the whole block first, then side A and B). Optional: plans saved before decode.
    public var reordered: Bool? = nil
    public var complete: Bool { !steps.isEmpty && issues.isEmpty }
    public var reviewed: Bool { complete && steps.allSatisfy(\.reviewed) }
    public init() {}
    public func step(for key: String) -> Step? { steps.first { $0.cutKeys.contains(key) } }
}

/// Assigns whole generated cutting operations/depth slices to owned library assemblies.
/// Cut order is preserved, and dynamic programming minimizes re-clampings. No cut is
/// silently omitted when every fixture obstructs it.
public enum LibraryWorkholdingPlanner {
    public struct Cut: Sendable {
        public var key: String
        public var side: Int
        public var operation: Operation
        public var tool: Tool
        public var moves: [Move]
        public init(key: String, side: Int, operation: Operation, tool: Tool, moves: [Move]) {
            self.key = key; self.side = side; self.operation = operation; self.tool = tool; self.moves = moves
        }
    }
    public struct Candidate: Sendable {
        public var fixture: Fixture
        public var field: FixtureField
        public var occupied: DexelGrid
        /// Moves beyond the measured machine envelope must also reject a candidate. The machine
        /// position with the bare spindle nose (stick-out 0) at work zero.
        public var machineOrigin: SIMD3<Double>?
        public var modelSignature: String?
        public init(fixture: Fixture, field: FixtureField, occupied: DexelGrid, machineOrigin: SIMD3<Double>? = nil, modelSignature: String? = nil) {
            self.fixture = fixture; self.field = field; self.machineOrigin = machineOrigin
            self.occupied = occupied
            self.modelSignature = modelSignature
        }
    }

    public static func eligibility(_ fixture: Fixture, stock: SIMD3<Double>) -> [String] {
        guard [stock.x, stock.y, stock.z].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 10_000 }) else { return ["Invalid stock dimensions."] }
        guard fixture.quantity > 0 else { return ["Not owned or unavailable (quantity is zero)."] }
        if let assembly = fixture.assembly, !assembly.planningIssues.isEmpty { return assembly.planningIssues }
        guard let profile = fixture.planning else { return ["Define how this fixture holds stock in Fixtures."] }
        var issues = profile.definitionIssues
        if fixture.modelPath?.isEmpty != false { issues.append("Attach the actual assembled CAD model.") }
        if !fixture.height.isFinite || fixture.height < 0 || fixture.height > 10_000 { issues.append("Stock height above the table must be finite and within the supported range.") }
        let size = SIMD3(profile.stockSize.x, profile.stockSize.y, profile.stockSize.z)
        if simd_length(size - stock) > 0.1 { issues.append("The CAD assembly is defined for \(profile.stockSize), not this stock. Define the matching assembled state.") }
        if let range = fixture.gripRange {
            let d = fixture.clampAxis == .x ? stock.x : stock.y
            if fixture.clampAxis != .none && !range.contains(d) { issues.append("Stock is outside the fixture's grip range.") }
        }
        return issues
    }

    public static func plan(cuts: [Cut], candidates: [Candidate], stock: SIMD3<Double>, machine: MachineProfile = .standard,
                            flipAxis: Int? = nil) -> LibraryWorkholdingPlan {
        var result = LibraryWorkholdingPlan()
        guard [stock.x, stock.y, stock.z].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 10_000 }),
              cuts.allSatisfy({ cut in
                  [cut.tool.diameter, cut.tool.stickout, cut.tool.fluteLength, cut.tool.shankDiameter].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 1_000 }
                  && cut.moves.allSatisfy { m in [m.x, m.y, m.z, m.i, m.j, m.feed].allSatisfy { $0.isFinite && abs($0) <= 100_000 } }
              }) else { result.issues = ["Invalid stock, tool or toolpath values; no fixture plan was produced."]; return result }
        guard !cuts.isEmpty else { result.issues = ["There are no generated cuts to assign."]; return result }
        let sides = Set(cuts.map(\.side))
        let fixtures = candidates.filter { c in !c.field.isEmpty && sides.contains { eligibility(c.fixture, stock: SetupSide.stockSize(stock, side: $0)).isEmpty } }
            .sorted { $0.fixture.id.uuidString < $1.fixture.id.uuidString }
        guard !fixtures.isEmpty else { result.issues = ["No owned fixture has a complete planning definition and usable CAD geometry for this stock."]; return result }
        let fitsSide = fixtures.map { c in Dictionary(uniqueKeysWithValues: sides.map { ($0, eligibility(c.fixture, stock: SetupSide.stockSize(stock, side: $0)).isEmpty) }) }
        // Removed material in side-A stock coordinates, on three grids (columns along A's X, Y
        // and Z): every setup's cuts land on the grid along its tool axis. Material is never
        // reset to a fresh blank at a fixture change, flip or turn.
        let cell = max(0.2, max(stock.x, stock.y, stock.z) / 400)
        var removal = StockRemoval(stock: stock, cell: cell)
        var cleared = removal.grids[2]
        func stockPoint(_ p: SIMD3<Double>, side: Int) -> SIMD3<Double> { SetupSide.toA(p, side: side, stock: stock, flipAxis: flipAxis) }
        func contactsRemain(_ fixture: Fixture, side: Int, removal: StockRemoval) -> Bool {
            guard let contacts = fixture.planning?.contacts else { return false }
            let s = SetupSide.stockSize(stock, side: side)
            let lo = SIMD3(-s.x / 2, -s.y / 2, -s.z), hi = SIMD3(s.x / 2, s.y / 2, 0)
            for patch in contacts {
                var point = SIMD3(patch.point.x, patch.point.y, patch.point.z)
                let axis = patch.normal ?? .z
                let normal = axis == .x ? 0 : axis == .y ? 1 : 2
                let radius = patch.radius
                guard (0..<3).allSatisfy({ point[$0] >= lo[$0] && point[$0] <= hi[$0] }) else { return false }
                // Contact lies on a surface; sample the material just inside it.
                if abs(point[normal] - lo[normal]) < cell { point[normal] = lo[normal] + cell }
                else if abs(point[normal] - hi[normal]) < cell { point[normal] = hi[normal] - cell }
                let (u, v) = normal == 0 ? (1, 2) : normal == 1 ? (0, 2) : (0, 1)
                guard point[u] - radius >= lo[u], point[u] + radius <= hi[u],
                      point[v] - radius >= lo[v], point[v] + radius <= hi[v] else { return false }
                let steps = max(Int((2 * radius / cell).rounded(.up)), 2)
                for a in 0...steps {
                    for b in 0...steps {
                        let du = -radius + 2 * radius * Double(a) / Double(steps)
                        let dv = -radius + 2 * radius * Double(b) / Double(steps)
                        guard du * du + dv * dv <= radius * radius + 1e-9 else { continue }
                        var p = point; p[u] += du; p[v] += dv
                        if removal.removed(stockPoint(p, side: side)) { return false }
                    }
                }
            }
            return true
        }
        func fitsRemainingStock(_ occupied: DexelGrid, side: Int, cleared: DexelGrid) -> Bool {
            if side >= 2 {
                // Turned: no cleared air is credited; the fixture stays out of the stock box.
                let s = SetupSide.stockSize(stock, side: side)
                for row in 0..<occupied.rows {
                    for col in 0..<occupied.cols where !occupied.spans[row * occupied.cols + col].isEmpty {
                        let xy = occupied.centre(col, row)
                        guard abs(xy.x) < s.x / 2, abs(xy.y) < s.y / 2 else { continue }
                        for span in occupied.spans[row * occupied.cols + col]
                        where min(Double(span.y), 0) - 0.1 > max(Double(span.x), -s.z) + 0.1 { return false }
                    }
                }
                return true
            }
            for row in 0..<occupied.rows {
                for col in 0..<occupied.cols where !occupied.spans[row * occupied.cols + col].isEmpty {
                    let xy = occupied.centre(col, row)
                    let p = stockPoint(SIMD3(xy.x, xy.y, 0), side: side)
                    let c = Int(((p.x - cleared.origin.x) / cleared.cell).rounded())
                    let r = Int(((p.y - cleared.origin.y) / cleared.cell).rounded())
                    guard c >= 0, r >= 0, c < cleared.cols, r < cleared.rows else { continue }
                    for span in occupied.spans[row * occupied.cols + col] {
                        let a = max(Double(span.x), -stock.z) + 0.1
                        let b = min(Double(span.y), 0) - 0.1
                        if b <= a { continue } // contact/model tolerance
                        let lo = side == 0 ? a : -stock.z - b, hi = side == 0 ? b : -stock.z - a
                        var covered = lo
                        for air in cleared.spans[r * cleared.cols + c] {
                            if Double(air.y) < covered { continue }
                            if Double(air.x) > covered + 1e-5 { break }
                            covered = max(covered, Double(air.y))
                            if covered >= hi { break }
                        }
                        if covered < hi { return false }
                    }
                }
            }
            return true
        }
        var allowed: [[Bool]] = []
        var fields = fixtures.map(\.field)
        for cut in cuts {
            let bounds = pathBounds(cut.moves)
            let before = removal
            let clearedBefore = cleared
            let (axisK, axisSign) = StockRemoval.toolAxis(side: cut.side)
            var previous = cut.moves.first?.position ?? .zero
            let shape = ToolShape(kind: .flat, radius: cut.tool.diameter / 2 + cell * 0.85, length: cut.tool.stickout)
            for move in cut.moves {
                if move.role != .rapid {
                    // Bound arc chord error relative to the stock grid, including large
                    // radius arcs. The radius margins also cover a cell's half diagonal.
                    let angle = min(0.08, sqrt(0.8 * cell / max(hypot(move.i, move.j), cell)))
                    for point in ToolpathGeometry.points(of: move, from: previous, segmentAngle: angle) {
                        removal.sweep(from: stockPoint(previous, side: cut.side), to: stockPoint(point, side: cut.side),
                                      axis: axisK, sign: axisSign, tool: shape)
                        // Only credit cavities certainly cleared by horizontal flat-cutter
                        // passes. Shrink for cell error; omit ramps/unsupported profiles.
                        let radius = cut.tool.diameter / 2 - cell * 0.85
                        if cut.side < 2, radius > 0.01, abs(point.z - previous.z) < 1e-6, cut.tool.kind == .flatEndMill {
                            let flat = ToolShape(kind: .flat, radius: radius, length: cut.tool.fluteLength)
                            var p = stockPoint(previous, side: cut.side), q = stockPoint(point, side: cut.side)
                            if cut.side == 1 { p.z -= flat.length; q.z -= flat.length }
                            cleared.sweep(from: p, to: q, tool: flat)
                        }
                        previous = point
                    }
                }
                previous = move.position
            }
            var row: [Bool] = []
            var rejection: [String] = []
            for (i, candidate) in fixtures.enumerated() {
                let fixture = candidate.fixture
                let heavy = [.adaptive, .facing].contains(cut.operation.kind)
                // The origin is for a bare spindle nose at work zero: a tool sticking out
                // further puts the spindle that much higher for the same tip position. The
                // worst excursion past the travel, if any, with its axis.
                let travel: String? = candidate.machineOrigin.flatMap { origin -> String? in
                    let offset = origin + SIMD3(0, 0, cut.tool.stickout)
                    let a = bounds.min + offset, b = bounds.max + offset
                    let e = machine.machineEnvelope
                    var worst: (axis: String, mm: Double)?
                    for (axis, lo, hi, range) in [("X", a.x, b.x, e.x), ("Y", a.y, b.y, e.y), ("Z", a.z, b.z, e.z)] {
                        let over = max(range.lowerBound - lo, hi - range.upperBound, 0)
                        if over > 1e-6, over > (worst?.mm ?? 0) { worst = (axis, over) }
                    }
                    return worst.map { "the \(cut.tool.name) would go \(Length.mm($0.mm)) mm past the machine's \($0.axis) travel (its moves span X \(Length.mm(bounds.min.x))…\(Length.mm(bounds.max.x)), Z \(Length.mm(bounds.min.z))…\(Length.mm(bounds.max.z)))" }
                }
                let reaches = travel == nil
                let field = fields[i], pad = max(cut.tool.diameter / 2, cut.tool.shankDiameter / 2, FixtureClearance.nutRadius) + 0.5
                let covered = bounds.min.x - pad >= field.minX && bounds.max.x + pad <= field.minX + Double(field.nx - 1) * field.cell
                    && bounds.min.y - pad >= field.minY && bounds.max.y + pad <= field.minY + Double(field.ny - 1) * field.cell
                let sized = fitsSide[i][cut.side] == true
                let holds = sized && contactsRemain(fixture, side: cut.side, removal: before) && contactsRemain(fixture, side: cut.side, removal: removal)
                let fits = sized && fitsRemainingStock(candidate.occupied, side: cut.side, cleared: clearedBefore)
                let hits = sized ? FixtureClearance.check(cut.moves, tool: cut.tool, field: &fields[i], limit: 1) : []
                let ok = sized && (!heavy || fixture.planning?.allowsRoughing == true) && reaches && covered && fits && holds && hits.isEmpty
                row.append(ok)
                if !ok {
                    let why = !sized ? "not fitted to the stock this way round"
                        : heavy && fixture.planning?.allowsRoughing != true ? "not defined for roughing/facing"
                        : !reaches ? (travel ?? "outside machine travel") : !covered ? "tool motion leaves the checked CAD region"
                        : !fits ? "fixture intersects material still present at this setup"
                        : !holds ? "grip/support material is absent or removed by the cuts"
                        : "\(hits.first?.part ?? "tool") clearance collision"
                    rejection.append("\(fixture.name): \(why)")
                }
            }
            allowed.append(row)
            if !row.contains(true) {
                let where_ = cut.side == 0 ? "side A" : cut.side == 1 ? "side B" : SetupSide.words(cut.side)
                result.issues.append("\(cut.operation.title) (\(where_)): " + rejection.joined(separator: "; "))
            }
        }
        guard result.issues.isEmpty else { return result }
        let n = fixtures.count, infinity = Int.max / 4
        var cost = Array(repeating: 1, count: n)
        var parents = Array(repeating: Array(repeating: -1, count: n), count: cuts.count)
        for j in 0..<n where !allowed[0][j] { cost[j] = infinity }
        for k in 1..<cuts.count {
            var next = Array(repeating: infinity, count: n)
            for j in 0..<n where allowed[k][j] {
                for i in 0..<n where cost[i] < infinity {
                    let change = i == j && cuts[k].side == cuts[k - 1].side ? 0 : 1
                    if cost[i] + change < next[j] { next[j] = cost[i] + change; parents[k][j] = i }
                }
            }
            cost = next
        }
        guard var best = cost.indices.min(by: { cost[$0] < cost[$1] }), cost[best] < infinity else {
            result.issues = ["No complete fixture sequence covers every operation."]; return result
        }
        var choices = Array(repeating: 0, count: cuts.count)
        for k in cuts.indices.reversed() { choices[k] = best; if k > 0 { best = parents[k][best] } }
        for (k, cut) in cuts.enumerated() {
            let fixture = fixtures[choices[k]].fixture
            if let last = result.steps.last, last.fixture.id == fixture.id, last.side == cut.side {
                let i = result.steps.count - 1
                result.steps[i].cutKeys.append(cut.key)
                if !result.steps[i].operations.contains(cut.operation.title) { result.steps[i].operations.append(cut.operation.title) }
            } else {
                result.steps.append(.init(number: result.steps.count + 1, side: cut.side, fixture: fixture,
                    cutKeys: [cut.key], operations: [cut.operation.title], reasons: [
                        "Owned fixture; assembled stock size and grip definition match.",
                        "Generated cutter, shank and holder paths clear its CAD geometry.",
                        "Defined contact patches remain in the accumulated stock simulation.",
                        "The assembly fits the sampled remaining stock at this point in the job.",
                        result.steps.isEmpty ? "Starts the sequence." : "Re-clamp and establish work zero before continuing."
                    ], modelSignature: fixtures[choices[k]].modelSignature))
            }
        }
        return result
    }

    /// Exact axis-aligned bounds of XY arcs, including extrema between endpoints.
    private static func pathBounds(_ moves: [Move]) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        var previous = moves.first?.position ?? .zero
        for move in moves {
            lo = simd_min(lo, move.position); hi = simd_max(hi, move.position)
            if move.motion != .line {
                let c = SIMD2(previous.x + move.i, previous.y + move.j)
                let r = simd_distance(SIMD2(previous.x, previous.y), c)
                let start = atan2(previous.y - c.y, previous.x - c.x)
                var end = atan2(move.y - c.y, move.x - c.x)
                if move.motion == .arcCCW { while end <= start + 1e-9 { end += 2 * .pi } }
                else { while end >= start - 1e-9 { end -= 2 * .pi } }
                for a in [0.0, .pi / 2, .pi, 3 * .pi / 2] {
                    var theta = a
                    if move.motion == .arcCCW { while theta < start { theta += 2 * .pi } }
                    else { while theta > start { theta -= 2 * .pi } }
                    if theta >= min(start, end) - 1e-9 && theta <= max(start, end) + 1e-9 {
                        let q = SIMD3(c.x + r * cos(theta), c.y + r * sin(theta), move.z)
                        lo = simd_min(lo, q); hi = simd_max(hi, q)
                    }
                }
            }
            previous = move.position
        }
        return (lo, hi)
    }
}


/// Material removed from the stock, in side-A work coordinates, on three dexel grids: columns
/// along A's X (grid 0, plane Y–Z), Y (grid 1, plane X–Z) and Z (grid 2, plane X–Y). A cut
/// lands on the grid along its tool axis, so every setup's removal is exact in its own grid.
struct StockRemoval: Sendable {
    var grids: [DexelGrid]
    let stock: SIMD3<Double>
    let cell: Double

    init(stock s: SIMD3<Double>, cell: Double) {
        (stock, self.cell) = (s, cell)
        grids = [DexelGrid(min: SIMD2(-s.y / 2, -s.z), max: SIMD2(s.y / 2, 0), cell: cell),
                 DexelGrid(min: SIMD2(-s.x / 2, -s.z), max: SIMD2(s.x / 2, 0), cell: cell),
                 DexelGrid(min: SIMD2(-s.x / 2, -s.y / 2), max: SIMD2(s.x / 2, s.y / 2), cell: cell)]
    }

    /// The A axis a side's tool lies along, and whether its shank points along + (tip to holder).
    static func toolAxis(side: Int) -> (Int, Double) {
        let d = SetupSide.rotation(side).transpose * SIMD3(0, 0, 1)
        let k = (0..<3).max { abs(d[$0]) < abs(d[$1]) }!
        return (k, d[k] > 0 ? 1 : -1)
    }

    /// A point's place on grid k: in-plane coordinates and along the columns.
    static func split(_ q: SIMD3<Double>, _ k: Int) -> (SIMD2<Double>, Double) {
        switch k {
        case 0: (SIMD2(q.y, q.z), q.x)
        case 1: (SIMD2(q.x, q.z), q.y)
        default: (SIMD2(q.x, q.y), q.z)
        }
    }

    func span(_ k: Int) -> (lo: Double, hi: Double) {
        switch k {
        case 0: (-stock.x / 2, stock.x / 2)
        case 1: (-stock.y / 2, stock.y / 2)
        default: (-stock.z, 0)
        }
    }

    /// The tool from tip a to tip b (side-A frame), its body along `axis` (`sign`: toward +).
    mutating func sweep(from a: SIMD3<Double>, to b: SIMD3<Double>, axis k: Int, sign: Double, tool: ToolShape) {
        var (pa, wa) = Self.split(a, k), (pb, wb) = Self.split(b, k)
        if sign < 0 { wa -= tool.length; wb -= tool.length }
        let (lo, hi) = span(k)
        guard min(wa, wb) <= hi, max(wa, wb) + tool.length >= lo else { return }
        wa = min(max(wa, lo - tool.length), hi)
        wb = min(max(wb, lo - tool.length), hi)
        grids[k].sweep(from: SIMD3(pa.x, pa.y, wa), to: SIMD3(pb.x, pb.y, wb), tool: tool)
    }

    /// Whether material at q (side-A frame) is gone, within a cell, on any grid.
    func removed(_ q: SIMD3<Double>) -> Bool {
        for k in 0..<3 {
            let g = grids[k]
            let (p, w) = Self.split(q, k)
            let col = Int(((p.x - g.origin.x) / cell).rounded()), row = Int(((p.y - g.origin.y) / cell).rounded())
            guard col >= -1, row >= -1, col <= g.cols, row <= g.rows else { continue }
            for r in max(row - 1, 0)...min(row + 1, g.rows - 1) {
                for c in max(col - 1, 0)...min(col + 1, g.cols - 1) {
                    if g.spans[r * g.cols + c].contains(where: { Double($0.x) - cell <= w && w <= Double($0.y) + cell }) { return true }
                }
            }
        }
        return false
    }
}
