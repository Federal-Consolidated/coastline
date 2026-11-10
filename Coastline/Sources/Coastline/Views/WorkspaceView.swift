import AppKit
import CoastlineCore
import SwiftUI
import UniformTypeIdentifiers
import Viewport

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    @State private var importing = false
    @State private var showSection = false

    var body: some View {
        @Bindable var model = model
        ViewportContainer(renderer: model.renderer, onClick: { point, size in
            if model.fixturePlacement != nil { model.handlePlacementClick(point, size: size) }
            else if model.inspecting { model.inspect(at: point, viewSize: size) } else { model.handleClick(at: point, viewSize: size) }
        }, handles: .init(begin: { model.gumballBegin($0, $1) }, drag: { model.gumballMove($0, $1) }, end: { model.gumballEnd() }))
        .accessibilityLabel("3D View")
        .accessibilityValue(model.part.map { "\($0.fileName), \(model.title(model.stage)) stage" } ?? "No part imported")
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay { SceneLabelsOverlay() }
        .overlay { FindingPinsOverlay() }
        .overlay(alignment: .topLeading) {
            if let prompt = model.gumballPrompt { TypedMoveField(prompt: prompt).offset(x: prompt.point.x + 14, y: prompt.point.y - 18) }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                ViewCube(camera: model.camera) { normal, view in
                    if let view { model.setView(view) } else { model.look(from: normal) }
                }
                if model.jogOpen { JogPanel() }
            }
            .padding(.top, 10).padding(.trailing, 14)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if (!model.timeline.entries.isEmpty || (model.isGenerating && !model.plannedPrograms.isEmpty)) && model.showsMachiningResults {
                    PlaybackBar().frame(maxWidth: 1100)
                }
                controlBar
            }
            .padding(16)
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                if model.fixturePlacement != nil { FixturePlacementBanner() } else { ViewModeBar() }
                if model.partChangedOnDisk, let name = model.part?.fileName {
                    HStack(spacing: 10) {
                        Label("\(name) changed on disk", systemImage: "arrow.triangle.2.circlepath")
                        Button("Reload") { Task { await model.reloadPart() } }
                            .buttonStyle(.glassProminent)
                    }
                    .padding(10)
                    .glassEffect(.regular, in: .capsule)
                }
                if let error = model.errorMessage {
                    ErrorBanner(text: error, shape: .rect(cornerRadius: 14)) { model.errorMessage = nil }
                }
                FindingsLegend()
                if model.undercutOverlayShown && model.timeline.entries.isEmpty { UndercutLegend() }
                if model.loosePieces > 0 && model.showsMachiningResults { LooseLegend(count: model.loosePieces) }
                if model.measuring { MeasureHUD() }
                if let stop = model.toolChangeStop {
                    ToolChangeCard(stop: stop)
                } else if !model.programs.isEmpty && model.showsMachiningResults && model.showStepCard && !model.measuring && model.inspected == nil { StepCard() }
                if model.manualEdgeFindingNow && model.toolChangeStop == nil { ManualEdgeFindingNote() }
                if let info = model.inspected { InspectCard(info: info) }
            }
            .frame(maxWidth: 360, alignment: .leading)
            .padding(16)
        }
        .overlay {
            // Only when nothing is open, opening or offered on the start sheet (both at once, or
            // this showing while a choice made there loads, looked like a second splash).
            if model.part == nil && model.machineLoaded && !model.isBusy {
                emptyState
                    .transition(.opacity)
            }
        }
        .navigationTitle(model.part?.fileName ?? "Workspace")
        .navigationSubtitle(model.status)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                PlanningMachinePicker()
            }
            ToolbarItem(placement: .automatic) {
                Menu("Job Resources", systemImage: "shippingbox") {
                    Text("This job keeps its selected stock, material and tool definitions.")
                    Button("Update from Library") { model.updateJobResources(from: inventory.inventory) }
                        .disabled(!model.canChangePlanningMachine || model.stock == nil)
                }
                .help("Apply library edits to this job. Generated toolpaths will be cleared.")
            }
            ToolbarItemGroup(placement: .navigation) {
                Button("Undo", systemImage: "arrow.uturn.backward") { model.undoAnywhere() }
                    .disabled(!model.canUndo)
                    .help(model.undoName.map { "Undo \($0) (⌘Z)" } ?? "Nothing to undo")
                Button("Redo", systemImage: "arrow.uturn.forward") { model.redoAnywhere() }
                    .disabled(!model.canRedo)
                    .help(model.redoName.map { "Redo \($0) (⇧⌘Z)" } ?? "Nothing to redo")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Import Part…", systemImage: "square.and.arrow.down") { importing = true }
                    .disabled(model.isBusy || model.fixturePlacement != nil)
                    .keyboardShortcut("i", modifiers: .command)
            }
        }
        .inspector(isPresented: $model.showInspector) {
            WorkspaceInspector()
                .panelEdge(.leading)
                .inspectorColumnWidth(min: 300, ideal: 330, max: 440)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: CADFile.types) { result in
            if case let .success(url) = result {
                Task {
                    let access = url.startAccessingSecurityScopedResource()
                    await model.importPart(url)
                    if access { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
        .task {
            model.stockLookup = { [inventory] id in inventory.inventory.stock.first { $0.id == id } }
            model.toolLookup = { [inventory] id in inventory.inventory.tools.first { $0.id == id } }
            model.fixtureLookup = { [inventory] id in inventory.inventory.fixtures.first { $0.id == id } }
            model.inventoryLookup = { [inventory] in inventory.inventory }
            model.addToInventory = { [inventory] tools, stock in
                inventory.update { inv in
                    inv.tools += tools.filter { t in !inv.tools.contains { $0.id == t.id } }
                    inv.stock += stock.filter { s in !inv.stock.contains { $0.id == s.id } }
                }
            }
            model.measuringToolNames = inventory.inventory.measuring.filter { [.micrometer, .caliper].contains($0.kind) }.map(\.name)
            if ProcessInfo.processInfo.environment["COASTLINE_DEV"] != "1" { await model.loadMachine() }
        }
        .onChange(of: inventory.inventory.stock) { model.layoutScene() }
        // Reduce Motion: the camera jumps to a view instead of easing round.
        .onAppear { model.applyReduceMotion() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            model.applyReduceMotion()
        }
    }

    /// Nothing open: a small prompt, not a second start screen (the start sheet has the examples).
    private var emptyState: some View {
        EmptyWorkspacePrompt(importing: $importing)
    }

    /// Floating glass controls: views, section, measuring, machine display.
    private var controlBar: some View {
        @Bindable var model = model
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    ForEach([OrbitCamera.StandardView.tool, .toolIso, .front, .top, .iso], id: \.self) { view in
                        Button(view.title) { model.setView(view) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.primary)  // plain readable text, not the tinted link colour
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 9)
                            .help(view == .tool ? "Look down the spindle at the face being cut" : "\(view.title) view")
                    }
                Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") {
                    if model.fixturePlacement != nil { model.focusPlacementContext() } else { model.focusWork() }
                }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                    .help(model.fixturePlacement == nil ? "Frame the part and stock" : "Frame the fixture, stock, X-table and spindle")
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 6)
                .glassEffect(.regular.interactive(), in: .capsule)

                GlassToggle(title: "Section", systemImage: "square.split.diagonal", isOn: Binding(
                    get: { model.sectionOn }, set: { model.sectionOn = $0; showSection = $0 }))
                    .popover(isPresented: Binding(get: { model.sectionOn && showSection }, set: { showSection = $0 }), arrowEdge: .top) {
                        SectionControls().padding(16).frame(width: 280)
                    }

                // M is the View menu's (it leaves a text field being typed in alone).
                GlassToggle(title: "Measure", systemImage: "ruler", isOn: $model.measuring)
                    .disabled(model.part == nil || model.fixturePlacement != nil)
                    .help("Measure faces and distances (M)")
            }
            .controlSize(.large)
        }
    }
}

