import CoastlineCore
import Foundation
import simd

private let snapStock = SIMD3<Double>(20, 20, 10)

private func snapBox(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) -> MeshData {
    let points = FixtureField.boxTriangles(min: lo, max: hi)
    return MeshData(vertices: points.flatMap { [Float($0.x), Float($0.y), Float($0.z)] },
        normals: Array(repeating: 0, count: points.count * 3), indices: (0..<UInt32(points.count)).map { $0 },
        boundsMin: Vec3(lo.x, lo.y, lo.z), boundsMax: Vec3(hi.x, hi.y, hi.z), exact: true, faceCount: 6)
}

let fixtureSnapTests: [TestCase] = [
    TestCase(name: "snapsTheJawFaceRatherThanAProtrudingHardwareBound") {
        let geometry = LibraryFixtureGeometry(solids: [
            snapBox(SIMD3(-5, -16, -10), SIMD3(5, -12, 0)),
            snapBox(SIMD3(-1, -13, -8), SIMD3(1, -9, -4)),
        ])
        try expectEqual(geometry.components.count, 1)
        let p = geometry.moved(FixturePlanningProfile(), componentID: nil, by: SIMD3(0, 1.8, 0))
        let result = FixtureEdgeSnap.snap(p, geometry: geometry, componentID: geometry.components[0].id,
            stock: snapStock, axes: [1], tolerance: SIMD3(repeating: 0.5))
        try expectEqual(result.constraints.count, 1)
        try expectEqual(result.constraints[0].label, "Stock left end")
        let jaw = geometry.solidTransform(0, profile: result.profile) * SIMD4<Double>(0, -12, 0, 1)
        try expect(abs(jaw.y + 10) < 1e-5)
        // The screw still protrudes: snapping did not substitute its outer bound for the jaw.
        let bounds = geometry.bounds(profile: result.profile)
        try expect(abs(bounds.max.y + 7) < 1e-5)
    },
    TestCase(name: "anAxisDragDoesNotSnapUnrelatedAxes") {
        let geometry = LibraryFixtureGeometry(solids: [snapBox(SIMD3(7.8, -12.2, -8), SIMD3(9.8, -10.2, -2))])
        let original = FixturePlanningProfile()
        let result = FixtureEdgeSnap.snap(original, geometry: geometry, componentID: nil,
            stock: snapStock, axes: [1], tolerance: SIMD3(repeating: 0.4))
        let a = geometry.bounds(profile: original), b = geometry.bounds(profile: result.profile)
        try expectEqual(result.constraints.map(\.axis), [1])
        try expect(abs(b.max.y + 10) < 1e-5)
        try expect(abs(a.max.x - b.max.x) < 1e-5 && abs(a.max.z - b.max.z) < 1e-5)
    },
    TestCase(name: "freeDraggingCanSnapToAStockCornerWithoutScaling") {
        let geometry = LibraryFixtureGeometry(solids: [snapBox(SIMD3(7.8, -12.2, 0.2), SIMD3(9.8, -10.2, 2.2))])
        let p = FixturePlanningProfile()
        let result = FixtureEdgeSnap.snap(p, geometry: geometry, componentID: nil,
            stock: snapStock, tolerance: SIMD3(repeating: 0.4))
        let a = geometry.bounds(profile: p), b = geometry.bounds(profile: result.profile)
        try expectEqual(Set(result.constraints.map(\.axis)), Set([0, 1, 2]))
        try expect(abs(b.max.x - 10) < 1e-5 && abs(b.max.y + 10) < 1e-5 && abs(b.min.z) < 1e-5)
        try expect(simd_distance(a.max - a.min, b.max - b.min) < 1e-7)
    },
    TestCase(name: "doesNotSnapToAFaceFarAwayInAnotherDirection") {
        let geometry = LibraryFixtureGeometry(solids: [snapBox(SIMD3(100, -12.2, -8), SIMD3(110, -10.2, -2))])
        let p = FixturePlanningProfile()
        let result = FixtureEdgeSnap.snap(p, geometry: geometry, componentID: nil,
            stock: snapStock, tolerance: SIMD3(repeating: 0.5))
        try expect(result.constraints.isEmpty)
        try expectEqual(result.profile, p)
    },
    TestCase(name: "snapsRemainLatchedUntilTheLargerReleaseDistance") {
        let geometry = LibraryFixtureGeometry(solids: [snapBox(SIMD3(-3, -14, -8), SIMD3(3, -10.2, -2))])
        let p = FixturePlanningProfile(), tolerance = SIMD3<Double>(repeating: 0.6)
        let first = FixtureEdgeSnap.snap(p, geometry: geometry, componentID: nil, stock: snapStock, axes: [1], tolerance: tolerance)
        try expectEqual(first.constraints.count, 1)
        let raw = geometry.moved(p, componentID: nil, by: SIMD3(0, -0.7, 0))
        let fresh = FixtureEdgeSnap.snap(raw, geometry: geometry, componentID: nil, stock: snapStock, axes: [1], tolerance: tolerance)
        let held = FixtureEdgeSnap.snap(raw, geometry: geometry, componentID: nil, stock: snapStock, axes: [1], tolerance: tolerance, previous: first.constraints)
        try expect(fresh.constraints.isEmpty)
        try expectEqual(held.constraints, first.constraints)
        let farther = geometry.moved(p, componentID: nil, by: SIMD3(0, -1.1, 0))
        let released = FixtureEdgeSnap.snap(farther, geometry: geometry, componentID: nil, stock: snapStock, axes: [1], tolerance: tolerance, previous: first.constraints)
        try expect(released.constraints.isEmpty)
    },
    TestCase(name: "snappingOneBookendLeavesTheOtherEndInPlace") {
        let geometry = LibraryFixtureGeometry(solids: [
            snapBox(SIMD3(-3, -14, -8), SIMD3(3, -10.2, -2)),
            snapBox(SIMD3(-3, 10.2, -8), SIMD3(3, 14, -2)),
        ])
        let p = FixturePlanningProfile(), id = geometry.components[0].id, other = geometry.components[1].id
        let result = FixtureEdgeSnap.snap(p, geometry: geometry, componentID: id, stock: snapStock,
            axes: [1], tolerance: SIMD3(repeating: 0.5))
        let a = geometry.bounds(profile: p, componentID: other), b = geometry.bounds(profile: result.profile, componentID: other)
        try expectEqual(result.constraints.count, 1)
        try expect(simd_distance(a.min, b.min) < 1e-7 && simd_distance(a.max, b.max) < 1e-7)
    },
    TestCase(name: "snapDirectionsFollowWorkAxesAfterAFixtureTurn") {
        let geometry = LibraryFixtureGeometry(solids: [snapBox(SIMD3(-14, -3, -8), SIMD3(-10.2, 3, -2))])
        let p = FixturePlanningProfile().turned(about: 2, quarterTurns: 1)
        let result = FixtureEdgeSnap.snap(p, geometry: geometry, componentID: nil, stock: snapStock,
            axes: [1], tolerance: SIMD3(repeating: 0.5))
        try expectEqual(result.constraints.count, 1)
        try expectEqual(result.constraints[0].axis, 1)
        let b = geometry.bounds(profile: result.profile)
        try expect(abs(b.max.y + 10) < 1e-5)
    },
]
