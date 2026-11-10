import CryptoKit
import Foundation

/// The immutable machine assignment of a planning job. Asset fingerprints travel with
/// the definition; local file paths and permission to operate hardware do not.
public struct PlanningMachineReference: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case legacy, profile }

    public let kind: Kind
    public let definition: MachineDefinition?
    private let legacyProfile: MachineProfile?

    /// Explicit migration for projects written before machine selection existed.
    /// Newly saved legacy projects retain these values rather than following later defaults.
    public static let legacy = PlanningMachineReference(legacyProfile: .standard)

    private init(legacyProfile: MachineProfile) {
        kind = .legacy
        definition = nil
        self.legacyProfile = legacyProfile
    }

    public init(definition: MachineDefinition) throws {
        try definition.validate()
        kind = .profile
        self.definition = definition
        legacyProfile = nil
    }

    public var isLegacy: Bool { kind == .legacy }
    public var reference: MachineDefinitionReference {
        definition?.reference ?? MachineDefinitionReference(id: "coastline.legacy-desktop", revision: 1)
    }
    public var displayName: String { definition?.name ?? "Legacy Desktop CNC" }
    public var profile: MachineProfile {
        // Both constructors and decoding enforce exactly one source of profile values.
        definition?.profile ?? legacyProfile!
    }

    /// A matching ID/revision is necessary but not sufficient: replacing its limits,
    /// evidence or model hashes must not change an existing job behind its back.
    /// Nil means the explicitly selected legacy implementation, never a missing package.
    public func resolve(in packages: [MachineDefinitionPackage]) throws -> MachineDefinitionPackage? {
        guard let definition else { return nil }
        let candidates = packages.filter { $0.definition.reference == reference }
        guard !candidates.isEmpty else {
            throw MachineDefinitionError("This job needs \(definition.name) revision \(definition.revision). Install its original machine profile package to open the job; a different machine will not be substituted.")
        }
        guard candidates.allSatisfy({ $0.definition == definition }) else {
            throw MachineDefinitionError("\(definition.name) revision \(definition.revision) differs from the profile saved with this job. Restore the original package, or deliberately change the job's machine and regenerate its toolpaths.")
        }
        return candidates[0]
    }

    /// Stable identity for asynchronous planning and persisted caches, including limits
    /// and asset hashes rather than only the user-visible ID and revision.
    public func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey { case kind, definition, legacyProfile }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        definition = try values.decodeIfPresent(MachineDefinition.self, forKey: .definition)
        legacyProfile = try values.decodeIfPresent(MachineProfile.self, forKey: .legacyProfile)
        switch kind {
        case .profile:
            guard let definition, legacyProfile == nil else {
                throw MachineDefinitionError("A job's machine profile must contain exactly one definition snapshot.")
            }
            try definition.validate()
        case .legacy:
            guard definition == nil, let legacyProfile else {
                throw MachineDefinitionError("A legacy job must retain its original machine limits.")
            }
            try Self.validateLegacy(legacyProfile)
        }
    }

    private static func validateLegacy(_ p: MachineProfile) throws {
        let positiveVectors = [p.travel, p.maxRate, p.acceleration, p.physicalEnvelope]
        let ranges = [p.machineEnvelope.x, p.machineEnvelope.y, p.machineEnvelope.z]
        let nonnegative = [p.junctionDeviation, p.arcTolerance, p.estimatedSpindlePower,
                           p.spindleRampIntermediateRPM, p.colletSeatDepth, p.probeFeed,
                           p.probeSpindleRPM, p.edgeFinderTipDiameter]
        guard !p.name.isEmpty,
              positiveVectors.allSatisfy({ $0.isFinite && $0.x > 0 && $0.y > 0 && $0.z > 0 }),
              ranges.allSatisfy({ $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound < $0.upperBound }),
              p.spindleRPM.lowerBound.isFinite, p.spindleRPM.upperBound.isFinite,
              p.spindleRPM.lowerBound > 0, p.spindleRPM.lowerBound <= p.spindleRPM.upperBound,
              p.maxShankDiameter.isFinite, p.maxShankDiameter > 0,
              p.maxToolLength.isFinite, p.maxToolLength > 0,
              nonnegative.allSatisfy({ $0.isFinite && $0 >= 0 }),
              p.maxLineLength > 0, p.plannerBlocks > 0, p.tSlotCount >= 0,
              p.homePosition.map({ $0.isFinite && p.machineEnvelope.contains($0) }) ?? true else {
            throw MachineDefinitionError("The saved legacy machine limits are invalid.")
        }
    }
}
