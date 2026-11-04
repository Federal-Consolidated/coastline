import CoastlineCore
import Foundation
import Metal
import simd
import Viewport

/// Representative geometry for inventory items that do not have a supplied CAD model.
/// These shapes are previews, not collision geometry or manufacturing drawings.
private struct InventoryPreviewGeometry {
    let device: MTLDevice
    var meshes: [SceneMesh] = []

    static func dimension(_ value: Double?, fallback: Float, min lower: Float = 0.1, max upper: Float = 500) -> Float {
        guard let value, value.isFinite else { return fallback }
        return Swift.min(Swift.max(Float(value), lower), upper)
    }

    mutating func add(_ mesh: SceneMesh?, material: SurfaceMaterial = .aluminium) {
        guard let mesh else { return }
        mesh.material = material
        meshes.append(mesh)
    }

    mutating func box(_ center: SIMD3<Float>, _ size: SIMD3<Float>, gray: Float = 0.58,
                      material: SurfaceMaterial = .aluminium, angle: Float = 0) {
        let transform = simd_float4x4(translation: center) * simd_float4x4(simd_quatf(angle: angle, axis: SIMD3(0, 0, 1)))
        add(SceneMesh.box(device: device, id: "preview.\(meshes.count)", min: -size / 2, max: size / 2,
                          color: SceneColor.surface(gray), transform: transform), material: material)
    }

    mutating func cylinder(_ center: SIMD3<Float>, radius: Float, length: Float,
                           axis: SIMD3<Float> = SIMD3(0, 0, 1), gray: Float = 0.65,
                           material: SurfaceMaterial = .chrome) {
        var builder = MeshBuilder()
        builder.cylinder(radius: radius, z0: -length / 2, z1: length / 2, segments: 48)
        let mesh = builder.mesh(device: device, id: "preview.\(meshes.count)", color: SceneColor.surface(gray))
        mesh?.transform = simd_float4x4(translation: center) * simd_float4x4(simd_quatf(from: SIMD3(0, 0, 1), to: axis))
        add(mesh, material: material)
    }

    /// An annulus or open ring, used for clamp frames, tapes and collets.
    mutating func ring(_ center: SIMD3<Float>, outer: Float, inner: Float, depth: Float,
                       axis: SIMD3<Float> = SIMD3(0, 0, 1), start: Float = 0, sweep: Float = 2 * .pi,
                       gray: Float = 0.4, material: SurfaceMaterial = .aluminium) {
        let steps = 64
        var positions: [Float] = [], normals: [Float] = [], indices: [UInt32] = []
        func point(_ radius: Float, _ angle: Float, _ z: Float) -> SIMD3<Float> {
            SIMD3(radius * cos(angle), radius * sin(angle), z)
        }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ normal: SIMD3<Float>) {
            let base = UInt32(positions.count / 3)
            for p in [a, b, c, d] { positions += [p.x, p.y, p.z]; normals += [normal.x, normal.y, normal.z] }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        let bottom = -depth / 2, top = depth / 2
        for i in 0..<steps {
            let a = start + sweep * Float(i) / Float(steps), b = start + sweep * Float(i + 1) / Float(steps)
            let radial = SIMD3<Float>(cos((a + b) / 2), sin((a + b) / 2), 0)
            quad(point(outer, a, bottom), point(outer, b, bottom), point(outer, b, top), point(outer, a, top), radial)
            quad(point(inner, b, bottom), point(inner, a, bottom), point(inner, a, top), point(inner, b, top), -radial)
            quad(point(inner, a, top), point(outer, a, top), point(outer, b, top), point(inner, b, top), SIMD3(0, 0, 1))
            quad(point(inner, b, bottom), point(outer, b, bottom), point(outer, a, bottom), point(inner, a, bottom), SIMD3(0, 0, -1))
        }
        if sweep < 2 * .pi - 0.001 {
            for (angle, sign): (Float, Float) in [(start, -1), (start + sweep, 1)] {
                let normal = SIMD3<Float>(-sin(angle), cos(angle), 0) * sign
                if sign < 0 {
                    quad(point(inner, angle, bottom), point(outer, angle, bottom), point(outer, angle, top), point(inner, angle, top), normal)
                } else {
                    quad(point(outer, angle, bottom), point(inner, angle, bottom), point(inner, angle, top), point(outer, angle, top), normal)
                }
            }
        }
        let transform = simd_float4x4(translation: center) * simd_float4x4(simd_quatf(from: SIMD3(0, 0, 1), to: axis))
        add(SceneMesh(device: device, id: "preview.\(meshes.count)", positions: positions, normals: normals,
                      indices: indices, color: SceneColor.surface(gray), transform: transform), material: material)
    }

