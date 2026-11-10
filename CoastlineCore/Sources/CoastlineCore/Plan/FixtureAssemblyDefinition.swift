import Foundation
import simd

/// An audited mechanical assembly. Entity paths are bound to one exact STEP asset;
/// proximity and display names never determine which hardware moves together.
public struct FixtureAssemblyDefinition: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case physical, reference }
    public struct Joint: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable { case prismatic, revolute, screw }
        public var id: String
        public var kind: Kind
        /// Axis and origin in the assembly's authored reference coordinates.
        /// A parent component's transform also transforms these coordinates.
        public var axis: Vec3
        public var origin: Vec3
        /// Linear and screw values are mm; revolute values are radians.
        public var minimum: Double
        public var maximum: Double
        public var referenceValue: Double
        /// Positive lead, mm/revolution. Screw rotation follows linear advance along axis.
        public var pitch: Double?
        public init(id: String, kind: Kind, axis: Vec3, origin: Vec3 = .zero,
                    minimum: Double, maximum: Double, referenceValue: Double = 0, pitch: Double? = nil) {
            self.id = id; self.kind = kind; self.axis = axis; self.origin = origin
            self.minimum = minimum; self.maximum = maximum; self.referenceValue = referenceValue; self.pitch = pitch
        }
    }
    public struct Component: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var parentID: String?
        public var role: Role
        /// Exact zero-based STEP assembly leaf occurrence paths, e.g. 0/3/4.
        public var modelEntities: [String]
        public var joint: Joint?
        public init(id: String, name: String, parentID: String? = nil, role: Role = .physical,
                    modelEntities: [String], joint: Joint? = nil) {
            self.id = id; self.name = name; self.parentID = parentID; self.role = role
            self.modelEntities = modelEntities; self.joint = joint
        }
    }
    public var schemaVersion = 1
    public var id: String
    public var revision: Int
    public var modelSHA256: String
    public var components: [Component]
    public var bookends: BookendSetup.Definition? = nil
    public var clampPair: ClampPairSetup.Definition? = nil
    public var vise: ViseSetup.Definition? = nil
    /// Exploded/reference CAD may be previewed but cannot be approved for machining.
    public var isAssembled = true
    public init(id: String, revision: Int, modelSHA256: String, components: [Component]) {
        self.id = id; self.revision = revision; self.modelSHA256 = modelSHA256; self.components = components
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, id, revision, modelSHA256, components, bookends, clampPair, vise, isAssembled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(String.self, forKey: .id); revision = try c.decode(Int.self, forKey: .revision)
        modelSHA256 = try c.decode(String.self, forKey: .modelSHA256)
        components = try c.decode([Component].self, forKey: .components)
        bookends = try c.decodeIfPresent(BookendSetup.Definition.self, forKey: .bookends)
        clampPair = try c.decodeIfPresent(ClampPairSetup.Definition.self, forKey: .clampPair)
        vise = try c.decodeIfPresent(ViseSetup.Definition.self, forKey: .vise)
        isAssembled = try c.decodeIfPresent(Bool.self, forKey: .isAssembled) ?? true
    }

    public var planningIssues: [String] {
        isAssembled ? [] : ["This CAD is an exploded/reference view. An assembled fixture definition is required before planning cuts."]
    }

    public var validationIssues: [String] {
        var issues: [String] = []
        if schemaVersion != 1 { issues.append("Unsupported fixture assembly format \(schemaVersion).") }
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || revision < 1 { issues.append("The assembly needs an ID and positive revision.") }
        if modelSHA256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) == nil { issues.append("The assembly needs the exact CAD SHA-256.") }
        if components.isEmpty || components.count > 256 { issues.append("The assembly must have 1–256 components.") }
        let ids = Set(components.map(\.id))
        if ids.count != components.count || ids.contains("") { issues.append("Component IDs must be unique and nonempty.") }
        var paths = Set<String>(), joints = Set<String>()
        for component in components {
            if component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Component \(component.id) needs a name.") }
            if let parent = component.parentID, !ids.contains(parent) || parent == component.id { issues.append("Component \(component.id) has an invalid parent.") }
            var ancestors = Set([component.id]), parent = component.parentID
            while let id = parent {
                if !ancestors.insert(id).inserted { issues.append("The assembly component hierarchy has a cycle."); break }
                parent = components.first { $0.id == id }?.parentID
            }
            if component.modelEntities.isEmpty && !components.contains(where: { $0.parentID == component.id }) { issues.append("Component \(component.id) has no CAD bodies or children.") }
            for path in component.modelEntities {
                if path.range(of: "^[0-9]+(/[0-9]+)*$", options: .regularExpression) == nil || !paths.insert(path).inserted { issues.append("CAD occurrence paths must be exact, unique indexed paths.") }
            }
            guard let joint = component.joint else { continue }
            if joint.id.isEmpty || !joints.insert(joint.id).inserted { issues.append("Joint IDs must be unique and nonempty.") }
            let axis = SIMD3(joint.axis.x, joint.axis.y, joint.axis.z)
            if ![axis.x, axis.y, axis.z].allSatisfy(\.isFinite) || abs(simd_length(axis) - 1) > 1e-6 { issues.append("Joint \(joint.id) needs a unit axis.") }
            if ![joint.origin.x, joint.origin.y, joint.origin.z, joint.minimum, joint.maximum, joint.referenceValue].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) ||
                joint.minimum > joint.maximum || joint.referenceValue < joint.minimum || joint.referenceValue > joint.maximum { issues.append("Joint \(joint.id) has invalid limits or reference position.") }
            if joint.kind == .screw {
                if joint.pitch.map({ $0.isFinite && $0 >= 0.000001 && $0 <= 1_000 }) != true { issues.append("Screw joint \(joint.id) needs a finite pitch between 0.000001 and 1000 mm.") }
            } else if joint.pitch != nil { issues.append("Only screw joints may have a pitch.") }
        }
        if !components.contains(where: { $0.role == .physical && !$0.modelEntities.isEmpty }) { issues.append("The assembly has no physical fixture bodies.") }
        if let bookends { issues += bookends.validationIssues }
        if let clampPair { issues += clampPair.validationIssues }
        if let vise { issues += vise.validationIssues }
        if [bookends != nil, clampPair != nil, vise != nil].filter({ $0 }).count > 1 { issues.append("An assembly has one mechanism.") }
        return Array(Set(issues)).sorted()
    }

    public func stateIssues(_ state: FixtureAssemblyState) -> [String] {
        var issues = validationIssues
        let joints = components.compactMap(\.joint)
        for (id, value) in state.jointValues {
            guard let joint = joints.first(where: { $0.id == id }) else { issues.append("Unknown assembly joint \(id)."); continue }
            if !value.isFinite || value < joint.minimum || value > joint.maximum { issues.append("Joint \(id) must be within \(joint.minimum)…\(joint.maximum).") }
        }
        let physicalIDs = Set(components.filter { $0.role == .physical }.map(\.id))
        if !state.lockedComponents.isSubset(of: physicalIDs) { issues.append("The assembly locks refer to unknown or reference components.") }
        return issues
    }

    public func validate(state: FixtureAssemblyState = .init()) throws {
        let issues = stateIssues(state)
        if !issues.isEmpty { throw AssemblyError.invalid(issues) }
    }

    public enum AssemblyError: Error, LocalizedError, CustomStringConvertible {
        case invalid([String])
        public var description: String { switch self { case .invalid(let issues): issues.joined(separator: "\n") } }
        public var errorDescription: String? { description }
    }
}

