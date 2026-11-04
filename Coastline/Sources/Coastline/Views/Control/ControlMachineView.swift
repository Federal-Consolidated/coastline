import CoastlineCore
import MillCore
import Observation
import simd
import SwiftUI
import Viewport

/// The real machine assembly, with its own scene and camera. Opening Control never changes
/// the workspace's part, toolpaths, fixture visibility or camera.
@MainActor
struct ControlMachineView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var machine = ControlMachineScene()

    var body: some View {
        VStack(spacing: 0) {
            viewBar
            ZStack {
                if let renderer = machine.renderer {
                    ViewportContainer(renderer: renderer)
                        .accessibilityLabel("Machine assembly. \(machine.positionSource)")
                        .accessibilityHint("Drag to orbit, pinch to zoom, or use the View menu.")
                } else if let problem = machine.problem {
                    ContentUnavailableView {
                        Label("Machine View Unavailable", systemImage: "cube")
                    } description: {
                        Text(problem)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ProgressView("Loading machine…")
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.windowBackground)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                machine.resize(size)
            }
            footer
        }
        .task { await load() }
        .onChange(of: app.mill.snapshot.revision) {
            machine.synchronize(app.mill.snapshot)
        }
        .onChange(of: app.realistic) {
            machine.renderer?.realistic = app.realistic
        }
        .onChange(of: reduceMotion) {
            machine.renderer?.animationsEnabled = !reduceMotion
        }
    }

    private var viewBar: some View {
        @Bindable var machine = machine
        return HStack(spacing: 10) {
            Text("Machine")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Picker("Assembly", selection: $machine.display) {
                ForEach(ControlMachineScene.Display.allCases) { display in
                    Text(display.title).tag(display)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Choose which parts of the machine to show")
            Menu("View", systemImage: "cube") {
                Button("Isometric") { machine.setView(.iso) }
                Button("Front") { machine.setView(.front) }
                Button("Tool") { machine.setView(.tool) }
                Button("Top") { machine.setView(.top) }
                Button("Right") { machine.setView(.right) }
                Divider()
                Button("Zoom In") { machine.renderer?.camera.zoom(by: 0.8) }
                Button("Zoom Out") { machine.renderer?.camera.zoom(by: 1.25) }
                Button("Frame Machine") { machine.frame(animated: !reduceMotion) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button("Frame Machine", systemImage: "viewfinder") {
                machine.frame(animated: !reduceMotion)
            }
            .labelStyle(.iconOnly)
            .help("Fit the machine in the view")
        }
        .controlSize(.small)
        .disabled(machine.renderer == nil)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panelBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(machine.positionSource)
                .help(machine.positionHelp)
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                Text("X · Table   Y · Gantry   Z · Spindle")
                Text("X / Y / Z")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.panelBackground)
        .overlay(alignment: .top) { Divider() }
    }

    private func load() async {
        await machine.load(app: app, reduceMotion: reduceMotion)
        machine.synchronize(app.mill.snapshot)
    }
}

@MainActor @Observable
private final class ControlMachineScene {
    enum Display: String, CaseIterable, Identifiable {
        case open, full, moving
        var id: Self { self }
        var title: String {
            switch self {
            case .open: "Open Assembly"
            case .full: "Whole Machine"
            case .moving: "Moving Parts"
            }
        }
    }

    private(set) var renderer: ViewportRenderer?
    private(set) var problem: String?
    private(set) var positionSource = "Reference pose"
    private(set) var positionHelp = "The assembly's modelled position. Home the connected machine to show its reported position."
    var display = Display.open {
        didSet {
            applyDisplay()
            frame(animated: true)
        }
    }
    @ObservationIgnored private var model: MachineModel?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var viewportSize = CGSize.zero

    func load(app: AppModel, reduceMotion: Bool) async {
        guard renderer == nil, !loading else { return }
        loading = true
        problem = nil
        defer { loading = false }
        do {
            let assembly: MachineModel
            if let cached = app.machineModel {
                assembly = cached
            } else {
                let engine = try await app.liveEngine()
                assembly = try await engine.machineModel(AppModel.repoRoot.appendingPathComponent("resources/machine/machine.step"))
            }
            try Task.checkCancellation()
            let renderer = try ViewportRenderer(device: app.renderer.device)
            renderer.worldToDisplay = ViewportRenderer.machineToDisplay
            renderer.realistic = app.realistic
            renderer.animationsEnabled = !reduceMotion
            renderer.camera.set(.iso)
            for (index, part) in assembly.parts.enumerated() {
                let color = AppModel.displayColor(role: part.role, part.color)
                guard let mesh = SceneMesh(device: renderer.device,
                                           id: "machine.\(part.group).\(part.role).\(index)",
                                           positions: part.mesh.vertices, normals: part.mesh.normals,
                                           indices: part.mesh.indices, color: SIMD4(color, 1)) else { continue }
                mesh.group = part.group
                mesh.material = AppModel.machineSurface(part.role)
                renderer.scene.setMesh(mesh)
            }
            guard !renderer.scene.meshes.isEmpty else {
                problem = "The machine assembly contained no displayable parts."
                return
            }
            model = assembly
            self.renderer = renderer
            applyDisplay()
            synchronize(app.mill.snapshot)
            frame(animated: false)
        } catch is CancellationError {
            // Leaving the page cancels the load. A later visit can try again.
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Render only homed controller positions as current. A lost connection or reset returns
    /// to the assembly's reference pose; stale reports stay explicitly marked as historical.
    func synchronize(_ snapshot: MillSnapshot) {
        guard let renderer, let model else { return }
        guard snapshot.link == .connected, snapshot.homed, !snapshot.needsReset,
              let status = snapshot.status else {
            showReferencePose()
            return
        }
        let p = status.machinePosition
        let m = model.modelPose
        let delta = SIMD3(Float(m.x - p.x), Float(p.y - m.y), Float(p.z - m.z))
        guard delta.x.isFinite, delta.y.isFinite, delta.z.isFinite else {
            showReferencePose()
            return
        }
        renderer.scene.groupTransforms["x"] = simd_float4x4(translation: SIMD3(delta.x, 0, 0))
        renderer.scene.groupTransforms["y"] = simd_float4x4(translation: SIMD3(0, delta.y, 0))
        renderer.scene.groupTransforms["z"] = simd_float4x4(translation: SIMD3(0, delta.y, delta.z))
        let fresh = snapshot.silentSince == nil && (snapshot.statusTime.map { Date().timeIntervalSince($0) <= 1 } ?? false)
        positionSource = fresh ? (snapshot.port?.isSimulated == true ? "Simulated position" : "Reported position") : "Last reported position"
        positionHelp = fresh
            ? "The assembly follows the machine coordinates reported by the controller."
            : "The controller's position report is out of date. This is its last reported position."
    }

    func setView(_ view: OrbitCamera.StandardView) {
        renderer?.moveCamera { $0.set(view) }
    }

    func frame(animated: Bool) {
        guard let renderer else { return }
        // Include the new pivot in the animation's destination camera.
        if let (lo, hi) = renderer.scene.visibleBounds() {
            renderer.setPivot(world: (lo + hi) / 2)
        }
        renderer.frameAll(animated: animated)
        let fit = horizontalFit(viewportSize)
        if fit > 1 {
            renderer.moveCamera(animated: animated) { $0.distance *= fit }
        }
    }

    /// Frame to the narrower viewport dimension. Keep the operator's pan/orbit/zoom while
    /// resizing, rather than resetting the camera whenever the inspector or window changes.
    func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let previous = viewportSize
        viewportSize = size
        guard let renderer else { return }
        if previous == .zero {
            frame(animated: false)
        } else {
            renderer.cancelCameraAnimation()
            renderer.camera.distance *= horizontalFit(size) / horizontalFit(previous)
        }
    }

    private func horizontalFit(_ size: CGSize) -> Float {
        guard size.width > 0, size.height > 0 else { return 1 }
        return Float(max(1, size.height / size.width))
    }

    private func showReferencePose() {
        renderer?.scene.groupTransforms.removeAll()
        positionSource = "Reference pose"
        positionHelp = "The assembly's modelled position. A valid, homed controller position is needed to show the machine's reported position."
    }

    private func applyDisplay() {
        guard let renderer else { return }
        for mesh in renderer.scene.meshes {
            let components = mesh.id.split(separator: ".")
            let role = components.count > 2 ? String(components[2]) : ""
            let shell = role.hasPrefix("enclosure")
            switch display {
            case .open: mesh.isVisible = !shell
            case .full: mesh.isVisible = true
            case .moving: mesh.isVisible = mesh.group != "static" && !shell
            }
            mesh.color.w = role.hasSuffix("guard") ? 0.2 : 1
        }
    }
}
