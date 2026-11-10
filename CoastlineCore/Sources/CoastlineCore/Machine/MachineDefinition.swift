import Foundation

/// Portable authored machine data. Loading a definition never selects it for machine control.
/// Geometry and frame origins are in CAD-world millimetres at model-axis position zero.
public struct MachineDefinition: Codable, Equatable, Sendable {
    /// Renderer arithmetic uses Float, including squared distances. This generous numeric
    /// domain reserves headroom for transforms; it is not a physical machine-size limit.
    public static let maximumCoordinateMagnitude = Double(Float.greatestFiniteMagnitude).squareRoot() / 1024
    public var schemaVersion: Int
    public var id: String
    public var revision: Int
    public var name: String
    public var manufacturer: String?
    public var units: String
    public var process: String
    public var controller: String
    /// Explicit Coastline output adapter, independent of a Fusion library post URL.
    public var postProcessorID: String?
    public var verification: MachineVerification
    public var profile: MachineProfile
    public var assets: [MachineAsset]
    public var components: [MachineComponent]
    public var frames: [MachineFrame]
    public var mountingInterfaces: [MachineMountingInterface]
    public var sources: [MachineSource]
    public var evidence: [MachineEvidence]
    public var findings: [MachineFinding]
    /// Optional in schema 1 for compatibility with the first package revision.
    public var checks: [MachineValidationCheck]?
    /// A digital setup specimen, not the stock selected for a machining job.
    public var referenceStock: MachineReferenceStock?

    public var reference: MachineDefinitionReference { .init(id: id, revision: revision) }
    public var blockingFindings: [MachineFinding] { findings.filter { $0.severity == .blocking } }
    public var validationChecks: [MachineValidationCheck] { checks ?? [] }

    public func validationStatus(for scope: MachineValidationScope) -> MachineValidationStatus {
        let scoped = validationChecks.filter { $0.scope == scope }
        if scoped.contains(where: { $0.status == .failed }) { return .failed }
        return !scoped.isEmpty && scoped.allSatisfy { $0.status == .passed } ? .passed : .pending
    }

    public var supportsDigitalSetup: Bool {
        [.geometry, .kinematics, .setupPlacement].allSatisfy { validationStatus(for: $0) == .passed }
    }

    /// Position inferred from explicitly defined axis homes and controller mappings, not envelope corners.
    public var controllerHomePosition: Vec3 {
        var result = Vec3.zero
        for axis in components.compactMap(\.axis) { result[axis.coordinate] = axis.controllerHome }
        return result
    }

    /// Authored travel mapped into controller coordinates; not a replacement for live soft limits.
    public var controllerEnvelope: AxisBox {
        var ranges: [MachineCoordinate: ClosedRange<Double>] = [:]
        for axis in components.compactMap(\.axis) { ranges[axis.coordinate] = axis.controllerRange }
        return AxisBox(x: ranges[.x] ?? 0...0, y: ranges[.y] ?? 0...0, z: ranges[.z] ?? 0...0)
    }

    /// Additive translations are sufficient for the supported three-linear-axis model.
    /// A child inherits every moving ancestor (for example Z rides on Y).
    public func worldTranslation(for componentID: String, at controllerPosition: Vec3) throws -> Vec3 {
        guard controllerPosition.isFinite else { throw MachineDefinitionError("Machine position must be finite.") }
        var result = Vec3.zero, current: String? = componentID, visited = Set<String>()
        while let id = current {
            guard visited.insert(id).inserted, let component = components.first(where: { $0.id == id }) else {
                throw MachineDefinitionError("Invalid machine component chain at '\(id)'.")
            }
            if let axis = component.axis {
                let q = axis.modelPosition(for: controllerPosition[axis.coordinate])
                result = result.adding(axis.direction.scaled(by: q))
                guard q.isFinite && result.fitsPreviewCoordinates(multiplier: 8) else {
                    throw MachineDefinitionError("Machine motion exceeds the supported numeric range.")
                }
            }
            current = component.parentID
        }
        return result
    }

