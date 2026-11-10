import AppKit
import CoastlineCore
import SwiftUI
import Viewport

/// Inspect a portable machine definition before it is accepted for planning or control.
struct MachineProfilesPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var library: MachineProfileLibrary { app.machineProfiles }
    @State private var preview = MachineProfilePreview()
    @State private var tab = DetailTab.motion
    @State private var loadError: String?
    @State private var loadGeneration = UUID()
    @State private var showCurrentMachine = false

    private enum DetailTab: String, CaseIterable, Identifiable {
        case motion = "Setup", definition = "Definition"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let package = library.selected {
                previewBar
                ZStack {
                    if let renderer = preview.renderer {
                        ViewportContainer(renderer: renderer)
                            .accessibilityLabel("Digital model of \(package.definition.name). \(preview.isReferencePose ? "Reference pose" : "Digital axis position").\(preview.showReferenceStock && package.definition.referenceStock != nil ? " Reference stock is visible." : "")")
                            .accessibilityHint("Drag to orbit or use the View menu. Axis controls are in the Setup inspector.")
                    } else if let error = preview.problem ?? loadError {
                        ContentUnavailableView {
                            Label("Couldn't Load Model", systemImage: "cube")
                        } description: { Text(error) } actions: {
                            Button("Try Again") { Task { await loadSelected() } }
                        }
                    } else {
                        ProgressView("Loading machine model…").controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.windowBackground)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { preview.resize($0) }
                footer
            } else if library.loading {
                ProgressView("Reading profiles…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Machine Profiles", systemImage: "gearshape.2")
                } description: {
                    Text(library.libraryIssues.first ?? "Import a machine profile folder to inspect its model, axes and mounting interfaces.")
                } actions: {
                    Button("Import Profile…") { library.importInteractively() }
                    Button("Reload") { Task { await library.reload() } }
                }
            }
        }
        .navigationTitle("Machine Profiles")
        .inspector(isPresented: Bindable(app).showInspector) {
            inspector
                .panelEdge(.leading)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .task { await library.reload() }
        .task(id: "\(library.selectedKey ?? "none"):\(library.reloadRevision)") { await loadSelected() }
        .onDisappear { loadGeneration = UUID(); preview.reset() }
        .onChange(of: reduceMotion) { preview.renderer?.animationsEnabled = !reduceMotion }
        .onChange(of: app.realistic) { preview.renderer?.realistic = app.realistic }
        .alert("Couldn't Select Machine", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK") { app.errorMessage = nil }
        } message: { Text(app.errorMessage ?? "") }
        .alert("Couldn't Import Machine Profile", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
        .sheet(isPresented: $showCurrentMachine) {
            VStack(spacing: 0) {
                HStack {
                    Text("Current Machine & Maintenance").font(.headline)
                    Spacer()
                    Button("Done") { showCurrentMachine = false }.keyboardShortcut(.cancelAction)
                }.padding()
                Divider()
                MachineView(machine: app.controlMachine)
            }
            .frame(minWidth: 600, idealWidth: 680, minHeight: 500, idealHeight: 640)
        }
    }

    private var header: some View {
        @Bindable var library = library
        return HStack(spacing: 12) {
            if !library.packages.isEmpty {
                Picker("Profile", selection: $library.selectedKey) {
                    ForEach(library.packages, id: \.definition.reference) { package in
                        Text("\(package.definition.name) · r\(package.definition.revision)")
                            .tag(Optional(MachineProfileLibrary.key(package)))
                    }
                }
                .frame(maxWidth: 330)
                .disabled(library.loading)
            }
            Spacer(minLength: 0)
            if let package = library.selected {
                let selected = app.planningMachineReference.definition == package.definition
                Button(selected ? "Used for Job" : "Use for Job", systemImage: selected ? "checkmark" : "checkmark.circle") {
                    Task {
                        do { await app.selectPlanningMachine(try PlanningMachineReference(definition: package.definition)) }
                        catch { app.errorMessage = error.localizedDescription }
                    }
                }
                .disabled(selected || library.loading || !app.canChangePlanningMachine)
                .help("Use this machine for the current job and new jobs. Generated toolpaths will be cleared.")
            }
            Button("Import Profile…", systemImage: "square.and.arrow.down") { library.importInteractively() }
                .disabled(library.loading)
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Reload Profiles") { Task { await library.reload() } }
                    .disabled(library.loading)
                if let package = library.selected {
                    Button("Show Profile Files") { NSWorkspace.shared.activateFileViewerSelecting([package.rootURL]) }
                }
                Divider()
                Button("Current Machine & Maintenance…") { showCurrentMachine = true }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
        .padding(12)
        .background(Theme.panelBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var previewBar: some View {
        @Bindable var preview = preview
        return HStack(spacing: 10) {
            Button("Reference Pose") { preview.showReference() }
                .help("Show the CAD model exactly as exported, which may lie outside operating travel")
            Button("Show Home", systemImage: "house") { preview.showHome() }
                .help("Preview the profile's home position without moving a physical machine")
            Spacer(minLength: 0)
            Menu("View", systemImage: "cube") {
                Button("Isometric") { preview.setView(.iso) }
                Button("Front") { preview.setView(.front) }
                Button("Top") { preview.setView(.top) }
                Button("Right") { preview.setView(.right) }
                Divider()
                Toggle("Reference Stock", isOn: $preview.showReferenceStock)
                    .disabled(library.selected?.definition.referenceStock == nil)
                Toggle("Enclosure", isOn: $preview.showEnclosure)
                Toggle("Moving Parts Only", isOn: $preview.movingOnly)
                Toggle("Frames & T-slots", isOn: $preview.showInterfaces)
            }.menuStyle(.borderlessButton).fixedSize()
            Button("Fit Machine", systemImage: "viewfinder") { preview.frame(animated: !reduceMotion) }
                .labelStyle(.iconOnly).help("Fit machine in the view")
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .disabled(preview.renderer == nil)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label("Digital setup", systemImage: "cube.transparent")
            Text(preview.isReferencePose ? "CAD reference pose" : "Digital axis position")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.panelBackground)
        .overlay(alignment: .top) { Divider() }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Profile details", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            if let definition = library.selected?.definition {
                HStack(spacing: 6) {
                    Label("Planning profile", systemImage: "cube.transparent")
                    Spacer(minLength: 0)
                    Text(app.planningMachineReference.definition == definition ? "In this job" : "Available")
                    InfoTip(text: "Use for Job applies this machine's model and limits to workspace setup and CAM planning. Physical control is commissioned separately.")
                        .accessibilityLabel("About profile status")
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 8)
                Form {
                    switch tab {
                    case .motion: motionSections(definition)
                    case .definition: definitionSections(definition)
                    }
                }
                .formStyle(.grouped).darkPanel()
                .scrollEdgeEffectStyle(.soft, for: .all)
            } else { Spacer() }
        }
    }

    @ViewBuilder
    private func motionSections(_ definition: MachineDefinition) -> some View {
        if let stock = definition.referenceStock {
            Section {
                Toggle(isOn: Bindable(preview).showReferenceStock) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reference stock")
                        Text("\(Length.mm(stock.size.x)) × \(Length.mm(stock.size.y)) × \(Length.mm(stock.size.z)) mm")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Show reference stock")
                .accessibilityHint("\(Length.mm(stock.size.x)) by \(Length.mm(stock.size.y)) by \(Length.mm(stock.size.z)) millimeters.")
                .help("An asymmetric test block for checking table seating and orientation.")
            }
        }
        Section {
            ForEach(MachineCoordinate.allCases, id: \.self) { coordinate in
                axisControl(coordinate)
            }
        } header: {
            HStack {
                Text("Axes · mm")
                InfoTip(text: "Moves the digital model within its axis limits. No physical motion or live collision checking.")
                    .accessibilityLabel("About digital axis motion")
            }
        } footer: {
            if preview.isReferencePose {
                Text("Choose Show Home to move the axes.")
            }
        }
    }

    private func axisControl(_ coordinate: MachineCoordinate) -> some View {
        let range = preview.range(coordinate)
        let title = coordinate.rawValue.uppercased()
        return HStack(spacing: 6) {
            Text(title).font(.headline).frame(width: 14, alignment: .leading)
            Button("Decrease \(title)", systemImage: "minus") {
                preview.set(coordinate, to: preview.position[coordinate] - 1)
            }
            .labelStyle(.iconOnly).frame(minWidth: 24, minHeight: 24)
            .help("Move the digital \(title) axis by −1 mm")
            Slider(value: Binding(get: { min(max(preview.position[coordinate], range.lowerBound), range.upperBound) },
                                  set: { preview.set(coordinate, to: $0) }), in: range) {
                Text("\(title) preview position")
            }
            .labelsHidden()
            .accessibilityLabel("\(title) preview position")
            .accessibilityValue(preview.isReferencePose ? "Reference pose" : "\(String(format: "%.2f", preview.position[coordinate])) millimeters")
            .help(String(format: "\(title): %.2f to %.2f mm", range.lowerBound, range.upperBound))
            Button("Increase \(title)", systemImage: "plus") {
                preview.set(coordinate, to: preview.position[coordinate] + 1)
            }
            .labelStyle(.iconOnly).frame(minWidth: 24, minHeight: 24)
            .help("Move the digital \(title) axis by 1 mm")
            Text(preview.isReferencePose ? "—" : String(format: "%.2f", preview.position[coordinate]))
                .monospacedDigit().frame(minWidth: 54, alignment: .trailing)
        }
        .controlSize(.small)
        .disabled(preview.isReferencePose || preview.renderer == nil)
    }

    @ViewBuilder
    private func definitionSections(_ definition: MachineDefinition) -> some View {
        Section("Identity") {
            LabeledContent("Name", value: definition.name)
            LabeledContent("Revision", value: "\(definition.revision)")
            LabeledContent("ID", value: definition.id)
            if let manufacturer = definition.manufacturer { LabeledContent("Manufacturer", value: manufacturer) }
            LabeledContent("Process", value: "Three-axis milling")
            LabeledContent("Controller", value: definition.controller.uppercased())
        }
        Section("Spindle & tooling") {
            LabeledContent("Usable speed", value: String(format: "%.0f–%.0f RPM", definition.profile.spindleRPM.lowerBound, definition.profile.spindleRPM.upperBound))
            LabeledContent("Collet", value: definition.profile.colletName)
            LabeledContent("Shank limit", value: "\(Length.mm(definition.profile.maxShankDiameter)) mm")
            LabeledContent("Tool length limit", value: "\(Length.mm(definition.profile.maxToolLength)) mm")
        }
        Section("Reference frames · mm") {
            ForEach(definition.frames.filter { $0.id != "view" }, id: \.id) { frame in
                VStack(alignment: .leading, spacing: 3) {
                    Text(frame.id.capitalized).font(.callout.weight(.medium))
                    Text(String(format: "%.3f, %.3f, %.3f", frame.origin.x, frame.origin.y, frame.origin.z))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Attached to \(frame.componentID)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section("Mounting interfaces") {
            ForEach(definition.mountingInterfaces, id: \.id) { mount in
                LabeledContent(mount.id, value: "\(mount.slots.count) T-slots")
                ForEach(mount.slots, id: \.id) { slot in
                    LabeledContent(slot.id, value: "\(Length.mm(slot.length)) × \(Length.mm(slot.openingWidth)) mm")
                }
            }
        }
        Section {
            DisclosureGroup("Assemblies") {
                ForEach(definition.components, id: \.id) { component in
                    LabeledContent(component.id, value: component.parentID.map { "Moves with \($0)" } ?? "Machine root")
                }
            }
            DisclosureGroup("Axis limits · mm") {
                ForEach(MachineCoordinate.allCases, id: \.self) { coordinate in
                    let range = preview.range(coordinate)
                    LabeledContent(coordinate.rawValue.uppercased(),
                                   value: String(format: "%.2f … %.2f", range.lowerBound, range.upperBound))
                }
            }
        }
    }

    private func loadSelected() async {
        guard !Task.isCancelled else { return }
        let request = UUID(), revision = library.reloadRevision
        loadGeneration = request
        preview.reset()
        loadError = nil
        guard let package = library.selected else { return }
        do {
            let engine = try await app.liveEngine()
            try Task.checkCancellation()
            guard loadGeneration == request, library.reloadRevision == revision,
                  library.selected?.manifestURL == package.manifestURL else { return }
            await preview.load(package, engine: engine, device: app.renderer.device,
                               realistic: app.realistic, reduceMotion: reduceMotion)
        } catch is CancellationError {
            // A newer selection owns the preview and error state.
        } catch {
            if !Task.isCancelled, loadGeneration == request, library.reloadRevision == revision,
               library.selected?.manifestURL == package.manifestURL { loadError = error.localizedDescription }
        }
    }
}
