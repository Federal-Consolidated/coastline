import Foundation
import simd

/// Placement rules for the audited two-base bookend mechanism. Coordinates and
/// contact planes come from its CAD manifest; machine slot limits come from its profile.
public struct BookendSetup: Sendable {
    public static let fixed = "fixed-end", clamp = "clamp-end", pressure = "pressure-screw"
    public static let fixedSlide = "fixed-slide", clampSlide = "clamp-slide", pressureExtension = "pressure-extension"

    public struct Definition: Codable, Hashable, Sendable {
        public var seatX: Double
        public var slotZ: [Double]
        public var fixedContactY: Double
        public var clampContactY: Double
        public var screwAxisX: Double
        public var screwAxisZ: Double
        public var stockBackZ: Double
        public var pressureTipRadius: Double
        /// Older saved definitions omitted contact dimensions. Preserve those files,
        /// but require an exact audited rebind before using their mechanical state.
        public var contactMetadataComplete = true
        public var fixedNutY: ClosedRange<Double>
        public var clampNutY: ClosedRange<Double>
        public init(seatX: Double, slotZ: [Double], fixedContactY: Double, clampContactY: Double,
                    screwAxisX: Double, screwAxisZ: Double, stockBackZ: Double, pressureTipRadius: Double, fixedNutY: ClosedRange<Double>, clampNutY: ClosedRange<Double>) {
            self.seatX = seatX; self.slotZ = slotZ; self.fixedContactY = fixedContactY; self.clampContactY = clampContactY
            self.screwAxisX = screwAxisX; self.screwAxisZ = screwAxisZ
            self.stockBackZ = stockBackZ; self.pressureTipRadius = pressureTipRadius; self.fixedNutY = fixedNutY; self.clampNutY = clampNutY
        }
        private enum CodingKeys: String, CodingKey {
            case seatX, slotZ, fixedContactY, clampContactY, screwAxisX, screwAxisZ, stockBackZ, pressureTipRadius
            case fixedNutY, clampNutY, contactMetadataComplete
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            seatX = try c.decode(Double.self, forKey: .seatX)
            slotZ = try c.decode([Double].self, forKey: .slotZ)
            fixedContactY = try c.decode(Double.self, forKey: .fixedContactY)
            clampContactY = try c.decode(Double.self, forKey: .clampContactY)
            screwAxisX = try c.decode(Double.self, forKey: .screwAxisX)
            screwAxisZ = try c.decode(Double.self, forKey: .screwAxisZ)
            fixedNutY = try c.decode(ClosedRange<Double>.self, forKey: .fixedNutY)
            clampNutY = try c.decode(ClosedRange<Double>.self, forKey: .clampNutY)
            let back = try c.decodeIfPresent(Double.self, forKey: .stockBackZ)
            let radius = try c.decodeIfPresent(Double.self, forKey: .pressureTipRadius)
            stockBackZ = back ?? 0
            pressureTipRadius = radius ?? 0
            contactMetadataComplete = (try c.decodeIfPresent(Bool.self, forKey: .contactMetadataComplete) ?? true)
                && back != nil && radius != nil
        }
        public var validationIssues: [String] {
            guard contactMetadataComplete else {
                return ["This older bookend definition is missing stock-locating and screw-contact dimensions. Reload its audited assembly definition before planning."]
            }
            let values = [seatX, fixedContactY, clampContactY, screwAxisX, screwAxisZ, stockBackZ, pressureTipRadius,
                          fixedNutY.lowerBound, fixedNutY.upperBound, clampNutY.lowerBound, clampNutY.upperBound] + slotZ
            guard values.allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }), slotZ.count == 2,
                  abs(slotZ[1] - slotZ[0]) > 0, fixedContactY < clampContactY, pressureTipRadius > 0,
                  fixedNutY.lowerBound < fixedNutY.upperBound, clampNutY.lowerBound < clampNutY.upperBound else {
                return ["The bookend mounting/contact definition is invalid."]
            }
            return []
        }
    }
    public struct Table: Sendable {
        public var topX: Double
        public var slotZ: [Double]
        public var slotY: ClosedRange<Double>
        public var frontZ: Double
        public var centreY: Double
        public init(topX: Double, slotZ: [Double], slotY: ClosedRange<Double>, frontZ: Double, centreY: Double) {
            self.topX = topX; self.slotZ = slotZ; self.slotY = slotY; self.frontZ = frontZ; self.centreY = centreY
        }
    }
    public enum PlacementError: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
    }
    public let definition: Definition
    public let assembly: FixtureAssemblyDefinition
    public let table: Table
    public let stock: SIMD3<Double>
    private let screw: FixtureAssemblyDefinition.Joint

    public init(assembly: FixtureAssemblyDefinition, table: Table, stock: SIMD3<Double>) throws {
        try assembly.validate()
        guard let d = assembly.bookends, d.validationIssues.isEmpty,
              let fixed = assembly.components.first(where: { $0.id == Self.fixed }), fixed.parentID == nil,
              let clamp = assembly.components.first(where: { $0.id == Self.clamp }), clamp.parentID == nil,
              let pressure = assembly.components.first(where: { $0.id == Self.pressure }), pressure.parentID == Self.clamp,
              let screw = pressure.joint, screw.id == Self.pressureExtension, screw.kind == .screw,
              screw.axis == Vec3(0, -1, 0), screw.minimum >= 0,
              fixed.joint?.id == Self.fixedSlide, fixed.joint?.axis == Vec3(0, 1, 0), fixed.joint?.kind == .prismatic,
              clamp.joint?.id == Self.clampSlide, clamp.joint?.axis == Vec3(0, 1, 0), clamp.joint?.kind == .prismatic,
              fixed.joint?.referenceValue == 0, clamp.joint?.referenceValue == 0 else {
            throw PlacementError.invalid("This fixture needs its audited bookend mechanism definition.")
        }
        guard [stock.x, stock.y, stock.z].allSatisfy({ $0.isFinite && $0 > 0 && $0 < 10_000 }),
              [table.topX, table.frontZ, table.centreY, table.slotY.lowerBound, table.slotY.upperBound].allSatisfy(\.isFinite),
              table.slotZ.count == 2, table.slotZ.allSatisfy(\.isFinite), table.slotY.lowerBound < table.slotY.upperBound else {
            throw PlacementError.invalid("Choose stock and a machine with two measured T-slots before seating the bookends.")
        }
        guard abs(abs(d.slotZ[1] - d.slotZ[0]) - abs(table.slotZ[1] - table.slotZ[0])) <= 0.02 else {
            throw PlacementError.invalid("The bookend keys do not match this machine's T-slot spacing.")
        }
        guard d.screwAxisX - d.pressureTipRadius >= d.seatX, d.screwAxisX + d.pressureTipRadius <= d.seatX + stock.x,
              d.screwAxisZ - d.pressureTipRadius >= d.stockBackZ, d.screwAxisZ + d.pressureTipRadius <= d.stockBackZ + stock.z else {
            throw PlacementError.invalid("This stock is too small for the side screw to contact its end face while seated against the locating lip.")
        }
        self.definition = d; self.assembly = assembly; self.table = table; self.stock = stock; self.screw = screw
    }

    /// Seats the keys, seats the stock against the locating lip and brings both contacts to
    /// its end faces. This is geometric contact only, not a grip/load certification.
    public func seat(_ profile: FixturePlanningProfile) throws -> FixturePlanningProfile {
        var p = profile
        p.facing = .plusZ; p.spin = 0; p.componentPlacements = nil
        p.stockSize = Vec3(stock.x, stock.y, stock.z)
        p.datum = Vec3(definition.seatX + stock.x / 2,
                       (definition.fixedContactY + definition.clampContactY - screw.referenceValue) / 2,
                       definition.stockBackZ + stock.z)
        p.facePastTable = table.slotZ.min()! - definition.slotZ.min()! + p.datum.z - table.frontZ
        var state = FixtureAssemblyState(mounted: true)
        state.jointValues[Self.fixedSlide] = p.datum.y - stock.y / 2 - definition.fixedContactY
        state.jointValues[Self.clampSlide] = p.datum.y + stock.y / 2 - definition.clampContactY + screw.referenceValue
        state.jointValues[Self.pressureExtension] = screw.referenceValue
        p.assemblyState = state; p.workspacePlaced = true; p.gripDefinitionReviewed = false
        let contactX = definition.screwAxisX - p.datum.x
        let radius = min(definition.pressureTipRadius, (definition.screwAxisX - definition.seatX) / 2,
                         (definition.seatX + stock.x - definition.screwAxisX) / 2, stock.z / 4)
        var fixedPatch = FixturePlanningProfile.Contact(point: Vec3(contactX, -stock.y / 2, definition.screwAxisZ - p.datum.z), radius: radius)
        var screwPatch = FixturePlanningProfile.Contact(point: Vec3(contactX, stock.y / 2, definition.screwAxisZ - p.datum.z), radius: radius)
        fixedPatch.normal = .y; screwPatch.normal = .y
        p.contacts = [fixedPatch, screwPatch]
        try validate(p)
        return p
    }

    public func value(_ profile: FixturePlanningProfile, jointID: String) -> Double {
        profile.assemblyState?.jointValues[jointID] ?? assembly.components.compactMap(\.joint).first { $0.id == jointID }?.referenceValue ?? 0
    }
    public func gap(_ p: FixturePlanningProfile) -> Double {
        definition.clampContactY + value(p, jointID: Self.clampSlide) - value(p, jointID: Self.pressureExtension) - p.datum.y - stock.y / 2
    }
    public func baseRange(_ p: FixturePlanningProfile, componentID: String) throws -> ClosedRange<Double> {
        let fixed = componentID == Self.fixed
        guard fixed || componentID == Self.clamp,
              let joint = assembly.components.first(where: { $0.id == componentID })?.joint else {
            throw PlacementError.invalid("Select a bookend base to slide along its T-slots.")
        }
        let footprint = fixed ? definition.fixedNutY : definition.clampNutY
        var low = max(joint.minimum, table.slotY.lowerBound - table.centreY + p.datum.y - footprint.lowerBound)
        var high = min(joint.maximum, table.slotY.upperBound - table.centreY + p.datum.y - footprint.upperBound)
        if fixed { high = min(high, p.datum.y - stock.y / 2 - definition.fixedContactY) }
        else { low = max(low, p.datum.y + stock.y / 2 - definition.clampContactY + value(p, jointID: Self.pressureExtension)) }
        guard low <= high + 1e-7 else { throw PlacementError.invalid("The stock and bookend mounting nuts do not fit within the available T-slot length.") }
        return low...max(low, high)
    }
    public func pressureRange(_ p: FixturePlanningProfile) throws -> ClosedRange<Double> {
        let contact = definition.clampContactY + value(p, jointID: Self.clampSlide) - p.datum.y - stock.y / 2
        guard contact >= screw.minimum - 1e-7 else { throw PlacementError.invalid("Slide the clamp base clear of the stock before advancing its side screw.") }
        return screw.minimum...max(screw.minimum, min(screw.maximum, contact))
    }
    public func sliding(_ profile: FixturePlanningProfile, componentID: String, to value: Double) throws -> FixturePlanningProfile {
        guard value.isFinite else { throw PlacementError.invalid("Enter a finite slide distance.") }
        guard profile.assemblyState?.mounted == true else { throw PlacementError.invalid("Seat the bookends on the table first.") }
        if profile.assemblyState?.lockedComponents.contains(componentID) == true { return profile }
        let range = try baseRange(profile, componentID: componentID)
        var p = profile
        p.assemblyState?.jointValues[componentID == Self.fixed ? Self.fixedSlide : Self.clampSlide] = min(range.upperBound, max(range.lowerBound, value))
        if p != profile { p.gripDefinitionReviewed = false }
        return p
    }
    public func settingPressure(_ profile: FixturePlanningProfile, to value: Double) throws -> FixturePlanningProfile {
        guard value.isFinite else { throw PlacementError.invalid("Enter a finite screw extension.") }
        guard profile.assemblyState?.mounted == true else { throw PlacementError.invalid("Seat the bookends on the table first.") }
        let range = try pressureRange(profile)
        var p = profile
        p.assemblyState?.jointValues[Self.pressureExtension] = min(range.upperBound, max(range.lowerBound, value))
        if p != profile { p.gripDefinitionReviewed = false }
        return p
    }
    /// Additional CAM eligibility checks: geometry alone cannot imply a secured setup.
    public func planningIssues(_ p: FixturePlanningProfile) -> [String] {
        do { try validate(p) } catch { return [error.localizedDescription] }
        var issues: [String] = []
        if p.assemblyState?.lockedComponents.isSuperset(of: [Self.fixed, Self.clamp]) != true {
            issues.append("Lock both bookend base positions before planning the cuts.")
        }
        let fixedGap = -stock.y / 2 - (definition.fixedContactY + value(p, jointID: Self.fixedSlide) - p.datum.y)
        if fixedGap > 0.01 || gap(p) > 0.01 { issues.append("Seat both bookends against the stock and advance the side screw to contact.") }
        return issues
    }

    public func validate(_ p: FixturePlanningProfile) throws {
        try assembly.validate(state: p.assemblyState ?? .init())
        guard p.assemblyState?.mounted == true, p.facing == .plusZ, p.spin == 0,
              p.componentPlacements?.isEmpty != false,
              simd_distance(stock, SIMD3(p.stockSize.x, p.stockSize.y, p.stockSize.z)) < 1e-6,
              abs(p.datum.x - definition.seatX - stock.x / 2) < 1e-6,
              abs(p.datum.z - definition.stockBackZ - stock.z) < 1e-6,
              abs(p.facePastTable - (table.slotZ.min()! - definition.slotZ.min()! + p.datum.z - table.frontZ)) < 1e-6 else {
            throw PlacementError.invalid("Seat the bookends to this stock and machine before saving.")
        }
        for id in [Self.fixed, Self.clamp] {
            let range = try baseRange(p, componentID: id), value = value(p, jointID: id == Self.fixed ? Self.fixedSlide : Self.clampSlide)
            guard value >= range.lowerBound - 1e-6, value <= range.upperBound + 1e-6 else {
                throw PlacementError.invalid("A bookend base extends beyond the T-slot or into the stock. Seat it to the stock again.")
            }
        }
        let range = try pressureRange(p), extensionMM = value(p, jointID: Self.pressureExtension)
        guard extensionMM >= range.lowerBound - 1e-6, extensionMM <= range.upperBound + 1e-6 else {
            throw PlacementError.invalid("The side screw intersects the stock. Release it or seat the bookends again.")
        }
    }
}