/// Job-owned mechanical settings, not a claim that hardware has been physically tightened.
public struct FixtureAssemblyState: Codable, Hashable, Sendable {
    public var jointValues: [String: Double]
    public var mounted: Bool
    public var lockedComponents: Set<String>
    public init(jointValues: [String: Double] = [:], mounted: Bool = false, lockedComponents: Set<String> = []) {
        self.jointValues = jointValues; self.mounted = mounted; self.lockedComponents = lockedComponents
    }
    public func value(for joint: FixtureAssemblyDefinition.Joint) -> Double { jointValues[joint.id] ?? joint.referenceValue }
    private enum CodingKeys: String, CodingKey { case jointValues, mounted, lockedComponents }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jointValues = try c.decodeIfPresent([String: Double].self, forKey: .jointValues) ?? [:]
        mounted = try c.decodeIfPresent(Bool.self, forKey: .mounted) ?? false
        lockedComponents = Set(try c.decodeIfPresent([String].self, forKey: .lockedComponents) ?? [])
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jointValues, forKey: .jointValues); try c.encode(mounted, forKey: .mounted)
        try c.encode(lockedComponents.sorted(), forKey: .lockedComponents)
    }
}

/// One closed solid of one exact CAD occurrence. Index is local to that occurrence,
/// never an index into a flattened, independently imported assembly.
public struct FixtureAssemblyPart: Sendable {
    public var componentID: String
    public var entityPath: String
    public var solidIndex: Int
    public var mesh: MeshData
    public init(componentID: String, entityPath: String, solidIndex: Int, mesh: MeshData) {
        self.componentID = componentID; self.entityPath = entityPath; self.solidIndex = solidIndex; self.mesh = mesh
    }
}
