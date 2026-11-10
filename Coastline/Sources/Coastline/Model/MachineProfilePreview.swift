import CoastlineCore
import Metal
import Observation
import simd
import SwiftUI
import Viewport

/// An isolated digital scene. It has no MillSession or path to a physical controller.
@MainActor @Observable
final class MachineProfilePreview {
    private(set) var renderer: ViewportRenderer?
    private(set) var problem: String?
    private(set) var loading = false
    private(set) var isReferencePose = true
    private(set) var position = Vec3.zero
    var showInterfaces = false { didSet { applyVisibility() } }
    var showReferenceStock = true { didSet { applyVisibility() } }
    var showEnclosure = false { didSet { applyVisibility() } }
    var movingOnly = false { didSet { applyVisibility() } }
    @ObservationIgnored private var definition: MachineDefinition?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var size = CGSize.zero

    func reset() {
        generation = UUID()
        renderer = nil
        problem = nil
        definition = nil
        loading = false
        isReferencePose = true
    }

    func load(_ package: MachineDefinitionPackage, engine: EngineClient, device: MTLDevice,
              realistic: Bool, reduceMotion: Bool) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        loading = true
        problem = nil
        renderer = nil
        definition = package.definition
        position = package.definition.controllerHomePosition
        isReferencePose = true
        defer { if generation == token { loading = false } }
        do {
            let parts = try await engine.machineProfileParts(package.manifestURL)
            try Task.checkCancellation()
            guard generation == token else { return }
            let model = try ViewportRenderer(device: device)
            model.realistic = realistic
            model.animationsEnabled = !reduceMotion
            model.worldToDisplay = Self.displayTransform(package.definition)
            model.camera.set(.iso)
            for (index, part) in parts.enumerated() {
                guard package.definition.components.contains(where: { $0.id == part.group }) else {
                    throw MachineDefinitionError("Geometry refers to an unknown motion group: \(part.group).")
                }
                guard let mesh = SceneMesh(device: device, id: "profile.\(index)",
                                           positions: part.mesh.vertices, normals: part.mesh.normals,
                                           indices: part.mesh.indices,
                                           color: SIMD4(AppModel.displayColor(role: part.role, part.color), 1)) else {
                    throw MachineDefinitionError("The graphics device couldn't create the machine model.")
                }
                mesh.group = part.group
                mesh.material = AppModel.machineSurface(part.role)
                if part.role.hasSuffix("guard") { mesh.color.w = 0.2 }
                model.scene.setMesh(mesh)
            }
            try addReferenceStock(to: model, definition: package.definition)
            addReferenceLines(to: model, definition: package.definition)
            renderer = model
            showHome()
            applyVisibility()
            frame(animated: false)
        } catch is CancellationError {
            // A different selection or leaving the page cancels this preview only.
        } catch {
            if generation == token { problem = error.localizedDescription }
        }
    }

    func showReference() {
        isReferencePose = true
        renderer?.scene.groupTransforms.removeAll()
    }

    func showHome() {
        guard let definition else { return }
        position = definition.controllerHomePosition
        isReferencePose = false
        updatePosition()
    }

    func set(_ coordinate: MachineCoordinate, to value: Double) {
        guard let definition, !isReferencePose, value.isFinite else { return }
        let range = Self.range(coordinate, definition: definition)
        position[coordinate] = min(max(value, range.lowerBound), range.upperBound)
        updatePosition()
    }

    func range(_ coordinate: MachineCoordinate) -> ClosedRange<Double> {
        guard let definition else { return -1...0 }
        return Self.range(coordinate, definition: definition)
    }

    private static func range(_ coordinate: MachineCoordinate, definition: MachineDefinition) -> ClosedRange<Double> {
        let box = definition.profile.machineEnvelope
        switch coordinate { case .x: return box.x; case .y: return box.y; case .z: return box.z }
    }

    private func updatePosition() {
        guard let renderer, let definition else { return }
        do {
            var transforms: [String: simd_float4x4] = [:]
            for component in definition.components {
                let t = try definition.worldTranslation(for: component.id, at: position)
                let translated = Self.float(t)
                guard translated.x.isFinite, translated.y.isFinite, translated.z.isFinite else {
                    throw MachineDefinitionError("Machine motion exceeds the supported preview coordinate range.")
                }
                transforms[component.id] = simd_float4x4(translation: translated)
            }
            renderer.scene.groupTransforms = transforms
        } catch { problem = error.localizedDescription }
    }

    func frame(animated: Bool = true) {
        guard let renderer else { return }
        if let (lo, hi) = renderer.scene.visibleBounds() { renderer.setPivot(world: (lo + hi) / 2) }
        renderer.frameAll(animated: animated)
        let fit = horizontalFit(size)
        if fit > 1 { renderer.moveCamera(animated: animated) { $0.distance *= fit } }
    }

    func resize(_ newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0 else { return }
        let previous = size
        size = newSize
        guard let renderer else { return }
        if previous == .zero { frame(animated: false) }
        else {
            renderer.cancelCameraAnimation()
            renderer.camera.distance *= horizontalFit(newSize) / horizontalFit(previous)
        }
    }

    func setView(_ view: OrbitCamera.StandardView) {
        renderer?.moveCamera { $0.set(view) }
    }

    private func horizontalFit(_ size: CGSize) -> Float {
        size.width > 0 && size.height > 0 ? Float(max(1, size.height / size.width)) : 1
    }

    private func applyVisibility() {
        guard let renderer, let definition else { return }
        for mesh in renderer.scene.meshes {
            var id = mesh.group
            var moving = false
            while let current = id, let component = definition.components.first(where: { $0.id == current }) {
                if component.axis != nil { moving = true; break }
                id = component.parentID
            }
            let enclosure = definition.components.first(where: { $0.id == mesh.group })?.isEnclosure == true
            mesh.isVisible = (!movingOnly || moving) && (!enclosure || showEnclosure)
                && (mesh.id != "reference.stock" || showReferenceStock)
        }
        for lines in renderer.scene.lines {
            lines.isVisible = lines.id == "reference.stock.edges" ? showReferenceStock : showInterfaces
        }
    }

    private func addReferenceStock(to renderer: ViewportRenderer, definition: MachineDefinition) throws {
        guard let stock = definition.referenceStock,
              let frame = definition.frames.first(where: { $0.id == stock.frameID }) else { return }
        let transform = simd_float4x4(columns: (
            SIMD4(Self.float(frame.xDirection), 0), SIMD4(Self.float(frame.yDirection), 0),
            SIMD4(Self.float(frame.zDirection), 0), SIMD4(Self.float(frame.origin), 1)))
        guard let mesh = SceneMesh.box(device: renderer.device, id: "reference.stock",
                                      min: Self.float(stock.minimum), max: Self.float(stock.minimum) + Self.float(stock.size),
                                      color: SIMD4(0.34, 0.48, 0.62, 0.7), transform: transform) else {
            throw MachineDefinitionError("The graphics device couldn't create the reference stock.")
        }
        mesh.group = frame.componentID
        renderer.scene.setMesh(mesh)
        let corners = try definition.referenceStockCorners().map(Self.float)
        let pairs = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7),
                     (0, 4), (1, 5), (2, 6), (3, 7)]
        if let edges = SceneLines(device: renderer.device, id: "reference.stock.edges",
                                  segments: pairs.map { LineSegment(corners[$0.0], corners[$0.1], color: SceneColor.edge) }) {
            edges.group = frame.componentID
            renderer.scene.setLines(edges)
        }
    }

    /// Optional authored view frame: X is screen-right, Z is up. Without it CAD Z is up.
    private static func displayTransform(_ definition: MachineDefinition) -> simd_float4x4 {
        guard let view = definition.frames.first(where: { $0.id == "view" }) else { return matrix_identity_float4x4 }
        return simd_float4x4(rows: [SIMD4(float(view.xDirection), 0), SIMD4(float(view.yDirection), 0),
                                  SIMD4(float(view.zDirection), 0), SIMD4(0, 0, 0, 1)])
    }

    private func addReferenceLines(to renderer: ViewportRenderer, definition: MachineDefinition) {
        for frame in definition.frames where frame.id != "view" {
            let origin = Self.float(frame.origin)
            let segments = [(frame.xDirection, PathColor.axisX), (frame.yDirection, PathColor.axisY),
                            (frame.zDirection, PathColor.axisZ)].map { vector, color in
                LineSegment(origin, origin + Self.float(vector) * 20, color: color)
            }
            if let lines = SceneLines(device: renderer.device, id: "frame.\(frame.id)", segments: segments) {
                lines.group = frame.componentID
                lines.xray = 0.3
                renderer.scene.setLines(lines)
            }
        }
        for mount in definition.mountingInterfaces {
            guard let frame = definition.frames.first(where: { $0.id == mount.frameID }) else { continue }
            let x = Self.float(frame.xDirection), y = Self.float(frame.yDirection), z = Self.float(frame.zDirection)
            let segments = mount.slots.map { slot in
                let p = Self.float(frame.origin) + x * Float(slot.origin.x) + y * Float(slot.origin.y) + z * Float(slot.origin.z)
                let d = x * Float(slot.direction.x) + y * Float(slot.direction.y) + z * Float(slot.direction.z)
                return LineSegment(p, p + d * Float(slot.length), color: SceneColor.caution)
            }
            if let lines = SceneLines(device: renderer.device, id: "mount.\(mount.id)", segments: segments) {
                lines.group = frame.componentID
                lines.xray = 0.3
                renderer.scene.setLines(lines)
            }
        }
    }

    private static func float(_ v: Vec3) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
}
