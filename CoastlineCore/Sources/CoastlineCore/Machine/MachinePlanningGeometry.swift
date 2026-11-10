import Foundation
import simd

/// Adapts authored CAD coordinates to the existing horizontal-spindle setup planner.
/// Controller-relative cutting axes define the workspace basis; CAD axis names and
/// component identifiers do not. Vertical-table setups remain available in the generic
/// digital preview, but need a different fixture-placement planner before activation.
public struct MachinePlanningGeometry: Sendable {
    public struct Bounds: Equatable, Sendable {
        public var minimum: Vec3
        public var maximum: Vec3
        public var size: Vec3 { .init(maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z) }
    }

    public let definition: MachineDefinition
    public let model: MachineModel
    /// World directions of positive controller-relative tool movement, expressed in CAD.
    public let basisX: Vec3
    public let basisY: Vec3
    public let basisZ: Vec3
    public let tableComponentID: String
    public let headComponentID: String
    /// Bounds of table meshes that supply the seating surface, including their lower
    /// surfaces. Separate chip guards are not treated as table plate material.
    public let tableBounds: Bounds
    /// Bounds of connected upward-facing table regions spanning the authored T-slots.
    /// Small coplanar fastener pads are excluded. Openings such as T-slots are not
    /// filled by this rectangular footprint.
    public let supportBounds: Bounds

