import CoastlineCore
import Foundation

extension AppModel {
    /// Candidate stock is workshop inventory, ranked by a defined jig match and then waste.
    /// Purchasing suggestions never silently become the material for a guided job.
    func guidedStock(in inventory: Inventory) -> [StockItem] {
        guidedStockChoices(in: inventory).map(\.stock)
    }

    func guidedStockChoices(in inventory: Inventory) -> [JobLibraryGuide.StockChoice] {
        guard let part else { return [] }
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        return JobLibraryGuide.stockChoices(partSize: hi - lo, inventory: inventory, preferredAxes: setup.stockAxes)
    }

    func matchingFixtureCount(for item: StockItem, inventory: Inventory) -> Int {
        guidedStockChoices(in: inventory).first { $0.stock.id == item.id }?.matchingFixtures ?? 0
    }

    func useGuidedStock(_ item: StockItem, inventory: Inventory) {
        let axes = guidedStockChoices(in: inventory).first { $0.stock.id == item.id }?.axes
        useStock(inventory.resolvedStock(item))
        if let axes { useStockAxes(axes) }
    }

    func libraryPlanningBlocker(in inventory: Inventory) -> String? {
        guard planningMachineReady else { return planningMachineProblem ?? "Load a machine before planning." }
        guard part != nil, let stock else { return "Load a part and choose stock first." }
        guard (stockLookup(stock.id)?.quantity ?? 0) > 0 else { return "Choose stock you have, or confirm this blank is in your library." }
        guard stock.material != nil else { return "Assign a material to this stock so cutting data can be planned." }
        guard status(.stock).state == .done else { return status(.stock).why }
        guard !OperationPlanner.usableTools(inventory, machine: machine).filter({ !$0.isSuggestion }).isEmpty else {
            return inventory.tools.contains { $0.quantity > 0 }
                ? "None of your owned tools is ready. Check matching collets, tool condition and dimensions in the library."
                : "Add your cutting tools and their matching collets to the library before planning."
        }
        if setup.planFromFixtureLibrary || setup.holding == nil {
            let available = jobFixtureInventory(inventory)
            guard available.fixtures.contains(where: {
                LibraryWorkholdingPlanner.eligibility($0, stock: setup.stockSize(stock)).isEmpty
            }) else { return "Choose workholding in Setups first." }
        } else if !holdingAssessment(holdingPath).possible {
            return holdingAssessment(holdingPath).why
        }
        return nil
    }

    /// One guided action: compare owned tooling, choose a usable proposal, generate its
    /// actual cuts, assign library fixtures, then hand the physical setups to the operator.
    func proposeJob(inventory: Inventory) async {
        guard !isPlanningJob, !isFindingPlans, !isGenerating else { return }
        guard libraryPlanningBlocker(in: inventory) == nil else {
            errorMessage = libraryPlanningBlocker(in: inventory); return
        }
        isPlanningJob = true
        errorMessage = nil
        defer { isPlanningJob = false }
        if setup.holding == nil { enableLibraryPlanning() }
        let partID = part?.partID, stockID = stockID, originalSetup = setup, machineReference = planningMachineReference
        let selectedName = chosenPlan
        planOptions = []; planCandidates = []
        await findPlans(inventory: inventory)
        guard errorMessage == nil else { return }
        guard part?.partID == partID, self.stockID == stockID, setup == originalSetup, planningMachineReference == machineReference else {
            status = "The part or setup changed while comparing plans. Build the proposal again."; return
        }
        // A tool you don't have yet doesn't stop the plan (it fits the machine and your collets):
        // the recommended plan may use tools to buy. They go on the shopping list, and running
        // waits until they are marked as owned.
        guard let proposed = planOptions.first(where: { $0.name == selectedName })
            ?? planOptions.first(where: { $0.name == recommendedPlan })
            ?? planOptions.min(by: { ($0.risk, $0.minutes) < ($1.risk, $1.minutes) }) else {
            errorMessage = "No plan fits this machine with your tools or ones to buy. Check the problems below."
            return
        }
        usePlan(proposed)
        await generateToolpaths(inventory: inventory)
        guard !cancelGeneration, !programs.isEmpty,
              !setup.planFromFixtureLibrary || libraryWorkholdingPlan?.complete == true else { return }
        let buy = jobToolsToBuy.count
        status = "Job proposed." + (coverageGapNote.map { " \($0)" } ?? "")
            + (buy > 0 ? " It uses \(buy == 1 ? "a tool" : "\(buy) tools") to buy." : "")
            + " Review each setup below, then inspect the toolpaths."
    }
}
