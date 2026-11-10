import CoastlineCore
import Foundation
import simd

let stockCatalogTests: [TestCase] = [
    TestCase(name: "catalogUpgradePreservesOwnedAndUnownedEditsAndRunsOnlyOnce") {
        var ownedStock = StockCatalog.suggestions[0]
        ownedStock.quantity = 3; ownedStock.sizeX = 143.5; ownedStock.notes = "Measured offcuts"
        var draftStock = StockCatalog.suggestions[1]
        draftStock.sizeZ = 7.25; draftStock.supplier = "My supplier"; draftStock.notes = "Quoted size"
        var ownedTool = ToolCatalog.suggestions[0]
        ownedTool.quantity = 2; ownedTool.stickout = 14.2; ownedTool.notes = "Measured installed length"
        var draftTool = ToolCatalog.suggestions[1]
        draftTool.diameter = 0.8; draftTool.unitCost = 17.5; draftTool.notes = "Quoted substitute"
        var retiredOwned = ownedTool
        retiredOwned.id = UUID(uuidString: "C0A57100-0000-4000-8000-000000000007")!
        var retiredSuggestion = draftTool
        retiredSuggestion.id = UUID(uuidString: "C0A57100-0000-4000-8000-000000000008")!
        var inventory = Inventory()
        inventory.stock = [ownedStock, draftStock]
        inventory.tools = [ownedTool, draftTool, retiredOwned, retiredSuggestion]
        inventory.stockSuggestionsVersion = StockCatalog.version - 1
        inventory.toolSuggestionsVersion = ToolCatalog.version - 1
        inventory.toolSuggestionsAdded = true

        try expect(inventory.installCatalogUpdates())
        try expectEqual(Array(inventory.stock.prefix(2)), [ownedStock, draftStock])
        try expectEqual(Array(inventory.tools.prefix(3)), [ownedTool, draftTool, retiredOwned])
        try expect(!inventory.tools.contains { $0.id == retiredSuggestion.id })
        try expectEqual(Set(inventory.stock.map(\.id)).count, inventory.stock.count)
        try expectEqual(Set(inventory.tools.map(\.id)).count, inventory.tools.count)
        try expectEqual(inventory.stockSuggestionsVersion, StockCatalog.version)
        try expectEqual(inventory.toolSuggestionsVersion, ToolCatalog.version)
        for blank in StockCatalog.basicBookendBlanks {
            try expectEqual(inventory.stock.first { $0.id == blank.id }, blank)
        }
        let installed = inventory
        try expect(!inventory.installCatalogUpdates())
        try expectEqual(inventory, installed)
        // Deliberately removed suggestions stay removed until a later catalog update.
        inventory.stock.removeLast(); inventory.tools.removeLast()
        let afterRemoval = inventory
        try expect(!inventory.installCatalogUpdates())
        try expectEqual(inventory, afterRemoval)
    },
    TestCase(name: "catalogIDsRemainStableAndNewBlanksDoNotClaimOwnership") {
        let catalog = StockCatalog.suggestions
        try expectEqual(Set(catalog.map(\.id)).count, catalog.count)
        try expect(catalog.allSatisfy { $0.quantity == 0 && $0.isSuggestion && $0.material != nil })
        let originals = (1...15).map { UUID(uuidString: String(format: "C0A57200-0000-4000-8000-%012d", $0))! }
        try expectEqual(Array(catalog.prefix(15).map(\.id)), originals, "catalog upgrades must not replace saved stock identities")
        try expectEqual(StockCatalog.basicBookendBlanks.map(\.id), [
            UUID(uuidString: "C0A57200-0000-4000-8000-000000000016")!,
            UUID(uuidString: "C0A57200-0000-4000-8000-000000000017")!,
        ])
        try expectEqual(StockCatalog.basicBookendBlanks.map(\.sizeX), [101.6, 152.4])
        try expect(StockCatalog.basicBookendBlanks.allSatisfy {
            $0.materialID == "al-6061" && $0.sizeY == 50.8 && $0.sizeZ == 50.8 && $0.extrusionAxis == 0
        })
    },
    TestCase(name: "basicBlanksSeatWithinReviewedMachineSlotsAndPhysicalEnvelope") {
        let root = repoRoot.appendingPathComponent("resources/machines/desktop-cnc")
        let machine = try MachineDefinitionPackage.load(from: root).definition
        let assembly = try JSONDecoder().decode(FixtureAssemblyDefinition.self,
            from: Data(contentsOf: repoRoot.appendingPathComponent("resources/fixtures/bookends/definition.json")))
        let mount = try unwrap(machine.mountingInterfaces.first { $0.id == "table-slots" })
        let starts = try mount.slots.map { try machine.worldPoint($0.origin, in: mount.frameID) }
        let ends = try mount.slots.map { slot in
            try machine.worldPoint(Vec3(slot.origin.x + slot.direction.x * slot.length,
                slot.origin.y + slot.direction.y * slot.length, slot.origin.z + slot.direction.z * slot.length), in: mount.frameID)
        }
        let low = try unwrap(zip(starts, ends).map { min($0.0.y, $0.1.y) }.max())
        let high = try unwrap(zip(starts, ends).map { max($0.0.y, $0.1.y) }.min())
        let yAxis = try unwrap(machine.components.compactMap(\.axis).first { $0.coordinate == .y })
        let referenceY = -yAxis.controllerOffset / yAxis.controllerScale
        let spindle = try machine.worldPoint(.zero, in: "tool")
        let centreY = spindle.y + (machine.profile.machineEnvelope.y.lowerBound + machine.profile.machineEnvelope.y.upperBound) / 2 - referenceY
        let audit = try unwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("geometry-validation.json"))) as? [String: Any])
        let surface = try unwrap(audit["tableSurface"] as? [String: Any])
        let maximum = try unwrap(surface["maximum"] as? [Double])
        let table = BookendSetup.Table(topX: try unwrap(surface["worldX"] as? Double), slotZ: starts.map(\.z),
                                      slotY: low...high, frontZ: maximum[2], centreY: centreY)
        for blank in StockCatalog.basicBookendBlanks {
            try expect(ResourceLibraryValidation.issues(for: blank).isEmpty)
            try expect(InventoryChecks.check(blank, machine: machine.profile).allSatisfy { $0.severity != .error }, blank.sizeDescription)
            let solver = try BookendSetup(assembly: assembly, table: table, stock: Setup().rawStockSize(blank))
            var placed = try solver.seat(.init())
            try solver.validate(placed)
            try expect(abs(solver.gap(placed)) < 1e-6)
            for (id, footprint, joint) in [
                (BookendSetup.fixed, solver.definition.fixedNutY, BookendSetup.fixedSlide),
                (BookendSetup.clamp, solver.definition.clampNutY, BookendSetup.clampSlide),
            ] {
                let offset = solver.value(placed, jointID: joint) - placed.datum.y + table.centreY
                try expect(footprint.lowerBound + offset >= low && footprint.upperBound + offset <= high, "\(id) runs beyond the real slots")
            }
            try expect(!solver.planningIssues(placed).isEmpty, "blank dimensions must not imply secured workholding")
            placed.assemblyState?.lockedComponents = [BookendSetup.fixed, BookendSetup.clamp]
            try expect(solver.planningIssues(placed).isEmpty)
            try expectEqual(blank.quantity, 0)
        }
    },
]
