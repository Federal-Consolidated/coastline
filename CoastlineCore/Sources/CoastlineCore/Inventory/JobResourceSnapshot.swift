import Foundation

/// The resource definitions a job was planned with. Ownership stays in the local
/// inventory; changing library geometry does not rewrite an existing job.
public struct JobResourceSnapshot: Codable, Equatable, Sendable {
    public var stock: StockItem?
    public var tools: [Tool]

    public init(stock: StockItem? = nil, tools: [Tool] = []) {
        self.stock = stock
        var ids = Set<UUID>()
        self.tools = tools.filter { ids.insert($0.id).inserted }
    }

    public mutating func captureTools(ids: Set<UUID>, from inventory: [Tool]) {
        var seen = Set<UUID>()
        tools = tools.filter { ids.contains($0.id) && seen.insert($0.id).inserted }
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) where !tools.contains(where: { $0.id == id }) {
            if let tool = inventory.first(where: { $0.id == id }) { tools.append(tool) }
        }
    }

    public func planningInventory(_ inventory: Inventory) -> Inventory {
        var result = inventory
        for saved in tools {
            var tool = saved
            if let index = result.tools.firstIndex(where: { $0.id == saved.id }) {
                let owned = result.tools[index]
                tool.quantity = owned.quantity
                tool.condition = owned.condition
                tool.cuttingMinutes = owned.cuttingMinutes
                tool.cuttingDistance = owned.cuttingDistance
                result.tools[index] = tool
            } else {
                tool.quantity = 0
                result.tools.append(tool)
            }
        }
        return result
    }
}
