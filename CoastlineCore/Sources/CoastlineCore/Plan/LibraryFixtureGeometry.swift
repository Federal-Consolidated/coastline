import Foundation
import CryptoKit
import simd

/// Editing groups, not a mechanical connectivity analysis. Nearby closed solids stay
/// together so screws/washers move with their bookend. No mesh is stretched or scaled.
public struct LibraryFixtureGeometry: Sendable {
    public struct Component: Sendable, Identifiable {
        public var id: String
        public var name: String
        public var role: FixtureAssemblyDefinition.Role
        public var solidIndices: [Int]
        public var mesh: MeshData
        public var snapFaces: [FixtureEdgeSnap.Face]
        public var centre: SIMD3<Double> {
            (SIMD3(mesh.boundsMin.x, mesh.boundsMin.y, mesh.boundsMin.z)
             + SIMD3(mesh.boundsMax.x, mesh.boundsMax.y, mesh.boundsMax.z)) / 2
        }
    }
    public let solids: [MeshData]
    public let components: [Component]
    public let layoutID: String
    public let assemblyDefinition: FixtureAssemblyDefinition?
    public let physicalSolidIndices: Set<Int>

    public init(solids: [MeshData], groupingGap: Double = 0.5) {
        self.solids = solids
        self.assemblyDefinition = nil
        self.physicalSolidIndices = Set(solids.indices)
        let gap = groupingGap.isFinite ? max(0, min(groupingGap, 5)) : 0.5
        func lo(_ i: Int) -> SIMD3<Double> { let p = solids[i].boundsMin; return SIMD3(p.x, p.y, p.z) }
        func hi(_ i: Int) -> SIMD3<Double> { let p = solids[i].boundsMax; return SIMD3(p.x, p.y, p.z) }
        var parents = Array(solids.indices)
        func root(_ index: Int) -> Int { var i = index; while parents[i] != i { i = parents[i] }; return i }
        for i in solids.indices {
            for j in solids.indices where j > i {
                if (0..<3).allSatisfy({ lo(i)[$0] <= hi(j)[$0] + gap && lo(j)[$0] <= hi(i)[$0] + gap }) {
                    parents[root(j)] = root(i)
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in solids.indices { groups[root(i), default: []].append(i) }
        let ordered = groups.values.sorted { a, b in
            let al = a.map(lo).reduce(SIMD3(repeating: .infinity), simd_min)
            let bl = b.map(lo).reduce(SIMD3(repeating: .infinity), simd_min)
            for k in 0..<3 where al[k] != bl[k] { return al[k] < bl[k] }
            return a[0] < b[0]
        }
        components = ordered.enumerated().map { i, indices in
            let mesh = Self.merge(indices.map { solids[$0] }, transforms: Array(repeating: matrix_identity_double4x4, count: indices.count))
            return .init(id: "piece-\(i)", name: "Piece \(i + 1)", role: .physical, solidIndices: indices, mesh: mesh, snapFaces: FixtureEdgeSnap.faces(in: mesh))
        }
        layoutID = "nearby-solids-v1|" + components.map { component in
            let m = component.mesh
            return [m.boundsMin.x, m.boundsMin.y, m.boundsMin.z, m.boundsMax.x, m.boundsMax.y, m.boundsMax.z]
                .map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ",")
                + ":\(component.solidIndices.count):\(m.indices.count)"
        }.joined(separator: "|")
    }

    /// Exact, versioned CAD ownership. The engine already verifies file hash and all leaf
    /// occurrences; this validates the wire data again before any transform is used.
    public init(parts: [FixtureAssemblyPart], definition: FixtureAssemblyDefinition) throws {
        try definition.validate()
        var seen = Set<String>()
        let wanted = Set(definition.components.flatMap(\.modelEntities))
        for part in parts {
            guard let component = definition.components.first(where: { $0.id == part.componentID }),
                  component.modelEntities.contains(part.entityPath), part.solidIndex >= 0,
                  seen.insert("\(part.entityPath)#\(part.solidIndex)").inserted else {
                throw FixtureAssemblyDefinition.AssemblyError.invalid(["The CAD body identity does not match its fixture definition."])
            }
            let m = part.mesh
            guard m.exact, m.vertices.count % 3 == 0, !m.indices.isEmpty, m.indices.count % 3 == 0,
                  m.normals.count == m.vertices.count, m.vertices.allSatisfy(\.isFinite), m.normals.allSatisfy(\.isFinite),
                  m.indices.allSatisfy({ Int($0) < m.vertexCount }),
                  [m.boundsMin.x, m.boundsMin.y, m.boundsMin.z, m.boundsMax.x, m.boundsMax.y, m.boundsMax.z].allSatisfy(\.isFinite) else {
                throw FixtureAssemblyDefinition.AssemblyError.invalid(["The fixture contains an invalid closed-solid mesh."])
            }
        }
        guard Set(parts.map(\.entityPath)) == wanted else {
            throw FixtureAssemblyDefinition.AssemblyError.invalid(["The fixture's exact CAD occurrences are missing or changed."])
        }
        for path in wanted {
            let indices = parts.filter { $0.entityPath == path }.map(\.solidIndex).sorted()
            guard indices == Array(0..<indices.count) else {
                throw FixtureAssemblyDefinition.AssemblyError.invalid(["The fixture CAD occurrence has missing or inconsistent solid identities."])
            }
        }
        self.solids = parts.map(\.mesh)
        self.assemblyDefinition = definition
        let physicalIDs = Set(definition.components.filter { $0.role == .physical }.map(\.id))
        self.physicalSolidIndices = Set(parts.indices.filter { physicalIDs.contains(parts[$0].componentID) })
        self.components = definition.components.filter { $0.role == .physical }.compactMap { c in
            let indices = parts.indices.filter { parts[$0].componentID == c.id }
            guard !indices.isEmpty else { return nil }
            let mesh = Self.merge(indices.map { parts[$0].mesh }, transforms: Array(repeating: matrix_identity_double4x4, count: indices.count))
            return Component(id: c.id, name: c.name, role: c.role, solidIndices: indices, mesh: mesh, snapFaces: FixtureEdgeSnap.faces(in: mesh))
        }
        self.layoutID = try Self.layoutID(definition)
    }

    /// Identifies the reviewed definition a saved placement was made with.
    public static func layoutID(_ definition: FixtureAssemblyDefinition) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let hash = SHA256.hash(data: try encoder.encode(definition)).map { String(format: "%02x", $0) }.joined()
        return "vetted-assembly-v1|\(definition.id)|\(definition.revision)|\(hash)"
    }

    public func validate(profile: FixturePlanningProfile) throws {
        guard let definition = assemblyDefinition else {
            guard placementsMatch(profile) else { throw FixtureAssemblyDefinition.AssemblyError.invalid(["The assembly's saved piece layout changed."]) }
            return
        }
        try definition.validate(state: profile.assemblyState ?? .init())
        guard [profile.datum.x, profile.datum.y, profile.datum.z, profile.facePastTable].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              (0..<4).contains(profile.spin) else {
            throw FixtureAssemblyDefinition.AssemblyError.invalid(["The fixture pose must have finite, supported coordinates and orientation."])
        }
        if let hash = profile.componentModelSignature, hash.lowercased() != definition.modelSHA256.lowercased() {
            throw FixtureAssemblyDefinition.AssemblyError.invalid(["The saved fixture refers to a different CAD revision."])
        }
        if let layout = profile.componentLayoutID, layout != layoutID {
            throw FixtureAssemblyDefinition.AssemblyError.invalid(["The saved fixture assembly definition changed."])
        }
        let placements = profile.componentPlacements ?? []
        guard Set(placements.map(\.id)).count == placements.count else { throw FixtureAssemblyDefinition.AssemblyError.invalid(["Duplicate component positions in the fixture state."]) }
        for placement in placements {
            guard let component = definition.components.first(where: { $0.id == placement.id }), component.role == .physical,
                  component.joint == nil,
                  [placement.offset.x, placement.offset.y, placement.offset.z].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }), (0..<4).contains(placement.spin) else {
                throw FixtureAssemblyDefinition.AssemblyError.invalid(["Joint-controlled fixture components cannot also have free piece positions."])
            }
        }
    }

    public func placementsMatch(_ profile: FixturePlanningProfile) -> Bool {
        if assemblyDefinition != nil { return (try? validate(profile: profile)) != nil }
        guard let pieces = profile.componentPlacements, !pieces.isEmpty else { return true }
        return profile.componentLayoutID == layoutID && pieces.allSatisfy { piece in components.contains { $0.id == piece.id } }
    }

    public func localTransform(_ component: Component, profile: FixturePlanningProfile) -> simd_double4x4 {
        if let definition = assemblyDefinition {
            return assemblyTransform(componentID: component.id, definition: definition, profile: profile)
        }
        return freeTransform(componentID: component.id, centre: component.centre, profile: profile)
    }

    private func freeTransform(componentID: String, centre c: SIMD3<Double>, profile: FixturePlanningProfile) -> simd_double4x4 {
        guard let placement = profile.componentPlacements?.first(where: { $0.id == componentID }) else { return matrix_identity_double4x4 }
        var s = Setup(); s.facing = placement.facing; s.spin = placement.spin
        let r = s.partRotation
        let t = c - r * c + SIMD3(placement.offset.x, placement.offset.y, placement.offset.z)
        return simd_double4x4(columns: (SIMD4(r[0], 0), SIMD4(r[1], 0), SIMD4(r[2], 0), SIMD4(t, 1)))
    }

    private func assemblyTransform(componentID: String, definition: FixtureAssemblyDefinition,
                                   profile: FixturePlanningProfile) -> simd_double4x4 {
        guard let component = definition.components.first(where: { $0.id == componentID }) else { return matrix_identity_double4x4 }
        let parent = component.parentID.map { assemblyTransform(componentID: $0, definition: definition, profile: profile) } ?? matrix_identity_double4x4
        let centre = components.first { $0.id == componentID }?.centre ?? .zero
        let free = freeTransform(componentID: componentID, centre: centre, profile: profile)
        guard let joint = component.joint else { return parent * free }
        let state = profile.assemblyState ?? FixtureAssemblyState()
        let delta = state.value(for: joint) - joint.referenceValue
        let axis = SIMD3(joint.axis.x, joint.axis.y, joint.axis.z)
        let origin = SIMD3(joint.origin.x, joint.origin.y, joint.origin.z)
        let angle = joint.kind == .revolute ? delta : (joint.kind == .screw ? delta * 2 * .pi / (joint.pitch ?? 1) : 0)
        let r = simd_double3x3(simd_quatd(angle: angle, axis: axis))
        let offset = origin - r * origin + (joint.kind == .revolute ? .zero : axis * delta)
        let transform = simd_double4x4(columns: (SIMD4(r[0], 0), SIMD4(r[1], 0), SIMD4(r[2], 0), SIMD4(offset, 1)))
        return parent * free * transform
    }

    public func transform(_ component: Component, profile: FixturePlanningProfile) -> simd_double4x4 {
        profile.modelToWork * localTransform(component, profile: profile)
    }

    public func solidTransform(_ index: Int, profile: FixturePlanningProfile) -> simd_double4x4 {
        guard let component = components.first(where: { $0.solidIndices.contains(index) }) else { return profile.modelToWork }
        return transform(component, profile: profile)
    }

    public func workMesh(profile: FixturePlanningProfile) -> MeshData {
        Self.merge(components.map(\.mesh), transforms: components.map { transform($0, profile: profile) })
    }

    public func bounds(profile: FixturePlanningProfile, componentID: String? = nil) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        for c in components where componentID == nil || c.id == componentID {
            let m = c.mesh, t = transform(c, profile: profile)
            for k in 0..<8 {
                let p = SIMD4(k & 1 == 0 ? m.boundsMin.x : m.boundsMax.x, k & 2 == 0 ? m.boundsMin.y : m.boundsMax.y,
                              k & 4 == 0 ? m.boundsMin.z : m.boundsMax.z, 1)
                let q = t * p
                lo = simd_min(lo, SIMD3(q.x, q.y, q.z)); hi = simd_max(hi, SIMD3(q.x, q.y, q.z))
            }
        }
        return (lo, hi)
    }

    public func moved(_ profile: FixturePlanningProfile, componentID: String?, by delta: SIMD3<Double>) -> FixturePlanningProfile {
        if let id = componentID, let definition = assemblyDefinition,
           let component = definition.components.first(where: { $0.id == id }) {
            let state = profile.assemblyState ?? .init()
            guard !state.lockedComponents.contains(id), component.joint == nil else { return profile }
        }
        guard let id = componentID, components.contains(where: { $0.id == id }) else {
            return profile.moved(inWork: Vec3(delta.x, delta.y, delta.z))
        }
        guard [delta.x, delta.y, delta.z].allSatisfy(\.isFinite) else { return profile }
        var p = profile, piece = profile.componentPlacements?.first { $0.id == id } ?? .init(id: id)
        let local = Self.rotation(profile.modelToWork).transpose * delta
        piece.offset = Vec3(piece.offset.x + local.x, piece.offset.y + local.y, piece.offset.z + local.z)
        p.componentPlacements = (p.componentPlacements ?? []).filter { $0.id != id } + [piece]
        p.componentLayoutID = layoutID; p.gripDefinitionReviewed = false
        return p
    }

    public func turned(_ profile: FixturePlanningProfile, componentID: String?, axis: Int, quarterTurns: Int) -> FixturePlanningProfile {
        if let id = componentID, let definition = assemblyDefinition,
           let component = definition.components.first(where: { $0.id == id }) {
            let state = profile.assemblyState ?? .init()
            guard !state.lockedComponents.contains(id), component.joint == nil else { return profile }
        }
        guard (0..<3).contains(axis) else { return profile }
        let workRotation = Setup().turned(about: axis, quarterTurns: quarterTurns).partRotation
        guard let id = componentID, components.contains(where: { $0.id == id }) else {
            let b = bounds(profile: profile), c = (b.min + b.max) / 2
            guard c.x.isFinite else { return profile }
            return profile.turned(about: axis, quarterTurns: quarterTurns)
                .moved(inWork: Vec3((c - workRotation * c).x, (c - workRotation * c).y, (c - workRotation * c).z))
        }
        var p = profile, piece = profile.componentPlacements?.first { $0.id == id } ?? .init(id: id)
        var old = Setup(); old.facing = piece.facing; old.spin = piece.spin
        let base = Self.rotation(profile.modelToWork)
        let want = base.transpose * workRotation * base * old.partRotation
        for face in Setup.Facing.allCases {
            for spin in 0..<4 {
                var test = Setup(); test.facing = face; test.spin = spin
                if (0..<3).allSatisfy({ simd_length(test.partRotation[$0] - want[$0]) < 1e-7 }) {
                    piece.facing = face; piece.spin = spin
                    p.componentPlacements = (p.componentPlacements ?? []).filter { $0.id != id } + [piece]
                    p.componentLayoutID = layoutID; p.gripDefinitionReviewed = false
                    return p
                }
            }
        }
        return profile
    }

    /// A visible starting position only. It aligns the two editing groups' bounding faces;
    /// the operator still identifies actual grip patches and checks the assembled hardware.
    public func alignedPair(_ profile: FixturePlanningProfile, stock: SIMD3<Double>) -> FixturePlanningProfile {
        guard components.count == 2, [stock.x, stock.y, stock.z].allSatisfy({ $0.isFinite && $0 > 0 }) else { return profile }
        let sorted = components.sorted { bounds(profile: profile, componentID: $0.id).min.y < bounds(profile: profile, componentID: $1.id).min.y }
        var p = profile
        let a = bounds(profile: p, componentID: sorted[0].id), b = bounds(profile: p, componentID: sorted[1].id)
        p = moved(p, componentID: sorted[0].id, by: SIMD3(0, -stock.y / 2 - a.max.y, 0))
        p = moved(p, componentID: sorted[1].id, by: SIMD3(0, stock.y / 2 - b.min.y, 0))
        return p
    }

    private static func merge(_ meshes: [MeshData], transforms: [simd_double4x4]) -> MeshData {
        var vertices: [Float] = [], normals: [Float] = [], indices: [UInt32] = []
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        for (mesh, t) in zip(meshes, transforms) {
            let offset = UInt32(vertices.count / 3), rotation = Self.rotation(t)
            for i in stride(from: 0, to: mesh.vertices.count, by: 3) {
                let p = t * SIMD4(Double(mesh.vertices[i]), Double(mesh.vertices[i + 1]), Double(mesh.vertices[i + 2]), 1)
                vertices += [Float(p.x), Float(p.y), Float(p.z)]
                lo = simd_min(lo, SIMD3(p.x, p.y, p.z)); hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
                let n = i + 2 < mesh.normals.count ? rotation * SIMD3(Double(mesh.normals[i]), Double(mesh.normals[i + 1]), Double(mesh.normals[i + 2])) : SIMD3(0, 0, 1)
                normals += [Float(n.x), Float(n.y), Float(n.z)]
            }
            indices += mesh.indices.map { $0 + offset }
        }
        return MeshData(vertices: vertices, normals: normals, indices: indices,
            boundsMin: Vec3(lo.x, lo.y, lo.z), boundsMax: Vec3(hi.x, hi.y, hi.z), exact: true,
            faceCount: meshes.reduce(0) { $0 + $1.faceCount })
    }

    private static func rotation(_ t: simd_double4x4) -> simd_double3x3 {
        simd_double3x3(columns: (SIMD3(t[0].x, t[0].y, t[0].z), SIMD3(t[1].x, t[1].y, t[1].z), SIMD3(t[2].x, t[2].y, t[2].z)))
    }
}
