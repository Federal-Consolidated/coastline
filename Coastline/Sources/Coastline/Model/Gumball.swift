import CoastlineCore
import Foundation
import simd
import Viewport

/// The gumball: placing the part in the stock (stage 1, R2) and the fixtures on the bed
/// (stage 3, R3). An arrow per axis; dragging one moves the target along it in snaps, never
/// past where it still makes sense. X is up, Y along the table, Z toward the spindle.
extension AppModel {
    /// Stage 1 shows only the stock as bought and the part in it.
    var showingStockOnly: Bool { fixturePlacement == nil && [.partStock, .stock].contains(stage) }

    /// Where the part's centre sits in the model (the gumball's origin).
    func partCentreWorld() -> SIMD3<Float>? {
        guard let part, let m = renderer.scene.mesh("part") else { return nil }
        let c = (part.boundsMin + part.boundsMax) / 2
        let w = renderer.scene.groupTransform(m.group) * m.transform * SIMD4(Float(c.x), Float(c.y), Float(c.z), 1)
        return SIMD3(w.x, w.y, w.z)
    }

    static let gumballAxes: [(id: String, dir: SIMD3<Float>, color: SIMD4<Float>)] = [
        // Apple's system red, green and blue (linear), like any modern 3D tool.
        ("gumball.x", SIMD3(1, 0, 0), SIMD4(1.0, 0.07, 0.05, 1)),
        ("gumball.y", SIMD3(0, 1, 0), SIMD4(0.03, 0.58, 0.12, 1)),
        ("gumball.z", SIMD3(0, 0, 1), SIMD4(0.0, 0.24, 1.0, 1)),
    ]

    /// Arrow length: a fixed share of the view, so the handles stay grabbable at any zoom.
    var gumballLength: Float { max(renderer.camera.distance * 0.12, 6) }

    /// What the gumball moves now: the part in its stock, or a library fixture being placed.
    enum GumballTarget: Equatable { case part, libraryFixture(String?) }

    var gumballTarget: GumballTarget? {
        if let session = fixturePlacement {
            return session.pickingGrip ? nil : .libraryFixture(session.selectedComponent)
        }
        guard ![.partStock, .stock, .planning].contains(stage) else { return nil }
        if stage == .setups { return .part }
        return nil
    }

    /// The arrows a target moves along.
    func gumballAxes(for t: GumballTarget) -> [(id: String, dir: SIMD3<Float>, color: SIMD4<Float>)] {
        switch t {
        case .part: return Self.gumballAxes
        case .libraryFixture(let id):
            if placingBookends { return canMoveBookendComponent(id) ? Self.gumballAxes.filter { $0.id == "gumball.y" } : [] }
            if placingMechanism { return mechanismAxis(id).map { a in Self.gumballAxes.filter { $0.id == ["gumball.x", "gumball.y", "gumball.z"][a] } } ?? [] }
            return Self.gumballAxes
        }
    }

    func gumballOrigin(_ t: GumballTarget) -> SIMD3<Float>? {
        switch t {
        case .libraryFixture(let id): return placementGumballOrigin(id)
        case .part: return partCentreWorld()
        }
    }

    /// The rings a target turns with: the part about all three axes (quarter turns, the stock
    /// is a box).
    func ringAxes(for t: GumballTarget) -> [Int] {
        switch t {
        case .part: [0, 1, 2]
        case .libraryFixture: placingBookends || placingMechanism ? [] : [0, 1, 2]
        }
    }

    /// Two unit vectors spanning ring `k`'s plane, right-handed with its axis.
    static func ringBasis(_ k: Int) -> (u: SIMD3<Float>, v: SIMD3<Float>, n: SIMD3<Float>) {
        switch k {
        case 0: (SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0))
        case 1: (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        default: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        }
    }

    static let ringIDs = ["gumball.ring.x", "gumball.ring.y", "gumball.ring.z"]