    mutating func plate(width: Float, length: Float, height: Float, holes: Bool = false) {
        box(SIMD3(0, 0, height / 2), SIMD3(width, length, height), gray: 0.48)
        if holes {
            for x in [-width * 0.3, 0, width * 0.3] {
                for y in [-length * 0.3, 0, length * 0.3] {
                    cylinder(SIMD3(x, y, height + 0.02), radius: min(width, length) * 0.035, length: 0.08,
                             gray: 0.055, material: .blackOxide)
                }
            }
        }
    }
}

extension Fixture {
    func sceneMeshes(device: MTLDevice) -> [SceneMesh] {
        var g = InventoryPreviewGeometry(device: device)
        let h = InventoryPreviewGeometry.dimension(height, fallback: 12, min: 4, max: 120)
        let grip = InventoryPreviewGeometry.dimension(gripRange?.upperBound, fallback: 45, min: 12, max: 150)
        switch kind {
        case .universalClamp:
            g.plate(width: grip + 45, length: 42, height: 7)
            for x in [-(grip / 2 + 10), grip / 2 + 10] {
                g.box(SIMD3(x, 0, h / 2 + 7), SIMD3(15, 38, h), gray: 0.28, material: .blackOxide)
                g.cylinder(SIMD3(x, 0, h + 10), radius: 5, length: 7, gray: 0.72)
            }
        case .vise:
            g.plate(width: 90, length: grip + 58, height: max(h * 0.4, 8))
            for y in [-(grip / 2 + 7), grip / 2 + 7] {
                g.box(SIMD3(0, y, h + 10), SIMD3(80, 14, 25), gray: 0.65)
            }
            g.cylinder(SIMD3(0, 0, h), radius: 5, length: grip + 90, axis: SIMD3(0, 1, 0), gray: 0.3)
            g.cylinder(SIMD3(0, -(grip + 86) / 2, h), radius: 2.5, length: 48, axis: SIMD3(1, 0, 0))
        case .jigPlate, .fixturePlate:
            g.plate(width: 110, length: 85, height: h, holes: true)
        case .tombstone:
            g.plate(width: 90, length: 90, height: 10, holes: true)
            g.box(SIMD3(0, 0, 75), SIMD3(55, 55, 130), gray: 0.52)
            for z: Float in [35, 70, 105] {
                for x: Float in [-17, 17] {
                    g.cylinder(SIMD3(x, -27.55, z), radius: 3, length: 0.1, axis: SIMD3(0, 1, 0), gray: 0.06)
                }
            }
        case .squaringBoss, .squaringStop:
            g.box(SIMD3(0, 0, 4), SIMD3(65, 40, 8), gray: 0.42)
            g.box(SIMD3(0, 14, h / 2 + 8), SIMD3(65, 12, h), gray: 0.62)
            if kind == .squaringBoss { g.box(SIMD3(-26, -4, h / 2 + 8), SIMD3(12, 24, h), gray: 0.62) }
        case .softJaws:
            for y in [-grip / 2 - 8, grip / 2 + 8] {
                g.box(SIMD3(0, y, h / 2), SIMD3(85, 16, h), gray: 0.73)
                for x: Float in [-25, 25] {
                    g.cylinder(SIMD3(x, y, h + 0.02), radius: 3, length: 0.1, gray: 0.08)
                }
            }
        case .printedNest:
            g.plate(width: 80, length: 65, height: 6)
            for x: Float in [-31, 31] { g.box(SIMD3(x, 0, h / 2 + 6), SIMD3(12, 58, h), gray: 0.72, material: .plastic) }
            g.box(SIMD3(0, 24, h / 2 + 6), SIMD3(50, 10, h), gray: 0.72, material: .plastic)
        case .tSlotNuts:
            g.box(SIMD3(0, 0, 3), SIMD3(22, 16, 6), gray: 0.22, material: .blackOxide)
            g.box(SIMD3(0, 0, 8), SIMD3(13, 16, 4), gray: 0.22, material: .blackOxide)
            g.ring(SIMD3(0, 0, 10.1), outer: 5, inner: 3, depth: 0.3, gray: 0.4)
            g.cylinder(SIMD3(0, 0, 10.02), radius: 3, length: 0.08, gray: 0.03)
        case .cClamp:
            g.ring(.zero, outer: 42, inner: 30, depth: 12, axis: SIMD3(0, -1, 0), start: .pi / 4,
                   sweep: 1.5 * .pi, gray: 0.16, material: .blackOxide)
            g.cylinder(SIMD3(25, 0, 28), radius: 4, length: 54)
            g.cylinder(SIMD3(25, 0, 3), radius: 8, length: 4)
            g.cylinder(SIMD3(25, 0, 53), radius: 2, length: 35, axis: SIMD3(1, 0, 0))
        case .riser:
            g.plate(width: 90, length: 60, height: h, holes: true)
            g.box(SIMD3(0, 0, -2), SIMD3(80, 50, 4), gray: 0.28)
        case .other:
            g.plate(width: 65, length: 45, height: max(h, 8), holes: true)
        }
        return g.meshes
    }
}

