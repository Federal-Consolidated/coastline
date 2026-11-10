import Foundation
import simd

extension FixtureField {
    /// The 12 triangles of a box.
    public static func boxTriangles(min a: SIMD3<Double>, max b: SIMD3<Double>) -> [SIMD3<Double>] {
        let c = (0..<8).map { i in SIMD3(i & 1 == 0 ? a.x : b.x, i & 2 == 0 ? a.y : b.y, i & 4 == 0 ? a.z : b.z) }
        let faces = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
        return faces.flatMap { f in [c[f[0]], c[f[1]], c[f[2]], c[f[0]], c[f[2]], c[f[3]]] }
    }
}