    public func worldOrigin(for frameID: String, at controllerPosition: Vec3) throws -> Vec3 {
        guard let frame = frames.first(where: { $0.id == frameID }) else {
            throw MachineDefinitionError("Unknown machine frame '\(frameID)'.")
        }
        let result = try frame.origin.adding(worldTranslation(for: frame.componentID, at: controllerPosition))
        guard result.fitsPreviewCoordinates(multiplier: 8) else { throw MachineDefinitionError("Machine frame exceeds the supported numeric range.") }
        return result
    }

    /// A frame-local direction expressed in CAD world axes. These are basis vectors,
    /// not controller axis letters: the seating frame and machining WCS can differ.
    public func worldDirection(_ local: Vec3, in frameID: String) throws -> Vec3 {
        guard local.fitsPreviewCoordinates(), let frame = frames.first(where: { $0.id == frameID }) else {
            throw MachineDefinitionError("Unknown frame or invalid local direction for '\(frameID)'.")
        }
        let result = frame.xDirection.scaled(by: local.x).adding(frame.yDirection.scaled(by: local.y))
            .adding(frame.zDirection.scaled(by: local.z))
        guard result.fitsPreviewCoordinates(multiplier: 8) else { throw MachineDefinitionError("Frame direction exceeds the supported numeric range.") }
        return result
    }

    /// A frame-local point in world millimetres. A nil position means the authored
    /// CAD pose q=0, not controller MPos=0 (which generally has different offsets).
    public func worldPoint(_ local: Vec3, in frameID: String, at controllerPosition: Vec3? = nil) throws -> Vec3 {
        guard let frame = frames.first(where: { $0.id == frameID }) else {
            throw MachineDefinitionError("Unknown machine frame '\(frameID)'.")
        }
        let origin = try controllerPosition.map { try worldOrigin(for: frameID, at: $0) } ?? frame.origin
        let result = try origin.adding(worldDirection(local, in: frameID))
        guard result.fitsPreviewCoordinates(multiplier: 8) else { throw MachineDefinitionError("Frame point exceeds the supported numeric range.") }
        return result
    }

    /// Eight corners ordered by X/Y/Z bits in the reference specimen's local frame.
    public func referenceStockCorners(at controllerPosition: Vec3? = nil) throws -> [Vec3] {
        guard let stock = referenceStock else { return [] }
        return try (0..<8).map { corner in
            let point = Vec3(stock.minimum.x + (corner & 1 == 0 ? 0 : stock.size.x),
                             stock.minimum.y + (corner & 2 == 0 ? 0 : stock.size.y),
                             stock.minimum.z + (corner & 4 == 0 ? 0 : stock.size.z))
            return try worldPoint(point, in: stock.frameID, at: controllerPosition)
        }
    }
}

public struct MachineDefinitionReference: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var revision: Int
    public init(id: String, revision: Int) { self.id = id; self.revision = revision }
}

public enum MachineVerification: String, Codable, Sendable { case draft, digital, hardware }
public enum MachineCoordinate: String, Codable, CaseIterable, Sendable { case x, y, z }
public enum MachineComponentRole: String, Codable, Sendable { case `static`, linearAxis, table, head }
public enum MachineAssetRole: String, Codable, Sendable { case geometry, fusionDefinition, fusionArchive, reference }
public enum MachineEvidenceStatus: String, Codable, Sendable { case source, inferred, measured, verified, unresolved }
public enum MachineFindingSeverity: String, Codable, Sendable { case blocking, warning, information }
public enum MachineValidationScope: String, Codable, CaseIterable, Sendable {
    case geometry, kinematics, setupPlacement, tooling, controller, hardware
}
public enum MachineValidationStatus: String, Codable, Sendable { case passed, pending, failed }

public struct MachineValidationCheck: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var scope: MachineValidationScope
    public var status: MachineValidationStatus
    public var detail: String
    public var sourceIDs: [String]
    public var action: String?
    public init(id: String, title: String, scope: MachineValidationScope, status: MachineValidationStatus,
                detail: String, sourceIDs: [String], action: String? = nil) {
        self.id = id; self.title = title; self.scope = scope; self.status = status
        self.detail = detail; self.sourceIDs = sourceIDs; self.action = action
    }
}

