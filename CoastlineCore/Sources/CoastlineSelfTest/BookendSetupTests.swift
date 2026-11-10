import CoastlineCore
import CryptoKit
import Foundation
import simd

private func mountingAssembly() -> FixtureAssemblyDefinition {
    var a = FixtureAssemblyDefinition(id: "bookends", revision: 1, modelSHA256: String(repeating: "a", count: 64), components: [
        .init(id: BookendSetup.fixed, name: "Fixed base", modelEntities: ["0/0"], joint: .init(id: BookendSetup.fixedSlide, kind: .prismatic, axis: Vec3(0, 1, 0), minimum: -1000, maximum: 1000)),
        .init(id: BookendSetup.clamp, name: "Clamp base", modelEntities: ["0/1"], joint: .init(id: BookendSetup.clampSlide, kind: .prismatic, axis: Vec3(0, 1, 0), minimum: -1000, maximum: 1000)),
        .init(id: BookendSetup.pressure, name: "Side screw", parentID: BookendSetup.clamp, modelEntities: ["0/2"], joint: .init(id: BookendSetup.pressureExtension, kind: .screw, axis: Vec3(0, -1, 0), minimum: 0, maximum: 15, referenceValue: 4, pitch: 0.8)),
    ])
    a.bookends = .init(seatX: 15.8651364, slotZ: [78.7585941251, 118.7635941251], fixedContactY: -343, clampContactY: -135.8,
        screwAxisX: 25.3651364, screwAxisZ: 104.4435941251, stockBackZ: 79.0435941251, pressureTipRadius: 2.5,
        fixedNutY: -353.5 ... -342.5, clampNutY: -136.3 ... -125.3)
    return a
}
private func mountingTable(slotY: ClosedRange<Double> = -400 ... -80) -> BookendSetup.Table {
    .init(topX: 15.8651364, slotZ: [78.7585941251, 118.7635941251], slotY: slotY, frontZ: 129.8435941251, centreY: -241.4)
}
private func mountingSolver(stock: SIMD3<Double> = SIMD3(50.8, 203.2, 50.8)) throws -> BookendSetup {
    try .init(assembly: mountingAssembly(), table: mountingTable(), stock: stock)
}
let bookendSetupTests: [TestCase] = [
    TestCase(name: "legacyAuditedDefinitionRebindsWithoutLosingStockOrKeepingApproval") {
        let resources = repoRoot.appendingPathComponent("resources")
        let modelPath = "fixtures/bookends/assembly.step"
        let current = try JSONDecoder().decode(FixtureAssemblyDefinition.self,
            from: Data(contentsOf: resources.appendingPathComponent("fixtures/bookends/definition.json")))
        var raw = try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        var metadata = try unwrap(raw["bookends"] as? [String: Any])
        metadata.removeValue(forKey: "stockBackZ"); metadata.removeValue(forKey: "pressureTipRadius")
        metadata.removeValue(forKey: "contactMetadataComplete"); raw["bookends"] = metadata
        let legacy = try JSONDecoder().decode(FixtureAssemblyDefinition.self, from: JSONSerialization.data(withJSONObject: raw))
        var fixture = Fixture(name: "My Bookends", kind: .other, modelPath: modelPath)
        fixture.assembly = legacy
        var approved = FixturePlanningProfile()
        approved.enabled = true; approved.gripDefinitionReviewed = true; approved.workspacePlaced = true
        approved.componentPlacements = [.init(id: "old-piece")]
        approved.componentLayoutID = "old-layout"; approved.componentModelSignature = "old-signature"
        approved.assemblyState = .init(jointValues: [BookendSetup.fixedSlide: 10], mounted: true,
                                      lockedComponents: [BookendSetup.fixed, BookendSetup.clamp])
        fixture.planning = approved
        let owned = StockItem(materialID: "al-6061", sizeX: 203.2, sizeY: 50.8, sizeZ: 50.8, quantity: 1)
        var inventory = Inventory(); inventory.stock = [owned]; inventory.fixtures = [fixture]

        try expect(VettedFixtureLibrary.migrate(&inventory, resources: resources))
        try expectEqual(inventory.stock, [owned])
        let rebound = inventory.fixtures[0]
        try expectEqual(rebound.id, fixture.id); try expectEqual(rebound.name, fixture.name)
        try expectEqual(rebound.assembly, current)
        try expect(rebound.assembly?.bookends?.contactMetadataComplete == true)
        try expect(rebound.planning?.gripDefinitionReviewed == false && rebound.planning?.workspacePlaced == false)
        try expectEqual(rebound.planning?.assemblyState, FixtureAssemblyState())
        try expect(rebound.planning?.componentPlacements == nil && rebound.planning?.componentLayoutID == nil
                   && rebound.planning?.componentModelSignature == nil)
        let migrated = inventory
        try expect(!VettedFixtureLibrary.migrate(&inventory, resources: resources))
        try expectEqual(inventory, migrated)

        // Matching a name or declared role cannot bless an unknown CAD file.
        let unknownURL = FileManager.default.temporaryDirectory.appendingPathComponent("coastline-unknown-fixture-\(UUID()).step")
        defer { try? FileManager.default.removeItem(at: unknownURL) }
        let unknownData = Data("unreviewed CAD file".utf8)
        try unknownData.write(to: unknownURL)
        var unknown = fixture
        unknown.modelPath = unknownURL.path
        unknown.assembly?.modelSHA256 = SHA256.hash(data: unknownData).map { String(format: "%02x", $0) }.joined()
        inventory.fixtures = [unknown]
        try expect(!VettedFixtureLibrary.migrate(&inventory, resources: resources))
        try expectEqual(inventory.fixtures, [unknown])
        try expectEqual(inventory.stock, [owned])
        try expectThrows { _ = try VettedFixtureLibrary.prepared(unknown, resources: resources) }
    },
    TestCase(name: "legacyContactMetadataPreservesInventoryWithoutInventingGeometry") {
        let owned = StockItem(id: UUID(uuidString: "0DEF6FB0-E68C-4118-BF68-A43D2AA1596F")!, materialID: "al-6061",
                              sizeX: 203.2, sizeY: 50.8, sizeZ: 50.8, quantity: 1)
        var fixture = Fixture(name: "Workholding-Bookends", kind: .other)
        fixture.assembly = mountingAssembly()
        var inventory = Inventory(); inventory.stock = [owned]; inventory.fixtures = [fixture]
        var json = try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(inventory)) as? [String: Any])
        var fixtures = try unwrap(json["fixtures"] as? [[String: Any]])
        var assembly = try unwrap(fixtures[0]["assembly"] as? [String: Any])
        var metadata = try unwrap(assembly["bookends"] as? [String: Any])
        metadata.removeValue(forKey: "stockBackZ")
        metadata.removeValue(forKey: "pressureTipRadius")
        metadata.removeValue(forKey: "contactMetadataComplete")
        assembly["bookends"] = metadata; fixtures[0]["assembly"] = assembly; json["fixtures"] = fixtures
        let loaded = try JSONDecoder().decode(Inventory.self, from: JSONSerialization.data(withJSONObject: json))
        try expectEqual(loaded.stock, [owned], "a fixture metadata upgrade must not hide owned stock")
        let incomplete = try unwrap(loaded.fixtures[0].assembly)
        try expect(incomplete.bookends?.contactMetadataComplete == false)
        try expect(!incomplete.validationIssues.isEmpty)
        try expectThrows { _ = try BookendSetup(assembly: incomplete, table: mountingTable(), stock: SIMD3(50.8, 203.2, 50.8)) }
        // Unknown CAD stays explicitly incomplete even after a save/reload.
        let savedAgain = try JSONDecoder().decode(Inventory.self, from: JSONEncoder().encode(loaded))
        try expectEqual(savedAgain.stock, [owned])
        try expect(savedAgain.fixtures[0].assembly?.bookends?.contactMetadataComplete == false)
        try expectThrows { try savedAgain.fixtures[0].assembly?.validate() }
        // Missing either new dimension independently must remain incomplete.
        metadata["pressureTipRadius"] = 2.5
        assembly["bookends"] = metadata; fixtures[0]["assembly"] = assembly; json["fixtures"] = fixtures
        let missingBack = try JSONDecoder().decode(Inventory.self, from: JSONSerialization.data(withJSONObject: json))
        try expect(missingBack.fixtures[0].assembly?.bookends?.contactMetadataComplete == false)
    },
    TestCase(name: "seatsUsingContactPlanesAndBothMachineSlots") {
        let solver = try mountingSolver(), p = try solver.seat(.init())
        try solver.validate(p)
        try expect(abs(solver.value(p, jointID: BookendSetup.fixedSlide)) < 1e-8)
        try expect(abs(solver.value(p, jointID: BookendSetup.clampSlide)) < 1e-8)
        try expect(abs(solver.gap(p)) < 1e-8)
        try expect(abs(p.datum.x - solver.stock.x / 2 - solver.definition.seatX) < 1e-8)
        for z in solver.definition.slotZ {
            let worldZ = z - p.datum.z + solver.table.frontZ + p.facePastTable
            try expect(solver.table.slotZ.contains { abs($0 - worldZ) < 1e-8 })
        }
        try expect(!p.gripDefinitionReviewed && !p.allowsRoughing)
        try expectEqual(p.contacts.count, 2)
        try expect(!solver.planningIssues(p).isEmpty, "automatic contact must not imply locked mounting")
    },
    TestCase(name: "asymmetricStockRemainsAgainstLocatingLip") {
        let solver = try mountingSolver(stock: SIMD3(37, 120, 37)), p = try solver.seat(.init())
        try expect(abs(p.datum.z - solver.stock.z - solver.definition.stockBackZ) < 1e-8)
        try expect(abs(p.contacts[1].point.z - (solver.definition.screwAxisZ - p.datum.z)) < 1e-8)
        try expect(abs(solver.gap(p)) < 1e-8)
        try expect(abs(solver.value(p, jointID: BookendSetup.fixedSlide) - 41.6) < 1e-8)
        try expect(abs(solver.value(p, jointID: BookendSetup.clampSlide) + 41.6) < 1e-8)
        try expectThrows { _ = try mountingSolver(stock: SIMD3(50.8, 120, 20)) }
        try expectThrows { _ = try mountingSolver(stock: SIMD3(10, 120, 50.8)) }
    },
    TestCase(name: "basesStayInSlotsAndCannotPenetrateStock") {
        let solver = try mountingSolver(), p = try solver.seat(.init())
        let left = try solver.sliding(p, componentID: BookendSetup.fixed, to: -10000)
        let right = try solver.sliding(p, componentID: BookendSetup.clamp, to: 10000)
        for (pose, id, nut, joint) in [(left, BookendSetup.fixed, solver.definition.fixedNutY, BookendSetup.fixedSlide), (right, BookendSetup.clamp, solver.definition.clampNutY, BookendSetup.clampSlide)] {
            try solver.validate(pose)
            let delta = solver.value(pose, jointID: joint) - pose.datum.y + solver.table.centreY
            try expect(nut.lowerBound + delta >= solver.table.slotY.lowerBound - 1e-8)
            try expect(nut.upperBound + delta <= solver.table.slotY.upperBound + 1e-8)
            try expectEqual(try solver.sliding(p, componentID: id, to: id == BookendSetup.fixed ? 1000 : -1000), p)
        }
        let short = try BookendSetup(assembly: mountingAssembly(), table: mountingTable(slotY: -300 ... -180), stock: solver.stock)
        try expectThrows { _ = try short.seat(.init()) }
    },
    TestCase(name: "lockedBasesDoNotPreventScrewReleaseOrStockFlip") {
        let solver = try mountingSolver()
        var p = try solver.seat(.init()); p.assemblyState?.lockedComponents = [BookendSetup.fixed, BookendSetup.clamp]
        p.gripDefinitionReviewed = true
        try expect(solver.planningIssues(p).isEmpty)
        try expectEqual(try solver.sliding(p, componentID: BookendSetup.fixed, to: -10), p)
        let released = try solver.settingPressure(p, to: 0)
        try expect(abs(solver.gap(released) - 4) < 1e-8)
        try expect(!released.gripDefinitionReviewed)
        try expectEqual(released.assemblyState?.lockedComponents, p.assemblyState?.lockedComponents)
        try expectEqual(solver.value(released, jointID: BookendSetup.fixedSlide), solver.value(p, jointID: BookendSetup.fixedSlide))
        let tightened = try solver.settingPressure(released, to: 15)
        try expect(abs(solver.value(tightened, jointID: BookendSetup.pressureExtension) - 4) < 1e-8)
        try expect(abs(solver.gap(tightened)) < 1e-8)
    },
    TestCase(name: "movingClampCarriesScrewButCannotExceedItsStroke") {
        let solver = try mountingSolver(), p = try solver.seat(.init())
        let moved = try solver.sliding(p, componentID: BookendSetup.clamp, to: 20)
        let extended = try solver.settingPressure(moved, to: 100)
        try expectEqual(solver.value(extended, jointID: BookendSetup.pressureExtension), 15)
        try expect(abs(solver.gap(extended) - 9) < 1e-8)
        try expect(!solver.planningIssues(extended).isEmpty)
        try expectThrows { _ = try solver.settingPressure(p, to: .infinity) }
    },
    TestCase(name: "rejectsMismatchedSlotsFreeRotationAndChangedStock") {
        var table = mountingTable(); table.slotZ[1] += 1
        try expectThrows { _ = try BookendSetup(assembly: mountingAssembly(), table: table, stock: SIMD3(50.8, 203.2, 50.8)) }
        let solver = try mountingSolver(), p = try solver.seat(.init())
        var rotated = p; rotated.spin = 1
        try expectThrows { try solver.validate(rotated) }
        var displaced = p; displaced.datum.z += 1
        try expectThrows { try solver.validate(displaced) }
        let smaller = try mountingSolver(stock: SIMD3(50.8, 120, 37))
        try expectThrows { try smaller.validate(p) }
        let loaded = try JSONDecoder().decode(FixtureAssemblyDefinition.self, from: JSONEncoder().encode(mountingAssembly()))
        try expectEqual(loaded, mountingAssembly())
    },
]
