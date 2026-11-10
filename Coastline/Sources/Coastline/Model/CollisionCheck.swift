import CoastlineCore
import Foundation
import simd
import Viewport

/// One object on the bed for the collision check: a fixture (its triangles) or a box (the stock).
struct BedBody: Sendable {
    enum Shape: Sendable {
        case box(SIMD3<Double>, SIMD3<Double>)
        case triangles([SIMD3<Double>])
    }
    var name: String
    /// Scene meshes of this body (tinted when it collides).
    var meshPrefix: String
    var shape: Shape
}

/// The collision engine at work in the 3D view (Safety/Collision.swift does the geometry): after
/// every layout the fixtures, the stock and the machine (bed, frame, enclosure) are checked
/// against each other in the background; what collides turns red, gets a marker, and is listed
/// with the issues.
extension AppModel {

    nonisolated static let machineBodyName = "the machine (bed, frame)"

    /// The machine's fixed parts and the table (as modelled, with the table at its setup pose),
    /// built once: it's the largest mesh.
    func machineCollisionTree() async -> TriangleTree? {
        guard let mm = machineModel else { return nil }
        let reference = planningMachineReference
        var offsetByGroup: [String: Vec3] = [:]
        let parts: [MachineModel.Part]
        var key = "legacy"
        if let geometry = planningGeometry {
            guard let translations = try? geometry.componentTranslations(at: Vec3(machinePosition.x, machinePosition.y, machinePosition.z)),
                  let table = translations[geometry.tableComponentID] else { return nil }
            key = "\(reference.reference.id):\(reference.reference.revision):\(table.x),\(table.y),\(table.z)"
            parts = mm.parts.filter { !geometry.isMoving(componentID: $0.group) || geometry.movesWithTable(componentID: $0.group) }
            for (id, t) in translations {
                offsetByGroup[id] = Vec3(t.x - table.x, t.y - table.y, t.z - table.z)
            }
        } else { parts = mm.parts.filter { $0.group == "static" || $0.group == "x" } }
        if machineTreeKey == key {
            if let tree = machineTree { return tree }
            if let running = machineTreeTask { return await running.value }
        }
        machineTreeTask?.cancel()
        machineTree = nil
        machineTreeKey = key
        let token = UUID()
        machineTreeTaskID = token
        let offsets = offsetByGroup
        // One build, shared by everyone who asks while it runs.
        let task = Task.detached(priority: .utility) { () -> TriangleTree? in
            var tris: [SIMD3<Double>] = []
            for p in parts {
                if Task.isCancelled { return nil }
                let offset = offsets[p.group] ?? .zero
                let v = p.mesh.vertices
                for idx in p.mesh.indices {
                    let i = Int(idx) * 3
                    tris.append(SIMD3(Double(v[i]) + offset.x, Double(v[i + 1]) + offset.y, Double(v[i + 2]) + offset.z))
                }
            }
            return TriangleTree(tris)
        }
        machineTreeTask = task
        let tree = await task.value
        guard machineTreeTaskID == token, planningMachineReference == reference else { return nil }
        machineTree = tree
        machineTreeTask = nil
        return tree
    }

    func scheduleCollisionCheck(_ bodies: [BedBody], stockSize: SIMD3<Double>) {
        collisionGeneration += 1
        let generation = collisionGeneration
        guard !bodies.isEmpty, stock != nil, !showingStockOnly, ProcessInfo.processInfo.environment["COASTLINE_NO_COLLISIONS"] == nil else {
            if !collisions.isEmpty { collisions = [] }
            showCollisions()
            return
        }
        // The stock as shown (a box; the simulation's cut shape doesn't matter here).
        let o = workOrigin(stockSize: stockSize)
        var all = bodies
        if setup.planFromFixtureLibrary {
            // Library planning checks fixture occupancy against accumulated remaining stock.
            // The original blank box would incorrectly reject a locating nest used later.
        } else {
            all.append(BedBody(name: "the stock", meshPrefix: "stock", shape: .box(SIMD3(o.x - stockSize.x / 2, o.y - stockSize.y / 2, o.z - stockSize.z),
                                                                                 SIMD3(o.x + stockSize.x / 2, o.y + stockSize.y / 2, o.z))))
        }
        bedBodies = all
        Task { @MainActor in
            // Let a drag settle: only the latest layout is checked.
            try? await Task.sleep(for: .milliseconds(60))
            guard generation == collisionGeneration else { return }
            let machine = await machineCollisionTree()
            guard generation == collisionGeneration else { return }
            let bodies = all
            let found = await Task.detached(priority: .userInitiated) { Self.collide(bodies, machine: machine) }.value
            guard generation == collisionGeneration else { return }
            if found != collisions { collisions = found }
            collisionPrefixes = Dictionary(all.map { ($0.name, $0.meshPrefix) }, uniquingKeysWith: { a, _ in a })
            showCollisions()
        }
    }

    /// All of the bodies' triangles together (model coordinates).
    nonisolated static func triangles(_ all: [BedBody]) -> [SIMD3<Double>] {
        var tris: [SIMD3<Double>] = []
        for b in all {
            switch b.shape {
            case .box(let lo, let hi): tris += Collision.boxTriangles(min: lo, max: hi)
            case .triangles(let t): tris += t
            }
        }
        return tris
    }

    nonisolated static func collide(_ all: [BedBody], machine: TriangleTree?) -> [Collision.Contact] {
        var list: [Collision.Body] = []
        for b in all {
            switch b.shape {
            case .box(let lo, let hi):
                list.append(.box(name: b.name, min: lo, max: hi))
            case .triangles(let t):
                list.append(Collision.Body(name: b.name, triangles: t))
            }
        }
        if let machine { list.append(Collision.Body(name: machineBodyName, tree: machine)) }
        // Contact by design is touching, never colliding. Up to 0.2 mm is the fit of a key in a
        // T-slot or a modelling tolerance; real overlaps beyond it count.
        return Collision.check(list, tolerance: 0.2)
    }

    /// The collisions as issues ("C-clamp 1 runs into the machine (bed, frame) by 3.2 mm").
    var collisionIssues: [Issue] {
        collisions.map { c in
            Issue(.warning, "\(c.a.prefix(1).uppercased() + c.a.dropFirst()) runs into \(c.b) by about \(Length.mm(max(c.depth, 0.1))) mm.")
        }
    }

    /// Red tint on colliding fixtures and a marker where they meet.
    func showCollisions() {
        let scene = renderer.scene
        scene.remove(id: "collision")
        guard !collisions.isEmpty else { return }
        var segs: [LineSegment] = []
        let c8 = SceneColor.danger
        for c in collisions {
            let p = SIMD3<Float>(c.point)
            let r: Float = 3
            for d in [SIMD3<Float>(r, 0, 0), SIMD3(0, r, 0), SIMD3(0, 0, r)] { segs.append(LineSegment(p - d, p + d, color: c8)) }
            // A small ring around it, so it's seen from any side.
            for k in 0..<24 {
                let a = Float(k) / 24 * 2 * .pi, b = Float(k + 1) / 24 * 2 * .pi
                segs.append(LineSegment(p + SIMD3(0, cos(a), sin(a)) * r, p + SIMD3(0, cos(b), sin(b)) * r, color: c8))
            }
        }
        if let set = SceneLines(device: renderer.device, id: "collision", segments: segs) { scene.setLines(set) }
    }
}
