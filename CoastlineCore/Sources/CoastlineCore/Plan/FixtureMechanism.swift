import Foundation
import simd

/// Placement rules for a pair of C-clamps that hook under the table and press the stock down
/// onto it. Each clamp slides along the table edge; its screw advances the pad to the stock.
/// Coordinates come from the reviewed CAD (machine planning coordinates: X up, Y across, Z
/// toward the spindle).
public struct ClampPairSetup: Sendable {
    public static let clamps = ["clamp-a", "clamp-b"], screws = ["screw-a", "screw-b"]
    public static let slides = ["clamp-a-slide", "clamp-b-slide"], advances = ["screw-a-advance", "screw-b-advance"]

    public struct Definition: Codable, Hashable, Sendable {
        /// Table top: the stock's lower face.
        public var seatX: Double
        /// The table's spindle-side edge, where the stock face sits.
        public var frontZ: Double
        /// Pad centre depth and radius, and the pad face at the authored pose.
        public var padZ: Double
        public var padRadius: Double
        public var padX: Double
        /// Pad centre across the table for clamp A and B at the authored pose.
        public var padY: [Double]
        /// Half the frame's width across the table: two frames may not overlap.
        public var frameHalfWidth: Double
        public var validationIssues: [String] {
            let values = [seatX, frontZ, padZ, padRadius, padX, frameHalfWidth] + padY
            guard values.allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }), padY.count == 2, padY[0] < padY[1],
                  padRadius > 0, frameHalfWidth > 0, padX > seatX, padZ < frontZ else {
                return ["The C-clamp mounting/contact definition is invalid."]
            }
            return []
        }
    }

    public let definition: Definition
    public let assembly: FixtureAssemblyDefinition
    public let table: BookendSetup.Table
    public let stock: SIMD3<Double>
    let screw: FixtureAssemblyDefinition.Joint

    public init(assembly: FixtureAssemblyDefinition, table: BookendSetup.Table, stock: SIMD3<Double>) throws {
        try assembly.validate()
        guard let d = assembly.clampPair, d.validationIssues.isEmpty,
              let screw = assembly.components.first(where: { $0.id == Self.screws[0] })?.joint else {
            throw BookendSetup.PlacementError.invalid("This fixture needs its reviewed C-clamp definition.")
        }
        for k in 0..<2 {
            guard let clamp = assembly.components.first(where: { $0.id == Self.clamps[k] }), clamp.parentID == nil,
                  clamp.joint?.id == Self.slides[k], clamp.joint?.kind == .prismatic, clamp.joint?.axis == Vec3(0, 1, 0),
                  clamp.joint?.referenceValue == 0,
                  let s = assembly.components.first(where: { $0.id == Self.screws[k] }), s.parentID == Self.clamps[k],
                  s.joint?.id == Self.advances[k], s.joint?.kind == .screw, s.joint?.axis == Vec3(-1, 0, 0),
                  s.joint?.referenceValue == 0, s.joint?.minimum == screw.minimum, s.joint?.maximum == screw.maximum else {
                throw BookendSetup.PlacementError.invalid("This fixture needs its reviewed C-clamp definition.")
            }
        }
        guard [stock.x, stock.y, stock.z].allSatisfy({ $0.isFinite && $0 > 0 && $0 < 10_000 }),
              [table.topX, table.frontZ, table.centreY, table.slotY.lowerBound, table.slotY.upperBound].allSatisfy(\.isFinite) else {
            throw BookendSetup.PlacementError.invalid("Choose stock and a machine with a measured table before fitting the C-clamps.")
        }
        let tallest = d.padX - screw.minimum - d.seatX
        guard stock.x <= tallest + 1e-6 else {
            throw BookendSetup.PlacementError.invalid("The stock is \(DFM.mm(stock.x, 0.1)) mm tall. The C-clamps open to \(DFM.mm(tallest, 0.1)) mm above the table.")
        }
        let deep = d.frontZ - d.padZ + d.padRadius
        guard stock.z >= deep else {
            throw BookendSetup.PlacementError.invalid("The stock is \(DFM.mm(stock.z, 0.1)) mm deep. The C-clamp pads need \(DFM.mm(deep, 0.1)) mm.")
        }
        let wide = 2 * (d.padRadius + 1) + 2 * d.frameHalfWidth + 1
        guard stock.y >= wide else {
            throw BookendSetup.PlacementError.invalid("The stock is \(DFM.mm(stock.y, 0.1)) mm long. Two C-clamps need \(DFM.mm(wide, 0.1)) mm.")
        }
        self.definition = d; self.assembly = assembly; self.table = table; self.stock = stock; self.screw = screw
    }

    /// The stock's top face above the pad at the authored pose: how far each screw advances
    /// to touch it.
    var contactAdvance: Double { definition.padX - (definition.seatX + stock.x) }

    func value(_ p: FixturePlanningProfile, _ joint: String) -> Double { p.assemblyState?.jointValues[joint] ?? 0 }
    func padY(_ p: FixturePlanningProfile, _ k: Int) -> Double { definition.padY[k] + value(p, Self.slides[k]) }

    /// Puts the stock on the table with its face at the table edge, a clamp near each end and
    /// both pads on the top face.
    public func seat(_ profile: FixturePlanningProfile) throws -> FixturePlanningProfile {
        let d = definition
        var p = profile
        p.facing = .plusZ; p.spin = 0; p.componentPlacements = nil
        p.stockSize = Vec3(stock.x, stock.y, stock.z)
        p.datum = Vec3(d.seatX + stock.x / 2, (d.padY[0] + d.padY[1]) / 2, d.frontZ)
        p.facePastTable = p.datum.z - d.frontZ
        let gap = 2 * d.frameHalfWidth + 1
        let inset = max(d.padRadius + 1, min(20, (stock.y - gap) / 2))
        var state = FixtureAssemblyState(mounted: true)
        state.jointValues[Self.slides[0]] = p.datum.y - stock.y / 2 + inset - d.padY[0]
        state.jointValues[Self.slides[1]] = p.datum.y + stock.y / 2 - inset - d.padY[1]
        for id in Self.advances { state.jointValues[id] = contactAdvance }
        p.assemblyState = state; p.workspacePlaced = true; p.gripDefinitionReviewed = false
        p.contacts = contacts(p)
        try validate(p)
        return p
    }

    /// Each pad on the top face, and the table under it.
    func contacts(_ p: FixturePlanningProfile) -> [FixturePlanningProfile.Contact] {
        let d = definition, z = d.padZ - p.datum.z
        let radius = min(d.padRadius, stock.y / 4)
        return (0..<2).flatMap { k -> [FixturePlanningProfile.Contact] in
            let y = padY(p, k) - p.datum.y
            var pad = FixturePlanningProfile.Contact(point: Vec3(stock.x / 2, y, z), radius: radius)
            var support = FixturePlanningProfile.Contact(point: Vec3(-stock.x / 2, y, z), radius: radius)
            pad.normal = .x; support.normal = .x
            return [pad, support]
        }
    }

    public func range(_ p: FixturePlanningProfile, joint: String) throws -> ClosedRange<Double> {
        let d = definition
        if Self.advances.contains(joint) {
            return screw.minimum...max(screw.minimum, min(screw.maximum, contactAdvance))
        }
        guard let k = Self.slides.firstIndex(of: joint) else { throw BookendSetup.PlacementError.invalid("Unknown C-clamp control.") }
        // Pad on the stock, frame on the table, frames apart.
        var low = p.datum.y - stock.y / 2 + d.padRadius
        var high = p.datum.y + stock.y / 2 - d.padRadius
        let tableLow = table.slotY.lowerBound - table.centreY + p.datum.y + d.frameHalfWidth
        let tableHigh = table.slotY.upperBound - table.centreY + p.datum.y - d.frameHalfWidth
        low = max(low, tableLow); high = min(high, tableHigh)
        let gap = 2 * d.frameHalfWidth + 1
        if k == 0 { high = min(high, padY(p, 1) - gap) } else { low = max(low, padY(p, 0) + gap) }
        guard low <= high + 1e-7 else { throw BookendSetup.PlacementError.invalid("The C-clamps don't fit along this stock on the table.") }
        return (low - d.padY[k])...(max(low, high) - d.padY[k])
    }

    public func setting(_ profile: FixturePlanningProfile, joint: String, to value: Double) throws -> FixturePlanningProfile {
        guard value.isFinite else { throw BookendSetup.PlacementError.invalid("Enter a finite value.") }
        guard profile.assemblyState?.mounted == true else { throw BookendSetup.PlacementError.invalid("Fit the C-clamps to the stock first.") }
        let r = try range(profile, joint: joint)
        var p = profile
        p.assemblyState?.jointValues[joint] = min(r.upperBound, max(r.lowerBound, value))
        p.contacts = contacts(p)
        if p != profile { p.gripDefinitionReviewed = false }
        return p
    }

    public func validate(_ p: FixturePlanningProfile) throws {
        try assembly.validate(state: p.assemblyState ?? .init())
        let d = definition
        guard p.assemblyState?.mounted == true, p.facing == .plusZ, p.spin == 0, p.componentPlacements?.isEmpty != false,
              simd_distance(stock, SIMD3(p.stockSize.x, p.stockSize.y, p.stockSize.z)) < 1e-6,
              abs(p.datum.x - d.seatX - stock.x / 2) < 1e-6, abs(p.datum.z - d.frontZ) < 1e-6 else {
            throw BookendSetup.PlacementError.invalid("Fit the C-clamps to this stock again.")
        }
        for joint in Self.slides + Self.advances {
            let r = try range(p, joint: joint), v = value(p, joint)
            guard v >= r.lowerBound - 1e-6, v <= r.upperBound + 1e-6 else {
                throw BookendSetup.PlacementError.invalid("A C-clamp is off the stock or into it. Fit them again.")
            }
        }
    }

    public func planningIssues(_ p: FixturePlanningProfile) -> [String] {
        do { try validate(p) } catch { return [error.localizedDescription] }
        if Self.advances.contains(where: { abs(value(p, $0) - contactAdvance) > 0.01 }) {
            return ["Tighten both C-clamp screws to the stock."]
        }
        return []
    }
}

