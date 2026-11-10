import AppKit
import CoastlineCore
import Foundation
import simd
import Viewport

extension AppModel {
    /// Shows another side (0 = A, 1 = B, 2… the side setups) with the clamping animation.
    func show(side: Int) {
        let old = viewSide
        guard old != side else { return }
        switchingView = true
        viewSide = side
        switchingView = false
        transition(from: old)
    }

    /// Re-lays the scene for the new view the way it happens at the machine: the fixture
    /// releases (fades out), the stock lifts out and turns the way it goes next (front-to-back
    /// for side B), the next setup's fixture comes in, then the stock goes in.
    func transition(from old: Int) {
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            if self.result(forSide: self.viewSide) == nil { self.layoutScene() } else { self.showSide() }
        }
        let animate = (ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil || ProcessInfo.processInfo.environment["COASTLINE_ANIMATE"] != nil)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate, let to = stockBox(forSide: viewSide) else {
            // No animation this time: one still running must not land on top of this view.
            flipTask?.cancel()
            renderer.scene.remove(id: "stock.anim")
            stockAnimating = false
            finish()
            return
        }
        // Side A ↔ B: front-to-back about the vertical.
        animateClamping(from: stockBox(forSide: old), to: to, axis: SIMD3<Float>(1, 0, 0), angle: .pi, then: finish)
    }

    /// One frame-paced animation step (t 0…1, eased by the caller); false when cancelled.
    private func run(_ duration: Double, _ step: (Float) -> Void) async -> Bool {
        let start = Date()
        while !Task.isCancelled {
            let t = Float(min(Date().timeIntervalSince(start) / duration, 1))
            step(t)
            if t >= 1 { return true }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return false
    }

    private static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    /// The clamping sequence (see `transition`), with a stand-in box for the stock; the real
    /// stock, part and paths are hidden until it's in.
    func animateClamping(from a: (centre: SIMD3<Float>, size: SIMD3<Float>)?, to b: (centre: SIMD3<Float>, size: SIMD3<Float>),
                         axis: SIMD3<Float>, angle: Float, then done: @escaping @MainActor () -> Void) {
        flipTask?.cancel()
        stockAnimating = true
        let scene = renderer.scene
        scene.remove(id: "stock.anim")
        let colour = stock?.material?.linearSwatch ?? SIMD3(0.6, 0.6, 0.62)
        guard let proxy = SceneMesh.box(device: renderer.device, id: "stock.anim", min: SIMD3(repeating: -0.5), max: SIMD3(repeating: 0.5),
                                        color: SIMD4(colour, 1)) else { stockAnimating = false; done(); return }
        proxy.material = scene.mesh("simstock")?.material ?? scene.mesh("stock")?.material ?? proxy.material
        let hide = ["part", "stock", "stock.edges", "simstock", "simstock.back", "simstock.walls", "simstock.loose", "toolpath", "tabs",
                    "cutface", "cutface.edges", "undercuts", "clearance"]
        func hideWork() {
            for id in hide { scene.mesh(id)?.isVisible = false; scene.lineSet(id)?.isVisible = false }
        }
        let q = simd_quatf(angle: angle, axis: simd_normalize(axis))
        let endLocal = simd_abs(q.inverse.act(b.size))
        func place(_ centre: SIMD3<Float>, _ turn: Float, _ size: SIMD3<Float>) {
            let rot = simd_slerp(simd_quatf(angle: 0, axis: SIMD3(1, 0, 0)), q, turn)
            proxy.transform = simd_float4x4(translation: centre) * simd_float4x4(rot) * simd_float4x4(diagonal: SIMD4(size.x, size.y, size.z, 1))
        }
        let lift = SIMD3<Float>(45, 0, 0)  // X is up
        let finish: @MainActor () -> Void = { [weak self] in
            scene.remove(id: "stock.anim")
            self?.stockAnimating = false
            done()
        }
        flipTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 1. The fixture releases: it fades out, the stock still in it.
            hideWork()
            if let a { place(a.centre, 0, a.size); scene.setMesh(proxy) }
            let old = scene.meshes.filter { $0.id.hasPrefix("fixture.") && $0.isVisible }.map { ($0, $0.color.w) }
            guard await self.run(0.35, { t in for (m, w) in old { m.color.w = w * (1 - Self.ease(t)) } }) else { return }
            for (m, _) in old { m.isVisible = false }
            // 2. The stock lifts out.
            if let a {
                guard await self.run(0.45, { t in place(a.centre + lift * Self.ease(t), 0, a.size) }) else { return }
            }
            // 3. The next setup's fixture comes in; the stock, in the air, turns over it.
            self.layoutScene()
            hideWork()
            let new = scene.meshes.filter { $0.id.hasPrefix("fixture.") && $0.isVisible }.map { ($0, $0.color.w) }
            for (m, _) in new { m.color.w = 0 }
            let start = a.map { $0.centre + lift } ?? b.centre + lift + SIMD3(30, 0, 0)
            let startSize = a?.size ?? b.size
            let startTurn: Float = a == nil ? 1 : 0
            let park = b.centre + lift
            if a == nil { place(start, 1, endLocal); scene.setMesh(proxy) }
            guard await self.run(0.75, { t in
                let e = Self.ease(t)
                for (m, w) in new { m.color.w = w * min(t * 1.6, 1) }
                place(simd_mix(start, park, SIMD3(repeating: e)), startTurn + (1 - startTurn) * e,
                      simd_mix(startSize, endLocal, SIMD3(repeating: e)))
            }) else { return }
            for (m, w) in new { m.color.w = w }
            // 4. The stock goes down into the fixture.
            guard await self.run(0.5, { t in place(simd_mix(park, b.centre, SIMD3(repeating: Self.ease(t))), 1, endLocal) }) else { return }
            finish()
        }
    }

    /// The stock's box in the model for a side (centre and size).
    func stockBox(forSide side: Int) -> (centre: SIMD3<Float>, size: SIMD3<Float>)? {
        guard let stock else { return nil }
        let s = setupFor(side: side >= 2 ? side : 0).stockSize(stock)
        let o = workToModel(stockSize: s)
        return (SIMD3<Float>(o - SIMD3(0, 0, s.z / 2)), SIMD3<Float>(s))
    }
}
