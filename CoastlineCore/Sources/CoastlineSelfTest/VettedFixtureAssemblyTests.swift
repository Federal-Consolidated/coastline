import CoastlineCore
import Foundation
import simd

private func vettedBox(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) -> MeshData {
    let points = FixtureField.boxTriangles(min: lo, max: hi)
    return MeshData(vertices: points.flatMap { [Float($0.x), Float($0.y), Float($0.z)] },
                    normals: Array(repeating: 0, count: points.count * 3), indices: Array(0..<UInt32(points.count)),
                    boundsMin: Vec3(lo.x, lo.y, lo.z), boundsMax: Vec3(hi.x, hi.y, hi.z), exact: true, faceCount: 6)
}

private func articulatedFixture() -> (FixtureAssemblyDefinition, [FixtureAssemblyPart]) {
    let definition = FixtureAssemblyDefinition(id: "test-bookend", revision: 1, modelSHA256: String(repeating: "a", count: 64), components: [
        .init(id: "base", name: "Base and mounting hardware", modelEntities: ["0/0", "0/1"],
              joint: .init(id: "slide", kind: .prismatic, axis: Vec3(0, 1, 0), minimum: -20, maximum: 20)),
        .init(id: "screw", name: "Pressure screw", parentID: "base", modelEntities: ["0/2"],
              joint: .init(id: "advance", kind: .screw, axis: Vec3(1, 0, 0), minimum: 0, maximum: 15, referenceValue: 4, pitch: 0.8)),
        .init(id: "table-reference", name: "Authored table reference", role: .reference, modelEntities: ["0/3"]),
    ])
    let parts = [
        FixtureAssemblyPart(componentID: "base", entityPath: "0/0", solidIndex: 0, mesh: vettedBox(SIMD3(-10, -2, -2), SIMD3(-8, 2, 2))),
        // Physically distant mounting hardware still follows the explicit base group.
        FixtureAssemblyPart(componentID: "base", entityPath: "0/1", solidIndex: 0, mesh: vettedBox(SIMD3(-10, 15, -2), SIMD3(-9, 16, -1))),
        FixtureAssemblyPart(componentID: "screw", entityPath: "0/2", solidIndex: 0, mesh: vettedBox(SIMD3(2, -0.2, -0.1), SIMD3(3, 0.2, 0.1))),
        FixtureAssemblyPart(componentID: "table-reference", entityPath: "0/3", solidIndex: 0, mesh: vettedBox(SIMD3(-100, -100, -100), SIMD3(100, 100, 100))),
    ]
    return (definition, parts)
}