/// Placement rules for a vise bolted to one T-slot: the stock sits on its floor against the
/// fixed jaw, and the moving jaw closes on the other side.
public struct ViseSetup: Sendable {
    public static let body = "vise-body", jaw = "moving-jaw", jawAdvance = "jaw-advance"

    public struct Definition: Codable, Hashable, Sendable {
        /// The vise floor: the stock's lower face.
        public var seatX: Double
        /// Fixed jaw face (facing +Y) and moving jaw face at the authored pose (facing −Y).
        public var fixedJawY: Double
        public var movingJawY: Double
        /// The jaws' faces span these heights and depths.
        public var jawX: [Double]
        public var jawZ: [Double]
        /// The T-slot the vise bolts to, and its nuts' extent along the slot.
        public var slotZ: [Double]
        public var nutY: [Double]
        /// The table's spindle-side edge.
        public var frontZ: Double
        public var validationIssues: [String] {
            let values = [seatX, fixedJawY, movingJawY, frontZ] + jawX + jawZ + slotZ + nutY
            guard values.allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }), jawX.count == 2, jawZ.count == 2,
                  slotZ.count == 1, nutY.count == 2, jawX[0] < jawX[1], jawZ[0] < jawZ[1], nutY[0] < nutY[1],
                  fixedJawY < movingJawY else {
                return ["The vise mounting/contact definition is invalid."]
            }
            return []
        }
    }

    public let definition: Definition
    public let assembly: FixtureAssemblyDefinition
    public let table: BookendSetup.Table
    public let stock: SIMD3<Double>
    let jawJoint: FixtureAssemblyDefinition.Joint
    /// Machine Z minus model Z, from the slot the vise bolts to.
    let slotOffset: Double

    public init(assembly: FixtureAssemblyDefinition, table: BookendSetup.Table, stock: SIMD3<Double>) throws {
        try assembly.validate()
        guard let d = assembly.vise, d.validationIssues.isEmpty,
              let body = assembly.components.first(where: { $0.id == Self.body }), body.parentID == nil, body.joint == nil,
              let jaw = assembly.components.first(where: { $0.id == Self.jaw }), jaw.parentID == Self.body,
              let joint = jaw.joint, joint.id == Self.jawAdvance, joint.kind == .screw, joint.axis == Vec3(0, -1, 0),
              joint.referenceValue == 0 else {
            throw BookendSetup.PlacementError.invalid("This fixture needs its reviewed vise definition.")
        }
        guard [stock.x, stock.y, stock.z].allSatisfy({ $0.isFinite && $0 > 0 && $0 < 10_000 }),
              [table.topX, table.frontZ, table.centreY, table.slotY.lowerBound, table.slotY.upperBound].allSatisfy(\.isFinite) else {
            throw BookendSetup.PlacementError.invalid("Choose stock and a machine with measured T-slots before fitting the vise.")
        }
        // The vise's slot, in machine Z, must be one of the table's slots.
        let expected = d.slotZ[0] + (table.frontZ - d.frontZ)
        guard let slot = table.slotZ.min(by: { abs($0 - expected) < abs($1 - expected) }), abs(slot - expected) <= 1 else {
            throw BookendSetup.PlacementError.invalid("The vise's mounting nuts don't line up with this machine's T-slots.")
        }
        let opening = (d.movingJawY - joint.maximum - d.fixedJawY)...(d.movingJawY - joint.minimum - d.fixedJawY)
        guard opening.contains(stock.y) else {
            throw BookendSetup.PlacementError.invalid("The stock is \(DFM.mm(stock.y, 0.1)) mm across. The vise holds \(DFM.mm(opening.lowerBound, 0.1))–\(DFM.mm(opening.upperBound, 0.1)) mm.")
        }
        guard stock.x >= 2 else { throw BookendSetup.PlacementError.invalid("The stock is too thin for the vise jaws.") }
        self.definition = d; self.assembly = assembly; self.table = table; self.stock = stock
        self.jawJoint = joint; self.slotOffset = slot - d.slotZ[0]
    }

    /// The vise floor's height above the table.
    public var height: Double { definition.seatX - table.topX }
    var contactAdvance: Double { definition.movingJawY - definition.fixedJawY - stock.y }
    /// How deep the jaws hold the stock: two-thirds of it, up to the jaws' depth.
    var grip: Double { min(definition.jawZ[1] - definition.jawZ[0], max(3, stock.z * 2 / 3)) }

    public func seat(_ profile: FixturePlanningProfile) throws -> FixturePlanningProfile {
        let d = definition
        var p = profile
        p.facing = .plusZ; p.spin = 0; p.componentPlacements = nil
        p.stockSize = Vec3(stock.x, stock.y, stock.z)
        let front = d.jawZ[1] + max(0, stock.z - grip)
        p.datum = Vec3(d.seatX + stock.x / 2, d.fixedJawY + stock.y / 2, front)
        p.facePastTable = front + slotOffset - table.frontZ
        var state = FixtureAssemblyState(mounted: true)
        state.jointValues[Self.jawAdvance] = contactAdvance
        p.assemblyState = state; p.workspacePlaced = true; p.gripDefinitionReviewed = false
        p.contacts = contacts(p)
        try validate(p)
        return p
    }

    func contacts(_ p: FixturePlanningProfile) -> [FixturePlanningProfile.Contact] {
        let d = definition
        let x0 = max(d.jawX[0], d.seatX) - p.datum.x, x1 = min(d.jawX[1], d.seatX + stock.x) - p.datum.x
        let z0 = max(d.jawZ[0], p.datum.z - stock.z) - p.datum.z, z1 = min(d.jawZ[1], p.datum.z) - p.datum.z
        let x = (x0 + x1) / 2, z = (z0 + z1) / 2
        let r = max(0.5, min((x1 - x0) / 2, (z1 - z0) / 2, 6))
        var fixed = FixturePlanningProfile.Contact(point: Vec3(x, -stock.y / 2, z), radius: r)
        var moving = FixturePlanningProfile.Contact(point: Vec3(x, stock.y / 2, z), radius: r)
        var floor = FixturePlanningProfile.Contact(point: Vec3(-stock.x / 2, 0, z), radius: max(0.5, min(stock.y / 4, (z1 - z0) / 2, 6)))
        fixed.normal = .y; moving.normal = .y; floor.normal = .x
        return [fixed, moving, floor]
    }

    public func range(_ p: FixturePlanningProfile, joint: String) throws -> ClosedRange<Double> {
        guard joint == Self.jawAdvance else { throw BookendSetup.PlacementError.invalid("Unknown vise control.") }
        return jawJoint.minimum...max(jawJoint.minimum, min(jawJoint.maximum, contactAdvance))
    }

    public func setting(_ profile: FixturePlanningProfile, joint: String, to value: Double) throws -> FixturePlanningProfile {
        guard value.isFinite else { throw BookendSetup.PlacementError.invalid("Enter a finite value.") }
        guard profile.assemblyState?.mounted == true else { throw BookendSetup.PlacementError.invalid("Fit the vise to the stock first.") }
        let r = try range(profile, joint: joint)
        var p = profile
        p.assemblyState?.jointValues[joint] = min(r.upperBound, max(r.lowerBound, value))
        if p != profile { p.gripDefinitionReviewed = false }
        return p
    }

    public func validate(_ p: FixturePlanningProfile) throws {
        try assembly.validate(state: p.assemblyState ?? .init())
        let d = definition
        guard p.assemblyState?.mounted == true, p.facing == .plusZ, p.spin == 0, p.componentPlacements?.isEmpty != false,
              simd_distance(stock, SIMD3(p.stockSize.x, p.stockSize.y, p.stockSize.z)) < 1e-6,
              abs(p.datum.x - d.seatX - stock.x / 2) < 1e-6, abs(p.datum.y - d.fixedJawY - stock.y / 2) < 1e-6,
              abs(p.facePastTable - (p.datum.z + slotOffset - table.frontZ)) < 1e-6 else {
            throw BookendSetup.PlacementError.invalid("Fit the vise to this stock again.")
        }
        // The nuts stay in the slot with the stock at the machine's travel centre.
        let low = d.nutY[0] - p.datum.y + table.centreY, high = d.nutY[1] - p.datum.y + table.centreY
        guard low >= table.slotY.lowerBound - 1e-6, high <= table.slotY.upperBound + 1e-6 else {
            throw BookendSetup.PlacementError.invalid("The vise's nuts run past the end of the T-slot.")
        }
        let r = try range(p, joint: Self.jawAdvance), v = p.assemblyState?.jointValues[Self.jawAdvance] ?? 0
        guard v >= r.lowerBound - 1e-6, v <= r.upperBound + 1e-6 else {
            throw BookendSetup.PlacementError.invalid("The moving jaw is into the stock. Open it or fit the vise again.")
        }
    }

    public func planningIssues(_ p: FixturePlanningProfile) -> [String] {
        do { try validate(p) } catch { return [error.localizedDescription] }
        if abs((p.assemblyState?.jointValues[Self.jawAdvance] ?? 0) - contactAdvance) > 0.01 { return ["Close the vise on the stock."] }
        return []
    }
}

