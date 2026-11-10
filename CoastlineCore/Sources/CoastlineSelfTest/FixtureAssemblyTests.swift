import CoastlineCore
import Foundation
import simd

private func fixtureBox(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) -> MeshData {
    let points = FixtureField.boxTriangles(min: lo, max: hi)
    return MeshData(vertices: points.flatMap { [Float($0.x), Float($0.y), Float($0.z)] },
        normals: Array(repeating: 0, count: points.count * 3), indices: (0..<UInt32(points.count)).map { $0 },
        boundsMin: Vec3(lo.x, lo.y, lo.z), boundsMax: Vec3(hi.x, hi.y, hi.z), exact: true, faceCount: 6)
}

private func bookends() -> LibraryFixtureGeometry {
    LibraryFixtureGeometry(solids: [
        fixtureBox(SIMD3(-3, -16, -10), SIMD3(3, -12, 0)),
        fixtureBox(SIMD3(-1, -15, 0.2), SIMD3(1, -13, 4)),
        fixtureBox(SIMD3(-3, 12, -10), SIMD3(3, 16, 0)),
        fixtureBox(SIMD3(-1, 13, 0.2), SIMD3(1, 15, 4)),
    ])
}

let fixtureAssemblyTests: [TestCase] = [
    TestCase(name: "keepsNearbyHardwareWithEachEndAndHasStablePieceIDs") {
        let assembly = bookends()
        try expectEqual(assembly.components.count, 2)
        try expect(assembly.components.allSatisfy { $0.solidIndices.count == 2 })
        let reordered = LibraryFixtureGeometry(solids: assembly.solids.reversed())
        try expectEqual(reordered.layoutID, assembly.layoutID)
        try expectEqual(reordered.components.map(\.id), assembly.components.map(\.id))
    },
    TestCase(name: "movesOnlyTheChosenBookendInWorkDirectionsAfterRotation") {
        let assembly = bookends(), id = assembly.components[0].id
        var p = FixturePlanningProfile(); p = p.turned(about: 2, quarterTurns: 1)
        let delta = SIMD3<Double>(4, -7, 3)
        let moved = assembly.moved(p, componentID: id, by: delta)
        for (i, c) in assembly.components.enumerated() {
            let a = assembly.bounds(profile: p, componentID: c.id)
            let b = assembly.bounds(profile: moved, componentID: c.id)
            let expected = i == 0 ? delta : .zero
            try expect(simd_distance(b.min - a.min, expected) < 1e-7)
            try expect(simd_distance(b.max - a.max, expected) < 1e-7)
            // Each original closed solid receives exactly the piece's transform.
            for solid in c.solidIndices {
                let before = assembly.solidTransform(solid, profile: p) * SIMD4<Double>(0, 0, 0, 1)
                let after = assembly.solidTransform(solid, profile: moved) * SIMD4<Double>(0, 0, 0, 1)
                try expect(simd_distance(SIMD3(after.x - before.x, after.y - before.y, after.z - before.z), expected) < 1e-7)
            }
        }
    },
    TestCase(name: "alignsTwoEndsWithoutScalingTheirBodiesOrHardware") {
        let assembly = bookends(), p = FixturePlanningProfile(), stock = SIMD3<Double>(20, 40, 10)
        let next = assembly.alignedPair(p, stock: stock)
        let left = assembly.bounds(profile: next, componentID: assembly.components[0].id)
        let right = assembly.bounds(profile: next, componentID: assembly.components[1].id)
        try expect(abs(left.max.y + stock.y / 2) < 1e-7)
        try expect(abs(right.min.y - stock.y / 2) < 1e-7)
        for component in assembly.components {
            let before = assembly.bounds(profile: p, componentID: component.id)
            let after = assembly.bounds(profile: next, componentID: component.id)
            try expect(simd_distance(before.max - before.min, after.max - after.min) < 1e-7)
        }
        let rigid = LibraryFixtureGeometry(solids: [fixtureBox(SIMD3(-10, -10, -10), SIMD3(10, 10, 0))])
        try expectEqual(rigid.alignedPair(p, stock: stock), p, "one rigid piece must never be stretched into two ends")
    },
    TestCase(name: "turnsOnePieceAroundItsCentreAndPreservesTheOtherEnd") {
        let assembly = bookends(), id = assembly.components[0].id
        var p = FixturePlanningProfile(); p = p.turned(about: 0, quarterTurns: 1)
        let before = assembly.bounds(profile: p, componentID: id)
        let other = assembly.bounds(profile: p, componentID: assembly.components[1].id)
        let next = assembly.turned(p, componentID: id, axis: 2, quarterTurns: 1)
        let after = assembly.bounds(profile: next, componentID: id)
        let otherAfter = assembly.bounds(profile: next, componentID: assembly.components[1].id)
        try expect(simd_distance((before.min + before.max) / 2, (after.min + after.max) / 2) < 1e-7)
        try expect(simd_distance(other.min, otherAfter.min) < 1e-7)
        try expect(simd_distance(other.max, otherAfter.max) < 1e-7)
    },
    TestCase(name: "piecePositionsRoundTripAndChangedAssembliesAreRejected") {
        let assembly = bookends()
        var p = assembly.alignedPair(FixturePlanningProfile(), stock: SIMD3(20, 40, 10))
        p.componentModelSignature = "test-cad"
        let loaded = try JSONDecoder().decode(FixturePlanningProfile.self, from: JSONEncoder().encode(p))
        try expectEqual(loaded, p)
        try expect(assembly.placementsMatch(loaded))
        let changed = LibraryFixtureGeometry(solids: assembly.solids + [fixtureBox(SIMD3(100, 100, 100), SIMD3(110, 110, 110))])
        try expect(!changed.placementsMatch(loaded))
        let mesh = assembly.workMesh(profile: loaded)
        try expectEqual(mesh.indices.count, assembly.solids.reduce(0) { $0 + $1.indices.count })
        try expect(mesh.vertices.allSatisfy(\.isFinite))
        try expect(mesh.indices.allSatisfy { Int($0) < mesh.vertexCount })
    },
    TestCase(name: "theCAMClearanceFieldUsesTheEditedBookendPosition") {
        let assembly = bookends()
        let tool = Tool(name: "Test", kind: .flatEndMill, diameter: 1, shankDiameter: 1, flutes: 2, fluteLength: 10, stickout: 20, overallLength: 40)
        let moves = [Move(.rapid, x: 0, y: -14, z: 6), Move(.plunge, x: 0, y: -14, z: -2, feed: 100)]
        func field(_ p: FixturePlanningProfile) -> FixtureField {
            let mesh = assembly.workMesh(profile: p)
            let triangles = mesh.indices.map { index -> SIMD3<Double> in
                let i = Int(index) * 3
                return SIMD3(Double(mesh.vertices[i]), Double(mesh.vertices[i + 1]), Double(mesh.vertices[i + 2]))
            }
            return FixtureField(triangles: triangles, regionMin: SIMD2(-40, -40), regionMax: SIMD2(40, 40), cell: 0.5)
        }
        var before = field(FixturePlanningProfile())
        try expect(!FixtureClearance.check(moves, tool: tool, field: &before).isEmpty)
        let placed = assembly.moved(FixturePlanningProfile(), componentID: assembly.components[0].id, by: SIMD3(0, -10, 0))
        var after = field(placed)
        try expect(FixtureClearance.check(moves, tool: tool, field: &after).isEmpty)
    },
]