public struct MachineReferenceStock: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var frameID: String
    public var minimum: Vec3
    /// Local frame X length, Y width, Z height; no automatic permutation by bbox size.
    public var size: Vec3
    public init(id: String, name: String, frameID: String, minimum: Vec3 = .zero, size: Vec3) {
        self.id = id; self.name = name; self.frameID = frameID; self.minimum = minimum; self.size = size
    }
}

public struct MachineComponent: Codable, Equatable, Sendable {
    public var id: String
    public var parentID: String?
    public var role: MachineComponentRole
    /// STEP occurrence index paths. The most specific matching ancestor owns a body.
    public var modelEntities: [String]
    public var axis: MachineLinearAxis?
    /// Presentation metadata only. Hiding an enclosure never removes it from the machine definition.
    public var isEnclosure: Bool?
}

public struct MachineLinearAxis: Codable, Equatable, Sendable {
    public var coordinate: MachineCoordinate
    /// World direction at reference pose; fixed because schema 1 supports only linear axes.
    public var direction: Vec3
    public var modelMinimum: Double
    public var modelMaximum: Double
    public var modelHome: Double
    public var controllerScale: Double
    public var controllerOffset: Double
    public func modelPosition(for controllerPosition: Double) -> Double {
        controllerScale * controllerPosition + controllerOffset
    }
    public var controllerHome: Double { (modelHome - controllerOffset) / controllerScale }
    public var controllerRange: ClosedRange<Double> {
        let a = (modelMinimum - controllerOffset) / controllerScale
        let b = (modelMaximum - controllerOffset) / controllerScale
        return min(a, b)...max(a, b)
    }
}

public struct MachineFrame: Codable, Equatable, Sendable {
    public var id: String
    public var componentID: String
    public var origin: Vec3
    public var xDirection: Vec3
    public var zDirection: Vec3
    public var yDirection: Vec3 { zDirection.cross(xDirection) }
}

public struct MachineMountingInterface: Codable, Equatable, Sendable {
    public var id: String
    public var frameID: String
    public var kind: String
    public var slots: [MachineMountingSlot]
}

public struct MachineMountingSlot: Codable, Equatable, Sendable {
    public var id: String
    /// Origin and direction in the named mounting frame, in millimetres.
    public var origin: Vec3
    public var direction: Vec3
    public var length: Double
    public var openingWidth: Double
    public var cavityWidth: Double
    public var cavityDepth: Double
    public var lipThickness: Double
}

public struct MachineAsset: Codable, Equatable, Sendable {
    public var path: String
    public var role: MachineAssetRole
    public var sha256: String
}

public struct MachineSource: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Optional path to a declared package asset. URLs can instead be retained in evidence detail.
    public var path: String?
}

public struct MachineEvidence: Codable, Equatable, Sendable {
    public var topic: String
    public var status: MachineEvidenceStatus
    public var sourceIDs: [String]
    public var detail: String
}

public struct MachineFinding: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var severity: MachineFindingSeverity
    public var summary: String
    public var detail: String
}

public struct MachineDefinitionError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

extension Vec3 {
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    public subscript(_ coordinate: MachineCoordinate) -> Double {
        get { switch coordinate { case .x: x; case .y: y; case .z: z } }
        set { switch coordinate { case .x: x = newValue; case .y: y = newValue; case .z: z = newValue } }
    }
    fileprivate var lengthSquared: Double { x*x + y*y + z*z }
    fileprivate var isUnit: Bool { isFinite && abs(lengthSquared - 1) < 0.000001 }
    fileprivate func dot(_ b: Vec3) -> Double { x*b.x + y*b.y + z*b.z }
    fileprivate func cross(_ b: Vec3) -> Vec3 { .init(y*b.z-z*b.y, z*b.x-x*b.z, x*b.y-y*b.x) }
    fileprivate func adding(_ b: Vec3) -> Vec3 { .init(x+b.x, y+b.y, z+b.z) }
    fileprivate func scaled(by s: Double) -> Vec3 { .init(x*s, y*s, z*s) }
    fileprivate func fitsPreviewCoordinates(multiplier: Double = 1) -> Bool {
        let limit = MachineDefinition.maximumCoordinateMagnitude * multiplier
        return isFinite && abs(x) <= limit && abs(y) <= limit && abs(z) <= limit
    }
}

