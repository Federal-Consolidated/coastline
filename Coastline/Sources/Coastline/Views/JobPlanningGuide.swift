import CoastlineCore
import SwiftUI

struct OwnedStockSuggestions: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        let choices = model.guidedStock(in: inventory.inventory)
        Section {
            if choices.isEmpty {
                Text("No owned blank currently fits the part. Add the stock you have below, or choose a different orientation in Setups.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(choices.prefix(3).enumerated()), id: \.element.id) { index, item in
                Button { model.useGuidedStock(item, inventory: inventory.inventory) } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(item.material?.name ?? "Stock") · \(item.sizeDescription)")
                                .font(.callout.weight(.medium))
                            let count = model.matchingFixtureCount(for: item, inventory: inventory.inventory)
                            Text(count > 0 ? "\(count) workholding option matches this stock"
                                 : "Fits the part · choose workholding next")
                                .font(.caption).foregroundStyle(.secondary)
                            if index == 0 { Text("Recommended from your library").font(.caption).foregroundStyle(Theme.accent) }
                        }
                        Spacer(minLength: 6)
                        Image(systemName: model.stockID == item.id ? "checkmark.circle.fill" : "circle")
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(model.stockID == item.id ? .isSelected : [])
            }
        } header: { Text("From your stock library") }
    }
}

