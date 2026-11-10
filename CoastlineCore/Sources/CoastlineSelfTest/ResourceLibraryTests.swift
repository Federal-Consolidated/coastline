import CoastlineCore
import Foundation

private func libraryTool() -> Tool {
    Tool(id: UUID(uuidString: "BA000000-0000-0000-0000-000000000001")!, name: "Library end mill", kind: .flatEndMill,
         diameter: 3.175, shankDiameter: 3.175, flutes: 2, fluteLength: 9, stickout: 15, overallLength: 38, quantity: 2)
}

private func libraryMaterial() -> Material {
    var material = MaterialLibrary.material(id: "al-6061")!
    material.id = "custom-test-aluminium"; material.name = "Shop aluminium"; material.source = "Shop test cuts"
    return material
}

private func libraryStock() -> StockItem {
    StockItem(id: UUID(uuidString: "BA000000-0000-0000-0000-000000000002")!, materialID: "custom-test-aluminium",
              sizeX: 80, sizeY: 30, sizeZ: 15, quantity: 4)
}

let resourceLibraryTests: [TestCase] = [
    TestCase(name: "portableRoundTripIncludesCustomStockMaterial") {
        var inventory = Inventory()
        inventory.customMaterials = [libraryMaterial()]; inventory.stock = [libraryStock()]; inventory.tools = [libraryTool()]
        let exported = try ResourceLibraryPackage.exporting(inventory, name: "Shop library")
        try expectEqual(exported.units, .millimeters)
        let decoded = try ResourceLibraryImport.parse(exported.encoded())
        try expectEqual(decoded, exported)
        let preview = try ResourceLibraryImport.prepare(decoded, into: Inventory())
        try expectEqual(preview.addedCount, 3)
        try expectEqual(preview.inventory.stock.first?.material, libraryMaterial())
        try expectEqual(preview.inventory.tools.first, libraryTool())
        let again = try ResourceLibraryImport.prepare(decoded, into: preview.inventory)
        try expectEqual(again.inventory, preview.inventory)
        try expectEqual(again.keptCount, 3)
    },
    TestCase(name: "keepAndReplacePreserveOwnership") {
        var inventory = Inventory()
        inventory.customMaterials = [libraryMaterial()]
        var existingTool = libraryTool(); existingTool.quantity = 7; existingTool.condition = .worn
        existingTool.cuttingMinutes = 123; existingTool.cuttingDistance = 456; existingTool.notes = "My tool edit"
        var existingStock = libraryStock(); existingStock.quantity = 8; existingStock.location = "Drawer 2"; existingStock.notes = "My stock edit"
        inventory.tools = [existingTool]; inventory.stock = [existingStock]
        var importedTool = libraryTool(); importedTool.diameter = 3; importedTool.quantity = 0
        var importedStock = libraryStock(); importedStock.sizeX = 90; importedStock.quantity = 0
        let package = ResourceLibraryPackage(name: "Update", stock: [importedStock], tools: [importedTool])
        let kept = try ResourceLibraryImport.prepare(package, into: inventory)
        try expectEqual(kept.inventory, inventory)
        let replaced = try ResourceLibraryImport.prepare(package, into: inventory, policy: .replaceExisting)
        let tool = try unwrap(replaced.inventory.tools.first)
        try expectEqual(tool.diameter, 3); try expectEqual(tool.quantity, 7); try expectEqual(tool.condition, .worn)
        try expectEqual(tool.cuttingMinutes, 123); try expectEqual(tool.cuttingDistance, 456)
        let stock = try unwrap(replaced.inventory.stock.first)
        try expectEqual(stock.sizeX, 90); try expectEqual(stock.quantity, 8); try expectEqual(stock.location, "Drawer 2")
        try expectEqual(replaced.replacedCount, 2)
        try expectEqual(replaced.rows.first(where: { $0.kind == .tool })?.quantity, 7)
        try expectEqual(replaced.rows.first(where: { $0.kind == .stock })?.quantity, 8)
        try expectEqual(inventory.tools.first, existingTool, "preparing a merge changed the caller's inventory")
    },
    TestCase(name: "copyRemapsMaterialDependenciesAndIsIdempotent") {
        var inventory = Inventory()
        inventory.customMaterials = [libraryMaterial()]; inventory.stock = [libraryStock()]; inventory.tools = [libraryTool()]
        var material = libraryMaterial(); material.chipLoadFactor = 0.7
        var stock = libraryStock(); stock.sizeX = 90; stock.materialSnapshot = material
        var tool = libraryTool(); tool.diameter = 3
        let package = ResourceLibraryPackage(name: "Copies", stock: [stock], tools: [tool], materials: [material])
        let copied = try ResourceLibraryImport.prepare(package, into: inventory, policy: .addAsCopy)
        try expectEqual(copied.copiedCount, 3)
        let copy = try unwrap(copied.inventory.stock.first { $0.id != stock.id })
        try expect(copy.materialID != material.id)
        try expectEqual(copy.material?.chipLoadFactor, 0.7)
        try expectEqual(copied.inventory.material(id: material.id), libraryMaterial())
        let again = try ResourceLibraryImport.prepare(package, into: copied.inventory, policy: .addAsCopy)
        try expectEqual(again.inventory, copied.inventory)
        try expectEqual(again.keptCount, 3)
    },
    TestCase(name: "builtInMaterialsCannotBeReplaced") {
        let builtin = MaterialLibrary.material(id: "al-6061")!
        let identical = try ResourceLibraryImport.prepare(ResourceLibraryPackage(name: "Known material", materials: [builtin]), into: Inventory(), policy: .replaceExisting)
        try expectEqual(identical.keptCount, 1)
        try expect((identical.inventory.customMaterials ?? []).isEmpty)
        var changed = builtin; changed.chipLoadFactor = 0.7
        let stock = StockItem(materialID: builtin.id, sizeX: 50, sizeY: 20, sizeZ: 10)
        let copied = try ResourceLibraryImport.prepare(ResourceLibraryPackage(name: "Custom alloy", stock: [stock], materials: [changed]), into: Inventory(), policy: .replaceExisting)
        try expectEqual(copied.inventory.material(id: builtin.id), builtin)
        try expect(copied.inventory.stock.first?.materialID != builtin.id)
        try expectEqual(copied.inventory.stock.first?.material?.chipLoadFactor, 0.7)
        try expect(!copied.warnings.isEmpty)
    },
    TestCase(name: "copyIdentityCollisionsCannotSilentlyChangeDependencies") {
        var inventory = Inventory()
        inventory.customMaterials = [libraryMaterial()]; inventory.stock = [libraryStock()]; inventory.tools = [libraryTool()]
        var material = libraryMaterial(); material.chipLoadFactor = 0.7
        var stock = libraryStock(); stock.sizeX = 90
        var tool = libraryTool(); tool.diameter = 3
        let package = ResourceLibraryPackage(name: "Copies", stock: [stock], tools: [tool], materials: [material])
        let installed = try ResourceLibraryImport.prepare(package, into: inventory, policy: .addAsCopy).inventory
        // A saved copy's ownership can change without installing another copy.
        var owned = installed
        let toolCopy = try unwrap(owned.tools.firstIndex { $0.id != tool.id })
        owned.tools[toolCopy].quantity = 9; owned.tools[toolCopy].condition = .worn
        let again = try ResourceLibraryImport.prepare(package, into: owned, policy: .addAsCopy)
        try expectEqual(again.inventory, owned)
        try expectEqual(again.rows.first(where: { $0.kind == .tool })?.quantity, 9)
        // But an ID occupied by different geometry must never satisfy the copied dependency.
        var conflicting = installed
        let materialCopy = try unwrap(conflicting.customMaterials?.firstIndex { $0.id != material.id })
        conflicting.customMaterials?[materialCopy].chipLoadFactor = 0.2
        try expectThrows { _ = try ResourceLibraryImport.prepare(package, into: conflicting, policy: .addAsCopy) }
        conflicting = installed
        let stockCopy = try unwrap(conflicting.stock.firstIndex { $0.id != stock.id })
        conflicting.stock[stockCopy].sizeX = 99
        try expectThrows { _ = try ResourceLibraryImport.prepare(package, into: conflicting, policy: .addAsCopy) }
        conflicting = installed; conflicting.tools[toolCopy].diameter = 2
        try expectThrows { _ = try ResourceLibraryImport.prepare(package, into: conflicting, policy: .addAsCopy) }
        // The same reservation also applies to another row inside this incoming package.
        var collidingPackage = package
        var unrelated = try unwrap(installed.customMaterials?.first { $0.id != material.id })
        unrelated.name = "Unrelated material with a colliding ID"
        collidingPackage.materials.append(unrelated)
        try expectThrows { _ = try ResourceLibraryImport.prepare(collidingPackage, into: inventory, policy: .addAsCopy) }
    },
    TestCase(name: "materialResolutionFollowsConflictChoice") {
        var inventory = Inventory(); inventory.customMaterials = [libraryMaterial()]
        var incoming = libraryMaterial(); incoming.chipLoadFactor = 0.6
        var stock = libraryStock(); stock.materialSnapshot = incoming
        let package = ResourceLibraryPackage(name: "Material conflict", stock: [stock], materials: [incoming])
        let kept = try ResourceLibraryImport.prepare(package, into: inventory)
        try expectEqual(kept.inventory.stock.first?.material, libraryMaterial())
        let replaced = try ResourceLibraryImport.prepare(package, into: inventory, policy: .replaceExisting)
        try expectEqual(replaced.inventory.stock.first?.material, incoming)
        // A kept existing stock record does not acquire a dependency from a rejected update.
        inventory.stock = [stock]; stock.materialID = "not-installed"; stock.materialSnapshot = nil
        let ignored = try ResourceLibraryImport.prepare(ResourceLibraryPackage(name: "Ignored stock update", stock: [stock]), into: inventory)
        try expectEqual(ignored.inventory, inventory)
    },
    TestCase(name: "invalidPackagesFailBeforeAnyMerge") {
        var inventory = Inventory(); inventory.tools = [libraryTool()]
        let before = inventory
        try expectThrows { _ = try ResourceLibraryImport.prepare(ResourceLibraryPackage(name: "Unresolved", stock: [libraryStock()]), into: inventory) }
        var invalid = libraryStock(); invalid.materialID = "al-6061"; invalid.sizeX = .nan
        try expectThrows { _ = try ResourceLibraryImport.prepare(ResourceLibraryPackage(name: "Invalid stock", stock: [invalid]), into: inventory) }
        var badTool = libraryTool(); badTool.overallLength = .infinity
        try expectThrows { _ = try ResourceLibraryImport.prepare(ResourceLibraryPackage(name: "Invalid tool", tools: [badTool]), into: inventory) }
        try expectThrows { _ = try ResourceLibraryImport.prepare(ResourceLibraryPackage(name: "Duplicate IDs", tools: [libraryTool(), libraryTool()]), into: inventory) }
        var newer = ResourceLibraryPackage(name: "New format"); newer.schemaVersion = 999
        try expectThrows { _ = try newer.encoded() }
        var unknown = ResourceLibraryPackage(name: "Unknown units"); unknown.units.length = "cm"
        try expectThrows { _ = try unknown.encoded() }
        try expectEqual(inventory, before)
        var inconsistent = libraryStock(); inconsistent.materialSnapshot = MaterialLibrary.material(id: "al-6061")
        try expectThrows { _ = try ResourceLibraryImport.prepare(ResourceLibraryPackage(name: "Wrong snapshot", stock: [inconsistent]), into: inventory) }
    },
    TestCase(name: "inchesConvertGeometryAndFeedsOnlyOnce") {
        var tool = libraryTool()
        tool.diameter = 0.125; tool.shankDiameter = 0.125; tool.fluteLength = 0.5; tool.stickout = 0.75; tool.overallLength = 1.5
        tool.presets = [Tool.Preset(name: "Inch preset", rpm: 6000, feed: 10, plungeFeed: 2, rampFeed: 3, stepdown: 0.1, stepover: 0.02)]
        let stock = StockItem(materialID: "al-6061", sizeX: 3, sizeY: 2, sizeZ: 1)
        let package = ResourceLibraryPackage(name: "Inch library", stock: [stock], tools: [tool], materials: [MaterialLibrary.material(id: "al-6061")!], units: .inches)
        let decoded = try ResourceLibraryImport.parse(package.encoded())
        try expectEqual(decoded.units, .millimeters)
        try expect(abs(decoded.stock[0].sizeX - 76.2) < 1e-9)
        try expect(abs(decoded.tools[0].diameter - 3.175) < 1e-9)
        try expectEqual(decoded.tools[0].presets[0].feed, 254)
        try expectEqual(decoded.warnings.filter { $0.contains("Converted inch") }.count, 1)
        try expectEqual(decoded.materials[0].surfaceSpeed, package.materials[0].surfaceSpeed)
        try expectEqual(try ResourceLibraryImport.parse(decoded.encoded()), decoded)
    },
    TestCase(name: "fusionIdentitySurvivesReimportAndFilenameChanges") {
        let guid = "7251705f-69bf-4c29-83d5-3864d6a5783d"
        let json = """
        {"data":[{"guid":"\(guid)","type":"flat end mill","unit":"millimeters","description":"Test","geometry":{"DC":3,"SFDM":3,"NOF":2,"LCF":8,"LB":15,"OAL":38}}]}
        """
        let a = try ToolLibraryImport.parse(Data(json.utf8), sourceName: "first.json")
        let b = try ToolLibraryImport.parse(Data(json.utf8), sourceName: "renamed.json")
        try expectEqual(a.tools.first?.id, UUID(uuidString: guid))
        try expectEqual(a.tools.first?.id, b.tools.first?.id)
        let noGUID = json.replacingOccurrences(of: "\"guid\":\"\(guid)\",", with: "")
        let c = try ToolLibraryImport.parse(Data(noGUID.utf8), sourceName: "first.json")
        let d = try ToolLibraryImport.parse(Data(noGUID.utf8), sourceName: "renamed.json")
        try expectEqual(c.tools.first?.id, d.tools.first?.id)
        var inventory = Inventory(); inventory.tools = c.tools; inventory.tools[0].quantity = 6
        let merged = try ResourceLibraryImport.prepare(ResourceLibraryPackage(name: "Reimport", tools: d.tools), into: inventory)
        try expectEqual(merged.inventory, inventory)
    },
    TestCase(name: "fusionMissingUnitsRejectedAndInferredGeometryReported") {
        let minimal = #"{"data":[{"type":"flat end mill","unit":"millimeters","geometry":{"DC":3}}]}"#
        let inferred = try ToolLibraryImport.parse(Data(minimal.utf8), sourceName: "minimal.json")
        try expectEqual(inferred.tools.count, 1)
        try expect(inferred.warnings.first?.contains("stickout") == true)
        let unknown = minimal.replacingOccurrences(of: "millimeters", with: "centimeters")
        let rejected = try ToolLibraryImport.parse(Data(unknown.utf8), sourceName: "unknown.json")
        try expect(rejected.tools.isEmpty)
        try expect(rejected.skipped.first?.contains("units") == true)
        let invalidFlutes = minimal.replacingOccurrences(of: "\"DC\":3", with: "\"DC\":3,\"NOF\":1e100")
        try expect(try ToolLibraryImport.parse(Data(invalidFlutes.utf8), sourceName: "bad.json").tools.isEmpty)
        let inch = minimal.replacingOccurrences(of: "millimeters", with: "inches")
        try expect(try ToolLibraryImport.parse(Data(inch.utf8), sourceName: "inch.json").warnings.contains { $0.contains("Converted Fusion inch") })
    },
    TestCase(name: "selectedExportCarriesOnlyRequestedRowsAndDependencies") {
        var inventory = Inventory(); inventory.customMaterials = [libraryMaterial()]
        inventory.stock = [libraryStock(), StockItem(materialID: "al-6061", sizeX: 10, sizeY: 10, sizeZ: 10)]
        inventory.tools = [libraryTool()]
        let package = try ResourceLibraryPackage.exporting(inventory, name: "Selected stock", stockIDs: [libraryStock().id], toolIDs: [], materialIDs: [])
        try expectEqual(package.stock.count, 1); try expect(package.tools.isEmpty)
        try expectEqual(package.materials.map(\.id), [libraryMaterial().id])
        let merged = try ResourceLibraryImport.prepare(package, into: Inventory())
        try expectEqual(merged.inventory.stock.first?.material?.id, libraryMaterial().id)
    },
]
