import CoastlineCore
import SwiftUI
import simd

/// Workholding is adjusted in the existing workspace, with only job-specific controls here.
struct FixturePlacementInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    @State private var step = 1.0

    private var readyToUse: Bool {
        guard let session = model.fixturePlacement, !session.loading, session.error == nil,
              let profile = session.fixture.planning, profile.definitionIssues.isEmpty,
              session.fixture.assembly?.planningIssues.isEmpty != false,
              model.fixturePlacementGeometry != nil else { return false }
        if model.placingBookends {
            guard let solver = model.placementBookendSolver else { return false }
            return solver.planningIssues(profile).isEmpty
        }
        if model.placingMechanism {
            guard let mechanism = model.placementMechanism else { return false }
            return mechanism.planningIssues(profile).isEmpty
        }
        return true
    }

    var body: some View {
        if let session = model.fixturePlacement {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(session.fixture.name).font(.headline)
                        Spacer()
                        Button("Fit Setup", systemImage: "arrow.up.left.and.arrow.down.right") { model.focusPlacementContext() }
                            .labelStyle(.iconOnly).controlSize(.small).help("Fit workholding and stock in view")
                    }
                    PlanningMachinePicker().font(.caption).controlSize(.small)
                    if let stock = model.stock {
                        Text("\(stock.material?.name ?? "Stock") · \(stock.sizeDescription)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(16)
                Divider()
                Form {
                    if let error = session.error {
                        Section {
                            Text(error).font(.caption).foregroundStyle(Theme.warning)
                            if let package = model.suggestedPlacementMachine {
                                Button("Use \(package.definition.name) for This Job") {
                                    Task {
                                        do { await model.selectPlanningMachine(try PlanningMachineReference(definition: package.definition)) }
                                        catch { model.fixturePlacement?.error = error.localizedDescription }
                                    }
                                }.disabled(model.isSwitchingPlanningMachine)
                            }
                        }
                    }
                    if session.loading || model.isSwitchingPlanningMachine {
                        Section { ProgressView("Preparing workholding…").controlSize(.small) }
                    } else if model.fixturePlacementGeometry != nil {
                        if model.placingBookends { BookendPlacementControls() }
                        else if model.placingMechanism { MechanismPlacementControls() }
                        else { manualPlacementControls }
                        FixtureGripReview()
                    }
                }.formStyle(.grouped).darkPanel().frame(minHeight: 0, maxHeight: .infinity)
                Divider()
                HStack {
                    Button("Cancel") { model.finishFixturePlacement(save: false, inventory: inventory) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Use Workholding") { model.finishFixturePlacement(save: true, inventory: inventory) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent).disabled(!readyToUse)
                }.padding(16)
            }
        }
    }

    @ViewBuilder private var manualPlacementControls: some View {
        Section {
            DisclosureGroup("Adjust placement") {
                if let geometry = model.fixturePlacementGeometry {
                    Picker("Move", selection: Binding(get: { model.fixturePlacement?.selectedComponent ?? "" }, set: {
                        model.selectPlacementComponent($0.isEmpty ? nil : $0)
                    })) {
                        Text("Whole assembly").tag("")
                        ForEach(Array(geometry.components.enumerated()), id: \.element.id) { i, component in
                            Text(component.name.isEmpty ? "Piece \(i + 1)" : component.name).tag(component.id)
                        }
                    }
                    if geometry.components.count == 2 {
                        Button("Fit to Stock Ends", systemImage: "arrow.left.and.right") { model.alignPlacementPair() }
                    } else {
                        Button("Centre on Stock", systemImage: "scope") { model.centrePlacementOnStock() }
                    }
                }
                Toggle("Snap to stock", isOn: Binding(get: { model.fixturePlacement?.snapEnabled ?? true }, set: { model.setPlacementSnapping($0) }))
                Button("Snap Selected Piece", systemImage: "scope") { model.snapPlacementToStock() }
                Picker("Move by", selection: $step) {
                    Text("0.5 mm").tag(0.5); Text("1 mm").tag(1.0); Text("5 mm").tag(5.0); Text("10 mm").tag(10.0)
                }
                movement("Up / down", axis: 0)
                movement("Left / right", axis: 1)
                movement("Toward / away from spindle", axis: 2)
                rotation("Lay on its side", axis: 2)
                rotation("Tip forward / back", axis: 1)
                rotation("Swivel", axis: 0)
                NumberField(title: "Stock above table", value: Binding(get: { model.fixturePlacement?.fixture.height ?? 0 }, set: { height in
                    guard var fixture = model.fixturePlacement?.fixture else { return }
                    fixture.height = height; fixture.planning?.gripDefinitionReviewed = false
                    model.updatePlacementFixture(fixture)
                }))
            }
        }
    }

    private func rotation(_ title: String, axis: Int) -> some View {
        HStack {
            Text(title).font(.callout); Spacer()
            Button { model.rotatePlacement(axis: axis, turns: -1) } label: { Label("−90°", systemImage: "rotate.left") }
                .accessibilityLabel("\(title), minus 90 degrees")
            Button { model.rotatePlacement(axis: axis, turns: 1) } label: { Label("+90°", systemImage: "rotate.right") }
                .accessibilityLabel("\(title), plus 90 degrees")
        }.controlSize(.small)
    }
    private func movement(_ title: String, axis: Int) -> some View {
        HStack {
            Text(title).font(.callout); Spacer()
            Button("−") { move(axis, -step) }.accessibilityLabel("\(title), minus \(step) millimetres")
            Button("+") { move(axis, step) }.accessibilityLabel("\(title), plus \(step) millimetres")
        }.controlSize(.small)
    }
    private func move(_ axis: Int, _ distance: Double) {
        var delta = SIMD3<Double>(repeating: 0); delta[axis] = distance
        model.movePlacement(delta)
    }
}

