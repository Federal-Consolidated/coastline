import CoastlineCore
import Foundation
import simd

/// A plain stand-in for the vise to buy, drawn where it would hold the stock (so the stock
/// isn't shown floating): a floor, two jaws gripping across Y with their fronts at the table
/// edge, and the screw block. Not a real fixture: no collision or clearance check uses it.
enum StandInVise {
    static let floor = 12.0, jawHeight = 18.0, jawDepth = 40.0, jawWidth = 12.0, facePast = 2.0

    /// Its boxes (and the table's) in a setup's work frame: the stock of size `s` sits on the
    /// floor centred across the jaws, its physical face `facedBefore` mm below work Z0 (what an
    /// earlier clamping faced away) and `facePast` past the table edge; the jaws' fronts at work
    /// Z `jawFront`. One list for the workspace drawing and the clearance check.
    static func boxes(stockSize s: SIMD3<Double>, facedBefore: Double, jawFront: Double,
                      table t: MachineTable) -> [(name: String, min: SIMD3<Double>, max: SIMD3<Double>)] {
        let edge = -facedBefore - facePast, bottom = -s.x / 2, w = jawWidth
        let front = min(jawFront, edge), back = front - jawDepth
        let tableTop = bottom - floor
        return [
            ("floor", SIMD3(tableTop, -s.y / 2 - w - 4, back - 6), SIMD3(bottom, s.y / 2 + w + 26, front)),
            ("fixedjaw", SIMD3(bottom, -s.y / 2 - w, back), SIMD3(bottom + jawHeight, -s.y / 2, front)),
            ("movingjaw", SIMD3(bottom, s.y / 2, back), SIMD3(bottom + jawHeight, s.y / 2 + w, front)),
            ("screw", SIMD3(bottom, s.y / 2 + w + 8, back + 10), SIMD3(bottom + 10, s.y / 2 + w + 26, front - 10)),
            ("table", SIMD3(tableTop - t.thickness, -200, edge - (t.northZ - t.backZ)), SIMD3(tableTop, 200, edge)),
        ]
    }

    /// The clearance field of those boxes (the jaws, floor, screw block and the table).
    static func field(stockSize s: SIMD3<Double>, facedBefore: Double, jawFront: Double, table t: MachineTable) -> FixtureField {
        let triangles = boxes(stockSize: s, facedBefore: facedBefore, jawFront: jawFront, table: t)
            .flatMap { FixtureField.boxTriangles(min: $0.min, max: $0.max) }
        return FixtureField(triangles: triangles, regionMin: SIMD2(-s.x / 2 - 40, -s.y / 2 - 80), regionMax: SIMD2(s.x / 2 + 40, s.y / 2 + 80))
    }
}