let vettedFixtureAssemblyTests: [TestCase] = [
    TestCase(name: "hierarchyMovesRealHardwareAndScrewIndependently") {
        let (definition, parts) = articulatedFixture()
        let geometry = try LibraryFixtureGeometry(parts: parts, definition: definition)
        var profile = FixturePlanningProfile()
        profile.assemblyState = .init(jointValues: ["slide": 7, "advance": 4.2])
        try geometry.validate(profile: profile)
        let base = try unwrap(geometry.components.first { $0.id == "base" })
        let screw = try unwrap(geometry.components.first { $0.id == "screw" })
        let basePoint = geometry.transform(base, profile: profile) * SIMD4<Double>(0, 0, 0, 1)
        let screwAxisPoint = geometry.transform(screw, profile: profile) * SIMD4<Double>(2, 0, 0, 1)
        try expect(simd_distance(SIMD3(basePoint.x, basePoint.y, basePoint.z), SIMD3(0, 7, 0)) < 1e-9)
        try expect(simd_distance(SIMD3(screwAxisPoint.x, screwAxisPoint.y, screwAxisPoint.z), SIMD3(2.2, 7, 0)) < 1e-9)
        // 0.2 mm / 0.8 mm pitch is a quarter-turn, about the authored shaft axis.
        let radialPoint = geometry.transform(screw, profile: profile) * SIMD4<Double>(2, 1, 0, 1)
        try expect(simd_distance(SIMD3(radialPoint.x, radialPoint.y, radialPoint.z), SIMD3(2.2, 7, 1)) < 1e-9)
        try expectEqual(base.solidIndices, [0, 1])
        for index in base.solidIndices {
            let p = geometry.solidTransform(index, profile: profile) * SIMD4<Double>(0, 0, 0, 1)
            try expect(simd_distance(SIMD3(p.x, p.y, p.z), SIMD3(0, 7, 0)) < 1e-9)
        }
    },
    TestCase(name: "referenceBodiesNeverBecomeFixtureCollisionGeometry") {
        let (definition, parts) = articulatedFixture()
        let geometry = try LibraryFixtureGeometry(parts: parts, definition: definition)
        try expectEqual(geometry.physicalSolidIndices, Set([0, 1, 2]))
        try expectEqual(geometry.components.map(\.id), ["base", "screw"])
        let mesh = geometry.workMesh(profile: .init())
        try expectEqual(mesh.indices.count, parts.prefix(3).reduce(0) { $0 + $1.mesh.indices.count })
        let bounds = geometry.bounds(profile: .init())
        try expect(bounds.min.x > -100 && bounds.max.x < 100, "reference table expanded physical fixture bounds")
        var exploded = definition; exploded.isAssembled = false
        var fixture = Fixture(name: "Exploded view", kind: .jigPlate); fixture.assembly = exploded
        try expect(LibraryWorkholdingPlanner.eligibility(fixture, stock: SIMD3(20, 20, 20)).contains { $0.contains("assembled fixture") },
                   "user review must not approve an exploded CAD view")
        // Display and inspection still work for an explicitly non-plannable assembly.
        _ = try LibraryFixtureGeometry(parts: parts, definition: exploded)
    },
    TestCase(name: "solidOrderDoesNotChangeComponentIdentityOrTransforms") {
        let (definition, parts) = articulatedFixture()
        let a = try LibraryFixtureGeometry(parts: parts, definition: definition)
        let b = try LibraryFixtureGeometry(parts: parts.reversed(), definition: definition)
        try expectEqual(a.layoutID, b.layoutID)
        try expectEqual(a.components.map(\.id), b.components.map(\.id))
        var profile = FixturePlanningProfile(); profile.assemblyState = .init(jointValues: ["slide": -6, "advance": 8])
        for id in a.components.map(\.id) {
            let aa = a.bounds(profile: profile, componentID: id), bb = b.bounds(profile: profile, componentID: id)
            try expect(simd_distance(aa.min, bb.min) < 1e-9 && simd_distance(aa.max, bb.max) < 1e-9)
        }
    },
    TestCase(name: "mechanicalStateRejectsUnknownOutOfRangeAndDoubleTransforms") {
        let (definition, parts) = articulatedFixture()
        let geometry = try LibraryFixtureGeometry(parts: parts, definition: definition)
        for state in [FixtureAssemblyState(jointValues: ["unknown": 1]), .init(jointValues: ["advance": 16]),
                      .init(jointValues: ["advance": .nan]), .init(lockedComponents: ["table-reference"])] {
            var profile = FixturePlanningProfile(); profile.assemblyState = state
            try expectThrows { try geometry.validate(profile: profile) }
            try expect(!geometry.placementsMatch(profile))
        }
        var profile = FixturePlanningProfile(); profile.componentPlacements = [.init(id: "base")]
        try expectThrows { try geometry.validate(profile: profile) }
        profile.componentPlacements = nil; profile.componentModelSignature = String(repeating: "b", count: 64)
        try expectThrows { try geometry.validate(profile: profile) }
        profile.componentModelSignature = nil; profile.componentLayoutID = "old-heuristic-layout"
        try expectThrows { try geometry.validate(profile: profile) }
        profile.componentLayoutID = nil; profile.datum.x = .nan
        try expectThrows { try geometry.validate(profile: profile) }
    },
    TestCase(name: "exactBindingsRejectMissingReassignedAndDuplicateBodies") {
        let (definition, parts) = articulatedFixture()
        try expectThrows { _ = try LibraryFixtureGeometry(parts: Array(parts.dropLast()), definition: definition) }
        try expectThrows { _ = try LibraryFixtureGeometry(parts: parts + [parts[0]], definition: definition) }
        var wrong = parts; wrong[0].componentID = "screw"
        try expectThrows { _ = try LibraryFixtureGeometry(parts: wrong, definition: definition) }
        var cycle = definition; cycle.components[0].parentID = "screw"
        try expectThrows { try cycle.validate() }
        var badAxis = definition; badAxis.components[0].joint?.axis = .zero
        try expectThrows { try badAxis.validate() }
        var badPitch = definition; badPitch.components[1].joint?.pitch = 1e-300
        try expectThrows { try badPitch.validate() }
    },
    TestCase(name: "definitionsAndStatePersistWithoutChangingLegacyFixtures") {
        let (definition, _) = articulatedFixture()
        var fixture = Fixture(name: "Bookend", kind: .other)
        fixture.assembly = definition
        var profile = FixturePlanningProfile()
        profile.assemblyState = .init(jointValues: ["slide": 8, "advance": 4.5], mounted: true, lockedComponents: ["base"])
        fixture.planning = profile
        let decoded = try JSONDecoder().decode(Fixture.self, from: JSONEncoder().encode(fixture))
        try expectEqual(decoded, fixture)
        var exploded = definition; exploded.isAssembled = false
        try expect(try JSONDecoder().decode(FixtureAssemblyDefinition.self, from: JSONEncoder().encode(exploded)).isAssembled == false)
        var oldDefinitionJSON = try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any])
        oldDefinitionJSON.removeValue(forKey: "isAssembled")
        try expect(try JSONDecoder().decode(FixtureAssemblyDefinition.self, from: JSONSerialization.data(withJSONObject: oldDefinitionJSON)).isAssembled)
        var setup = Setup(); setup.fixtureAssemblies = [fixture]
        let saved = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(setup))
        try expectEqual(saved.fixtureAssemblies, [fixture], "pre-CAM setup lost its mechanical state")
        setup.flipped.toggle()
        try expectEqual(setup.fixtureAssemblies, saved.fixtureAssemblies, "flipping stock moved mounted hardware")
        var oldSetupJSON = try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? [String: Any])
        oldSetupJSON.removeValue(forKey: "fixtureAssemblies")
        let oldSetup = try JSONDecoder().decode(Setup.self, from: JSONSerialization.data(withJSONObject: oldSetupJSON))
        try expect(oldSetup.fixtureAssemblies == nil)
        var old = fixture; old.assembly = nil; old.planning?.assemblyState = nil
        let legacy = try JSONDecoder().decode(Fixture.self, from: JSONEncoder().encode(old))
        try expect(legacy.assembly == nil && legacy.planning?.assemblyState == nil)
        try expectEqual(legacy, old)
        var bookend = fixture
        bookend.assembly = try JSONDecoder().decode(FixtureAssemblyDefinition.self,
            from: Data(contentsOf: repoRoot.appendingPathComponent("resources/fixtures/bookends/definition.json")))
        let fixtureJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bookend))
        let stepJSON: [String: Any] = ["id": UUID().uuidString, "number": 1, "side": 0, "fixture": fixtureJSON,
                                      "cutKeys": [], "operations": [], "reasons": [], "reviewed": false]
        var step = try JSONDecoder().decode(LibraryWorkholdingPlan.Step.self, from: JSONSerialization.data(withJSONObject: stepJSON))
        try expect(step.instructions.contains("secure both bases") && step.instructions.contains("advance the side screw"))
        step.side = 1
        try expect(step.instructions.contains("Release the side screw") && step.instructions.contains("Keep the bases mounted"))
        try expect(step.instructions.contains("do not prove clamping force"))
    },
    TestCase(name: "collisionFieldFollowsPressureScrewState") {
        let (definition, parts) = articulatedFixture()
        let geometry = try LibraryFixtureGeometry(parts: parts, definition: definition)
        func field(_ advance: Double) throws -> FixtureField {
            var profile = FixturePlanningProfile(); profile.assemblyState = .init(jointValues: ["advance": advance])
            try geometry.validate(profile: profile)
            let mesh = geometry.workMesh(profile: profile)
            let triangles = mesh.indices.map { index -> SIMD3<Double> in
                let i = Int(index) * 3; return SIMD3(Double(mesh.vertices[i]), Double(mesh.vertices[i + 1]), Double(mesh.vertices[i + 2]))
            }
            return FixtureField(triangles: triangles, regionMin: SIMD2(-20, -20), regionMax: SIMD2(20, 20), cell: 0.1)
        }
        let tool = Tool(name: "Probe cut", kind: .flatEndMill, diameter: 0.2, shankDiameter: 0.2, flutes: 2, fluteLength: 2, stickout: 3, overallLength: 10)
        let moves = [Move(.rapid, x: 2.5, y: 0, z: 2), Move(.plunge, x: 2.5, y: 0, z: -0.2, feed: 100)]
        var original = try field(4), moved = try field(8)
        try expect(!FixtureClearance.check(moves, tool: tool, field: &original).isEmpty)
        try expect(FixtureClearance.check(moves, tool: tool, field: &moved).isEmpty)
    },
]
