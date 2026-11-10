import CoastlineCore
import Foundation

private func reviewedCatalogTool(_ number: Int) throws -> Tool {
    let id = UUID(uuidString: String(format: "C0A57100-0000-4000-8000-%012d", number))!
    return try unwrap(ToolCatalog.suggestions.first { $0.id == id })
}

let toolCatalogTests: [TestCase] = [
    TestCase(name: "publishedDimensionsPreserveUnitsAndCuttingShape") {
        let rougher = try reviewedCatalogTool(33)
        try expectEqual(rougher.kind, .bullNoseEndMill)
        try expectEqual(rougher.flutes, 3)
        try expect(abs(rougher.diameter - 6.35) < 1e-9)
        try expect(abs(rougher.fluteLength - 19.05) < 1e-9)
        try expect(abs(rougher.overallLength - 63.5) < 1e-9)
        try expect(abs(rougher.cornerRadius - 0.254) < 1e-9)
        try expectEqual(rougher.toolMaterial, .unspecified)
        try expect(rougher.notes.contains("ZPLUS"))

        let smallMill = try reviewedCatalogTool(34)
        try expectEqual(smallMill.kind, .flatEndMill)
        try expectEqual(smallMill.flutes, 4)
        try expect(abs(smallMill.diameter - 3.175) < 1e-9)
        try expect(abs(smallMill.fluteLength - 6.35) < 1e-9)
        try expect(abs(smallMill.overallLength - 50.8) < 1e-9)
        try expectEqual(smallMill.toolMaterial, .unspecified)
        try expect(smallMill.notes.contains("APLUS"))

        let drill = try reviewedCatalogTool(35)
        try expectEqual(drill.kind, .drill)
        try expectEqual(drill.toolMaterial, .carbide)
        try expect(abs(drill.diameter - 2.794) < 1e-9)
        try expect(abs(drill.fluteLength - 28.575) < 1e-9)
        try expect(abs(drill.overallLength - 57.15) < 1e-9)
        try expectEqual(drill.flutes, 0, "the source does not publish a flute count")
        try expect(drill.angle == nil, "the source does not publish a point angle")
        try expect(Set(drill.unconfirmedSpecifications ?? []).isSuperset(of: ["Flute count", "Point angle"]))
    },
    TestCase(name: "suggestionsHaveStableIdentityGenericNamesAndExplicitUnknowns") {
        try expectEqual(Set(ToolCatalog.suggestions.map(\.id)).count, ToolCatalog.suggestions.count)
        let links = ["https://ghostgunner.net/product/1-4-helical-end-mill/",
                     "https://ghostgunner.net/product/1-8-end-mill/",
                     "https://ghostgunner.net/product/34-drill-bit/"]
        for (number, link) in zip(33...35, links) {
            let tool = try reviewedCatalogTool(number)
            try expectEqual(tool.productLink, link)
            try expectEqual(tool.quantity, 0)
            try expect(tool.isSuggestion && tool.requiresSpecificationReview)
            try expectEqual(tool.vendor, "")
            try expect(!tool.name.lowercased().contains("ghost") && !tool.name.lowercased().contains("helical"))
            try expectEqual(tool.source, ToolCatalog.source)
            try expect(tool.unitCost == nil)
            try expectEqual(tool.shankDiameter, 0, "cutting diameter must not stand in for unpublished shank geometry")
            try expectEqual(tool.stickout, 0, "stick-out depends on how the user mounts the tool")
            try expectEqual(tool.coating, .unspecified)
            try expect(Set(tool.unconfirmedSpecifications ?? []).isSuperset(of: ["Shank diameter", "Stick-out", "Coating"]))
            try expect(ResourceLibraryValidation.issues(for: tool).isEmpty)
        }
        let unsupported = ["https://ghostgunner.net/product/drill-bit-custom-carbide-5-32/",
                           "https://ghostgunner.net/product/1-8-ball-end-mill-for-steel/"]
        try expect(!ToolCatalog.suggestions.contains { unsupported.contains($0.productLink) },
                   "contradictory flute counts or LOC/OAL cannot be silently repaired")
    },
    TestCase(name: "reviewStateSurvivesPortableLibraryAndBlocksOwnedTools") {
        var inventory = Inventory()
        inventory.tools = try (33...35).map(reviewedCatalogTool)
        let exported = try ResourceLibraryPackage.exporting(inventory, name: "Draft tool catalog")
        let decoded = try ResourceLibraryImport.parse(exported.encoded())
        try expectEqual(decoded.tools, inventory.tools)
        let imported = try ResourceLibraryImport.prepare(decoded, into: Inventory())
        try expectEqual(imported.addedCount, 3)
        try expect(ToolLife.shoppingList(imported.inventory, material: MaterialLibrary.all[0]).isEmpty,
                   "incomplete catalog entries have no estimated wear")
        for var tool in imported.inventory.tools {
            tool.quantity = 1
            // Even entering valid dimensions does not silently assert that the user reviewed
            // the source gaps. The explicit confirmation is separate from claiming ownership.
            tool.shankDiameter = tool.diameter
            tool.stickout = tool.fluteLength + 3
            tool.flutes = max(tool.flutes, 2)
            tool.toolMaterial = .carbide
            tool.coating = .none
            if tool.kind == .drill { tool.angle = 118 }
            try expect(ResourceLibraryValidation.issues(for: tool).isEmpty)
            try expect(InventoryChecks.check(tool, inventory: inventory).contains {
                $0.severity == .error && $0.message.contains("confirm the tool specifications")
            })
        }
    },
    TestCase(name: "clearingReviewCannotTurnMissingGeometryIntoAUsableTool") {
        for number in 33...35 {
            var tool = try reviewedCatalogTool(number)
            tool.unconfirmedSpecifications = nil
            try expect(!ResourceLibraryValidation.issues(for: tool).isEmpty)
            try expect(InventoryChecks.check(tool, inventory: Inventory()).contains { $0.severity == .error })
        }
    },
]