extension MeasuringTool {
    func sceneMeshes(device: MTLDevice) -> [SceneMesh] {
        var g = InventoryPreviewGeometry(device: device)
        let span = InventoryPreviewGeometry.dimension(range?.upperBound, fallback: 150, min: 25, max: 300)
        switch kind {
        case .caliper:
            let length = span + 70
            g.box(.zero, SIMD3(length, 12, 4), gray: 0.68)
            g.box(SIMD3(-length / 2 + 5, -18, 0), SIMD3(10, 46, 5), gray: 0.74)
            g.box(SIMD3(-length / 2 + 35, 0, 2), SIMD3(36, 24, 9), gray: 0.3, material: .plastic)
            g.box(SIMD3(-length / 2 + 35, 0, 6.7), SIMD3(24, 13, 0.5), gray: 0.06, material: .plastic)
            g.box(SIMD3(-length / 2 + 46, -18, 0), SIMD3(10, 46, 5), gray: 0.74)
            for x: Float in stride(from: -length / 2 + 60, through: length / 2 - 10, by: 10) {
                g.box(SIMD3(x, 2, 2.05), SIMD3(0.5, 5, 0.1), gray: 0.13)
            }
        case .micrometer:
            g.ring(.zero, outer: 34, inner: 24, depth: 10, start: .pi / 4, sweep: 1.5 * .pi,
                   gray: 0.2, material: .blackOxide)
            g.cylinder(SIMD3(21, 20, 0), radius: 3, length: 15, axis: SIMD3(0, 1, 0))
            g.cylinder(SIMD3(21, -13, 0), radius: 3, length: 28, axis: SIMD3(0, 1, 0))
            g.cylinder(SIMD3(21, -38, 0), radius: 7, length: 27, axis: SIMD3(0, 1, 0), gray: 0.52)
            g.cylinder(SIMD3(21, -55, 0), radius: 5, length: 9, axis: SIMD3(0, 1, 0), gray: 0.22)
        case .depthMicrometer:
            g.box(.zero, SIMD3(90, 18, 7), gray: 0.7)
            g.cylinder(SIMD3(0, 0, -25), radius: 2, length: 50)
            g.cylinder(SIMD3(0, 0, 18), radius: 7, length: 30, gray: 0.55)
            g.cylinder(SIMD3(0, 0, 38), radius: 8, length: 15, gray: 0.25)
        case .heightGauge:
            let height = max(span, 100)
            g.box(SIMD3(0, 0, 7), SIMD3(65, 40, 14), gray: 0.16, material: .blackOxide)
            g.box(SIMD3(-10, 0, height / 2 + 14), SIMD3(12, 12, height), gray: 0.72)
            g.box(SIMD3(-10, 0, height * 0.5), SIMD3(30, 25, 25), gray: 0.3)
            g.box(SIMD3(21, 0, height * 0.5 - 8), SIMD3(48, 6, 5), gray: 0.72)
        case .dialIndicator, .testIndicator:
            let radius: Float = kind == .dialIndicator ? 23 : 17
            g.cylinder(.zero, radius: radius, length: 10, gray: 0.2, material: .blackOxide)
            g.cylinder(SIMD3(0, 0, 5.1), radius: radius - 2, length: 0.5, gray: 0.86, material: .plastic)
            g.ring(SIMD3(0, 0, 6), outer: radius, inner: radius - 2, depth: 2, gray: 0.68)
            g.box(SIMD3(0, radius * 0.3, 5.6), SIMD3(0.8, radius, 0.3), gray: 0.04, angle: -.pi / 5)
            for i in 0..<12 {
                let a = Float(i) * .pi / 6
                g.box(SIMD3((radius - 5) * cos(a), (radius - 5) * sin(a), 5.7), SIMD3(3, 0.5, 0.3), gray: 0.08, angle: a)
            }
            g.cylinder(SIMD3(0, -radius - 10, 0), radius: 3, length: 25, axis: SIMD3(0, 1, 0))
            g.cylinder(SIMD3(0, -radius - 26, 0), radius: 1, length: 12, axis: SIMD3(0, 1, 0))
        case .edgeFinder:
            g.cylinder(SIMD3(0, 0, 20), radius: 5, length: 40)
            g.cylinder(SIMD3(0, 0, -3), radius: 2, length: 6, gray: 0.25)
            g.cylinder(SIMD3(0, 0, -10), radius: 3, length: 9)
        case .touchProbe:
            g.cylinder(SIMD3(0, 0, 8), radius: 18, length: 16, gray: 0.7)
            g.cylinder(SIMD3(0, 0, 17), radius: 12, length: 2, gray: 0.3)
            g.cylinder(SIMD3(0, 0, -10), radius: 1.5, length: 20, gray: 0.18)
            g.cylinder(SIMD3(0, 0, -21), radius: 3, length: 3, gray: 0.7)
        case .gaugePins:
            g.box(SIMD3(0, 0, -3), SIMD3(65, 38, 6), gray: 0.2, material: .plastic)
            for i in 0..<6 {
                g.cylinder(SIMD3(Float(i) * 9 - 22.5, 0, 12), radius: Float(i + 2) * 0.55, length: 24)
            }
        case .gaugeBlocks:
            for i in 0..<5 {
                let h = Float(i + 1) * 5
                g.box(SIMD3(Float(i) * 14 - 28, 0, h / 2), SIMD3(10, 30, h), gray: 0.72, material: .chrome)
            }
        case .radiusGauge, .threadGauge, .feelerGauge:
            for i in 0..<7 {
                let angle = Float(i - 3) * 0.16
                let length: Float = kind == .feelerGauge ? 75 : 48
                g.box(SIMD3(length / 2 * cos(angle), length / 2 * sin(angle), Float(i) * 0.6),
                      SIMD3(length, 8, 0.5), gray: 0.6 + Float(i % 2) * 0.1, angle: angle)
                if kind == .threadGauge {
                    for j in 0..<5 {
                        let x = Float(j) * 4 + 25
                        g.box(SIMD3(x * cos(angle) - 4 * sin(angle), x * sin(angle) + 4 * cos(angle), Float(i) * 0.6),
                              SIMD3(2, 2, 0.5), gray: 0.45, angle: angle + .pi / 4)
                    }
                }
            }
            g.cylinder(SIMD3(0, 0, 2), radius: 3, length: 6, gray: 0.3)
        case .loupe:
            g.ring(.zero, outer: 23, inner: 18, depth: 14, gray: 0.17, material: .plastic)
            g.cylinder(.zero, radius: 18, length: 1, gray: 0.65, material: SurfaceMaterial(metallic: 0, roughness: 0.04))
            g.box(SIMD3(31, 0, -3), SIMD3(27, 12, 5), gray: 0.25, material: .plastic)
        case .surfacePlate:
            g.box(SIMD3(0, 0, 12), SIMD3(120, 90, 24), gray: 0.18, material: .rubber)
        }
        return g.meshes
    }
}

