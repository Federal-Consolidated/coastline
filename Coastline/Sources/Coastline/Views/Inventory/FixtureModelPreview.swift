import AppKit
import CoastlineCore
import Metal
import simd
import SwiftUI
import Viewport

@MainActor
private enum FixturePreviewCache {
    static var meshes: [String: MeshData] = [:]
    static var images: [String: NSImage] = [:]

    static func key(_ fixture: Fixture, app: AppModel) -> String {
        guard let path = fixture.modelPath else { return fixture.id.uuidString }
        let url = app.fixtureModelURL(path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
    }

    static func load(_ fixture: Fixture, app: AppModel) async throws -> MeshData? {
        guard let path = fixture.modelPath, !path.isEmpty else { return nil }
        if let profile = fixture.planning, !(profile.componentPlacements ?? []).isEmpty {
            let (geometry, signature) = try await app.loadFixtureGeometry(fixture)
            guard signature == profile.componentModelSignature, geometry.placementsMatch(profile) else {
                throw EngineClient.EngineError(type: "Fixture", message: "The assembly changed. Re-place its pieces in the workspace.")
            }
            return geometry.workMesh(profile: profile)
        }
        let key = key(fixture, app: app)
        if let mesh = meshes[key] { return mesh }
        let engine = try await app.liveEngine()
        let mesh = try await engine.importPart(app.fixtureModelURL(path))
        guard !mesh.indices.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        meshes[key] = mesh
        return mesh
    }
}

/// Work X is vertical on this horizontal mill; display the model and stock with X up.
private let fixtureWorkToDisplay = simd_float4x4(columns: (
    SIMD4(0, 0, 1, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)))

@MainActor
private func previewMeshes(_ fixture: Fixture, mesh: MeshData?, app: AppModel, device: MTLDevice,
                           includeStock: Bool) -> [SceneMesh] {
    var result: [SceneMesh]
    if let mesh, let model = SceneMesh(device: device, id: "fixture.preview", positions: mesh.vertices,
        normals: mesh.normals, indices: mesh.indices, color: SceneColor.part) {
        if let profile = fixture.planning {
            model.transform = (profile.componentPlacements ?? []).isEmpty ? fixtureWorkToDisplay * profile.modelToWork.float : fixtureWorkToDisplay
        }
        result = [model]
    } else {
        let kit = app.fixtureMeshes(fixture.kind, device: device)
        result = kit.isEmpty ? fixture.sceneMeshes(device: device) : kit
    }
    if includeStock, let profile = fixture.planning {
        let s = profile.stockSize
        if [s.x, s.y, s.z].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 10_000 }),
           let stock = SceneMesh.box(device: device, id: "stock.preview",
              min: SIMD3(Float(-s.x / 2), Float(-s.y / 2), Float(-s.z)),
              max: SIMD3(Float(s.x / 2), Float(s.y / 2), 0), color: SIMD4(0.3, 0.6, 0.95, 0.2), transform: fixtureWorkToDisplay) {
            result.append(stock)
        }
        for contact in profile.contacts where [contact.point.x, contact.point.y, contact.point.z, contact.radius].allSatisfy(\.isFinite) {
            let p = SIMD3(Float(contact.point.x), Float(contact.point.y), Float(contact.point.z))
            let r = Float(min(max(contact.radius, 0.3), 4))
            if let marker = SceneMesh.box(device: device, id: "contact.\(contact.id)", min: p - SIMD3(repeating: r),
                max: p + SIMD3(repeating: r), color: SIMD4(0.15, 0.55, 1, 1), transform: fixtureWorkToDisplay) { result.append(marker) }
        }
    }
    return result
}

struct FixtureThumbnail: View {
    let fixture: Fixture
    @Environment(AppModel.self) private var app
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "cube.transparent").font(.title).foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }
        .frame(width: 100, height: 88)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(fixture.name) \(fixture.modelPath == nil ? "illustration" : "model")")
        .task(id: FixturePreviewCache.key(fixture, app: app) + "|\(String(describing: fixture.planning))") {
            let key = FixturePreviewCache.key(fixture, app: app) + "|\(String(describing: fixture.planning))"
            if let cached = FixturePreviewCache.images[key] { image = cached; return }
            image = nil; failed = false
            do {
                let mesh = try await FixturePreviewCache.load(fixture, app: app)
                try Task.checkCancellation()
                let renderer = try ViewportRenderer(device: app.renderer.device)
                for model in previewMeshes(fixture, mesh: mesh, app: app, device: renderer.device, includeStock: false) { renderer.scene.setMesh(model) }
                renderer.background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                renderer.animationsEnabled = false; renderer.camera.set(.iso); renderer.frameAll()
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                defer { try? FileManager.default.removeItem(at: file) }
                try renderer.snapshot(width: 240, height: 200, to: file)
                guard let loaded = NSImage(data: try Data(contentsOf: file)) else { throw CocoaError(.fileReadCorruptFile) }
                image = loaded; FixturePreviewCache.images[key] = loaded
            } catch is CancellationError { } catch { failed = true }
        }
    }
}

struct FixtureAssemblyPreview: View {
    let fixture: Fixture
    @Environment(AppModel.self) private var app
    @State private var mesh: MeshData?
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Group {
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).frame(height: 220) }
            else if loaded {
                ItemViewer3D(build: { device in previewMeshes(fixture, mesh: mesh, app: app, device: device, includeStock: true) },
                    key: String(describing: fixture), name: fixture.name, preserveCameraOnChange: true)
            } else { ProgressView("Loading fixture…").frame(height: 220) }
        }
        .frame(maxWidth: .infinity)
        .task(id: FixturePreviewCache.key(fixture, app: app) + "|\(String(describing: fixture.planning?.componentPlacements))") {
            loaded = false; error = nil
            do {
                mesh = try await FixturePreviewCache.load(fixture, app: app)
                try Task.checkCancellation()
                loaded = true
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
}
