import Foundation
import simd

/// One setup: how the part sits in the stock and how the stock sits in the machine.
///
/// **Work frame** (the WCS the G-code uses), aligned with the machine axes:
/// - +X up (the table's vertical travel; X− lifts the table, so the tool moves "down" the work)
/// - +Y to the operator's right (gantry)
/// - +Z along the spindle toward the tool: the tool comes from +Z and cuts toward −Z
/// - origin: the centre of the stock's top face (the face toward the spindle), so Z = 0 is
///   the stock surface and the part is below it. This matches the maker's edge-finding
///   (midpoints with M100) and paper touch-off on the top face.
///
/// The machine is a horizontal-spindle mill: "top face" means the face pointing at the spindle,
/// and the stock stands on the table with its X extent vertical.
public struct Setup: Equatable, Sendable, Codable {
    public enum Workholding: String, CaseIterable, Identifiable, Sendable, Codable {
        /// A fixture of the user's own (`customFixture`): its geometry isn't modelled, so it is
        /// outside the collision checks.
        case custom
        public var id: Self { self }
    }

    /// nil: Coastline plans the workholding from the fixture library. A user's explicit choice
    /// is never replaced automatically.
    public var holding: Workholding?
    public var planFromFixtureLibrary = false
    public var customFixture = CustomFixture()
    /// Complete job-owned fixture definitions and mechanical positions before CAM exists.
    public var fixtureAssemblies: [Fixture]? = nil
    /// Workholding explicitly available to this job. nil preserves older jobs' automatic
    /// library selection; an empty list deliberately allows no fixtures.
    public var selectedFixtureIDs: [UUID]? = nil

    /// Replace the holding method as a single value.
    public func selectingHolding(_ method: Workholding) -> Setup {
        var s = self
        s.planFromFixtureLibrary = false
        s.holding = method
        return s
    }

    /// Placement and setup notes for workholding outside the fixture library.
    /// Its detailed geometry is not modelled by the fixture clearance checker.
    public struct CustomFixture: Equatable, Sendable, Codable {
        public var name = "Vise / custom fixture"
        public var height = 0.0
        public var faceProtrusion = 2.0
        public var notes = ""
        public init() {}
    }

    /// Which part axis points at the spindle (becomes +Z of the work frame).
    public enum Facing: String, CaseIterable, Sendable, Codable {
        case plusZ, minusZ, plusX, minusX, plusY, minusY
        public var title: String {
            switch self {
            case .plusZ: "+Z (top)"
            case .minusZ: "−Z (bottom)"
            case .plusX: "+X"
            case .minusX: "−X"
            case .plusY: "+Y"
            case .minusY: "−Y"
            }
        }
    }

