import Foundation
import simd

extension simd_double4x4 {
    init(translation t: SIMD3<Double>) {
        self.init(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t, 1)))
    }
}
