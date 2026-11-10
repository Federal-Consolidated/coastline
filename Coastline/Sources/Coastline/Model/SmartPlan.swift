import CoastlineCore
import Foundation
import simd

extension AppModel {
    /// Searches the plans the inventory allows (StrategyEngine) and keeps three to choose from.
    func findPlans(inventory library: Inventory) async {
        captureJobTools()
        let inventory = planningInventory(library)
        guard planningMachineReady else { errorMessage = planningMachineProblem ?? "Load a machine before planning."; return }
        let machine = self.machine, machineReference = planningMachineReference
        guard let part, let stock, let material = stock.material else { return }
        guard material.validationIssues.isEmpty else {
            errorMessage = "\(material.name): " + material.validationIssues.joined(separator: " ")
            return
        }
        if setup.holding == nil, inventory.fixtures.contains(where: {
            LibraryWorkholdingPlanner.eligibility($0, stock: setup.stockSize(stock)).isEmpty
        }) { enableLibraryPlanning() }
        isFindingPlans = true
        defer { isFindingPlans = false }
        status = "Analysing the part…"
        do {
            let engine = try await liveEngine()
            let m = workTransform(part)
            // Found again when the part or its orientation changed since (cachedFeatures).
            if cachedFeatures(part, transform: m) == nil {
                let result = try await engine.features(partID: part.partID, transform: m)
                guard planningMachineReady, planningMachineReference == machineReference else { return }
                features = result
                featuresKey = (part.partID, m)
            }
            if analysis == nil {
                // With access, as runAnalysis: the Machinability section reads the same analysis.
                let result = try await engine.analyse(partID: part.partID, transform: m, access: true)
                guard planningMachineReady, planningMachineReference == machineReference else { return }
                analysisTransform = m
                analysis = result
            }
        } catch {
            guard planningMachineReference == machineReference else { return }
            errorMessage = "Couldn't analyse the part: \(error)"
            return
        }
        guard let a = analysis else { return }
        chooseSides(a)  // one or two sides decides how deep each side cuts
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        var facts = StrategyEngine.Facts(analysis: a, part: hi - lo, stock: setup.stockSize(stock), faceDepth: min(0.25, setup.topAllowance),
                                         holeDiameters: features?.holes.map(\.diameter) ?? [],
                                         hasFloors: features?.floorLevels.contains { $0 < -1e-6 } ?? false, material: material)
        // Holes are made by drilling and boring: the narrow "pockets" they are (their own
        // diameter) and the rings of counterbores around them (floors as wide as the step)
        // aren't pockets or floors the end mills must fit.
        let holes = features?.holes ?? []
        var rings: [Double] = []
        for a in holes {
            for b in holes where b.diameter > a.diameter + 0.01 && hypot(a.x - b.x, a.y - b.y) < 0.01 {
                rings.append((b.diameter - a.diameter) / 2)
            }
        }
        func isHole(_ w: Double) -> Bool { holes.contains { abs($0.diameter - w) < 0.06 } }
        facts.pocketWidths = (features?.pocketWidths ?? []).filter { !isHole($0) }
        let floorWidths = features?.floorWidths ?? [], floorDepths = features?.floorDepths ?? []
        let keep = floorWidths.indices.filter { k in
            floorDepths.indices.contains(k) && floorDepths[k] > 1e-6
                && !rings.contains { abs($0 - floorWidths[k]) < 0.06 } && !isHole(floorWidths[k])
        }
        facts.floorWidths = keep.map { floorWidths[$0] }
        facts.floorDepths = keep.compactMap { floorDepths.indices.contains($0) ? floorDepths[$0] : nil }
        // How deep the tools go on the deeper side. Side A: to the split (+ overlap). Side B first
        // faces its backing to 0.5 mm above the part, then cuts the rest of the part (+ overlap).
        let partZ = hi.z - lo.z
        if let z = splitZ {
            let partAbove = -z - setup.topAllowance
            facts.cutDepth = max(-z + 0.5, partZ - partAbove + 1.0)
        } else {
            facts.cutDepth = setup.topAllowance + partZ
        }
        // Hundreds of plans: off the main thread, so the window (and the button's spinner) stays live.
        status = "Comparing plans…"
        let cal = calibration, f = facts
        let (all, withBuyAll) = await Task.detached(priority: .userInitiated) {
            (StrategyEngine.candidates(facts: f, inventory: inventory, calibration: cal, machine: machine),
             StrategyEngine.candidates(facts: f, inventory: inventory, calibration: cal, includeSuggestions: true, machine: machine))
        }.value
        guard planningMachineReady, planningMachineReference == machineReference else { return }
        planCandidates = all
        planOptions = StrategyEngine.recommend(all)
        // The same with the tools Coastline would suggest buying: offered when one is clearly
        // better (finer, less risky) or the only way.
        let withBuy = withBuyAll.filter { !$0.needsTools.isEmpty }
        if ProcessInfo.processInfo.environment["COASTLINE_PLAN_DEBUG"] != nil {
            for c in StrategyEngine.pareto(withBuy).prefix(8) {
                print("buyplan \(Int(c.minutes)) min finish \(c.finish) risk \(c.risk) needs \(c.needsTools.map(\.name)) \(c.reasons.filter { $0.hasPrefix("Risk") || $0.hasPrefix("Unfinished") })")
            }
        }
        let bestOwnedFinish = planOptions.map(\.finish).min() ?? .infinity
        let bestOwnedRisk = planOptions.map(\.risk).min() ?? .infinity
        var extra = StrategyEngine.recommend(withBuy).filter { c in
            planOptions.isEmpty || c.finish < bestOwnedFinish * 0.7 || c.risk < bestOwnedRisk - 0.15
        }
        // The safest first, then the quickest (a machined finish you polish anyway; the finest
        // cusps cost hours): Balanced or Fastest is recommended, Finest stays a choice.
        extra = Array(extra.sorted { ($0.risk, $0.name.hasPrefix("Finest") ? 1 : 0, $0.minutes) < ($1.risk, $1.name.hasPrefix("Finest") ? 1 : 0, $1.minutes) }.prefix(3))
        for k in extra.indices {
            let n = extra[k].needsTools.count
            extra[k].name = "\(extra[k].name), with \(n == 1 ? "a tool" : "\(n) tools") to buy"
        }
        // When your own tools can't do it safely (risk: shanks rubbing, pockets left uncut), the
        // plan with tools to buy is the recommended one, shown first.
        // A shank rubbing the walls is never offered when a longer tool fixes it: those plans
        // go, and the ones with the tool to buy take their place.
        let rubs: (StrategyEngine.Candidate) -> Bool = { $0.reasons.contains { $0.contains("its shank rubs") } }
        if extra.contains(where: { !rubs($0) }) {
            planOptions.removeAll(where: rubs)
        }
        // Nor one that leaves holes out (too small for your tools) when micro tools to buy make them.
        let unfinished: (StrategyEngine.Candidate) -> Bool = { $0.finish >= StrategyEngine.unmadeHoleFinish }
        if extra.contains(where: { !unfinished($0) }) {
            planOptions.removeAll(where: unfinished)
        }
        if let best = extra.first, planOptions.isEmpty || best.risk < bestOwnedRisk - 0.15 {
            planOptions = extra + planOptions
            recommendedPlan = best.name
        } else {
            planOptions += extra
            recommendedPlan = planOptions.min { ($0.risk, $0.minutes) < ($1.risk, $1.minutes) }?.name
        }
        planCandidates += withBuy
        let more = extra.isEmpty ? "" : "; \(extra.count) would be better with a tool you don't have yet"
        status = planOptions.isEmpty ? "No usable plan: add a flat end mill to your inventory." :
            "Compared \(all.count + withBuy.count) plans; \(StrategyEngine.pareto(all).count) are best at something\(more)"
    }