    public init(definition: MachineDefinition, parts: [MachineModel.Part]) throws {
        try definition.validate()
        guard definition.supportsDigitalSetup,
              definition.validationStatus(for: .tooling) == .passed,
              definition.validationStatus(for: .controller) == .passed,
              definition.postProcessorID == GRBLPost.adapterID else {
            throw MachineDefinitionError("This machine profile needs completed digital setup, tooling and controller checks before planning.")
        }
        let planningIssues = definition.validationChecks.filter { $0.scope != .hardware && $0.status != .passed }
        let otherBlockers = definition.blockingFindings.filter { finding in
            !definition.validationChecks.contains { $0.id == finding.id && $0.scope == .hardware && $0.status != .passed }
        }
        guard planningIssues.isEmpty && otherBlockers.isEmpty else {
            throw MachineDefinitionError("Resolve this profile's planning findings before using it: " +
                                         (planningIssues.map(\.title) + otherBlockers.map(\.summary)).joined(separator: "; "))
        }
        let table = definition.components.first { $0.role == .table }!
        let head = definition.components.first { $0.role == .head }!
        let tableChain = Self.ancestors(table.id, in: definition)
        var basis: [MachineCoordinate: Vec3] = [:]
        var reference = Vec3.zero
        for component in definition.components {
            guard let axis = component.axis else { continue }
            let sign = axis.controllerScale * (tableChain.contains(component.id) ? -1 : 1)
            basis[axis.coordinate] = Self.scaled(axis.direction, sign)
            reference[axis.coordinate] = -axis.controllerOffset / axis.controllerScale
        }
        let x = basis[.x]!, y = basis[.y]!, z = basis[.z]!
        guard Self.dot(Self.cross(x, y), z) > 0.999999 else {
            throw MachineDefinitionError("This planner requires right-handed controller-relative X, Y and Z cutting axes.")
        }
        func projected(_ p: Vec3) -> Vec3 { .init(Self.dot(p, x), Self.dot(p, y), Self.dot(p, z)) }
        let seatingCandidates = definition.frames.filter {
            $0.componentID == table.id && Self.near(projected($0.zDirection), Vec3(1, 0, 0))
        }
        let seating = definition.referenceStock.flatMap { stock in
            definition.frames.first { $0.id == stock.frameID && $0.componentID == table.id }
        } ?? (seatingCandidates.count == 1 ? seatingCandidates.first : nil)
        guard let seating else {
            throw MachineDefinitionError("The machine profile needs an explicit table seating frame before planning.")
        }
        let toolFrames = definition.frames.filter { $0.componentID == head.id }
        guard let tool = toolFrames.first(where: { $0.id == "tool" }) ?? (toolFrames.count == 1 ? toolFrames.first : nil) else {
            throw MachineDefinitionError("The machine profile needs an unambiguous tool reference frame before planning.")
        }
        guard Self.near(projected(seating.zDirection), Vec3(1, 0, 0)),
              Self.near(projected(tool.zDirection), Vec3(0, 0, 1)) else {
            throw MachineDefinitionError("This setup planner currently supports a horizontal spindle with the table normal along cutting X and the tool along cutting −Z. This profile can still be inspected digitally.")
        }
        let surface = projected(seating.origin)
        let supportSpan = definition.mountingInterfaces.filter { mount in
            guard let frame = definition.frames.first(where: { $0.id == mount.frameID }) else { return false }
            return Self.ancestors(frame.componentID, in: definition).contains(table.id)
        }.flatMap(\.slots).map(\.length).max() ?? 0
        var converted: [MachineModel.Part] = []
        var tablePoints: [Vec3] = [], supportPoints: [Vec3] = []
        let ids = Set(definition.components.map(\.id))
        guard !parts.isEmpty else { throw MachineDefinitionError("The machine profile has no workspace geometry.") }
        for part in parts {
            guard ids.contains(part.group) else {
                throw MachineDefinitionError("Machine geometry references unknown component '\(part.group)'.")
            }
            let mesh = part.mesh
            guard !mesh.vertices.isEmpty, mesh.vertices.count % 3 == 0,
                  mesh.normals.count == mesh.vertices.count, !mesh.indices.isEmpty,
                  mesh.indices.count % 3 == 0,
                  mesh.indices.allSatisfy({ Int($0) < mesh.vertexCount }),
                  mesh.vertices.allSatisfy(\.isFinite), mesh.normals.allSatisfy(\.isFinite) else {
                throw MachineDefinitionError("Machine geometry for '\(part.group)' is invalid.")
            }
            var positions: [Float] = [], normals: [Float] = [], points: [Vec3] = [], seated: [Bool] = []
            positions.reserveCapacity(mesh.vertices.count); normals.reserveCapacity(mesh.normals.count)
            let attachedToTable = Self.ancestors(part.group, in: definition).contains(table.id)
            for index in stride(from: 0, to: mesh.vertices.count, by: 3) {
                let point = projected(.init(Double(mesh.vertices[index]), Double(mesh.vertices[index + 1]), Double(mesh.vertices[index + 2])))
                let normal = projected(.init(Double(mesh.normals[index]), Double(mesh.normals[index + 1]), Double(mesh.normals[index + 2])))
                let floats = [Float(point.x), Float(point.y), Float(point.z)]
                guard floats.allSatisfy(\.isFinite) else {
                    throw MachineDefinitionError("Machine geometry exceeds the workspace coordinate range.")
                }
                points.append(point)
                positions += floats
                normals += [Float(normal.x), Float(normal.y), Float(normal.z)]
                seated.append(attachedToTable && abs(point.x - surface.x) <= 0.01 && normal.x > 0.999)
            }
            let broadRegions = Self.planarRegions(points, indices: mesh.indices, eligible: seated).filter {
                guard let bounds = try? Self.bounds($0) else { return false }
                return bounds.size.y + 0.01 >= supportSpan
            }
            if !broadRegions.isEmpty {
                tablePoints += points
                supportPoints += broadRegions.flatMap { $0 }
            }
            let box = try Self.bounds(points)
            var changed = part
            changed.mesh = MeshData(vertices: positions, normals: normals, indices: mesh.indices,
                                    boundsMin: box.minimum, boundsMax: box.maximum, exact: mesh.exact,
                                    faceCount: mesh.faceCount, partID: mesh.partID, warnings: mesh.warnings)
            converted.append(changed)
        }
        let tableBox = try Self.bounds(tablePoints)
        var supportBox = try Self.bounds(supportPoints)
        guard supportBox.size.y > 0 && supportBox.size.z > 0 && tableBox.minimum.x < surface.x - 0.001 else {
            throw MachineDefinitionError("The declared seating frame does not match a usable table surface in the model.")
        }
        // The authored frame is the coordinate datum; tessellation is only used to verify
        // the plane and recover its extents, never to redefine its origin.
        supportBox.minimum.x = surface.x; supportBox.maximum.x = surface.x
        var slots: [Double] = []
        for mount in definition.mountingInterfaces {
            guard let frame = definition.frames.first(where: { $0.id == mount.frameID }),
                  Self.ancestors(frame.componentID, in: definition).contains(table.id) else { continue }
            for slot in mount.slots {
                let direction = projected(try definition.worldDirection(slot.direction, in: frame.id))
                guard abs(abs(direction.y) - 1) < 0.000001 && abs(direction.x) < 0.000001 && abs(direction.z) < 0.000001 else {
                    throw MachineDefinitionError("This fixture planner requires table T-slots parallel to cutting Y.")
                }
                let start = projected(try definition.worldPoint(slot.origin, in: frame.id))
                let end = Self.adding(start, Self.scaled(direction, slot.length))
                guard abs(start.x - surface.x) < 0.01,
                      start.z >= supportBox.minimum.z - 0.01, start.z <= supportBox.maximum.z + 0.01,
                      min(start.y, end.y) >= supportBox.minimum.y - 0.01,
                      max(start.y, end.y) <= supportBox.maximum.y + 0.01 else {
                    throw MachineDefinitionError("The table T-slot definition lies outside the model's support surface.")
                }
                slots.append(start.z)
            }
        }
        guard !slots.isEmpty else {
            throw MachineDefinitionError("This fixture planner requires an authored T-slot interface on the table.")
        }
        self.definition = definition
        self.basisX = x; self.basisY = y; self.basisZ = z
        self.tableComponentID = table.id; self.headComponentID = head.id
        self.tableBounds = tableBox; self.supportBounds = supportBox
        self.model = MachineModel(parts: converted, spindleNose: projected(tool.origin), tableTopX: surface.x,
                                  modelPose: reference, tSlotZ: slots.sorted())
    }

