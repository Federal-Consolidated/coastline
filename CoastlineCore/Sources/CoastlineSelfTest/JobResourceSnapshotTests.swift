import CoastlineCore
import Foundation

let jobResourceSnapshotTests: [TestCase] = [
    TestCase(name: "libraryEditsDoNotChangeSavedCuttingGeometry") {
        let tool = Tool(name: "Test end mill", kind: .flatEndMill, diameter: 3, shankDiameter: 3,
                        flutes: 2, fluteLength: 8, stickout: 15, overallLength: 38)
        let stock = StockItem(materialID: "al-6061", sizeX: 80, sizeY: 30, sizeZ: 12)
        var saved = JobResourceSnapshot(stock: stock)
        saved.captureTools(ids: [tool.id], from: [tool])
        var edited = tool
        edited.diameter = 6
        edited.stickout = 22
        edited.quantity = 2
        edited.condition = .worn
        var inventory = Inventory()
        inventory.tools = [edited]
        inventory.stock = [stock]
        inventory.stock[0].sizeX = 100
        let restored = try JSONDecoder().decode(JobResourceSnapshot.self, from: JSONEncoder().encode(saved))
        let planned = restored.planningInventory(inventory)
        try expectEqual(planned.tools[0].diameter, 3)
        try expectEqual(planned.tools[0].stickout, 15)
        try expectEqual(planned.tools[0].quantity, 2)
        try expectEqual(planned.tools[0].condition, .worn)
        try expectEqual(restored.stock?.sizeX, 80)
        saved.captureTools(ids: [tool.id], from: [edited])
        try expectEqual(saved.tools[0].diameter, 3)
    },
    TestCase(name: "missingToolsKeepTheirDefinitionWithoutClaimingOwnership") {
        let tool = Tool(name: "Shared tool", kind: .flatEndMill, diameter: 4, shankDiameter: 4,
                        flutes: 2, fluteLength: 10, stickout: 18, overallLength: 40)
        var saved = JobResourceSnapshot(tools: [tool])
        let planned = saved.planningInventory(Inventory())
        try expectEqual(planned.tools[0].id, tool.id)
        try expectEqual(planned.tools[0].quantity, 0)
        saved.captureTools(ids: [], from: [tool])
        try expect(saved.tools.isEmpty)
    },
]