struct SectionControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Section").font(.headline)
            Picker("Cut across", selection: $model.sectionAxis) {
                Text("X (vertical)").tag(AppModel.SectionAxis.x)
                Text("Y").tag(AppModel.SectionAxis.y)
                Text("Z (depth)").tag(AppModel.SectionAxis.z)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Slider(value: $model.sectionOffset, in: -60 ... 60) { Text("Section offset") }
                    .labelsHidden()
                    .accessibilityValue("\(Length.mm(model.sectionOffset)) millimetres")
                Text("\(Length.mm(model.sectionOffset)) mm").monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            Text("The cut face is drawn hatched, like a drawing's cross-section.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Measuring results, floating over the viewport.
struct MeasureHUD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Measure", systemImage: "ruler").font(.headline)
                if model.measurePoints.isEmpty {
                    Text("Click a face to see what it is (flat, cylinder radius, curvature). Click a second point for the distance.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(model.measurePoints.enumerated()), id: \.offset) { i, p in
                    HStack(alignment: .firstTextBaseline) {
                        Text(i == 0 ? "A" : "B").font(.caption.weight(.bold))
                            .frame(width: 18, height: 18).background(Color.white.opacity(0.9), in: Circle())
                            .foregroundStyle(.black)
                        Text(p.info?.summary ?? (model.part?.exact == true ? "Measuring…" : "Point on render mesh"))
                            .font(.callout)
                    }
                }
                if let d = model.measuredDistance, let delta = model.measuredDelta {
                    Divider()
                    Text("\(Length.mm(d)) mm").font(.title2.weight(.semibold).monospacedDigit())
                    Text("ΔX \(Length.mm(abs(delta.x)))  ΔY \(Length.mm(abs(delta.y)))  ΔZ \(Length.mm(abs(delta.z)))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

enum CADFile {
    static let types: [UTType] = [
        UTType(filenameExtension: "step"), UTType(filenameExtension: "stp"),
        UTType(filenameExtension: "iges"), UTType(filenameExtension: "igs"),
        UTType(filenameExtension: "3dm"),
    ].compactMap { $0 }
}


/// The little field a clicked gumball arrow or ring opens: type a distance or an angle.
struct TypedMoveField: View {
    @Environment(AppModel.self) private var model
    let prompt: GumballPrompt
    @State private var value: Double?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(prompt.title).font(.caption).foregroundStyle(.secondary)
            TextField(prompt.unit, value: $value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .focused($focused)
                .onSubmit { model.applyTyped(value ?? 0, prompt) }
            Text(prompt.unit).font(.caption).foregroundStyle(.secondary)
            Button { model.gumballPrompt = nil } label: {
                Label("Close", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .onAppear { focused = true }
        .onExitCommand { model.gumballPrompt = nil }
    }
}

extension AppModel {
    /// Reduce Motion: the 3D camera jumps to a view instead of easing round. Scripted runs keep
    /// the setting they started with.
    func applyReduceMotion() {
        let env = ProcessInfo.processInfo.environment
        guard env["COASTLINE_SCRIPT"] == nil || env["COASTLINE_ANIMATE"] != nil else { return }
        renderer.animationsEnabled = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// An error over the content: selectable text, the whole message on hover, and a close button.
struct ErrorBanner<S: Shape>: View {
    let text: String
    let shape: S
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .lineLimit(4)
                .textSelection(.enabled)
            Button(action: dismiss) {
                Label("Dismiss", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(12)
        .glassEffect(.regular.tint(Theme.danger.opacity(0.3)), in: shape)
        .help(text)
    }
}

/// The empty workspace's prompt: import a part, or the start screen again. It appears after a
/// moment, so a part being opened never flashes it.
struct EmptyWorkspacePrompt: View {
    @Environment(AppModel.self) private var model
    @Binding var importing: Bool
    @State private var shown = false

    var body: some View {
        VStack(spacing: 12) {
            Text("No part open").font(.title3.weight(.semibold))
            Text("STEP, IGES or Rhino (.3dm). Rhino surfaces are imported exactly.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Import Part…", systemImage: "square.and.arrow.down") { importing = true }
                    .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .opacity(shown ? 1 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeOut(duration: 0.25)) { shown = true }
        }
    }
}

/// Shown while edge finding plays with the edge finder: the animation is only the order of
/// the edges; at the machine it's all done by hand.
struct ManualEdgeFindingNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill").font(.title3).foregroundStyle(Theme.warning).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Simulation only: by hand at the machine").font(.callout.weight(.semibold))
                Text("The machine can't feel this stock (not insulated, or against the acetal stop on the bed). In Machine Control, jog the spinning edge finder to each edge until it kicks, then store it. This shows only the order and the edges.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .glassEffect(.regular.tint(Theme.warning.opacity(0.12)), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