extension Accessory {
    func sceneMeshes(device: MTLDevice) -> [SceneMesh] {
        var g = InventoryPreviewGeometry(device: device)
        let diameter = InventoryPreviewGeometry.dimension(size, fallback: 6, min: 0.5, max: 50)
        switch kind {
        case .collet:
            let outer = max(diameter / 2 + 3, 6)
            g.ring(.zero, outer: outer, inner: diameter / 2, depth: 16, gray: 0.54)
            g.ring(SIMD3(0, 0, -9), outer: outer + 0.7, inner: diameter / 2, depth: 2, gray: 0.6)
            for i in 0..<8 {
                let angle = Float(i) * .pi / 4
                g.box(SIMD3((outer - 0.15) * cos(angle), (outer - 0.15) * sin(angle), 0),
                      SIMD3(0.5, 1, 12), gray: 0.025, material: .blackOxide, angle: angle)
            }
        case .lubricant, .adhesive:
            let radius: Float = kind == .lubricant ? 18 : 12
            g.cylinder(SIMD3(0, 0, 25), radius: radius, length: 50, gray: 0.65, material: .plastic)
            g.cylinder(SIMD3(0, 0, 53), radius: radius * 0.65, length: 7, gray: 0.18, material: .plastic)
            if kind == .adhesive {
                var builder = MeshBuilder()
                builder.cone(r0: 5, z0: 57, r1: 1, z1: 77)
                g.add(builder.mesh(device: device, id: "preview.nozzle", color: SceneColor.surface(0.72)), material: .plastic)
            } else {
                g.cylinder(SIMD3(0, 0, 62), radius: 3, length: 12, gray: 0.18, material: .plastic)
            }
            g.box(SIMD3(0, -radius - 0.05, 26), SIMD3(radius * 1.2, 0.2, 22), gray: 0.3, material: .plastic)
        case .dowelPin:
            for i in 0..<3 { g.cylinder(SIMD3(Float(i) * diameter * 1.7, 0, 0), radius: diameter / 2, length: diameter * 5) }
        case .tape:
            g.ring(.zero, outer: 30, inner: 17, depth: 15, gray: 0.72, material: .rubber)
            g.ring(.zero, outer: 18, inner: 16, depth: 15.2, gray: 0.34, material: .plastic)
        case .deburring:
            g.cylinder(SIMD3(0, 0, 30), radius: 8, length: 60, gray: 0.16, material: .rubber)
            g.cylinder(SIMD3(0, 0, -12), radius: 2, length: 24)
            g.cylinder(SIMD3(4, 0, -25), radius: 2, length: 12, axis: SIMD3(1, 0, 0))
        case .polishing:
            g.cylinder(.zero, radius: 25, length: 12, gray: 0.75, material: .rubber)
            g.cylinder(SIMD3(0, 0, 24), radius: 3, length: 36, gray: 0.65)
            g.ring(SIMD3(0, 0, 6.1), outer: 20, inner: 17, depth: 0.2, gray: 0.5, material: .rubber)
        case .other:
            g.box(SIMD3(0, 0, 15), SIMD3(44, 34, 30), gray: 0.5, material: .plastic)
            g.box(SIMD3(0, 0, 30.2), SIMD3(7, 34, 0.4), gray: 0.7, material: .plastic)
        }
        return g.meshes
    }
}
