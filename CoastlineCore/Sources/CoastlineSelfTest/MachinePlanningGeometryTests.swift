import CoastlineCore
import Foundation

private func planningDefinition() throws -> MachineDefinition {
    try MachineDefinitionPackage.load(from: repoRoot.appendingPathComponent("resources/machines/desktop-cnc")).definition
}

/// Small triangulated surfaces exercise coordinate conversion and reject invalid support
/// planes. The full STEP is separately checked through the Engine integration test.
private func planningTableParts() -> [MachineModel.Part] {
    let points: [Float] = [
        15.865, -389.423, 54.914, 15.865, -84.423, 54.914,
        15.865, -84.423, 129.844, 15.865, -389.423, 129.844,
        1.260, -429.423, 54.914, 1.260, -44.423, 54.914,
        1.260, -44.423, 129.844, 1.260, -429.423, 129.844,
    ]
    let mesh = MeshData(vertices: points, normals: Array(repeating: [Float(1), 0, 0], count: 8).flatMap { $0 },
                        indices: [0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6],
                        boundsMin: .zero, boundsMax: .zero, exact: false, faceCount: 2)
    return [.init(group: "table", role: "aluminium", color: SIMD3(repeating: 0.5), mesh: mesh)]
}

private func expectPlanningVec(_ actual: Vec3, _ expected: Vec3, tolerance: Double = 0.00001) throws {
    try expect(abs(actual.x - expected.x) < tolerance && abs(actual.y - expected.y) < tolerance
               && abs(actual.z - expected.z) < tolerance, "Expected \(expected), got \(actual)")
}