    /// A risk's fix applied to a plan (and that plan used).
    func applyRemedy(_ r: StrategyEngine.Remedy, to c: StrategyEngine.Candidate) {
        guard planningMachineReady else { errorMessage = planningMachineProblem ?? "Wait for the job's machine to finish loading."; return }
        var fixed = c
        fixed.operations = StrategyEngine.apply(r, to: c.operations)
        fixed.remedies.removeAll { $0 == r }
        fixed.reasons.append("Changed: \(r.title).")
        if case .swap(_, let to) = r.change, let t = toolLookup(to), !fixed.tools.contains(where: { $0.id == to }) { fixed.tools.append(t) }
        // Each fix takes roughly one risk step away.
        fixed.risk = max(fixed.risk - 0.2, 0)
        if let k = planOptions.firstIndex(where: { $0.id == c.id }) { planOptions[k] = fixed }
        usePlan(fixed)
        status = "\(r.title): done. Generate to see it."
    }

    /// The directions the job's setups cut from: the front, and the back when both sides are machined.
    var plannedSides: [String] { twoSided ? ["+z", "-z"] : ["+z"] }

    /// The other sides Coastline makes setups and toolpaths for (automatic workholding).
    var turnedSideNames: [String] {
        guard let part, let stock else { return [] }
        return sideSetupSides(part: part, stock: stock).map { SetupSide.names[$0] }
    }

