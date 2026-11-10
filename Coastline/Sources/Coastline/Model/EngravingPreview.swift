import CoastlineCore
import Foundation
import simd
import Viewport

extension AppModel {
    /// The engraving's outline on the part's face (purple), while there's an engraving op.
    func layoutEngravingPreview() {
        let scene = renderer.scene
        scene.remove(id: "engrave.preview")
        guard !showingStockOnly, viewSide >= 0, let size = displayStockSize else { return }
        let texts = operations.filter { $0.kind == .engrave && $0.enabled }.compactMap(\.engraving).filter { $0.side == viewSide || !twoSided }
        guard !texts.isEmpty else { return }
        let o = workOrigin(stockSize: size)
        let z = -setupFor(side: viewSide).topAllowance + 0.05
        let purple = SceneColor.highlight
        var segs: [LineSegment] = []
        for e in texts {
            for loop in e.polylines(tolerance: 0.05) {
                for (a, b) in zip(loop, loop.dropFirst()) {
                    segs.append(LineSegment(SIMD3<Float>(SIMD3(a.x, a.y, z) + o), SIMD3<Float>(SIMD3(b.x, b.y, z) + o), color: purple))
                }
            }
        }
        if let l = SceneLines(device: renderer.device, id: "engrave.preview", segments: segs) { scene.setLines(l) }
    }
}