extension MachineDefinition {
    /// Structural validation is separate from the authored verification claim and unresolved findings.
    public func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw MachineDefinitionError(message) }
        }
        func unique(_ values: [String], _ label: String) throws {
            try require(values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        && Set(values).count == values.count, "\(label) must have unique, nonempty identifiers.")
        }
        try require(schemaVersion == 1, "Unsupported machine profile schema \(schemaVersion); expected 1.")
        try require(id.range(of: "^[a-z0-9][a-z0-9._-]{0,79}$", options: .regularExpression) != nil,
                    "Machine ID must be a short lowercase identifier using letters, numbers, '.', '_' or '-'.")
        try require(revision > 0, "Machine revision must be positive.")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Machine name is required.")
        try require(units == "mm", "Unsupported machine units '\(units)'; schema 1 uses millimetres.")
        try require(process == "milling", "Unsupported process '\(process)'; this version supports three-axis milling.")
        try require(controller == "grbl", "Unsupported controller '\(controller)'; this version supports GRBL profile review.")
        if let postProcessorID {
            try require(postProcessorID == GRBLPost.adapterID, "Unsupported Coastline post processor '\(postProcessorID)'.")
        }
        try require(components.count <= 128 && !components.isEmpty, "Machine must have 1–128 components.")
        try unique(components.map(\.id), "Components")
        try unique(frames.map(\.id), "Frames")
        try unique(mountingInterfaces.map(\.id), "Mounting interfaces")
        try unique(sources.map(\.id), "Sources")
        try unique(findings.map(\.id), "Findings")
        let componentIDs = Set(components.map(\.id))
        let axes = components.compactMap(\.axis)
        try require(axes.count == 3 && Set(axes.map(\.coordinate)) == Set(MachineCoordinate.allCases),
                    "A supported machine needs exactly one linear X, Y and Z axis.")
        try require(components.filter { $0.role == .table }.count == 1 && components.filter { $0.role == .head }.count == 1,
                    "A supported machine needs one table and one head.")
        var bindings = Set<String>()
        for component in components {
            try require(component.parentID.map { componentIDs.contains($0) } ?? true, "Unknown parent of '\(component.id)'.")
            try require((component.role == .linearAxis) == (component.axis != nil), "Only linear-axis components may define axis motion.")
            for binding in component.modelEntities {
                try require(binding.range(of: "^(0|[1-9][0-9]*)(/(0|[1-9][0-9]*))*$", options: .regularExpression) != nil,
                            "Component '\(component.id)' must bind STEP occurrence index paths.")
                try require(bindings.insert(binding).inserted, "STEP occurrence '\(binding)' is assigned more than once.")
            }
            if let axis = component.axis {
                try require(axis.direction.isUnit, "Axis \(axis.coordinate.rawValue.uppercased()) direction must be a finite unit vector.")
                try require([axis.modelMinimum, axis.modelMaximum, axis.modelHome, axis.controllerScale, axis.controllerOffset].allSatisfy(\.isFinite),
                            "Axis \(axis.coordinate.rawValue.uppercased()) contains a non-finite value.")
                try require([axis.modelMinimum, axis.modelMaximum, axis.modelHome, axis.controllerOffset].allSatisfy { abs($0) <= Self.maximumCoordinateMagnitude },
                            "Axis \(axis.coordinate.rawValue.uppercased()) exceeds the supported preview numeric range.")
                try require(axis.modelMinimum < axis.modelMaximum && axis.modelHome >= axis.modelMinimum && axis.modelHome <= axis.modelMaximum,
                            "Axis \(axis.coordinate.rawValue.uppercased()) must have an ordered range containing home.")
                try require(abs(abs(axis.controllerScale) - 1) < 0.000001, "Axis controller scale must be +1 or −1; units are millimetres.")
            }
            _ = try worldTranslation(for: component.id, at: .zero) // rejects cycles, including static-only cycles
        }
        try require(!bindings.isEmpty, "Machine components need explicit STEP occurrence bindings.")
        for i in axes.indices {
            for j in axes.indices where i < j {
                try require(abs(axes[i].direction.dot(axes[j].direction)) < 0.000001,
                            "The supported three-axis machine requires orthogonal linear axes.")
            }
        }
        func ancestors(of role: MachineComponentRole) -> Set<String> {
            var result = Set<String>(), current = components.first { $0.role == role }?.id
            while let id = current, result.insert(id).inserted {
                current = components.first { $0.id == id }?.parentID
            }
            return result
        }
        let tableChain = ancestors(of: .table), headChain = ancestors(of: .head)
        for component in components where component.axis != nil {
            try require(tableChain.contains(component.id) != headChain.contains(component.id),
                        "Axis '\(component.id)' must move either the table or head; shared or disconnected motion is unsupported.")
        }
        for frame in frames {
            try require(componentIDs.contains(frame.componentID), "Frame '\(frame.id)' references an unknown component.")
            try require(frame.origin.isFinite && frame.xDirection.isUnit && frame.zDirection.isUnit
                        && abs(frame.xDirection.dot(frame.zDirection)) < 0.000001,
                        "Frame '\(frame.id)' needs a finite origin and orthogonal unit directions.")
            try require(frame.origin.fitsPreviewCoordinates(), "Frame '\(frame.id)' exceeds the supported preview numeric range.")
        }
        try require(frames.contains { f in components.contains { $0.id == f.componentID && $0.role == .table } }
                    && frames.contains { f in components.contains { $0.id == f.componentID && $0.role == .head } },
                    "Machine needs reference frames on both the table and head.")
        let frameIDs = Set(frames.map(\.id))
        for mount in mountingInterfaces {
            try require(frameIDs.contains(mount.frameID), "Mount '\(mount.id)' references an unknown frame.")
            try require(mount.kind == "tSlots", "Unsupported mounting interface '\(mount.kind)'.")
            try require(!mount.slots.isEmpty && mount.slots.count <= 64, "T-slot interface needs 1–64 slots.")
            try unique(mount.slots.map(\.id), "Slots in '\(mount.id)'")
            for slot in mount.slots {
                try require(slot.origin.isFinite && slot.direction.isUnit, "Slot '\(slot.id)' needs a finite origin and unit direction.")
                try require(slot.origin.fitsPreviewCoordinates(), "Slot '\(slot.id)' origin exceeds the supported preview numeric range.")
                try require([slot.length, slot.openingWidth, slot.cavityWidth, slot.cavityDepth, slot.lipThickness].allSatisfy { $0.isFinite && $0 > 0 },
                            "Slot '\(slot.id)' dimensions must be finite and positive.")
                try require([slot.length, slot.openingWidth, slot.cavityWidth, slot.cavityDepth, slot.lipThickness].allSatisfy { $0 <= Self.maximumCoordinateMagnitude },
                            "Slot '\(slot.id)' dimensions exceed the supported preview numeric range.")
                try require(slot.openingWidth < slot.cavityWidth, "Slot '\(slot.id)' cavity must be wider than its opening.")
            }
        }
        try require(!assets.isEmpty && assets.count <= 32 && Set(assets.map(\.path)).count == assets.count, "Machine assets must have unique paths (maximum 32).")
        try require(assets.filter { $0.role == .geometry }.count == 1, "Machine package requires exactly one STEP geometry asset.")
        for asset in assets {
            try require(asset.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
                        "Asset '\(asset.path)' needs a SHA-256 fingerprint.")
            if asset.role == .geometry {
                try require(["step", "stp"].contains((asset.path as NSString).pathExtension.lowercased()), "Machine geometry must be STEP.")
            }
        }
        let sourceIDs = Set(sources.map(\.id)), assetPaths = Set(assets.map(\.path))
        for source in sources {
            try require(source.path.map { assetPaths.contains($0) } ?? true, "Source '\(source.id)' must reference a declared asset.")
        }
        for item in evidence {
            try require(!item.topic.isEmpty && !item.detail.isEmpty && item.sourceIDs.allSatisfy { sourceIDs.contains($0) },
                        "Evidence must name its topic, detail and valid sources.")
        }
        try unique(validationChecks.map(\.id), "Validation checks")
        try require(validationChecks.count <= 64, "A profile may contain at most 64 validation checks.")
        for check in validationChecks {
            try require(!check.title.isEmpty && !check.detail.isEmpty && !check.sourceIDs.isEmpty
                        && check.sourceIDs.allSatisfy { sourceIDs.contains($0) },
                        "Validation checks need a title, result and valid evidence sources.")
            if check.status != .passed {
                try require(check.action?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                            "Unresolved validation check '\(check.id)' needs a concrete next action.")
            }
        }
        if let stock = referenceStock {
            try require(!stock.id.isEmpty && !stock.name.isEmpty && frameIDs.contains(stock.frameID),
                        "Reference stock needs a name, identifier and valid frame.")
            try require(stock.minimum.fitsPreviewCoordinates() && stock.size.fitsPreviewCoordinates()
                        && stock.size.x > 0 && stock.size.y > 0 && stock.size.z > 0,
                        "Reference stock dimensions must be finite and positive.")
            let frame = frames.first { $0.id == stock.frameID }!
            try require(components.first { $0.id == frame.componentID }?.role == .table,
                        "Reference stock must attach to the table's seating frame.")
            _ = try referenceStockCorners()
        }
        let p = profile
        try require(p.travel.isFinite && p.maxRate.isFinite && p.acceleration.isFinite && p.physicalEnvelope.isFinite,
                    "Machine capability vectors must be finite.")
        for coordinate in MachineCoordinate.allCases {
            try require(p.travel[coordinate] > 0 && p.maxRate[coordinate] > 0 && p.acceleration[coordinate] > 0 && p.physicalEnvelope[coordinate] > 0,
                        "Travel, rates, acceleration and physical envelope must be positive.")
        }
        let envelopeRanges = [p.machineEnvelope.x, p.machineEnvelope.y, p.machineEnvelope.z]
        try require(envelopeRanges.allSatisfy { $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound < $0.upperBound },
                    "Machine control envelope must contain finite, ordered ranges.")
        try require(p.homePosition?.isFinite == true, "Machine profile needs an explicit controller home position.")
        let home = controllerHomePosition
        try require(p.homePosition.map { abs($0.x-home.x) < 0.0001 && abs($0.y-home.y) < 0.0001 && abs($0.z-home.z) < 0.0001 } == true,
                    "Profile home does not match the kinematic axis homes and controller mapping.")
        try require(p.machineEnvelope.contains(home), "Controller home must lie inside the declared control envelope.")
        let authoredEnvelope = controllerEnvelope
        try require(authoredEnvelope.contains(Vec3(p.machineEnvelope.x.lowerBound, p.machineEnvelope.y.lowerBound, p.machineEnvelope.z.lowerBound))
                    && authoredEnvelope.contains(Vec3(p.machineEnvelope.x.upperBound, p.machineEnvelope.y.upperBound, p.machineEnvelope.z.upperBound)),
                    "Control envelope exceeds the mapped authored axis travel.")
        try require(p.spindleRPM.lowerBound.isFinite && p.spindleRPM.upperBound.isFinite && p.spindleRPM.lowerBound > 0 && p.spindleRPM.lowerBound <= p.spindleRPM.upperBound,
                    "Spindle usable RPM range must be finite and positive.")
        try require([p.maxShankDiameter, p.maxToolLength, p.colletSeatDepth, p.probeFeed, p.probeSpindleRPM, p.edgeFinderTipDiameter,
                     p.junctionDeviation, p.arcTolerance, p.estimatedSpindlePower, p.spindleRampIntermediateRPM].allSatisfy { $0.isFinite && $0 >= 0 },
                    "Machine capability values must be finite and nonnegative.")
        try require(p.maxShankDiameter > 0 && p.maxToolLength > 0 && p.maxLineLength > 0 && p.plannerBlocks > 0 && p.tSlotCount >= 0,
                    "Tool and controller limits must be positive.")
    }
}