    public func worldToPlanning(_ point: Vec3) -> Vec3 {
        .init(Self.dot(point, basisX), Self.dot(point, basisY), Self.dot(point, basisZ))
    }

    public func planningToWorld(_ point: Vec3) -> Vec3 {
        Self.adding(Self.adding(Self.scaled(basisX, point.x), Self.scaled(basisY, point.y)), Self.scaled(basisZ, point.z))
    }

    /// Actual component groups stay distinct; callers can give stock/table and tool/head
    /// their own aliases without replacing or flattening the imported machine hierarchy.
    public func componentTranslations(at position: Vec3) throws -> [String: Vec3] {
        try Dictionary(uniqueKeysWithValues: definition.components.map {
            ($0.id, worldToPlanning(try definition.worldTranslation(for: $0.id, at: position)))
        })
    }

    /// How far stock may reach past the table's far edge (away from the spindle) before it
    /// meets any other part of the machine anywhere in the axes' travel. The stock box rises
    /// `height` from the table top and is `width` wide about `centreY`. Every other component is
    /// swept over its motion relative to the table (each axis's travel, both ends); parts that
    /// ride with the table count where they are. Triangle bounds are used, so the answer is on
    /// the safe side. mm, with the component that stops it (nil: nothing within `limit`).
    /// `skip`: components to leave out (the enclosure, for "fits with the enclosure open").
    public func roomBehindTable(height: Double, width: Double, centreY: Double, clearance: Double = 1,
                                limit: Double = 1000, skip: Set<String> = []) throws -> (distance: Double, by: String?) {
        let back = supportBounds.minimum.z
        let lo = SIMD3(model.tableTopX - clearance, centreY - width / 2 - clearance, back - limit)
        let hi = SIMD3(model.tableTopX + height + clearance, centreY + width / 2 + clearance, back)
        // Each component's offset from the table at the travel's corners, less its offset at the
        // pose it is modelled in: the box of places it can be relative to the stock.
        let e = definition.profile.machineEnvelope
        var corners: [Vec3] = []
        for x in [e.x.lowerBound, e.x.upperBound] {
            for y in [e.y.lowerBound, e.y.upperBound] {
                for z in [e.z.lowerBound, e.z.upperBound] { corners.append(Vec3(x, y, z)) }
            }
        }
        func relative(_ at: Vec3) throws -> [String: SIMD3<Double>] {
            let t = try componentTranslations(at: at)
            guard let table = t[tableComponentID] else { return [:] }
            return t.mapValues { SIMD3($0.x - table.x, $0.y - table.y, $0.z - table.z) }
        }
        let posed = try relative(model.modelPose)
        var sweepLo: [String: SIMD3<Double>] = [:], sweepHi: [String: SIMD3<Double>] = [:]
        for c in corners {
            for (id, r) in try relative(c) {
                let d = r - (posed[id] ?? .zero)
                sweepLo[id] = simd_min(sweepLo[id] ?? d, d)
                sweepHi[id] = simd_max(sweepHi[id] ?? d, d)
            }
        }
        var best: (distance: Double, by: String?) = (limit, nil)
        for part in model.parts where part.group != tableComponentID && !skip.contains(part.group) {
            let a = sweepLo[part.group] ?? .zero, b = sweepHi[part.group] ?? .zero
            let v = part.mesh.vertices
            for t in stride(from: 0, to: part.mesh.indices.count - 2, by: 3) {
                var tlo = SIMD3<Double>(repeating: .infinity), thi = -tlo
                for k in 0..<3 {
                    let i = Int(part.mesh.indices[t + k]) * 3
                    let p = SIMD3(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]))
                    tlo = simd_min(tlo, p); thi = simd_max(thi, p)
                }
                tlo += a; thi += b
                guard thi.x > lo.x, tlo.x < hi.x, thi.y > lo.y, tlo.y < hi.y, tlo.z < hi.z, thi.z > lo.z else { continue }
                let room = max(back - thi.z, 0)
                if room < best.distance { best = (room, part.group) }
            }
        }
        return best
    }

    public func isMoving(componentID: String) -> Bool {
        let chain = Self.ancestors(componentID, in: definition)
        return definition.components.contains { chain.contains($0.id) && $0.axis != nil }
    }

    public func isEnclosure(componentID: String) -> Bool {
        let chain = Self.ancestors(componentID, in: definition)
        return definition.components.contains { chain.contains($0.id) && $0.isEnclosure == true }
    }

    public func movesWithTable(componentID: String) -> Bool {
        let motion = Self.ancestors(componentID, in: definition).intersection(Set(definition.components.filter { $0.axis != nil }.map(\.id)))
        let tableMotion = Self.ancestors(tableComponentID, in: definition).intersection(Set(definition.components.filter { $0.axis != nil }.map(\.id)))
        return !motion.isEmpty && motion == tableMotion
    }

    /// Interface eligibility for the currently vetted clamp/Bookend family. This does
    /// not prove a particular fixture placement, insertion path or clamping force.
    /// Other slot families remain inspectable until matching fixtures are supported.
    public var supportsVettedFixtureMounting: Bool {
        let slots = tableMountingInterfaces.flatMap(\.slots)
        let tolerance = 0.1
        // wh_build2.py NUT_L=11mm follows the slot; NUT_W=11.6mm crosses it.
        // scripts/audit-desktop-machine-geometry.py checks that same oriented box.
        let minimumSlotLength = 11.0
        guard slots.count == 2, model.tSlotZ.count == 2,
              abs((model.tSlotZ[1] - model.tSlotZ[0]) - 40.005) <= tolerance else { return false }
        return slots.allSatisfy {
            $0.length >= minimumSlotLength
                && abs($0.openingWidth - 6.13) <= tolerance && abs($0.cavityWidth - 12) <= tolerance
                && abs($0.cavityDepth - 3) <= tolerance && abs($0.lipThickness - 2) <= tolerance
        }
    }

    /// Measured mounting limits in the same canonical workspace as the table model.
    /// The caller supplies the job's existing travel centre in those coordinates.
    /// Interfaces on other assemblies cannot extend or invalidate the table's slots.
    /// No legacy table dimensions or unmeasured slot lengths are substituted here.
    public func bookendMountTable(centreY: Double) -> BookendSetup.Table? {
        guard supportsVettedFixtureMounting, centreY.isFinite else { return nil }
        var lower = -Double.infinity, upper = Double.infinity
        for mount in tableMountingInterfaces {
            for slot in mount.slots {
                guard let origin = try? definition.worldPoint(slot.origin, in: mount.frameID),
                      let direction = try? definition.worldDirection(slot.direction, in: mount.frameID) else { return nil }
                let a = worldToPlanning(origin)
                let b = worldToPlanning(Self.adding(origin, Self.scaled(direction, slot.length)))
                lower = max(lower, min(a.y, b.y))
                upper = min(upper, max(a.y, b.y))
            }
        }
        guard lower.isFinite, upper.isFinite, lower < upper else { return nil }
        return BookendSetup.Table(topX: model.tableTopX, slotZ: model.tSlotZ, slotY: lower...upper,
                                 frontZ: supportBounds.maximum.z, centreY: centreY)
    }

    private var tableMountingInterfaces: [MachineMountingInterface] {
        definition.mountingInterfaces.filter { mount in
            guard let frame = definition.frames.first(where: { $0.id == mount.frameID }) else { return false }
            return Self.ancestors(frame.componentID, in: definition).contains(tableComponentID)
        }
    }

    private static func ancestors(_ id: String, in definition: MachineDefinition) -> Set<String> {
        var chain = Set<String>(), current: String? = id
        while let id = current, chain.insert(id).inserted {
            current = definition.components.first { $0.id == id }?.parentID
        }
        return chain
    }
    private static func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x*b.x + a.y*b.y + a.z*b.z }
    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 { .init(a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x) }
    private static func scaled(_ a: Vec3, _ k: Double) -> Vec3 { .init(a.x*k, a.y*k, a.z*k) }
    private static func adding(_ a: Vec3, _ b: Vec3) -> Vec3 { .init(a.x+b.x, a.y+b.y, a.z+b.z) }
    private static func near(_ a: Vec3, _ b: Vec3) -> Bool { abs(a.x-b.x) < 0.000001 && abs(a.y-b.y) < 0.000001 && abs(a.z-b.z) < 0.000001 }
    /// Merge tessellation vertices at shared geometric locations, then find connected
    /// coplanar triangle regions. A bounding box of all vertices at one height would
    /// wrongly include the table's small, separate fastener pads.
    private static func planarRegions(_ points: [Vec3], indices: [UInt32], eligible: [Bool]) -> [[Vec3]] {
        guard eligible.contains(true) else { return [] }
        struct Key: Hashable {
            var x: Double; var y: Double; var z: Double
            init(_ p: Vec3) { x = (p.x * 10_000).rounded(); y = (p.y * 10_000).rounded(); z = (p.z * 10_000).rounded() }
        }
        var keys: [Key: Int] = [:], positions: [Vec3] = [], parents: [Int] = []
        func vertex(_ index: Int) -> Int {
            let key = Key(points[index])
            if let id = keys[key] { return id }
            let id = parents.count
            keys[key] = id; parents.append(id); positions.append(points[index])
            return id
        }
        func root(_ index: Int) -> Int {
            var i = index
            while parents[i] != i { parents[i] = parents[parents[i]]; i = parents[i] }
            return i
        }
        for index in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[index]), b = Int(indices[index + 1]), c = Int(indices[index + 2])
            guard eligible[a] && eligible[b] && eligible[c] else { continue }
            let pa = points[a], pb = points[b], pc = points[c]
            let area = abs((pb.y-pa.y)*(pc.z-pa.z) - (pb.z-pa.z)*(pc.y-pa.y))
            guard area > 1e-9 else { continue }
            let ia = vertex(a), ib = vertex(b), ic = vertex(c)
            let ra = root(ia), rb = root(ib), rc = root(ic)
            parents[rb] = ra
            parents[rc] = ra
        }
        var regions: [Int: [Vec3]] = [:]
        for index in positions.indices { regions[root(index), default: []].append(positions[index]) }
        return Array(regions.values)
    }
    private static func bounds(_ points: [Vec3]) throws -> Bounds {
        guard let first = points.first else { throw MachineDefinitionError("The machine model does not contain the declared table surface.") }
        var lo = first, hi = first
        for point in points.dropFirst() {
            lo.x = min(lo.x, point.x); lo.y = min(lo.y, point.y); lo.z = min(lo.z, point.z)
            hi.x = max(hi.x, point.x); hi.y = max(hi.y, point.y); hi.z = max(hi.z, point.z)
        }
        return Bounds(minimum: lo, maximum: hi)
    }
}