    /// The setups the part needs, every one of the stock's six sides considered, and what each
    /// cuts; after a plan, what its toolpaths leave out. From the part check (line of sight and
    /// reach, not the simulation). nil while the part check isn't in.
    var planCoverage: PlanCoverage? {
        guard let findings = dfmFindings(inventory: inventoryLookup()) else { return nil }
        let proposed = PlanCoverage.propose(findings)
        let sides = PlanCoverage.sides.filter { proposed.contains($0) || (!operations.isEmpty && plannedSides.contains($0)) }
        return PlanCoverage.assess(findings, sides: sides, jobTools: Set(operations.filter(\.enabled).compactMap(\.toolID)),
                                   toolpathSides: Set(plannedSides + turnedSideNames), room: setupRoom, stock: stock.map(setup.stockSize))
    }

    /// "2 features are not in the toolpaths." when the plan leaves some out, else nil.
    var coverageGapNote: String? {
        guard !operations.isEmpty, let n = planCoverage?.open, n > 0 else { return nil }
        return "\(n) feature\(n == 1 ? " is" : "s are") not in the toolpaths."
    }

    /// Lights a setup's faces on the part (green) and frames them.
    func selectCoverage(_ cut: PlanCoverage.SetupCut?) {
        guard let cut else { selectFinding(nil); return }
        selectFinding(DFMFinding(id: "setup\(cut.side)", category: .ok, title: "Setup \(cut.number)", summary: "", faces: cut.faces))
    }

    /// The tools the current job uses that aren't in the inventory yet (Coastline suggestions):
    /// on the Shopping List, flagged in Machining. The simulation uses them like owned ones.
    var jobToolsToBuy: [Tool] {
        var seen = Set<UUID>()
        return operations.filter(\.enabled).compactMap { $0.toolID.flatMap(toolLookup) }
            .filter { $0.isSuggestion && seen.insert($0.id).inserted }
    }

    func usePlan(_ c: StrategyEngine.Candidate) {
        guard planningMachineReady else { errorMessage = planningMachineProblem ?? "Wait for the job's machine to finish loading."; return }
        for tool in c.tools {
            jobResources.tools.removeAll { $0.id == tool.id }
            jobResources.tools.append(tool)
        }
        // Threads and engraving are yours (no plan makes them): they stay, at the end.
        operations = c.operations + operations.filter { [.thread, .engrave].contains($0.kind) }
        planNotes = c.reasons
        planEstimate = c.minutesByOp
        chosenPlan = c.name
    }

    /// "Use This Plan": the plan, and its toolpaths start building at once (a build of the
    /// plan before is stopped first; its finished operations stay cached).
    func usePlanAndBuild(_ c: StrategyEngine.Candidate, inventory: Inventory) async {
        if isGenerating {
            cancelGenerationNow()
            while isGenerating { try? await Task.sleep(for: .milliseconds(100)) }
        }
        usePlan(c)
        guard chosenPlan == c.name else { return }
        await generateOrApply(inventory: inventory)
    }

    /// After generating: teach the time model what the simulation says each operation takes.
    func learnFromGeneration() {
        guard !planEstimate.isEmpty, !sideResults.isEmpty else { return }
        // Simulated minutes per operation over the whole job: both sides, every depth slice and
        // strip of it.
        var simulated: [UUID: Double] = [:]
        for r in sideResults {
            for (k, path) in r.paths.enumerated() where k < r.planned.count {
                simulated[r.planned[k].operation.id, default: 0] += TimeEstimate.seconds([path], machine: machine) / 60
            }
        }
        var cal = calibration
        for op in operations {
            guard let est = planEstimate[op.id], let sim = simulated[op.id], sim > 0 else { continue }
            // The estimate already includes the current factor: learn the raw model's error.
            let raw = est / (calibration.factor[op.kind.rawValue] ?? 1)
            cal.learn(op.kind, estimated: raw, simulated: sim)
        }
        calibration = cal
        if let data = try? JSONEncoder().encode(cal) {
            UserDefaults.standard.set(data, forKey: Self.calibrationStorageKey(for: planningMachineReference))
        }
    }

    private static func calibrationStorageKey(for reference: PlanningMachineReference) -> String {
        if reference.isLegacy { return "strategyCalibration" }
        return "strategyCalibration." + ((try? reference.fingerprint()) ?? "unavailable")
    }

    static func loadCalibration(for reference: PlanningMachineReference = .legacy) -> StrategyEngine.Calibration {
        guard let d = UserDefaults.standard.data(forKey: calibrationStorageKey(for: reference)),
              let c = try? JSONDecoder().decode(StrategyEngine.Calibration.self, from: d) else { return StrategyEngine.Calibration() }
        return c
    }
}