let machinePlanningGeometryTests: [TestCase] = [
    TestCase(name: "profileCoordinatesAndTableGeometryReplaceLegacyConstants") {
        let d = try planningDefinition()
        let g = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        try expectPlanningVec(g.model.modelPose, Vec3(0, -69, -79.9))
        try expectPlanningVec(g.model.spindleNose, Vec3(105.43, -176.8, 112.26))
        try expect(abs(g.model.tableTopX - 15.865) < 0.000001)
        try expectEqual(g.model.tSlotZ.count, 2)
        try expect(abs(g.model.tSlotZ[0] - 78.759) < 0.000001)
        try expect(abs(g.model.tSlotZ[1] - 118.764) < 0.000001)
        try expect(abs(g.supportBounds.size.y - 305) < 0.0001)
        try expect(abs(g.tableBounds.size.y - 385) < 0.0001)
        let table = try unwrap(g.bookendMountTable(centreY: -251.75))
        try expectEqual(table.topX, g.model.tableTopX)
        try expectEqual(table.slotZ, g.model.tSlotZ)
        try expect(abs(table.slotY.lowerBound - -389.42) < 0.000001)
        try expect(abs(table.slotY.upperBound - -84.42) < 0.000001)
        try expectEqual(table.frontZ, g.supportBounds.maximum.z)
        try expectEqual(table.centreY, -251.75)
        try expect(g.bookendMountTable(centreY: .nan) == nil)
        // The real table takes the C-clamps on the 2 × 2 × 8" bar and the vise on a small block.
        let fixtures = repoRoot.appendingPathComponent("resources/fixtures")
        for (file, stock) in [("c-clamps/definition.json", SIMD3(50.8, 203.2, 50.8)), ("vise/definition.json", SIMD3(30, 40, 20))] {
            var f = Fixture(name: file, kind: .other, quantity: 2)
            f.assembly = try JSONDecoder().decode(FixtureAssemblyDefinition.self, from: Data(contentsOf: fixtures.appendingPathComponent(file)))
            try expect(try FixtureMechanism.automatic(f, table: table, stock: stock) != nil, file)
        }
        let home = try g.componentTranslations(at: d.controllerHomePosition)
        try expectPlanningVec(home[g.tableComponentID]!, Vec3(86, 0, 0))
        try expectPlanningVec(home[g.headComponentID]!, Vec3(0, 68.5, 79.4))
        try expectPlanningVec(home["cover"]!, .zero)
        try expect(g.isMoving(componentID: "head"))
        try expect(g.movesWithTable(componentID: "table"))
        try expect(!g.movesWithTable(componentID: "head"))
        try expect(g.isEnclosure(componentID: "cover"))
        try expect(!g.isEnclosure(componentID: "table"))
    },
    TestCase(name: "rotatedCADBasisAndRenamedComponentsProduceSameWorkspace") {
        var d = try planningDefinition()
        let original = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        // A proper rotation: CAD (X,Y,Z) becomes (Z,X,Y). Coordinate letters and
        // component IDs must not select the desktop's original orientation.
        func rotate(_ p: Vec3) -> Vec3 { .init(p.z, p.x, p.y) }
        let renamed = Dictionary(uniqueKeysWithValues: d.components.enumerated().map { ($0.element.id, "assembly-\($0.offset)") })
        for i in d.components.indices {
            d.components[i].id = renamed[d.components[i].id]!
            d.components[i].parentID = d.components[i].parentID.map { renamed[$0]! }
            if let axis = d.components[i].axis { d.components[i].axis!.direction = rotate(axis.direction) }
        }
        for i in d.frames.indices {
            d.frames[i].componentID = renamed[d.frames[i].componentID]!
            d.frames[i].origin = rotate(d.frames[i].origin)
            d.frames[i].xDirection = rotate(d.frames[i].xDirection)
            d.frames[i].zDirection = rotate(d.frames[i].zDirection)
        }
        var parts = planningTableParts()
        for i in parts.indices {
            parts[i].group = renamed[parts[i].group]!
            for j in stride(from: 0, to: parts[i].mesh.vertices.count, by: 3) {
                let v = parts[i].mesh.vertices, n = parts[i].mesh.normals
                parts[i].mesh.vertices[j] = v[j + 2]; parts[i].mesh.vertices[j + 1] = v[j]; parts[i].mesh.vertices[j + 2] = v[j + 1]
                parts[i].mesh.normals[j] = n[j + 2]; parts[i].mesh.normals[j + 1] = n[j]; parts[i].mesh.normals[j + 2] = n[j + 1]
            }
        }
        let transformed = try MachinePlanningGeometry(definition: d, parts: parts)
        try expectPlanningVec(transformed.model.spindleNose, original.model.spindleNose)
        try expectEqual(transformed.supportBounds, original.supportBounds)
        try expectEqual(transformed.model.parts[0].mesh.vertices, original.model.parts[0].mesh.vertices)
        try expectEqual(transformed.model.parts[0].mesh.normals, original.model.parts[0].mesh.normals)
        let originalMount = try unwrap(original.bookendMountTable(centreY: -200))
        let rotatedMount = try unwrap(transformed.bookendMountTable(centreY: -200))
        try expectEqual(rotatedMount.slotY, originalMount.slotY)
        try expectEqual(rotatedMount.slotZ, originalMount.slotZ)
        try expectEqual(rotatedMount.topX, originalMount.topX)
        try expectEqual(rotatedMount.frontZ, originalMount.frontZ)
        try expectEqual(rotatedMount.centreY, originalMount.centreY)
        let translated = try transformed.componentTranslations(at: d.controllerHomePosition)
        try expectPlanningVec(translated[renamed["table"]!]!, Vec3(86, 0, 0))
        try expectPlanningVec(transformed.planningToWorld(transformed.worldToPlanning(Vec3(7, 8, 9))), Vec3(7, 8, 9))
    },
    TestCase(name: "unsupportedVerticalPlannerCannotSilentlyBecomeHorizontal") {
        var d = try planningDefinition()
        let frame = d.frames.firstIndex { $0.id == "table-surface" }!
        d.frames[frame].xDirection = Vec3(1, 0, 0)
        d.frames[frame].zDirection = Vec3(0, 0, 1)
        try d.validate() // still a valid generic digital machine definition
        try expectThrows { _ = try MachinePlanningGeometry(definition: d, parts: planningTableParts()) }
    },
    TestCase(name: "modelAndMountingMismatchMustBeCorrectedBeforePlanning") {
        let original = try planningDefinition()
        var d = original
        let frame = d.frames.firstIndex { $0.id == "table-surface" }!
        d.frames[frame].origin.x += 2
        try expectThrows { _ = try MachinePlanningGeometry(definition: d, parts: planningTableParts()) }
        d = original; d.mountingInterfaces[0].slots[0].origin.z += 300
        try expectThrows { _ = try MachinePlanningGeometry(definition: d, parts: planningTableParts()) }
        d = original; d.mountingInterfaces[0].slots[0].direction = Vec3(0, 0, 1)
        try expectThrows { _ = try MachinePlanningGeometry(definition: d, parts: planningTableParts()) }
        try expectThrows { _ = try MachinePlanningGeometry(definition: original, parts: []) }
    },
    TestCase(name: "physicalCalibrationDoesNotHideUnresolvedPlanningRequirements") {
        var d = try planningDefinition()
        _ = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        d.checks![d.checks!.firstIndex { $0.id == "native-post" }!].status = .pending
        d.checks![d.checks!.firstIndex { $0.id == "native-post" }!].action = "Review the changed post."
        try expectThrows { _ = try MachinePlanningGeometry(definition: d, parts: planningTableParts()) }
    },
    TestCase(name: "differentSlotFamiliesStayDigitalWithoutClaimingVettedFixtureCompatibility") {
        var d = try planningDefinition()
        let original = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        try expect(original.supportsVettedFixtureMounting)
        // A broader physical table can validly have 80 mm slot spacing. Its geometry
        // still loads, but the currently vetted 40 mm fixture family must not be used.
        d.mountingInterfaces[0].slots[1].origin.z = d.mountingInterfaces[0].slots[0].origin.z + 80
        var parts = planningTableParts()
        for i in stride(from: 2, to: parts[0].mesh.vertices.count, by: 3) {
            if parts[0].mesh.vertices[i] > 129 { parts[0].mesh.vertices[i] = 190 }
        }
        let wider = try MachinePlanningGeometry(definition: d, parts: parts)
        try expect(!wider.supportsVettedFixtureMounting)
        try expect(wider.bookendMountTable(centreY: 0) == nil)
        d = try planningDefinition()
        d.mountingInterfaces[0].slots[0].cavityDepth = 4
        let deeperSlots = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        try expect(!deeperSlots.supportsVettedFixtureMounting)
        d = try planningDefinition()
        d.mountingInterfaces[0].slots[0].length = 10.99
        let tooShort = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        try expect(!tooShort.supportsVettedFixtureMounting, "The reviewed nut is 11 mm along the slot, regardless of matching cross-section")
        d.mountingInterfaces[0].slots[0].length = 11
        let nutLength = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        try expect(nutLength.supportsVettedFixtureMounting)
    },
    TestCase(name: "bookendMountUsesOnlyTableSlotsAndTheirSharedLength") {
        var d = try planningDefinition()
        let original = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        let expected = try unwrap(original.bookendMountTable(centreY: -210))
        // A separate mounting interface on the head is valid machine metadata, but it
        // does not supply slots for a fixture seated on the moving table.
        var other = d.mountingInterfaces[0]
        other.id = "head-accessory-slots"; other.frameID = "tool"
        other.slots[0].length = 5; other.slots[1].length = 5
        d.mountingInterfaces.append(other)
        let withHeadMount = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        try expect(withHeadMount.supportsVettedFixtureMounting)
        let actual = try unwrap(withHeadMount.bookendMountTable(centreY: -210))
        try expectEqual(actual.slotY, expected.slotY)
        try expectEqual(actual.slotZ, expected.slotZ)
        try expectEqual(actual.topX, expected.topX)
        try expectEqual(actual.frontZ, expected.frontZ)
        try expectEqual(actual.centreY, expected.centreY)

        // Each key must remain in its own slot. Only their common longitudinal span
        // is usable, including when one slot was authored from its opposite end.
        d.mountingInterfaces[0].slots[0].length = 250
        d.mountingInterfaces[0].slots[1].origin.y += 280
        d.mountingInterfaces[0].slots[1].direction.y = -1
        d.mountingInterfaces[0].slots[1].length = 260
        let partial = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        let overlap = try unwrap(partial.bookendMountTable(centreY: -210))
        try expect(abs(overlap.slotY.lowerBound - (expected.slotY.lowerBound + 20)) < 0.000001)
        try expect(abs(overlap.slotY.upperBound - (expected.slotY.lowerBound + 250)) < 0.000001)

        d.mountingInterfaces[0].slots[0].length = 11
        d.mountingInterfaces[0].slots[1].length = 11
        let disjoint = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        try expect(disjoint.supportsVettedFixtureMounting)
        try expect(disjoint.bookendMountTable(centreY: -210) == nil,
                   "matching cross-sections do not create a usable overlap between disjoint slots")
    },
    TestCase(name: "coplanarFastenerPadsDoNotEnlargeTheStockSupportFootprint") {
        let d = try planningDefinition()
        let original = try MachinePlanningGeometry(definition: d, parts: planningTableParts())
        var parts = planningTableParts()
        // The real table has small upper pads beyond both ends of its broad seating
        // strips. They share X and normals but are separate planar triangle regions.
        let base = UInt32(parts[0].mesh.vertexCount)
        parts[0].mesh.vertices += [15.865, -412, 126, 15.865, -403, 126,
                                  15.865, -403, 129, 15.865, -412, 129]
        parts[0].mesh.normals += Array(repeating: [Float(1), 0, 0], count: 4).flatMap { $0 }
        parts[0].mesh.indices += [base, base+1, base+2, base, base+2, base+3]
        let actual = try MachinePlanningGeometry(definition: d, parts: parts)
        try expectEqual(actual.supportBounds, original.supportBounds)
        try expect(abs(actual.supportBounds.size.y - 305) < 0.001)
    },
]