struct FixturePlacementBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let session = model.fixturePlacement {
            GlassCard {
                VStack(alignment: .leading, spacing: 4) {
                    Label(session.fixture.name, systemImage: "hand.draw").font(.callout.weight(.semibold))
                    if session.pickingGrip {
                        Text("Click the stock to mark a contact area.").font(.caption).foregroundStyle(.secondary)
                    } else if !session.snapLocks.isEmpty {
                        Label("Snapped · " + session.snapLocks.map(\.label).joined(separator: " · "), systemImage: "scope")
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }
}

/// Side-screw adjustment is immediately available; repositioning bases is optional.
private struct BookendPlacementControls: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let solver = model.placementBookendSolver, let p = model.fixturePlacement?.fixture.planning {
            Section("Side screw") {
                let extensionMM = solver.value(p, jointID: BookendSetup.pressureExtension)
                let range = (try? solver.pressureRange(p)) ?? 0...0
                let quarterTurn = (solver.assembly.components.first { $0.id == BookendSetup.pressure }?.joint?.pitch ?? 0.8) / 4
                LabeledContent("Contact", value: solver.gap(p) < 0.01 ? "Against stock" : solver.gap(p).formatted(.number.precision(.fractionLength(2))) + " mm gap")
                    .monospacedDigit()
                HStack {
                    Button { model.setBookendPressure(extensionMM - quarterTurn) } label: { Image(systemName: "minus") }
                        .accessibilityLabel("Release side screw one quarter turn")
                    Slider(value: Binding(get: { extensionMM }, set: { model.setBookendPressure($0) }), in: range.lowerBound...max(range.lowerBound + 0.001, range.upperBound))
                        .accessibilityLabel("Side screw extension in millimetres")
                        .disabled(range.upperBound <= range.lowerBound)
                    Button { model.setBookendPressure(extensionMM + quarterTurn) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Advance side screw one quarter turn")
                }.controlSize(.small)
                HStack {
                    Button("Release") { model.setBookendPressure(range.lowerBound) }
                    Button("Tighten to Stock") { model.setBookendPressure(range.upperBound) }
                    Spacer()
                }.controlSize(.small)
            }
            Section {
                DisclosureGroup("Adjust placement") {
                    Button("Refit to Stock", systemImage: "scope") { model.seatPlacementBookends() }
                    Picker("Selected", selection: Binding(get: { model.fixturePlacement?.selectedComponent ?? BookendSetup.pressure }, set: { model.selectPlacementComponent($0) })) {
                        Text("Fixed base").tag(BookendSetup.fixed)
                        Text("Clamp base").tag(BookendSetup.clamp)
                        Text("Side screw").tag(BookendSetup.pressure)
                    }
                    baseRow("Fixed base", id: BookendSetup.fixed, joint: BookendSetup.fixedSlide, solver: solver, profile: p)
                    baseRow("Clamp base", id: BookendSetup.clamp, joint: BookendSetup.clampSlide, solver: solver, profile: p)
                    Text("Unlock a base to slide it along the T-slots.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func baseRow(_ title: String, id: String, joint: String, solver: BookendSetup, profile p: FixturePlanningProfile) -> some View {
        let locked = p.assemblyState?.lockedComponents.contains(id) == true
        return HStack {
            Text(title)
            Spacer()
            Text(solver.value(p, jointID: joint).formatted(.number.precision(.fractionLength(1))) + " mm")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button { model.movePlacement(SIMD3(0, -1, 0), componentID: id, useSelection: false) } label: { Image(systemName: "minus") }
                .accessibilityLabel("Slide \(title.lowercased()) minus 1 millimetre").disabled(locked)
            Button { model.movePlacement(SIMD3(0, 1, 0), componentID: id, useSelection: false) } label: { Image(systemName: "plus") }
                .accessibilityLabel("Slide \(title.lowercased()) plus 1 millimetre").disabled(locked)
            Button { model.setBookendBaseLocked(id, locked: !locked) } label: { Image(systemName: locked ? "lock.fill" : "lock.open") }
                .accessibilityLabel("\(locked ? "Unlock" : "Lock") \(title.lowercased()) position")
                .help(locked ? "Unlock base position" : "Lock base position")
        }.controlSize(.small)
    }
}

/// C-clamps and vises: each screw tightens to the stock; clamps slide along it.
private struct MechanismPlacementControls: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let mechanism = model.placementMechanism, let p = model.fixturePlacement?.fixture.planning {
            let controls = mechanism.controls
            Section("Clamping") {
                ForEach(controls.filter(\.tightens)) { control in row(control, mechanism, p) }
                Button("Refit to Stock", systemImage: "scope") { model.seatPlacementBookends() }.controlSize(.small)
            }
            let slides = controls.filter { !$0.tightens }
            if !slides.isEmpty {
                Section { DisclosureGroup("Adjust placement") { ForEach(slides) { control in row(control, mechanism, p) } } }
            }
        }
    }

    private func row(_ control: FixtureMechanism.Control, _ mechanism: FixtureMechanism, _ p: FixturePlanningProfile) -> some View {
        let value = mechanism.value(p, joint: control.id)
        let range = (try? mechanism.range(p, joint: control.id)) ?? value...value
        let step = control.pitch.map { $0 / 4 } ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(control.title)
                Spacer()
                Text(control.tightens ? (range.upperBound - value < 0.01 ? "Against stock" : (range.upperBound - value).formatted(.number.precision(.fractionLength(1))) + " mm gap")
                     : value.formatted(.number.precision(.fractionLength(1))) + " mm")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Button { model.setPlacementJoint(control.id, to: value - step) } label: { Image(systemName: "minus") }
                    .accessibilityLabel(control.tightens ? "Loosen \(control.title) a quarter turn" : "Move \(control.title) 1 millimetre back")
                Slider(value: Binding(get: { value }, set: { model.setPlacementJoint(control.id, to: $0) }),
                       in: range.lowerBound...max(range.lowerBound + 0.001, range.upperBound))
                    .accessibilityLabel(control.title)
                    .disabled(range.upperBound <= range.lowerBound)
                Button { model.setPlacementJoint(control.id, to: value + step) } label: { Image(systemName: "plus") }
                    .accessibilityLabel(control.tightens ? "Tighten \(control.title) a quarter turn" : "Move \(control.title) 1 millimetre on")
                if control.tightens {
                    Button("Tighten") { model.setPlacementJoint(control.id, to: range.upperBound) }
                }
            }.controlSize(.small)
        }
    }
}

/// This acknowledgement stays explicit; digital contact does not establish grip or load capacity.
private struct FixtureGripReview: View {
    @Environment(AppModel.self) private var model
    private var profile: Binding<FixturePlanningProfile> {
        Binding(get: { model.fixturePlacement?.fixture.planning ?? .init() }, set: { next in
            var next = next
            if var previous = model.fixturePlacement?.fixture.planning {
                previous.gripDefinitionReviewed = false
                var compared = next; compared.gripDefinitionReviewed = false
                if previous != compared { next.gripDefinitionReviewed = false }
            }
            model.setPlacementProfile(next)
        })
    }
    private var mountingIssue: String? {
        guard let p = model.fixturePlacement?.fixture.planning else { return nil }
        if model.placingMechanism { return model.placementMechanism?.planningIssues(p).first }
        guard model.placingBookends, let solver = model.placementBookendSolver else { return nil }
        return solver.planningIssues(p).first
    }
    var body: some View {
        Section("Review") {
            if !model.placingBookends && !model.placingMechanism {
                HStack {
                    Text("\(profile.wrappedValue.contacts.count) contact areas").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.fixturePlacement?.pickingGrip == true ? "Done Marking" : "Mark on Stock") {
                        model.fixturePlacement?.pickingGrip.toggle()
                    }.controlSize(.small)
                }
            }
            Toggle("Suitable for roughing and facing", isOn: profile.allowsRoughing)
            Toggle("I checked the grip and cutting load", isOn: profile.gripDefinitionReviewed)
                .disabled(mountingIssue != nil || profile.wrappedValue.contacts.count < 2)
            if let mountingIssue { Text(mountingIssue).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Contact areas") {
                ForEach(profile.contacts) { contact in
                    VStack(alignment: .leading) {
                        Button("Remove Contact", systemImage: "minus.circle") {
                            var updated = profile.wrappedValue
                            updated.contacts.removeAll { $0.id == contact.wrappedValue.id }
                            profile.wrappedValue = updated
                        }.buttonStyle(.borderless).controlSize(.small)
                        NumberField(title: "Contact X", value: contact.point.x)
                        NumberField(title: "Contact Y", value: contact.point.y)
                        NumberField(title: "Contact Z", value: contact.point.z)
                        NumberField(title: "Radius", value: contact.radius)
                    }
                }
            }
        }
    }
}