/// A reviewed fixture mechanism that fits itself to the stock. Fixtures without one are placed
/// by hand.
public enum FixtureMechanism: Sendable {
    case bookends(BookendSetup), clampPair(ClampPairSetup), vise(ViseSetup)

    /// One adjustable joint, for the placement controls.
    public struct Control: Sendable, Identifiable, Hashable {
        public var id: String
        public var title: String
        public var componentID: String
        /// A screw, shown in turns of its pitch; else a slide in mm.
        public var pitch: Double?
        /// Its value grows toward the stock.
        public var tightens: Bool
    }

    public static func has(_ assembly: FixtureAssemblyDefinition?) -> Bool {
        guard let a = assembly else { return false }
        return a.bookends != nil || a.clampPair != nil || a.vise != nil
    }

    /// nil when the fixture has no reviewed mechanism; throws when it has one and the stock
    /// doesn't fit it.
    public static func make(_ fixture: Fixture, table: BookendSetup.Table, stock: SIMD3<Double>) throws -> FixtureMechanism? {
        guard let a = fixture.assembly else { return nil }
        if a.bookends != nil { return .bookends(try BookendSetup(assembly: a, table: table, stock: stock)) }
        if a.clampPair != nil { return .clampPair(try ClampPairSetup(assembly: a, table: table, stock: stock)) }
        if a.vise != nil { return .vise(try ViseSetup(assembly: a, table: table, stock: stock)) }
        return nil
    }