/// Plan: what the part needs from your tools and stock (Machinability, shown on the part in
/// the workspace), then the toolpaths and the setups that come out of them.
struct JobPlanInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        Form {
            Section("The job") {
                LabeledContent("Part", value: model.part?.fileName ?? "No part")
                LabeledContent("Stock", value: model.stock.map { "\($0.material?.name ?? "Stock") · \($0.sizeDescription)" } ?? "Choose stock")
                LabeledContent("Workholding") {
                    Button(workholdingName) { model.enter(.setups) }
                        .buttonStyle(.link)
                        .help("Change the workholding in Setups")
                }
                LabeledContent("Usable tools", value: "\(OperationPlanner.usableTools(inventory.inventory, machine: model.machine).count)")
            }
            MachinabilitySection(numbered: true)
            if let coverage = model.planCoverage { PlanCoverageSection(coverage: coverage) }
            if !model.planOptions.isEmpty {
                Section("Machining alternatives") {
                    if let chosen = model.chosenPlan { LabeledContent("Current proposal", value: chosen) }
                    DisclosureGroup("Compare time, finish and tools") { PlanOptionsView() }
                }
            }
            if model.setup.planFromFixtureLibrary, model.libraryWorkholdingPlan != nil {
                LibraryWorkholdingSection()
            }
            if let error = model.errorMessage {
                Section("Planning needs attention") { Text(error).font(.caption).textSelection(.enabled) }
            }
            Section {
                Button("Manage Cutting Tools…", systemImage: "wrench.and.screwdriver") { model.page = .tools }
                Button("Check Collets…", systemImage: "shippingbox") { model.page = .accessories }
            }
        }
        .formStyle(.grouped).darkPanel()
        .safeAreaInset(edge: .bottom, spacing: 0) { planningAction }
    }

    private var workholdingName: String {
        if model.automaticWorkholding {
            let names = model.automaticFixtures(inventory.inventory).fitted.map(\.name)
            return names.isEmpty ? "None fits; choose in Setups" : "Automatic: " + names.joined(separator: ", ")
        }
        if model.setup.planFromFixtureLibrary || model.setup.holding == nil {
            let names = (model.setup.fixtureAssemblies ?? []).filter { model.setup.selectedFixtureIDs?.contains($0.id) == true }.map(\.name)
            return names.isEmpty ? "Choose in Setups" : names.joined(separator: ", ")
        }
        return model.setup.holding == .custom ? model.setup.customFixture.name : "Fixture library"
    }

    private var planningAction: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isPlanningJob {
                ProgressView(model.status).controlSize(.small)
                if model.isGenerating { Button("Cancel") { model.cancelGenerationNow() }.controlSize(.small) }
            } else {
                let blocker = model.libraryPlanningBlocker(in: inventory.inventory)
                let build = Button {
                    Task { await model.proposeJob(inventory: inventory.inventory) }
                } label: {
                    Label(model.programs.isEmpty ? "Build Toolpaths" : "Rebuild Toolpaths", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(blocker != nil || model.isGenerating || model.isFindingPlans)
                // Once built, Inspect Toolpaths is the step forward; rebuilding is secondary.
                if model.programs.isEmpty { build.buttonStyle(.glassProminent) } else { build.buttonStyle(.glass) }
                if let blocker {
                    HStack(alignment: .firstTextBaseline) {
                        Text(blocker).font(.caption).foregroundStyle(.secondary)
                        if blocker.contains("Setups") {
                            Button("Go to Setups") { model.enter(.setups) }.controlSize(.small)
                        }
                    }
                }
                if !model.programs.isEmpty {
                    let needsReview = model.setup.planFromFixtureLibrary && model.libraryWorkholdingPlan?.reviewed != true
                    Button { model.enter(.machining) } label: {
                        Label("Inspect Toolpaths", systemImage: "chevron.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(needsReview)
                    if needsReview { Text("Review each setup above first.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
}

/// How the stock is held: library fixtures (cards that open in the workspace) or a manual method.
struct WorkholdingChoiceSection: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    @State private var manualDetails = false
    @State private var importingFixture = false

    private var fromLibrary: Bool { model.setup.planFromFixtureLibrary || model.setup.holding == nil }

    var body: some View {
        Section("Workholding") {
            if fromLibrary {
                let accessories: Set<Fixture.Kind> = [.tSlotNuts, .riser, .squaringStop, .squaringBoss, .softJaws]
                let fixtures = inventory.inventory.fixtures.filter { $0.quantity > 0 && !accessories.contains($0.kind) }
                if fixtures.isEmpty {
                    Text("Add workholding from your library to preview it around this stock.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let automatic = model.automaticWorkholding ? model.automaticFixtures(inventory.inventory) : nil
                if automatic != nil {
                    Text("Coastline fits these to the stock and picks one for each cut. Click one to place it by hand.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.setup.planFromFixtureLibrary {
                    Button("Choose Automatically", systemImage: "wand.and.stars") { model.useAutomaticWorkholding() }
                }
                ForEach(fixtures) { fixture in fixtureRow(fixture, automatic: automatic) }
                Button("Add Workholding…", systemImage: "plus") { importingFixture = true }
            } else {
                LabeledContent("Method", value: model.setup.holding == .custom ? model.setup.customFixture.name : "Fixture library")
                Button("Choose from Library", systemImage: "square.grid.2x2") { model.enableLibraryPlanning() }
                Button("Fixture Placement and Grip…") { manualDetails = true }
            }
        }
        .sheet(isPresented: $manualDetails) {
            VStack(spacing: 0) {
                if model.setup.holding == .custom { CustomHoldingInspector() }
                else { SetupInspector(scope: .setups) }
                HStack { Spacer(); Button("Done") { manualDetails = false } }.padding()
            }.frame(width: 500, height: 700)
        }
        .fileImporter(isPresented: $importingFixture, allowedContentTypes: FixtureModelImport.types) { result in
            do {
                let url = try result.get()
                var fixture = Fixture(name: url.deletingPathExtension().lastPathComponent, kind: .jigPlate)
                fixture.modelPath = try FixtureModelImport.store(url)
                inventory.add(fixture, to: \.fixtures)
                chooseWorkholding(fixture)
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func fixtureRow(_ fixture: Fixture, automatic: (fitted: [Fixture], why: [UUID: String])? = nil) -> some View {
        let current = model.setup.fixtureAssemblies?.first { $0.id == fixture.id } ?? fixture
        let fits = automatic?.fitted.contains { $0.id == fixture.id } == true
        let selected = model.setup.selectedFixtureIDs?.contains(current.id) == true || fits
        let needsAssembly = current.assembly?.isAssembled == false
        let detail = automatic.map { a in fits ? "Fits this stock" : a.why[fixture.id] ?? "Doesn't fit this stock" }
        return Button { chooseWorkholding(current) } label: {
            HStack(spacing: 12) {
                FixtureThumbnail(fixture: current)
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.name).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(detail ?? (current.modelPath == nil ? "No model in the library" : needsAssembly ? "Needs an assembled model" : selected ? "Selected for this job" : "Preview on stock"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                    .font(.callout).foregroundStyle(.secondary)
            }.contentShape(Rectangle()).padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .disabled(current.modelPath == nil || needsAssembly || model.stock == nil || model.isPlanningJob || model.isGenerating)
        .accessibilityLabel("Set up \(current.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if selected { Button("Remove from Job", role: .destructive) { model.removeJobFixture(current.id) } }
        }
        .help(current.modelPath == nil ? "Add this fixture's model in the Fixtures library" : "Preview this workholding around the current stock")
    }

    private func chooseWorkholding(_ fixture: Fixture) {
        Task { await model.beginFixturePlacement(fixture) }
    }
}

/// Setups: how the stock is held, which way the part faces, where it sits and work zero. Plan
/// follows and checks its cuts against these.
struct JobSetupsInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            WorkholdingChoiceSection()
            Section("Part orientation and access") {
                Picker("First face toward spindle", selection: $model.setup.facing) {
                    ForEach(Setup.Facing.allCases, id: \.self) { Text("Part \($0.title)").tag($0) }
                }
                Picker("Turn around spindle", selection: $model.setup.spin) {
                    ForEach(0..<4) { Text("\($0 * 90)°").tag($0) }
                }
                Toggle("Machine both sides", isOn: Binding(get: { model.twoSided }, set: {
                    model.twoSided = $0; model.twoSidedChosen = true
                }))
                Text("Plan shows what each orientation can reach. Changing it clears the toolpaths.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            PlacementSection()
            if model.part != nil && model.stock != nil {
                IssuesSection(issues: model.stockContainmentIssues)
            }
        }
        .formStyle(.grouped).darkPanel()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Button { model.enter(.planning) } label: {
                    Label("Continue to Plan", systemImage: "chevron.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(!model.canVisit(.planning))
                if model.status(.setups).state == .todo {
                    Text(model.status(.setups).why).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
        }
    }
}
