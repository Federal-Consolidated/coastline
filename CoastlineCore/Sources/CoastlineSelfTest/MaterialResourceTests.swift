import CoastlineCore
import Foundation

private func customMaterialResource() -> Material {
    var material = MaterialLibrary.material(id: "al-6061")!
    material.id = "custom-test-alloy"
    material.name = "Shop alloy"
    material.source = "Supplier cutting-data sheet, revision 2"
    return material
}

let materialResourceTests: [TestCase] = [
    TestCase(name: "customizingStockMaterialOnlyChangesTheSelectedStock") {
        let shared = customMaterialResource()
        var inventory = Inventory()
        inventory.customMaterials = [shared]
        let first = inventory.resolvedStock(StockItem(materialID: shared.id, sizeX: 40, sizeY: 30, sizeZ: 10,
                                                      quantity: 3, notes: "Measured blank"))
        let second = inventory.resolvedStock(StockItem(materialID: shared.id, sizeX: 80, sizeY: 40, sizeZ: 20))
        inventory.stock = [first, second]
        inventory.fixtures = [Fixture(name: "Shop vise", kind: .vise)]
        var custom = shared; custom.id = "custom-one-stock"; custom.name = "First blank alloy"; custom.chipLoadFactor = 0.6
        let updated = try inventory.customizingStockMaterial(custom, stockID: first.id, expectedMaterialID: shared.id)
        var expected = inventory
        expected.customMaterials = [shared, custom]
        expected.stock[0].materialID = custom.id; expected.stock[0].materialSnapshot = custom
        try expectEqual(updated, expected, "all unrelated stock, fixtures and material definitions must remain identical")
        try expectEqual(inventory.stock, [first, second], "preparing a transaction must not mutate its source")
        try expectEqual(updated.stock[1].material, shared)
    },
    TestCase(name: "customizingStockMaterialRejectsInvalidStaleOrMissingTargets") {
        var inventory = Inventory()
        let blank = StockItem(materialID: "al-6061", sizeX: 40, sizeY: 30, sizeZ: 10)
        inventory.stock = [blank]
        let original = inventory
        var invalid = customMaterialResource(); invalid.density = 0
        try expectThrows { _ = try inventory.customizingStockMaterial(invalid, stockID: blank.id, expectedMaterialID: blank.materialID) }
        let valid = customMaterialResource()
        try expectThrows { _ = try inventory.customizingStockMaterial(valid, stockID: UUID(), expectedMaterialID: blank.materialID) }
        try expectThrows { _ = try inventory.customizingStockMaterial(valid, stockID: blank.id, expectedMaterialID: "brass-c360") }
        try expectEqual(inventory, original)
        // Duplicate stock identities are ambiguous and cannot select a unique target.
        inventory.stock.append(blank)
        try expectThrows { _ = try inventory.customizingStockMaterial(valid, stockID: blank.id, expectedMaterialID: blank.materialID) }
        try expectEqual(inventory.stock, [blank, blank])
    },
    TestCase(name: "customizingStockMaterialRequiresAnUnusedMaterialIdentity") {
        var inventory = Inventory()
        let shared = customMaterialResource()
        inventory.customMaterials = [shared]
        let target = StockItem(materialID: "al-6061", sizeX: 40, sizeY: 30, sizeZ: 10)
        var embeddedOnly = shared; embeddedOnly.id = "custom-embedded-only"
        inventory.stock = [target, StockItem(materialID: embeddedOnly.id, sizeX: 20, sizeY: 20, sizeZ: 10, materialSnapshot: embeddedOnly)]
        for existing in [MaterialLibrary.material(id: "al-6061")!, shared, embeddedOnly] {
            let before = inventory
            try expectThrows { _ = try inventory.customizingStockMaterial(existing, stockID: target.id, expectedMaterialID: target.materialID) }
            try expectEqual(inventory, before)
        }
    },
    TestCase(name: "customizingStockMaterialPreservesSavedJobsAndExportsItsDependency") {
        let shared = customMaterialResource()
        var inventory = Inventory(); inventory.customMaterials = [shared]
        let original = inventory.resolvedStock(StockItem(materialID: shared.id, sizeX: 40, sizeY: 30, sizeZ: 10))
        inventory.stock = [original]
        let job = JobResourceSnapshot(stock: original)
        var custom = shared; custom.id = "custom-new-cutting-data"; custom.chipLoadFactor = 0.4
        let updated = try inventory.customizingStockMaterial(custom, stockID: original.id, expectedMaterialID: shared.id)
        let reopenedJob = try JSONDecoder().decode(JobResourceSnapshot.self, from: JSONEncoder().encode(job))
        try expectEqual(reopenedJob, job)
        try expectEqual(reopenedJob.stock?.material, shared)
        try expectEqual(updated.stock[0].material, custom)
        let package = try ResourceLibraryPackage.exporting(updated, name: "Selected stock", stockIDs: [original.id],
                                                            toolIDs: [], materialIDs: [])
        let reopenedPackage = try ResourceLibraryImport.parse(package.encoded())
        try expectEqual(reopenedPackage.materials, [custom])
        try expectEqual(reopenedPackage.stock, updated.stock)
        let imported = try ResourceLibraryImport.prepare(reopenedPackage, into: Inventory()).inventory
        try expectEqual(imported.stock[0].material, custom)
    },
    TestCase(name: "catalogIncludesCustomMaterialsWithoutReplacingBuiltins") {
        let custom = customMaterialResource()
        var shadow = custom
        shadow.id = "al-6061"
        shadow.name = "Should not replace the built-in"
        var inventory = Inventory()
        inventory.customMaterials = [custom, shadow, custom]
        try expectEqual(inventory.material(id: custom.id), custom)
        try expectEqual(inventory.material(id: "al-6061"), MaterialLibrary.material(id: "al-6061"))
        try expectEqual(inventory.materials.count, MaterialLibrary.all.count + 1)
        try expectEqual(Set(inventory.materials.map(\.id)).count, inventory.materials.count)
        try expect(!inventory.isEmpty, "A material-only library still contains resources.")
    },
    TestCase(name: "stockSnapshotKeepsCuttingDataAfterLibraryEditAndRemoval") {
        let custom = customMaterialResource()
        var inventory = Inventory()
        inventory.customMaterials = [custom]
        let blank = StockItem(materialID: custom.id, sizeX: 40, sizeY: 30, sizeZ: 10)
        let pinned = inventory.resolvedStock(blank)
        let tool = Tool(name: "Test end mill", kind: .flatEndMill, diameter: 3.175,
                        shankDiameter: 3.175, flutes: 2, fluteLength: 10, stickout: 20, overallLength: 40)
        let originalFeed = FeedsEngine.compute(tool: tool, material: try unwrap(pinned.material), kind: .adaptive).feed
        var edited = custom
        edited.name = "Shop alloy, updated"
        edited.chipLoadFactor = 0.3
        inventory.customMaterials = [edited]
        let updated = inventory.resolvedStock(blank)
        try expectEqual(updated.material, edited)
        try expectEqual(pinned.material, custom)
        try expect(FeedsEngine.compute(tool: tool, material: try unwrap(updated.material), kind: .adaptive).feed < originalFeed)
        inventory.customMaterials = []
        let reopened = try JSONDecoder().decode(StockItem.self, from: JSONEncoder().encode(pinned))
        try expectEqual(reopened.material, custom)
        try expectEqual(inventory.resolvedStock(reopened), reopened, "Embedded definitions survive without an installed library.")
        try expectEqual(FeedsEngine.compute(tool: tool, material: try unwrap(reopened.material), kind: .adaptive).feed, originalFeed)
    },
    TestCase(name: "materialSnapshotsMustMatchTheStockMaterialID") {
        let custom = customMaterialResource()
        var stock = StockItem(materialID: "al-6061", sizeX: 40, sizeY: 30, sizeZ: 10, materialSnapshot: custom)
        try expectEqual(stock.material, MaterialLibrary.material(id: "al-6061"))
        let inventory = Inventory()
        try expectEqual(inventory.resolvedStock(stock).materialSnapshot, MaterialLibrary.material(id: "al-6061"))
        stock.materialID = "missing-material"
        try expect(stock.material == nil)
        try expect(inventory.resolvedStock(stock).materialSnapshot == nil)
    },
    TestCase(name: "materialValidationRejectsInvalidCuttingInputs") {
        for material in MaterialLibrary.all { try expect(material.validationIssues.isEmpty, material.name) }
        let changes: [(inout Material) -> Void] = [
            { $0.id = " " }, { $0.name = "\n" }, { $0.density = 0 }, { $0.density = .nan },
            { $0.surfaceSpeed = -10...100 }, { $0.surfaceSpeed = 1...Double.infinity },
            { $0.chipLoadFactor = 0 }, { $0.adaptiveStepoverMax = 1.1 },
            { $0.adaptiveStepoverMax = 0 }, { $0.adaptiveDepthMax = -1 },
            { $0.slotDepthMax = 0 }, { $0.specificCuttingForce = .infinity }, { $0.toolWearFactor = 0 },
            { $0.density = 1e100 }, { $0.surfaceSpeed = 1...1e100 }, { $0.chipLoadFactor = 1e100 },
            { $0.adaptiveDepthMax = 1e100 }, { $0.slotDepthMax = 1e100 },
            { $0.specificCuttingForce = 1e100 }, { $0.toolWearFactor = 1e100 },
        ]
        for change in changes {
            var material = customMaterialResource()
            change(&material)
            try expect(!material.validationIssues.isEmpty)
        }
    },
    TestCase(name: "oldInventoryStockAndMaterialDecodeWithoutNewFields") {
        let materialData = try JSONEncoder().encode(customMaterialResource())
        var materialJSON = try unwrap(JSONSerialization.jsonObject(with: materialData) as? [String: Any])
        materialJSON.removeValue(forKey: "source")
        let oldMaterial = try JSONDecoder().decode(Material.self, from: JSONSerialization.data(withJSONObject: materialJSON))
        try expect(oldMaterial.source == nil)

        var inventory = Inventory()
        inventory.stock = [StockItem(materialID: "al-6061", sizeX: 40, sizeY: 30, sizeZ: 10)]
        var json = try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(inventory)) as? [String: Any])
        json["schema"] = 1
        json.removeValue(forKey: "customMaterials")
        var stocks = try unwrap(json["stock"] as? [[String: Any]])
        stocks[0].removeValue(forKey: "materialSnapshot")
        json["stock"] = stocks
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coastline-material-v1-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = try unwrap(InventoryStore.load(from: url))
        try expectEqual(loaded.schema, Inventory.currentSchema)
        try expect(loaded.customMaterials == nil)
        try expectEqual(loaded.stock[0].material, MaterialLibrary.material(id: "al-6061"))
        try expect(loaded.stock[0].materialSnapshot == nil)
    },
    TestCase(name: "customMaterialInventoryRoundTripsWithSourceAndStockSnapshot") {
        var inventory = Inventory()
        let custom = customMaterialResource()
        inventory.customMaterials = [custom]
        inventory.stock = [inventory.resolvedStock(StockItem(materialID: custom.id, sizeX: 40, sizeY: 30, sizeZ: 10))]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coastline-custom-material-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try InventoryStore.save(inventory, to: url)
        let reopened = try unwrap(InventoryStore.load(from: url))
        try expectEqual(reopened, inventory)
        try expectEqual(reopened.stock[0].material?.source, custom.source)
    },
    TestCase(name: "journalPreservesCustomMaterialNameAndDefinition") {
        let custom = customMaterialResource()
        var entry = JournalEntry(partName: "Sample", materialID: custom.id, stockDescription: "40 × 30 × 10", programs: [], measurements: [])
        entry.materialSnapshot = custom
        let reopened = try JSONDecoder().decode(JournalEntry.self, from: JSONEncoder().encode(entry))
        try expectEqual(reopened.materialSnapshot, custom)
        var oldJSON = try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        oldJSON.removeValue(forKey: "materialSnapshot")
        let old = try JSONDecoder().decode(JournalEntry.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        try expect(old.materialSnapshot == nil)
    },
]