/// Workholding Coastline suggests buying for a setup nothing you own holds.
struct WorkholdingToBuy: Identifiable, Hashable {
    /// The setup's side ("+y").
    var id: String
    var setup: Int
    var title: String
    var detail: String
}

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
            // The safest; of those about as quick, the finest (StrategyEngine.pick: a small
            // drift in the time model never changes the recommendation). Planning the same job
            // again keeps the plan it has when that is still one of them (every generation
            // teaches the time model a little; that alone shouldn't move the badge).
            let safest = planOptions.map(\.risk).min() ?? 0
            let safe = planOptions.filter { $0.risk <= safest + 1e-9 }
            let kept = currentPlanSignature.flatMap { s in StrategyEngine.pool(safe) { $0.minutes }.first { $0.signature == s } }
            recommendedPlan = (kept ?? StrategyEngine.pick(safe) { $0.minutes })?.name
        }
        planCandidates += withBuy
        let more = extra.isEmpty ? "" : "; \(extra.count) would be better with a tool you don't have yet"
        status = planOptions.isEmpty ? "No usable plan: add a flat end mill to your inventory." :
            "Compared \(all.count + withBuy.count) plans; \(StrategyEngine.pareto(all).count) are best at something\(more)"
    }

    /// The job's plan as StrategyEngine.Candidate.signature spells it (its passes and their
    /// tools, without the threads and engraving no plan makes), or nil before a plan is used.
    var currentPlanSignature: String? {
        guard chosenPlan != nil else { return nil }
        return operations.filter { ![.thread, .engrave].contains($0.kind) }.map { op in
            op.kind.rawValue + ":" + (op.toolID.flatMap { jobTool($0)?.name } ?? "") + (op.pocketsOnly == true ? "(pockets)" : "")
        }.joined(separator: " ")
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
        // Once generated, only the turned sides that got toolpaths count (a side setup the
        // machine can't reach is left out with a note; its features stay open here).
        let turned = sideResults.isEmpty ? turnedSideNames
            : sideResults.filter { $0.side >= 2 && SetupSide.names.indices.contains($0.side) }.map { SetupSide.names[$0.side] }
        return PlanCoverage.assess(findings, sides: sides, jobTools: Set(operations.filter(\.enabled).compactMap(\.toolID)),
                                   toolpathSides: Set(plannedSides + turned), room: setupRoom, stock: stock.map(setup.stockSize))
    }

    /// "2 features are not in the toolpaths." when the plan leaves some out, else nil.
    var coverageGapNote: String? {
        guard !operations.isEmpty, let n = planCoverage?.open, n > 0 else { return nil }
        return "\(n) feature\(n == 1 ? " is" : "s are") not in the toolpaths."
    }

    /// The workholding for a side's setup: the plan's fixture for that side, else your library's
    /// fixture fitted to the stock turned that way; none, and why each fixture can't hold it.
    func coverageWorkholding(side: Int) -> (fixture: Fixture?, why: String?) {
        if let step = libraryWorkholdingPlan?.steps.first(where: { $0.side == side }), !isStandIn(step.fixture) { return (step.fixture, nil) }
        guard setup.planFromFixtureLibrary, let stock else { return (nil, nil) }
        let library = inventoryLookup()
        let fit = automaticFixtures(library, stockSize: setupFor(side: side).stockSize(stock))
        if let fixture = fit.fitted.first { return (fixture, nil) }
        let reasons = library.fixtures.filter { $0.quantity > 0 && FixtureMechanism.has($0.assembly) }
            .compactMap { f in fit.why[f.id].map { "\(f.name): \($0)" } }
        return (nil, reasons.isEmpty ? nil : reasons.joined(separator: " "))
    }

    /// The vise to buy as the fixture of an end setup's step: no model (the workspace draws
    /// StandInVise), quantity 0, its stand-out and how to grip in the notes.
    /// The vise to buy as the fixture of one clamping of an end setup: no model (StandInVise
    /// draws and checks it), quantity 0. Its face past the table counts from work Z0, so it is
    /// StandInVise.facePast plus what earlier clampings faced away; its two jaw patches sit at
    /// `jawFront` (work Z) and the notes say how to clamp.
    func standInFixture(side: Int, clamping: Int, stockSize s: SIMD3<Double>, facedBefore: Double, jawFront: Double,
                        facing: Double?) -> Fixture {
        let opening = Int((s.y + 1).rounded(.up))
        let how: String
        if let facing {
            how = (clamping == 0 ? "" : "Slide the bar toward the spindle until its faced end stands \(Length.mm(StandInVise.facePast)) mm past the table edge again. ")
                + "Grip the bar's long faces in the jaws at least \(Length.mm(facing + 3)) mm behind its end, the end standing \(Length.mm(StandInVise.facePast)) mm past the table edge and the rest out the back. This clamping faces \(Length.mm(facing)) mm off the end."
        } else {
            how = "Slide the bar toward the spindle until its faced end stands \(Length.mm(StandInVise.facePast)) mm past the table edge, and grip it again with the jaws at the table edge. Touch off Z on the faced end."
        }
        var f = Fixture(id: Self.standInID(side: side, clamping: clamping), name: "Vise to buy (opens to \(opening) mm)", kind: .vise, quantity: 0,
                        height: StandInVise.floor, notes: how + " Bolt the vise to a T-slot with M4 hardware.")
        var p = FixturePlanningProfile()
        p.stockSize = Vec3(s.x, s.y, s.z)
        p.facePastTable = StandInVise.facePast + facedBefore
        let z = min(jawFront, -facedBefore - StandInVise.facePast) - StandInVise.jawDepth / 2
        var a = FixturePlanningProfile.Contact(point: Vec3(0, -s.y / 2, z), radius: 6), b = FixturePlanningProfile.Contact(point: Vec3(0, s.y / 2, z), radius: 6)
        a.normal = .y; b.normal = .y
        p.contacts = [a, b]
        f.planning = p
        return f
    }

    static func standInID(side: Int, clamping: Int = 0) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000B%02d%02d", side, clamping))!
    }

    /// The fixture is the vise to buy (a placeholder), not one you own.
    func isStandIn(_ f: Fixture) -> Bool { f.id.uuidString.hasPrefix("00000000-0000-4000-8000-0000000B") }

    /// The jaws' front (work Z) of the vise to buy as the workspace shows it: from the step's
    /// jaw patches, else behind the end piece the setup faces off.
    func standInJawFront(side: Int) -> Double {
        if let f = displayedJobFixture, isStandIn(f), let z = f.planning?.contacts.first?.point.z { return z + StandInVise.jawDepth / 2 }
        return -(endPieceThickness(side: side) + 3)
    }

    /// Material a stand-in clamping's step has already faced off the shown stock's front.
    var standInFacedBefore: Double {
        guard let f = displayedJobFixture, isStandIn(f), let p = f.planning else { return 0 }
        return max(p.facePastTable - StandInVise.facePast, 0)
    }

    /// The plan has a setup held by workholding you don't have yet: running waits for it.
    var planWaitsForWorkholding: Bool { libraryWorkholdingPlan?.steps.contains { isStandIn($0.fixture) } ?? false }

    /// What to buy when nothing you own holds the stock turned to `side`: a vise wide enough for
    /// it, the face at the table edge and the rest out the back (FixtureMechanism.maxFacePastTable).
    func workholdingToBuy(side: Int, number: Int) -> WorkholdingToBuy? {
        guard setup.planFromFixtureLibrary, let stock, SetupSide.names.indices.contains(side), bookendMountTable != nil else { return nil }
        let hold = coverageWorkholding(side: side)
        guard hold.fixture == nil else { return nil }
        let s = setupFor(side: side).stockSize(stock)
        let opening = Int((s.y + 1).rounded(.up))
        let facing = side < 2 ? "side \(side == 0 ? "A" : "B") up" : "its \(SetupSide.words(side)) toward the spindle"
        return WorkholdingToBuy(id: SetupSide.names[side], setup: number, title: "A vise that opens to \(opening) mm or more",
                                detail: "For setup \(number), the stock with \(facing). Its jaws hold the \(Length.mm(s.y)) mm width with the face at the table edge and the rest out the back. Bolt it to a T-slot with M4 hardware."
                                    + (hold.why.map { " Why yours don't: " + $0 } ?? ""))
    }

    /// The stand-in vise is drawn: the shown setup has nothing you own to hold it.
    var showsStandInVise: Bool {
        guard setup.planFromFixtureLibrary, fixturePlacement == nil, !showingStockOnly, stock != nil else { return false }
        if let f = displayedJobFixture { return isStandIn(f) }
        return workholdingToBuy(side: max(viewSide, 0), number: 0) != nil
    }

    /// The workholding to buy for this job: one per setup nothing you own holds.
    var jobWorkholdingToBuy: [WorkholdingToBuy] {
        guard let coverage = planCoverage else { return [] }
        return coverage.setups.compactMap { cut in SetupSide.index(cut.side).flatMap { workholdingToBuy(side: $0, number: cut.number) } }
    }

    /// Lights a setup's faces on the part (green) and frames them, and shows the stock as that
    /// setup mounts it: turned with that side toward the spindle, in the plan's fixture for it
    /// when there is one; without a fixture (and a status line saying so) when none holds it.
    func selectCoverage(_ cut: PlanCoverage.SetupCut?) {
        guard let cut else { selectFinding(nil); return }
        selectFinding(DFMFinding(id: "setup\(cut.side)", category: .ok, title: "Setup \(cut.number)", summary: "", faces: cut.faces))
        guard let side = SetupSide.index(cut.side), part != nil, stock != nil else { return }
        selectedLibraryStep = libraryWorkholdingPlan?.steps.first { $0.side == side }?.id
        if viewSide != side { show(side: side) } else { layoutScene() }
        focusWork()
        let facing = side < 2 ? "side \(side == 0 ? "A" : "B") up" : "its \(SetupSide.words(side)) toward the spindle"
        // Why a held setup has no toolpaths (the plan's note for it), when it has none.
        let title = Self.setupTitle(side: side, twoSided: twoSided)
        let dropped = planNotes.first { $0.hasPrefix(title + ": ") && $0.contains("left out") }
            .map { " " + $0.dropFirst(title.count + 2).prefix(1).uppercased() + $0.dropFirst(title.count + 3) } ?? ""
        let hold = coverageWorkholding(side: side)
        if let fixture = hold.fixture ?? displayedJobFixture {
            status = "Setup \(cut.number): the stock with \(facing), in \(fixture.name).\(dropped)"
        } else if setup.planFromFixtureLibrary {
            let buy = workholdingToBuy(side: side, number: cut.number).map { " To buy: \($0.title.prefix(1).lowercased() + $0.title.dropFirst()), on the Shopping List." } ?? ""
            status = "Setup \(cut.number): the stock with \(facing). No fixture you own holds it this way.\(buy)"
        }
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