    func layoutGumball() {
        let scene = renderer.scene
        for a in Self.gumballAxes { scene.remove(id: a.id) }
        for id in Self.ringIDs { scene.remove(id: id) }
        scene.remove(id: "gumball.centre")
        guard let target = gumballTarget, let o = gumballOrigin(target) else { return }
        // Slim: a hairline shaft, a small pointed head, a gap at the centre.
        let len = gumballLength, r = len * 0.011
        let hotColour = SIMD4<Float>(1, 0.78, 0.0, 1)
        for a in gumballAxes(for: target) {
            var b = MeshBuilder()
            b.cylinder(radius: r, z0: len * 0.12, z1: len * 0.84, segments: 20)
            b.cone(r0: r * 3.6, z0: len * 0.84, r1: 0, z1: len)
            // Built along +Z; turn it onto the axis.
            let rot: simd_float4x4 = a.dir.x > 0.5 ? simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
                : a.dir.y > 0.5 ? simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))) : matrix_identity_float4x4
            let hot = gumballDrag?.axis == a.id
            if let m = b.mesh(device: renderer.device, id: a.id, color: hot ? hotColour : a.color) {
                m.transform = simd_float4x4(translation: o) * rot
                m.onTop = true
                m.unlit = true
                scene.setMesh(m)
            }
        }
        for k in ringAxes(for: target) {
            let id = Self.ringIDs[k], (u, v, n) = Self.ringBasis(k)
            let hot = gumballDrag?.axis == id
            if let m = Self.ring(radius: len * Self.ringShare, tube: r * 1.2).mesh(device: renderer.device, id: id,
                                                                                  color: hot ? hotColour : Self.gumballAxes[k].color) {
                // The ring is built about +Z: its x → u, y → v, z → the axis.
                m.transform = simd_float4x4(translation: o) * simd_float4x4(columns: (SIMD4(u, 0), SIMD4(v, 0), SIMD4(n, 0), SIMD4(0, 0, 0, 1)))
                m.onTop = true
                m.unlit = true
                scene.setMesh(m)
            }
        }
        var c = MeshBuilder()
        c.ballEnd(radius: r * 2.6, tip: -r * 2.6)
        if let m = c.mesh(device: renderer.device, id: "gumball.centre", color: SceneColor.surface(0.9)) {
            m.transform = simd_float4x4(translation: o)
            m.onTop = true
            m.unlit = true
            scene.setMesh(m)
        }
    }

    static let ringShare: Float = 0.62

    /// A thin torus about +Z.
    static func ring(radius R: Float, tube t: Float, segments: Int = 96, sides: Int = 10) -> MeshBuilder {
        var b = MeshBuilder()
        for i in 0...segments {
            let u = Float(i) / Float(segments) * 2 * .pi
            let c = SIMD3(cos(u), sin(u), 0)
            for j in 0...sides {
                let v = Float(j) / Float(sides) * 2 * .pi
                let n = c * cos(v) + SIMD3(0, 0, sin(v))
                let p = c * R + n * t
                b.positions += [p.x, p.y, p.z]
                b.normals += [n.x, n.y, n.z]
            }
        }
        let w = UInt32(sides + 1)
        for i in 0..<UInt32(segments) {
            for j in 0..<UInt32(sides) {
                let a = i * w + j, d = (i + 1) * w + j
                b.indices += [a, d, a + 1, a + 1, d, d + 1]
            }
        }
        return b
    }

    // MARK: Dragging

    struct GumballDrag {
        /// An arrow ("gumball.x"…), a ring ("gumball.ring.x"…), or the object itself dragged in
        /// the horizontal plane ("gumball.plane").
        var axis: String
        var dir: SIMD3<Double>
        var origin: SIMD3<Double>
        var t0: Double
        var start: Setup
        var target: GumballTarget
        /// Where the mouse went down and whether it has moved since (a click types a value).
        var downAt: CGPoint = .zero
        var moved = false
        /// Grabbed by an arrow or ring (a click there types a value), not by the object itself.
        var fromHandle = false
        var fixtureStart: FixturePlanningProfile? = nil
    }

    /// Mouse down: an arrow or ring under the point (screen distance to its projection), or on
    /// the bed a fixture itself (picked and dragged in one go). False: the camera gets the drag.
    func gumballBegin(_ p: CGPoint, _ size: CGSize) -> Bool {
        guard size.width > 0 else { return false }
        if fixturePlacement?.pickingGrip == true { return false }
        if let target = gumballTarget, let o = gumballOrigin(target) {
            let len = gumballLength
            var best: (id: String, dir: SIMD3<Float>, d: Double, ring: Int?)?
            for a in gumballAxes(for: target) {
                guard let s0 = project(o, size), let s1 = project(o + a.dir * len, size) else { continue }
                let d = distance(p, s0, s1)
                if d < 9, d < (best?.d ?? .infinity) { best = (a.id, a.dir, d, nil) }
            }
            for k in ringAxes(for: target) {
                let (u, v, _) = Self.ringBasis(k)
                let pts = (0...72).compactMap { i -> CGPoint? in
                    let a = Float(i) / 72 * 2 * .pi
                    return project(o + (u * cos(a) + v * sin(a)) * len * Self.ringShare, size)
                }
                let d = zip(pts, pts.dropFirst()).map { distance(p, $0, $1) }.min() ?? .infinity
                if d < 8, d < (best?.d ?? .infinity) { best = (Self.ringIDs[k], Self.ringBasis(k).n, d, k) }
            }
            if let best {
                let origin = SIMD3<Double>(o)
                if let k = best.ring {
                    guard let a0 = ringAngle(p, size, origin: origin, axis: k) else { return false }
                    pause()
                    gumballDrag = GumballDrag(axis: best.id, dir: SIMD3<Double>(best.dir), origin: origin, t0: a0, start: setup, target: target,
                                              downAt: p, fromHandle: true)
                } else {
                    guard let t = axisParameter(p, size, origin: origin, dir: SIMD3<Double>(best.dir)) else { return false }
                    pause()
                    gumballDrag = GumballDrag(axis: best.id, dir: SIMD3<Double>(best.dir), origin: origin, t0: t, start: setup, target: target,
                                              downAt: p, fromHandle: true)
                }
                gumballPrompt = nil
                gumballDrag?.fixtureStart = fixturePlacement?.fixture.planning
                layoutGumball()
                return true
            }
        }
        if fixturePlacement != nil {
            guard let (id, hit) = pickPlacementComponent(p, size: size) else { return false }
            pause(); selectPlacementComponent(id)
            if placingBookends || placingMechanism {
                let axis = placingBookends ? (canMoveBookendComponent(id) ? 1 : nil) : mechanismAxis(id)
                var dir = SIMD3<Double>(repeating: 0)
                if let axis { dir[axis] = 1 }
                guard let axis, let t = axisParameter(p, size, origin: SIMD3<Double>(hit), dir: dir) else {
                    layoutGumball(); return true
                }
                gumballDrag = GumballDrag(axis: ["gumball.x", "gumball.y", "gumball.z"][axis], dir: dir, origin: SIMD3<Double>(hit), t0: t,
                    start: setup, target: .libraryFixture(id), downAt: p, fixtureStart: fixturePlacement?.fixture.planning)
                layoutGumball(); return true
            }
            let ray = renderer.ray(at: p, viewSize: size)
            gumballDrag = GumballDrag(axis: "gumball.fixturePlane", dir: SIMD3<Double>(ray.direction),
                origin: SIMD3<Double>(hit), t0: 0, start: setup, target: .libraryFixture(id), downAt: p,
                fixtureStart: fixturePlacement?.fixture.planning)
            layoutGumball()
            return true
        }
        return false
    }

    func gumballMove(_ p: CGPoint, _ size: CGSize) {
        guard var d = gumballDrag else { return }
        if !d.moved, hypot(p.x - d.downAt.x, p.y - d.downAt.y) > 3 {
            d.moved = true
            gumballDrag = d
        }
        guard d.moved else { return }
        if let k = Self.ringIDs.firstIndex(of: d.axis) {
            guard let a = ringAngle(p, size, origin: d.origin, axis: k) else { return }
            let turn = remainder(a - d.t0, 2 * .pi)
            switch d.target {
            case .libraryFixture(let id):
                guard let start = d.fixtureStart else { return }
                rotatePlacement(axis: k, turns: Int((turn / (.pi / 2)).rounded()), from: start, componentID: id, useSelection: false)
            case .part:
                // Quarter turns: the part snaps to the next orientation past 45°.
                let q = Int((turn / (Double.pi / 2)).rounded())
                let s = placementLimited(d.start.turned(about: k, quarterTurns: q))
                if s != setup { setup = s }
            }
            layoutGumball()
            return
        }
        if d.axis == "gumball.fixturePlane", case .libraryFixture(let id) = d.target, let start = d.fixtureStart {
            let ray = renderer.ray(at: p, viewSize: size)
            let ro = SIMD3<Double>(ray.origin), rd = SIMD3<Double>(ray.direction), normal = simd_normalize(d.dir)
            let den = simd_dot(rd, normal)
            guard abs(den) > 1e-6 else { return }
            let hit = ro + rd * (simd_dot(d.origin - ro, normal) / den)
            let scale = placementDragScale
            let delta = (hit - d.origin) * scale
            let snapped = SIMD3(delta.x.rounded(), delta.y.rounded(), delta.z.rounded()) / scale
            movePlacement(snapped, from: start, componentID: id, useSelection: false, snapViewSize: size)
            return
        }
        guard let t = axisParameter(p, size, origin: d.origin, dir: d.dir) else { return }
        switch d.target {
        case .libraryFixture(let id):
            guard let start = d.fixtureStart else { return }
            let scale = placingBookends && id == BookendSetup.pressure ? max(10, placementDragScale) : placementDragScale
            let delta = ((t - d.t0) * scale).rounded() / scale
            let axis = d.axis == "gumball.x" ? 0 : d.axis == "gumball.y" ? 1 : 2
            movePlacement(d.dir * delta, from: start, componentID: id, useSelection: false, snapViewSize: size, snapAxes: [axis])
        case .part:
            let delta = ((t - d.t0) * 2).rounded() / 2  // 0.5 mm snaps
            var s = d.start
            switch d.axis {
            case "gumball.x": s.partOffsetX = d.start.partOffsetX + delta
            case "gumball.y": s.partOffsetY = d.start.partOffsetY + delta
            default: s.topAllowance = d.start.topAllowance - delta  // toward the spindle = closer to the face
            }
            let limited = placementLimited(s)
            if limited != setup { setup = limited }
        }
        layoutGumball()
    }

    func gumballEnd() {
        let wasLibrary: Bool = gumballDrag.map { if case .libraryFixture = $0.target { return true }; return false } ?? false
        // A click on an arrow or ring (no drag): type the move instead, like Rhino.
        if let d = gumballDrag, !d.moved, d.fromHandle {
            gumballDrag = nil
            gumballPrompt = GumballPrompt(axis: d.axis, target: d.target, point: d.downAt)
            layoutGumball()
            return
        }
        gumballDrag = nil
        layoutGumball()
        if wasLibrary { return }
        if let w = placementWarning { status = w }
    }

    // MARK: Limits and snaps

    /// How far the part may move while staying inside the stock (work frame).
    func placementRange(_ s: Setup) -> (x: ClosedRange<Double>, y: ClosedRange<Double>, depth: ClosedRange<Double>)? {
        guard let part, let stock else { return nil }
        return s.placementLimits(partMin: part.boundsMin, partMax: part.boundsMax, stock: stock, toolDiameter: 6.35)
    }

    func placementLimited(_ s: Setup) -> Setup {
        guard let r = placementRange(s) else { return s }
        var s = s
        s.partOffsetX = min(max(s.partOffsetX, r.x.lowerBound), r.x.upperBound)
        s.partOffsetY = min(max(s.partOffsetY, r.y.lowerBound), r.y.upperBound)
        s.topAllowance = min(max(s.topAllowance, r.depth.lowerBound), r.depth.upperBound)
        return s
    }

    var placementWarning: String? {
        guard let r = placementRange(setup) else { return nil }
        if setup.partOffsetX == r.x.upperBound || setup.partOffsetX == r.x.lowerBound { return "The part meets the stock boundary. Existing finished stock faces can be left uncut; check the selected workholding's grip and clearance." }
        return nil
    }

    enum PlacementSnap { case centre, face, back, top, bottom, left, right }

    func snapPart(_ snap: PlacementSnap) {
        guard let r = placementRange(setup) else { return }
        var s = setup
        switch snap {
        case .centre: s.partOffsetX = 0; s.partOffsetY = 0
        case .face: s.topAllowance = 0
        case .back: s.topAllowance = r.depth.upperBound
        case .top: s.partOffsetX = r.x.upperBound
        case .bottom: s.partOffsetX = r.x.lowerBound
        case .left: s.partOffsetY = r.y.lowerBound
        case .right: s.partOffsetY = r.y.upperBound
        }
        setup = placementLimited(s)
    }

    // MARK: Geometry helpers

    func project(_ w: SIMD3<Float>, _ size: CGSize) -> CGPoint? {
        let aspect = Float(size.width / max(size.height, 1))
        let vp = renderer.camera.projectionMatrix(aspect: aspect) * renderer.camera.viewMatrix() * renderer.worldToDisplay
        let c = vp * SIMD4(w, 1)
        guard c.w > 1e-6 else { return nil }
        return CGPoint(x: Double((c.x / c.w + 1) / 2) * size.width, y: Double((1 - c.y / c.w) / 2) * size.height)
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y), ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
        let l2 = max(ab.x * ab.x + ab.y * ab.y, 1e-9)
        let t = min(max((ap.x * ab.x + ap.y * ab.y) / l2, 0), 1)
        return hypot(p.x - (a.x + ab.x * t), p.y - (a.y + ab.y * t))
    }

    /// The mouse ray's angle about model axis `k` around `o`, in the ring's plane through it.
    private func ringAngle(_ p: CGPoint, _ size: CGSize, origin o: SIMD3<Double>, axis k: Int) -> Double? {
        let ray = renderer.ray(at: p, viewSize: size)
        let ro = SIMD3<Double>(ray.origin), rd = SIMD3<Double>(ray.direction)
        let (u, v, n) = Self.ringBasis(k)
        let nd = SIMD3<Double>(n)
        let den = simd_dot(rd, nd)
        guard abs(den) > 1e-4 else { return nil }
        let h = ro + rd * (simd_dot(o - ro, nd) / den) - o
        return atan2(simd_dot(h, SIMD3<Double>(v)), simd_dot(h, SIMD3<Double>(u)))
    }

    /// Where along the axis line the mouse ray passes closest (mm from `origin`).
    private func axisParameter(_ p: CGPoint, _ size: CGSize, origin o: SIMD3<Double>, dir d: SIMD3<Double>) -> Double? {
        let ray = renderer.ray(at: p, viewSize: size)
        let ro = SIMD3<Double>(ray.origin), rd = simd_normalize(SIMD3<Double>(ray.direction))
        let w = ro - o, b = simd_dot(rd, d)
        let denom = 1 - b * b
        guard denom > 1e-6 else { return nil }
        return (simd_dot(w, d) - simd_dot(w, rd) * b) / denom
    }
}
