import CoastlineCore
import CryptoKit
import Foundation
import simd

extension AppModel {
    func preparedFixture(_ fixture: Fixture) throws -> Fixture {
        try VettedFixtureLibrary.prepared(fixture, resources: Self.repoRoot.appendingPathComponent("resources"))
    }

    func loadFixtureGeometry(_ fixture: Fixture) async throws -> (LibraryFixtureGeometry, String) {
        guard let path = fixture.modelPath else {
            throw EngineClient.EngineError(type: "Fixture", message: "Choose the assembly's STEP model to place this fixture.")
        }
        let url = fixtureModelURL(path), signature = try fixtureModelSignature(url)
        if let definition = fixture.assembly {
            try definition.validate(state: fixture.planning?.assemblyState ?? .init())
        }
        if libraryFixtureGeometrySignatures[fixture.id] == signature,
           let geometry = libraryFixtureGeometries[fixture.id], geometry.assemblyDefinition == fixture.assembly {
            return (geometry, signature)
        }
        let engine = try await liveEngine(), mesh = try await engine.importPart(url)
        let geometry: LibraryFixtureGeometry
        if let definition = fixture.assembly {
            try definition.validate(state: fixture.planning?.assemblyState ?? .init())
            let parts = try await engine.fixtureAssembly(partID: mesh.partID, definition: definition)
            geometry = try await Task.detached(priority: .userInitiated) {
                try LibraryFixtureGeometry(parts: parts, definition: definition)
            }.value
        } else {
            let solids = try await engine.fixtureSolids(partID: mesh.partID)
            guard !solids.isEmpty, solids.allSatisfy({ solid in
                solid.vertices.count % 3 == 0 && !solid.indices.isEmpty && solid.indices.count % 3 == 0
                    && solid.vertices.allSatisfy(\.isFinite) && solid.normals.count == solid.vertices.count
                    && solid.normals.allSatisfy(\.isFinite) && solid.indices.allSatisfy { Int($0) < solid.vertexCount }
            }) else { throw EngineClient.EngineError(type: "Fixture", message: "The assembly has no usable closed solids.") }
            geometry = await Task.detached(priority: .userInitiated) { LibraryFixtureGeometry(solids: solids) }.value
        }
        guard try signature == fixtureModelSignature(url) else {
            throw EngineClient.EngineError(type: "Fixture", message: "The CAD file changed while loading. Try again.")
        }
        libraryFixtureGeometries[fixture.id] = geometry
        libraryFixtureGeometrySignatures[fixture.id] = signature
        return (geometry, signature)
    }

    var bookendMountTable: BookendSetup.Table? {
        if let geometry = planningGeometry {
            return geometry.bookendMountTable(centreY: travelCentreY)
        }
        guard let model = machineModel else { return nil }
        guard model.tSlotZ.count == 2, let lower = tableGeometry.minimumY, let upper = tableGeometry.maximumY else { return nil }
        guard lower < upper else { return nil }
        return BookendSetup.Table(topX: tableGeometry.topX, slotZ: model.tSlotZ, slotY: lower...upper,
                                 frontZ: tableGeometry.northZ, centreY: travelCentreY)
    }

    func fixtureStateKey(_ fixture: Fixture) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(fixture)) ?? Data(fixture.id.uuidString.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func jobFixtureInventory(_ inventory: Inventory) -> Inventory {
        guard automaticWorkholding else { return inventory.forFixtureSetup(setup) }
        let fitted = automaticFixtures(inventory).fitted
        var result = inventory
        result.fixtures = inventory.fixtures.map { owned in fitted.first { $0.id == owned.id } ?? owned }
        return result
    }

    /// No fixture chosen by hand: Coastline fits every owned fixture with a reviewed mechanism
    /// to the stock, and the plan picks between them for each cut.
    var automaticWorkholding: Bool {
        (setup.planFromFixtureLibrary || setup.holding == nil) && setup.selectedFixtureIDs == nil
    }

    /// Owned fixtures fitted to this job's stock, and why each other one isn't.
    func automaticFixtures(_ inventory: Inventory, stockSize: SIMD3<Double>? = nil) -> (fitted: [Fixture], why: [UUID: String]) {
        guard let stock else { return ([], [:]) }
        // Read the observed load state, so the list refreshes once the machine is in.
        let loaded = machineLoaded && !isSwitchingPlanningMachine
        guard let table = bookendMountTable else {
            if !loaded, !isSwitchingPlanningMachine { Task { await loadMachine() } }
            let why = loaded ? "\(planningMachineTitle) has no measured T-slots for this fixture." : "Loading the machine…"
            return ([], Dictionary(uniqueKeysWithValues: inventory.fixtures.map { ($0.id, why) }))
        }
        let size = stockSize ?? setup.stockSize(stock)
        var fitted: [Fixture] = [], why: [UUID: String] = [:]
        for fixture in inventory.fixtures where fixture.quantity > 0 {
            if let issues = fixture.assembly?.planningIssues, !issues.isEmpty { why[fixture.id] = issues.joined(separator: " "); continue }
            do {
                if let f = try FixtureMechanism.automatic(fixture, table: table, stock: size) { fitted.append(f) }
                else { why[fixture.id] = fixture.modelPath == nil ? "No model in the library." : "Not set up to fit itself yet. Place it by hand." }
            } catch { why[fixture.id] = error.localizedDescription }
        }
        return (fitted, why)
    }

    var automaticPreviewFixtures: [Fixture] { automaticFixtures(inventoryLookup()).fitted }

    func mechanism(for fixture: Fixture, stock size: SIMD3<Double>? = nil) throws -> FixtureMechanism? {
        guard FixtureMechanism.has(fixture.assembly) else { return nil }
        guard let stock = size ?? placementStockSize else { throw BookendSetup.PlacementError.invalid("Choose the stock block for this job first.") }
        guard !isSwitchingPlanningMachine else { throw BookendSetup.PlacementError.invalid("Loading \(planningMachineTitle)…") }
        guard let table = bookendMountTable else {
            throw BookendSetup.PlacementError.invalid(planningMachineReference.isLegacy
                ? "This job still uses an older machine definition without table mounting data. Apply your machine profile below."
                : "\(planningMachineTitle) does not provide the measured table this fixture needs.")
        }
        return try FixtureMechanism.make(fixture, table: table, stock: stock)
    }

    /// A single in-context action can apply the profile the user was inspecting.
    /// Inspecting it alone never replaces an existing job's saved machine identity.
    var suggestedPlacementMachine: MachineDefinitionPackage? {
        guard placingBookends, bookendMountTable == nil, let package = machineProfiles.selected,
              package.definition != planningMachineReference.definition else { return nil }
        return package
    }

    /// Back to automatic workholding: forget the fixtures placed by hand for this job.
    func useAutomaticWorkholding() {
        var updated = setup
        updated.selectedFixtureIDs = nil
        updated.fixtureAssemblies = nil
        setup = updated
        clearToolpathResults()
        layoutScene()
    }

    func removeJobFixture(_ id: UUID) {
        guard let selected = setup.selectedFixtureIDs else { return }
        var updated = setup
        updated.selectedFixtureIDs = selected.filter { $0 != id }
        updated.fixtureAssemblies?.removeAll { $0.id == id }
        setup = updated
        clearToolpathResults()
    }
}
