import CoastlineCore
import Metal
import simd
import SwiftUI
import Viewport

/// A small realistic 3D view of one inventory item that can be orbited
/// and zoomed like the workspace. Display space: Z up.
struct ItemViewer3D: View {
    /// Builds the item's meshes on the given device.
    let build: (MTLDevice) -> [SceneMesh]
    /// Changes when the item changes, to rebuild.
    let key: String
    var name: String = "Item"
    var preserveCameraOnChange = false
    @State private var renderer: ViewportRenderer?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let renderer {
                ViewportContainer(renderer: renderer)
                    .accessibilityLabel("3D model of \(name)")
                    .accessibilityHint("Use the View menu to change orientation or zoom.")
            } else if unavailable {
                ContentUnavailableView("Preview Unavailable", systemImage: "cube",
                                       description: Text("The 3D preview couldn't be rendered."))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 220)
        .overlay(alignment: .bottomTrailing) {
            if let renderer {
                Menu("View", systemImage: "cube") {
                    Button("Isometric") { renderer.camera.set(.iso) }
                    Button("Front") { renderer.camera.set(.front) }
                    Button("Top") { renderer.camera.set(.top) }
                    Button("Right") { renderer.camera.set(.right) }
                    Divider()
                    Button("Zoom In") { renderer.camera.zoom(by: 0.8) }
                    Button("Zoom Out") { renderer.camera.zoom(by: 1.25) }
                    Button("Reset View", systemImage: "arrow.counterclockwise") { frameItem(renderer) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
                .help("Change the preview orientation, zoom, or reset the view")
            }
        }
        .onAppear { setUp(resetCamera: true) }
        .onChange(of: key) { _, _ in setUp(resetCamera: !preserveCameraOnChange) }
    }

    private func setUp(resetCamera: Bool) {
        unavailable = false
        guard let device = MTLCreateSystemDefaultDevice() else { unavailable = true; return }
        let r = renderer ?? (try? ViewportRenderer(device: device))
        guard let r else { unavailable = true; return }
        let meshes = build(device)
        guard !meshes.isEmpty else { renderer = nil; unavailable = true; return }
        r.background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)  // drawn on the card
        for m in r.scene.meshes { r.scene.remove(id: m.id) }
        for m in meshes { r.scene.setMesh(m) }
        r.realistic = true
        r.animationsEnabled = false
        if resetCamera || renderer == nil { frameItem(r) }
        renderer = r
    }

    private func frameItem(_ r: ViewportRenderer) {
        r.camera.set(.iso)
        r.camera.pitch = .pi / 7
        r.frameAll()
        r.camera.zoom(by: 0.8)
    }
}

/// Shared preview section for inventory items without a dimensioned drawing.
struct InventoryPreviewSection: View {
    let name: String
    let key: String
    var note: String? = nil
    let build: (MTLDevice) -> [SceneMesh]

    var body: some View {
        Section {
            ItemViewer3D(build: build, key: key, name: name)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        } header: {
            Text("3D preview")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let note { Text(note) }
                Text("Drag to orbit · Pinch to zoom · Double-click to fit")
            }
        }
    }
}

/// A preview card with a drawing and a 3D view, toggled in its corner.
struct PreviewCard<Drawing: View>: View {
    let itemID: UUID
    let drawing: Drawing
    let build: (MTLDevice) -> [SceneMesh]
    let key: String
    let name: String
    @State private var show3D = true

    init(itemID: UUID, key: String, name: String, build: @escaping (MTLDevice) -> [SceneMesh], @ViewBuilder drawing: () -> Drawing) {
        self.itemID = itemID
        self.key = key
        self.name = name
        self.build = build
        self.drawing = drawing()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if show3D { ItemViewer3D(build: build, key: key, name: name) } else { drawing.frame(height: 220) }
            Picker("Preview", selection: $show3D) {
                Text("Drawing").tag(false)
                Text("3D").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .padding(6)
            .help("Switch between the dimensioned drawing and a 3D view you can orbit (drag) and zoom (pinch)")
        }
        // One container: a single rounded panel for both the drawing and the 3D view.
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onChange(of: itemID) { _, _ in show3D = true }
    }
}

extension StockItem {
    /// Stock in its material and shape, with extrusion lines along its length.
    func sceneMeshes(device: MTLDevice) -> [SceneMesh] {
        func dimension(_ value: Double) -> Float { Float(value.isFinite ? min(max(value, 0.1), 100_000) : 1) }
        let e = SIMD3<Float>(dimension(envelope.x), dimension(envelope.y), dimension(envelope.z))
        let c = material?.linearSwatch ?? SIMD3(0.5, 0.5, 0.5)
        let mesh: SceneMesh?
        if shape == .roundBar {
            var cylinder = MeshBuilder()
            cylinder.cylinder(radius: e.x / 2, z0: -e.y / 2, z1: e.y / 2, segments: 64)
            mesh = cylinder.mesh(device: device, id: "item", color: SIMD4(c, 1))
            // The stock envelope stores the bar's length on Y.
            mesh?.transform = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))
        } else {
            mesh = SceneMesh.box(device: device, id: "item", min: -e / 2, max: e / 2, color: SIMD4(c, 1))
        }
        guard let m = mesh else { return [] }
        let metal = [.aluminium, .copperAlloy, .steel, .stainless, .titanium].contains(material?.family)
        var axis = SIMD3<Float>(0, 0, 0)
        // Pattern axes are mesh-local, before the cylinder's rotation.
        let longest = [e.x, e.y, e.z].enumerated().max { $0.element < $1.element }!.offset
        axis[shape == .roundBar ? 2 : min(max(extrusionAxis ?? longest, 0), 2)] = 1
        m.material = metal ? SurfaceMaterial(metallic: 1, roughness: 0.3, pattern: 1, axis: axis) : .plastic
        return [m]
    }
}

extension AppModel {
    /// Clamp-kit meshes for a fixture kind (kit-local frame, z up), if the kit has it.
    func fixtureMeshes(_ kind: Fixture.Kind, device: MTLDevice) -> [SceneMesh] {
        let kit: [String] = switch kind {
        case .universalClamp: ["clamp"]
        case .squaringBoss, .squaringStop: ["brick"]
        case .cClamp: ["cclamp"]
        case .vise: ["eccentric"]
        case .tSlotNuts: []
        default: []
        }
        return kitParts.enumerated().compactMap { j, p in
            guard kit.contains(p.kit) else { return nil }
            let look = Self.kitAppearance(p)
            let m = SceneMesh(device: device, id: "item.\(j)", positions: p.mesh.vertices, normals: p.mesh.normals,
                              indices: p.mesh.indices, color: look.color)
            m?.material = look.material
            return m
        }
    }
}