    /// How far it raises the stock above the table.
    public var height: Double {
        switch self {
        case .bookends, .clampPair: 0
        case .vise(let v): v.height
        }
    }

    public var controls: [Control] {
        switch self {
        case .bookends:
            return []
        case .clampPair(let c):
            let pitch = c.screw.pitch
            return [
                Control(id: ClampPairSetup.slides[0], title: "Clamp A position", componentID: ClampPairSetup.clamps[0], pitch: nil, tightens: false),
                Control(id: ClampPairSetup.advances[0], title: "Clamp A screw", componentID: ClampPairSetup.screws[0], pitch: pitch, tightens: true),
                Control(id: ClampPairSetup.slides[1], title: "Clamp B position", componentID: ClampPairSetup.clamps[1], pitch: nil, tightens: false),
                Control(id: ClampPairSetup.advances[1], title: "Clamp B screw", componentID: ClampPairSetup.screws[1], pitch: pitch, tightens: true),
            ]
        case .vise(let v):
            return [Control(id: ViseSetup.jawAdvance, title: "Vise jaw", componentID: ViseSetup.jaw, pitch: v.jawJoint.pitch, tightens: true)]
        }
    }

    public func seat(_ p: FixturePlanningProfile) throws -> FixturePlanningProfile {
        switch self {
        case .bookends(let b):
            var seated = try b.seat(p)
            seated.assemblyState?.lockedComponents = [BookendSetup.fixed, BookendSetup.clamp]
            return seated
        case .clampPair(let c): return try c.seat(p)
        case .vise(let v): return try v.seat(p)
        }
    }

