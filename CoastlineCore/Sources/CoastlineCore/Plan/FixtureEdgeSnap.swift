import Foundation
import simd

/// Magnetic alignment is an editing aid. It aligns model faces/edges; it does not certify
/// a secure grip or clearance. The placed solids still go through the CAM checks.
public enum FixtureEdgeSnap {
    public struct Face: Sendable {
        public var id: String
        public var axis: Int
        public var min: SIMD3<Double>
        public var max: SIMD3<Double>
        public var area: Double
        public var isBounds: Bool
    }

    public struct Constraint: Sendable, Equatable {
        public var componentID: String
        public var faceID: String
        public var axis: Int
        public var upper: Bool
        public var label: String {
            switch (axis, upper) {
            case (0, false): "Stock bottom edge"
            case (0, true): "Stock top edge"
            case (1, false): "Stock left end"
            case (1, true): "Stock right end"
            case (2, false): "Stock back edge"
            default: "Stock front edge"
            }
        }
    }

    public struct Result: Sendable {
        public var profile: FixturePlanningProfile
        public var constraints: [Constraint]
    }

    /// Precomputed once per imported piece, so dragging never traverses the CAD triangles.
    static func faces(in mesh: MeshData) -> [Face] {
        guard mesh.vertices.count % 3 == 0, mesh.indices.count % 3 == 0,
              mesh.indices.allSatisfy({ Int($0) < mesh.vertexCount }) else { return [] }
        struct Bucket {
            var axis: Int
            var lo: SIMD3<Double>
            var hi: SIMD3<Double>
            var area: Double
        }
        var buckets: [String: Bucket] = [:]
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let points = (0..<3).map { j -> SIMD3<Double> in
                let k = Int(mesh.indices[i + j]) * 3
                return SIMD3(Double(mesh.vertices[k]), Double(mesh.vertices[k + 1]), Double(mesh.vertices[k + 2]))
            }
            let a = points[0], b = points[1], c = points[2]
            guard points.allSatisfy({ p in [p.x, p.y, p.z].allSatisfy { $0.isFinite && abs($0) < 10_000_000 } }) else { continue }
            let lo = simd_min(a, simd_min(b, c)), hi = simd_max(a, simd_max(b, c))
            let area = simd_length(simd_cross(b - a, c - a)) / 2
            guard area > 1e-6 else { continue }
            for axis in 0..<3 where hi[axis] - lo[axis] < 1e-4 {
                let key = "\(axis):\(Int64(((lo[axis] + hi[axis]) * 5000).rounded()))"
                if var bucket = buckets[key] {
                    bucket.lo = simd_min(bucket.lo, lo); bucket.hi = simd_max(bucket.hi, hi); bucket.area += area
                    buckets[key] = bucket
                } else { buckets[key] = Bucket(axis: axis, lo: lo, hi: hi, area: area) }
            }
        }
        var result = buckets.sorted { $0.key < $1.key }.compactMap { key, bucket -> Face? in
            guard bucket.area >= 0.5 else { return nil }
            return Face(id: key, axis: bucket.axis, min: bucket.lo, max: bucket.hi, area: bucket.area, isBounds: false)
        }
        // Curved pieces can still align their outer extents when no flat face exists.
        let lo = SIMD3(mesh.boundsMin.x, mesh.boundsMin.y, mesh.boundsMin.z)
        let hi = SIMD3(mesh.boundsMax.x, mesh.boundsMax.y, mesh.boundsMax.z)
        if [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z].allSatisfy(\.isFinite) {
            for axis in 0..<3 where !result.contains(where: { $0.axis == axis }) {
                for upper in [false, true] {
                    var a = lo, b = hi
                    a[axis] = upper ? hi[axis] : lo[axis]; b[axis] = a[axis]
                    result.append(Face(id: "bounds:\(axis):\(upper)", axis: axis, min: a, max: b, area: 0, isBounds: true))
                }
            }
        }
        return result
    }

    public static func snap(_ profile: FixturePlanningProfile, geometry: LibraryFixtureGeometry,
                            componentID: String?, stock: SIMD3<Double>, axes: Set<Int> = [0, 1, 2],
                            tolerance: SIMD3<Double>, previous: [Constraint] = []) -> Result {
        var result = Result(profile: profile, constraints: [])
        guard [stock.x, stock.y, stock.z].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 10_000 }),
              [tolerance.x, tolerance.y, tolerance.z].allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1000 }) else { return result }
        let stockMin = SIMD3(-stock.x / 2, -stock.y / 2, -stock.z), stockMax = SIMD3(stock.x / 2, stock.y / 2, 0)
        struct Candidate {
            var constraint: Constraint
            var delta: Double
            var area: Double
            var isBounds: Bool
        }
        var candidates: [Int: [Candidate]] = [:]
        for component in geometry.components where componentID == nil || component.id == componentID {
            let t = geometry.transform(component, profile: profile)
            for face in component.snapFaces {
                let direction = t[face.axis]
                let d = SIMD3(abs(direction.x), abs(direction.y), abs(direction.z))
                guard let axis = (0..<3).max(by: { d[$0] < d[$1] }), d[axis] > 0.999,
                      axes.contains(axis), tolerance[axis] > 0 else { continue }
                var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
                for corner in 0..<8 {
                    let p = t * SIMD4(corner & 1 == 0 ? face.min.x : face.max.x,
                        corner & 2 == 0 ? face.min.y : face.max.y, corner & 4 == 0 ? face.min.z : face.max.z, 1)
                    lo = simd_min(lo, SIMD3(p.x, p.y, p.z)); hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
                }
                guard [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z].allSatisfy(\.isFinite) else { continue }
                guard (0..<3).filter({ $0 != axis }).allSatisfy({ other in
                    let margin = max(tolerance[other], 1e-4)
                    return hi[other] >= stockMin[other] - margin && lo[other] <= stockMax[other] + margin
                }) else { continue }
                let coordinate = (lo[axis] + hi[axis]) / 2
                for upper in [false, true] {
                    let delta = (upper ? stockMax[axis] : stockMin[axis]) - coordinate
                    let constraint = Constraint(componentID: component.id, faceID: face.id, axis: axis, upper: upper)
                    let latched = previous.contains(constraint)
                    // A larger release radius avoids flickering between adjacent faces.
                    guard abs(delta) <= tolerance[axis] * (latched ? 1.6 : 1) else { continue }
                    candidates[axis, default: []].append(.init(constraint: constraint, delta: delta, area: face.area, isBounds: face.isBounds))
                }
            }
        }
        var correction = SIMD3<Double>(repeating: 0)
        for axis in 0..<3 {
            guard let best = candidates[axis]?.min(by: { a, b in
                let al = previous.contains(a.constraint), bl = previous.contains(b.constraint)
                if al != bl { return al }
                if abs(abs(a.delta) - abs(b.delta)) > 1e-5 { return abs(a.delta) < abs(b.delta) }
                if a.isBounds != b.isBounds { return !a.isBounds }
                if a.area != b.area { return a.area > b.area }
                if a.constraint.componentID != b.constraint.componentID { return a.constraint.componentID < b.constraint.componentID }
                return a.constraint.faceID < b.constraint.faceID
            }) else { continue }
            correction[axis] = best.delta
            result.constraints.append(best.constraint)
        }
        if simd_length(correction) > 1e-9 { result.profile = geometry.moved(profile, componentID: componentID, by: correction) }
        return result
    }
}