    public var facing: Facing = .plusZ
    /// Quarter turns about the tool axis (0…3).
    public var spin: Int = 0
    /// Stock dimension (0, 1, 2 = its x, y, z) that runs along each work axis.
    /// Default: thinnest along Z (toward the spindle), longest along Y (the long gantry travel).
    public var stockAxes: [Int] = [1, 0, 2]
    /// Material left above the part, to face off first, mm.
    public var topAllowance: Double = 0.5
    /// Part offset from the stock centre in work X and Y, mm.
    public var partOffsetX: Double = 0
    public var partOffsetY: Double = 0
    /// Uniform scale of the imported part (1 = as modelled), so a big design can be machined
    /// smaller from the stock there is.
    public var partScale: Double = 1
    /// Side B of a two-sided job: the stock is turned front-to-back about the vertical (X) axis,
    /// so the back of the part faces the spindle.
    public var flipped = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case fixtureAssemblies, selectedFixtureIDs, planFromFixtureLibrary, holding, customFixture, facing, spin, stockAxes, topAllowance, partOffsetX, partOffsetY, flipped, partScale
    }

    /// Tolerant decoding: sessions saved by older versions miss newer keys, and may name holding
    /// methods that no longer exist (they fall back to the library).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planFromFixtureLibrary = try c.decodeIfPresent(Bool.self, forKey: .planFromFixtureLibrary) ?? false
        fixtureAssemblies = try c.decodeIfPresent([Fixture].self, forKey: .fixtureAssemblies)
        selectedFixtureIDs = try c.decodeIfPresent([UUID].self, forKey: .selectedFixtureIDs)
        holding = (try? c.decodeIfPresent(Workholding.self, forKey: .holding)) ?? nil
        customFixture = try c.decodeIfPresent(CustomFixture.self, forKey: .customFixture) ?? CustomFixture()
        facing = try c.decodeIfPresent(Facing.self, forKey: .facing) ?? .plusZ
        spin = try c.decodeIfPresent(Int.self, forKey: .spin) ?? 0
        stockAxes = try c.decodeIfPresent([Int].self, forKey: .stockAxes) ?? [1, 0, 2]
        topAllowance = try c.decodeIfPresent(Double.self, forKey: .topAllowance) ?? 0.5
        partOffsetX = try c.decodeIfPresent(Double.self, forKey: .partOffsetX) ?? 0
        partOffsetY = try c.decodeIfPresent(Double.self, forKey: .partOffsetY) ?? 0
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        partScale = try c.decodeIfPresent(Double.self, forKey: .partScale) ?? 1
    }

    // MARK: Part transform

    /// Rotation from part coordinates into the work frame.
    public var partRotation: simd_double3x3 {
        let base: simd_double3x3
        switch facing {
        case .plusZ: base = matrix_identity_double3x3
        case .minusZ: base = Self.rotation(axis: SIMD3(1, 0, 0), quarterTurns: 2)
        case .plusX: base = Self.rotation(axis: SIMD3(0, 1, 0), quarterTurns: -1)
        case .minusX: base = Self.rotation(axis: SIMD3(0, 1, 0), quarterTurns: 1)
        case .plusY: base = Self.rotation(axis: SIMD3(1, 0, 0), quarterTurns: 1)
        case .minusY: base = Self.rotation(axis: SIMD3(1, 0, 0), quarterTurns: -1)
        }
        let r = Self.rotation(axis: SIMD3(0, 0, 1), quarterTurns: spin) * base
        return flipped ? Self.rotation(axis: SIMD3(1, 0, 0), quarterTurns: 2) * r : r
    }

    /// The part turned a quarter turn (or several) about a work axis (0 = X, 1 = Y, 2 = Z), as
    /// the orientation (facing + spin) that gives exactly that rotation.
    public func turned(about axis: Int, quarterTurns q: Int) -> Setup {
        var unit = SIMD3<Double>(0, 0, 0)
        unit[axis] = 1
        var plain = self
        plain.flipped = false
        let want = Self.rotation(axis: unit, quarterTurns: q) * plain.partRotation
        var out = self
        for f in Facing.allCases {
            for spin in 0..<4 {
                var t = plain
                t.facing = f
                t.spin = spin
                let r = t.partRotation
                if (0..<3).allSatisfy({ simd_length(r[$0] - want[$0]) < 1e-9 }) {
                    out.facing = f
                    out.spin = spin
                    return out
                }
            }
        }
        return out
    }

    /// Side B of this setup for the same stock: turned front-to-back about X, so work y → −y and
    /// z → −T − z. The part keeps its place in the stock: its top is now as far below the new
    /// face as its bottom was above the old stock bottom.
    public func sideB(partMin lo: SIMD3<Double>, partMax hi: SIMD3<Double>, stock: StockItem) -> Setup {
        var b = self
        b.flipped = true
        let thickness = stockSize(stock).z
        let (rlo, rhi) = rotatedPartBounds(min: lo, max: hi)
        b.topAllowance = thickness - topAllowance - (rhi.z - rlo.z)
        b.partOffsetY = -partOffsetY
        return b
    }

    /// Maps a side-A work Z to side B (−T − z).
    public func sideBZ(_ z: Double, stock: StockItem) -> Double { -stockSize(stock).z - z }

    /// Exact quarter-turn rotation (no floating-point drift: entries are −1, 0 or 1).
    static func rotation(axis: SIMD3<Double>, quarterTurns: Int) -> simd_double3x3 {
        let q = ((quarterTurns % 4) + 4) % 4
        let c = [1.0, 0, -1, 0][q], s = [0.0, 1, 0, -1][q]
        let (x, y, z) = (axis.x, axis.y, axis.z)
        // Rodrigues for a unit axis, with exact c/s.
        return simd_double3x3(rows: [
            SIMD3(c + x * x * (1 - c), x * y * (1 - c) - z * s, x * z * (1 - c) + y * s),
            SIMD3(y * x * (1 - c) + z * s, c + y * y * (1 - c), y * z * (1 - c) - x * s),
            SIMD3(z * x * (1 - c) - y * s, z * y * (1 - c) + x * s, c + z * z * (1 - c)),
        ])
    }

    /// Part bounds (part coordinates) → rotated bounds in the work frame (before translation).
    public func rotatedPartBounds(min lo: SIMD3<Double>, max hi: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        var rlo = SIMD3<Double>(repeating: .infinity), rhi = -rlo
        for i in 0..<8 {
            let c = SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
            let r = partRotation * c * partScale
            rlo = simd_min(rlo, r)
            rhi = simd_max(rhi, r)
        }
        return (rlo, rhi)
    }

    /// Full part → work transform (rotation, then translation that puts the part's top
    /// `topAllowance` below Z = 0 and centres it in X/Y plus the offsets).
    public func partToWork(partMin lo: SIMD3<Double>, partMax hi: SIMD3<Double>) -> simd_double4x4 {
        let (rlo, rhi) = rotatedPartBounds(min: lo, max: hi)
        let t = SIMD3(partOffsetX - (rlo.x + rhi.x) / 2,
                      partOffsetY - (rlo.y + rhi.y) / 2,
                      -topAllowance - rhi.z)
        let r = partRotation * partScale
        return simd_double4x4(columns: (
            SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(t, 1)
        ))
    }

    // MARK: Stock

    /// Stock size along work X, Y, Z.
    public func stockSize(_ stock: StockItem) -> SIMD3<Double> { rawStockSize(stock) }

    /// The stock as bought, along work X, Y, Z.
    public func rawStockSize(_ stock: StockItem) -> SIMD3<Double> {
        let e = [stock.envelope.x, stock.envelope.y, stock.envelope.z]
        return SIMD3(e[stockAxes[0]], e[stockAxes[1]], e[stockAxes[2]])
    }

    /// Stock box in the work frame.
    public func stockBox(_ stock: StockItem) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        let s = stockSize(stock)
        return (SIMD3(-s.x / 2, -s.y / 2, -s.z), SIMD3(s.x / 2, s.y / 2, 0))
    }

    /// The stock as triangles (work frame): the box.
    public func stockTriangles(stockSize s: SIMD3<Double>) -> [SIMD3<Double>] {
        Collision.boxTriangles(min: SIMD3(-s.x / 2, -s.y / 2, -s.z), max: SIMD3(s.x / 2, s.y / 2, 0))
    }

    /// Physical placement inside the blank, without inventing a machining allowance on a
    /// face that is already to size. Workholding clearance is checked separately.
    public func placementLimits(partMin: SIMD3<Double>, partMax: SIMD3<Double>, stock: StockItem,
                                toolDiameter: Double = 6.35) -> (x: ClosedRange<Double>, y: ClosedRange<Double>, depth: ClosedRange<Double>) {
        let (lo, hi) = rotatedPartBounds(min: partMin, max: partMax)
        let size = hi - lo
        let raw = stockSize(stock)
        let mx = max((raw.x - size.x) / 2, 0), my = max((raw.y - size.y) / 2, 0)
        return (-mx...mx, -my...my, 0...max(raw.z - size.z, 0))
    }

    /// The default stock arrangement: thinnest dimension toward the spindle, longest along Y.
    public static func defaultStockAxes(_ stock: StockItem) -> [Int] {
        let e = [stock.envelope.x, stock.envelope.y, stock.envelope.z]
        let order = [0, 1, 2].sorted { e[$0] < e[$1] }  // thin, mid, long
        return [order[1], order[2], order[0]]           // X ← mid, Y ← long, Z ← thin
    }

    /// The default part orientation: thinnest part dimension along the tool axis, longest along Y.
    public static func defaultOrientation(partMin lo: SIMD3<Double>, partMax hi: SIMD3<Double>) -> (Facing, Int) {
        let size = hi - lo
        let thin = [0, 1, 2].min { size[$0] < size[$1] }!
        let facing: Facing = [.plusX, .plusY, .plusZ][thin]
        var best = (facing, 0)
        for spin in 0..<4 {
            var s = Setup()
            s.facing = facing
            s.spin = spin
            let (rlo, rhi) = s.rotatedPartBounds(min: lo, max: hi)
            if rhi.y - rlo.y >= rhi.x - rlo.x - 1e-9 { best = (facing, spin); break }
        }
        return best
    }
}