    public func validate(_ p: FixturePlanningProfile) throws {
        switch self {
        case .bookends(let b): try b.validate(p)
        case .clampPair(let c): try c.validate(p)
        case .vise(let v): try v.validate(p)
        }
    }

    public func planningIssues(_ p: FixturePlanningProfile) -> [String] {
        switch self {
        case .bookends(let b): b.planningIssues(p)
        case .clampPair(let c): c.planningIssues(p)
        case .vise(let v): v.planningIssues(p)
        }
    }

    public func value(_ p: FixturePlanningProfile, joint: String) -> Double {
        p.assemblyState?.jointValues[joint] ?? 0
    }

    public func range(_ p: FixturePlanningProfile, joint: String) throws -> ClosedRange<Double> {
        switch self {
        case .bookends: throw BookendSetup.PlacementError.invalid("Use the bookend controls.")
        case .clampPair(let c): try c.range(p, joint: joint)
        case .vise(let v): try v.range(p, joint: joint)
        }
    }

    public func setting(_ p: FixturePlanningProfile, joint: String, to value: Double) throws -> FixturePlanningProfile {
        switch self {
        case .bookends: throw BookendSetup.PlacementError.invalid("Use the bookend controls.")
        case .clampPair(let c): try c.setting(p, joint: joint, to: value)
        case .vise(let v): try v.setting(p, joint: joint, to: value)
        }
    }

    /// The fixture fitted to this stock for an automatic plan. Its mechanism sets the contacts,
    /// so the grip definition counts as reviewed; every setup is still reviewed before export.
    public static func automatic(_ fixture: Fixture, table: BookendSetup.Table, stock: SIMD3<Double>) throws -> Fixture? {
        guard let mechanism = try make(fixture, table: table, stock: stock) else { return nil }
        var f = fixture
        var p = f.planning ?? FixturePlanningProfile()
        let roughing: Bool
        if case .bookends = mechanism { roughing = p.allowsRoughing } else { roughing = true }
        p = try mechanism.seat(p)
        // The same fit must give the same fixture, so its preview and checks are reused.
        for k in p.contacts.indices {
            p.contacts[k].id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, UInt8(k)))
        }
        p.enabled = true
        p.allowsRoughing = roughing
        p.gripDefinitionReviewed = true
        p.componentModelSignature = f.assembly?.modelSHA256.lowercased()
        p.componentLayoutID = try f.assembly.map(LibraryFixtureGeometry.layoutID)
        f.planning = p
        f.height = mechanism.height
        return f
    }
}
