import CoastlineCore
import Foundation

extension AppModel {
    var savedResourceSnapshot: JobResourceSnapshot {
        var snapshot = jobResources
        snapshot.stock = stock
        let ids = Set(operations.compactMap(\.toolID))
        snapshot.captureTools(ids: ids, from: ids.compactMap(toolLookup))
        return snapshot
    }

    func captureJobTools() {
        let ids = Set(operations.compactMap(\.toolID))
        jobResources.captureTools(ids: ids, from: ids.compactMap(toolLookup))
    }

    func planningInventory(_ inventory: Inventory) -> Inventory {
        jobFixtureInventory(jobResources.planningInventory(inventory))
    }

    func jobTool(_ id: UUID) -> Tool? {
        jobResources.tools.first { $0.id == id } ?? toolLookup(id)
    }

    /// Explicitly refreshes definitions; routine library edits leave the current job intact.
    func updateJobResources(from inventory: Inventory) {
        guard canChangePlanningMachine else { return }
        let ids = Set(operations.compactMap(\.toolID))
        var next = jobResources
        for index in next.tools.indices {
            if let current = inventory.tools.first(where: { $0.id == next.tools[index].id }) { next.tools[index] = current }
        }
        next.captureTools(ids: ids, from: inventory.tools)
        if let id = stockID, let item = inventory.stock.first(where: { $0.id == id }) {
            next.stock = inventory.resolvedStock(item)
        }
        guard next != savedResourceSnapshot else { status = "Job resources are up to date"; return }
        jobResources = next
        clearToolpathResults()
        opCache.removeAll(); opCacheOrder.removeAll()
        prepProgramCache = nil
        toolChangeSpotCache = nil
        kitShiftCache = nil
        referencePlan = nil
        planCandidates = []; planOptions = []; chosenPlan = nil; recommendedPlan = nil
        if let stock = next.stock { stockEdited(stock) }
        noteProjectChange()
        saveSession()
        saveDevelopmentSession()
        status = "Job resources updated. Regenerate toolpaths."
    }
}