/// Fit checks for a setup. Plain-language results, like the inventory checks.
public enum SetupChecks {
    public static func check(_ setup: Setup, partMin lo: SIMD3<Double>, partMax hi: SIMD3<Double>,
                             stock: StockItem, machine: MachineProfile = .standard) -> [Issue] {
        var issues: [Issue] = []
        let m = setup.partToWork(partMin: lo, partMax: hi)
        let (rlo, rhi) = setup.rotatedPartBounds(min: lo, max: hi)
        let shift = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let plo = rlo + shift, phi = rhi + shift
        let box = setup.stockBox(stock)
        let names = ["X (vertical)", "Y (left–right)"]
        for axis in 0..<2 {
            let slackLow = plo[axis] - box.min[axis], slackHigh = box.max[axis] - phi[axis]
            let slack = min(slackLow, slackHigh)
            if slack < -1e-6 {
                issues.append(Issue(.error, "The part sticks out of the stock in \(names[axis]) by \(Length.mm(-slack)) mm. Use bigger stock, turn the part, or move it."))
            } else if slack < 1e-6 {
                issues.append(Issue(.info, "The part meets an existing stock face in \(names[axis]). No extra stock is required on a face that stays as supplied."))
            } else if slack < 3 {
                issues.append(Issue(.info, "\(Length.mm(slack)) mm of stock around the part in \(names[axis]). Tool and fixture clearance is checked on the generated paths."))
            }
        }
        let depth = phi.z - plo.z + setup.topAllowance
        let thickness = box.max.z - box.min.z
        if depth > thickness + 1e-6 {
            issues.append(Issue(.error, "The part (\(Length.mm(phi.z - plo.z)) mm deep plus \(Length.mm(setup.topAllowance)) mm to face) is thicker than the stock (\(Length.mm(thickness)) mm)."))
        } else if thickness - depth < 2 {
            issues.append(Issue(.info, "The part reaches the stock's back face. Any cut that frees it needs independent support or holding tabs."))
        }
        // Reach: the tool has to cover the stock face in X and Y.
        let size = setup.stockSize(stock)
        if size.x > machine.travel.x {
            issues.append(Issue(.error, "The stock is \(Length.mm(size.x)) mm tall in X; the machine only travels \(Length.mm(machine.travel.x)) mm vertically."))
        }
        if size.y > machine.travel.y {
            issues.append(Issue(.error, "The stock is \(Length.mm(size.y)) mm wide in Y; the machine travels \(Length.mm(machine.travel.y)) mm."))
        }
        if phi.z - plo.z > 25 {
            issues.append(Issue(.info, "The part is \(Length.mm(phi.z - plo.z)) mm deep along the spindle. Deep walls need long tools; the planner will check reach per tool."))
        }
        return issues
    }
}
