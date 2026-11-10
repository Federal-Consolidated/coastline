import CoastlineCore
import Foundation

/// The guided workflow: six stages, each with a status and the reason
/// for it, free to go back and forth. Coastline proposes; every stage shows why.
enum JobStage: Int, CaseIterable, Identifiable {
    case partStock, holding, prep, clampKit, machining, review
    // Keep existing raw values for older callers; holding/prep are setup detail views.
    case stock, planning
    // Setups (workholding, orientation, work zero) before Plan: the plan's cuts are checked
    // against the chosen fixtures, and Plan shows what the part needs (Machinability).
    static let workflow: [Self] = [.partStock, .stock, .clampKit, .planning, .machining, .review]
    var workflowStage: Self { self == .holding || self == .prep ? .clampKit : self }
    var number: Int { (Self.workflow.firstIndex(of: workflowStage) ?? 0) + 1 }
    var next: Self? { Self.workflow.dropFirst(number).first }
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .partStock: "Part"
        case .stock: "Stock"
        case .planning: "Plan"
        case .holding: "Holding"
        case .prep: "Stock prep"
        case .clampKit: "Setups"
        case .machining: "Toolpaths"
        case .review: "Review"
        }
    }
    var symbol: String {
        switch self {
        case .partStock: "cube.transparent"
        case .stock: "shippingbox"
        case .planning: "sparkles"
        case .holding: "hand.raised"
        case .prep: "square.3.layers.3d.down.right"
        case .clampKit: "square.and.arrow.down.on.square"
        case .machining: "point.topleft.down.to.point.bottomright.curvepath"
        case .review: "checklist"
        }
    }
}

/// How the stock is held for the job (stage 2).
typealias HoldingPath = Setup.Workholding

extension Setup.Workholding {
    var letter: String { ["A", "B", "C", "D", "E"][Self.allCases.firstIndex(of: self)!] }
    var title: String {
        switch self {
        case .clampKit: "Clamp kit directly"
        case .bedOnly: "Flat on the bed only"
        case .prepThenKit: "Prep on the bed, then the clamp kit"
        case .shoulders: "Shoulders, then the clamp kit"
        case .custom: "Vise / custom fixture"
        }
    }
    /// The release that brings it (nil: available now).
    var arrives: String? {
        switch self {
        case .clampKit, .prepThenKit, .bedOnly, .shoulders, .custom: nil
        }
    }
}

struct StageStatus {
    /// todo: the next thing to do there (nothing wrong); attention: something to look at.
    enum State { case done, todo, attention, blocked, notNeeded, later }
    var state: State
    var why: String
}

extension AppModel {
    /// Explicit user choices take precedence over automatic fixture recommendations.
    var holdingPath: HoldingPath {
        setup.holding ?? (setup.onBed ? .bedOnly : setup.shoulders != nil ? .shoulders : setup.downsizeHeight != nil ? .prepThenKit : .clampKit)
    }

    /// What each path would mean for this part and stock, and whether it's the one to use.
    func holdingAssessment(_ path: HoldingPath) -> (possible: Bool, recommended: Bool, why: String) {
        guard let part, let stock else { return (false, false, "Choose a part and stock first.") }
        let option = stockOptions(forClampKit: true).first { $0.axes == setup.stockAxes }
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        let partSize = hi - lo
        let raw = setup.rawStockSize(stock)
        let kitMax = UniversalClamp.onJaw(softJaw: false).upperBound
        let needX = GripZones.neededHeight(partX: partSize.x)
        switch path {
        case .custom:
            return (true, false, "Use your own vise or fixture without reserving a clamp-kit frame. Set its placement and setup notes in the Workholding step. Custom fixture geometry is not included in collision checks.")
        case .clampKit:
            let fits = option?.workable == true && option?.prepHeight == nil && option?.viaShoulders != true
            let why: String
            if fits {
                why = "The stock (\(Length.mm(raw.x)) mm tall) fits the kit's grip as it is: no prep, straight to machining."
            } else if option?.viaShoulders == true {
                why = "Not as a whole bar: the part with its frame needs \(Length.mm(needX)) mm\(raw.x > kitMax ? " and the kit grips \(Length.mm(kitMax)) mm" : ""). Held by the ends (D) it works."
            } else if raw.x <= kitMax && needX > raw.x {
                why = "The kit grips this \(Length.mm(raw.x)) mm stock, but the part with its frame needs \(Length.mm(needX)) mm: taller stock, or scale the part."
            } else if let reason = option?.reason {
                why = "This setup needs more clamping stock: \(reason). Choose another holding method or larger stock."
            } else {
                why = "At \(Length.mm(raw.x)) mm tall the stock doesn't fit the kit's grip (up to \(Length.mm(kitMax)) mm without soft jaws)."
            }
            return (fits, fits, why)
        case .prepThenKit:
            let possible = option?.workable == true && option?.prepHeight != nil
            let plan = flatPrepPlan
            let steps = plan.map { p in "face end A\(p.rounds > 0 ? ", then the edge down to \(Length.mm(p.target)) mm in \(p.rounds) round\(p.rounds == 1 ? "" : "s")" : "")" } ?? "square it and mill it down"
            let why: String
            if possible {
                why = "Too tall for the kit as bought: on the bed, \(steps); then into the kit at full length."
            } else if needX > kitMax {
                why = "Milling the whole edge down can't help: the part with its frame needs \(Length.mm(needX)) mm, more than the kit grips."
            } else {
                why = "Not needed: the stock fits the kit as it is."
            }
            return (possible, possible, why)
        case .bedOnly:
            let b = bedAssessment()
            // Recommended only when the clamp kit can't do it, with or without prep.
            let kitWorks = option?.workable == true
            return (b.possible, b.possible && !kitWorks, b.why)
        case .shoulders:
            guard let proposal = shoulderProposal else {
                return (false, false, "Needs a bar at least \(Length.mm(partSize.x)) mm tall and \(Length.mm(partSize.y + 2 * Shoulders.gripZone + 2)) mm long: the part between the clamps' jaws at the ends.")
            }
            let taller = needX > kitMax || needX > raw.x
            let cut = raw.x - proposal.height
            if cut < 0.01 {
                return (true, taller, "The kit grips the bar's two ends only (\(Length.mm(Shoulders.gripZone)) mm each): the part can reach the top and bottom edges, no frame strips along them. Nothing to mill first.")
            }
            return (true, taller, taller
                    ? "The part (with its frame) needs \(Length.mm(needX)) mm: taller than the kit grips (\(Length.mm(kitMax)) mm). A \(Length.mm(proposal.length)) mm shoulder at each end is milled down to \(Length.mm(proposal.height)) mm for the jaws; the full-height middle carries the part."
                    : "Instead of milling the whole edge down, only two \(Length.mm(proposal.length)) mm shoulders lose \(Length.mm(cut)) mm: much less to cut, the bar stays \(Length.mm(raw.x)) mm tall in the middle.")
        }
    }

    /// A stage's name for this job: on path B stage 4 is the bed, not the clamp kit.
    func title(_ stage: JobStage) -> String {
        stage.title
    }

    /// Each stage's state and the reason, shown in the stage bar.
    /// Why Generate can't run yet (nil: it can): an earlier step still blocked, no operations,
    /// or an operation without a tool.
    var generationBlocker: String? {
        if fixturePlacement != nil { return "Save or cancel the fixture placement before generating the job." }
        for st in [JobStage.partStock, .stock, .holding, .prep, .clampKit] where status(st).state == .blocked {
            return "First: \(st.title), \(status(st).why.prefix(1).lowercased() + status(st).why.dropFirst())"
        }
        let ops = operations.filter(\.enabled)
        if ops.isEmpty { return "First: find the best plan (or a quick suggestion) above." }
        if ops.contains(where: { $0.toolID == nil || jobTool($0.toolID!) == nil }) {
            return "First: choose a tool for every operation."
        }
        return nil
    }

    func status(_ stage: JobStage) -> StageStatus {
        let hasPart = part != nil, hasStock = stock != nil
        switch stage {
        case .partStock:
            if !hasPart { return StageStatus(state: .todo, why: "Import a part (STEP, IGES or Rhino).") }
            return StageStatus(state: .done, why: "Part loaded at its designed size. Next, choose material from your stock library.")
        case .stock:
            if !hasPart { return StageStatus(state: .later, why: "Load a part first.") }
            if !hasStock { return StageStatus(state: .todo, why: "Choose the stock you have.") }
            if let stock, (stockLookup(stock.id)?.quantity ?? 0) <= 0 { return StageStatus(state: .attention, why: "This blank is not marked as owned. Confirm you have it before planning with your library.") }
            if stockOptions().first(where: { $0.axes == setup.stockAxes })?.workable != true {
                return StageStatus(state: .blocked, why: "The part is larger than this stock as oriented: turn it, scale it (Fit), or choose other stock.")
            }
            if let error = stockContainmentIssues.first(where: { $0.severity == .error }) {
                return StageStatus(state: .blocked, why: error.message)
            }
            return StageStatus(state: .done, why: "The part fits your stock. Next, choose the workholding in Setups.")
        case .planning:
            guard hasPart && hasStock else { return StageStatus(state: .later, why: "Load a part and choose your stock first.") }
            if isPlanningJob { return StageStatus(state: .todo, why: "Comparing your tools, generating cuts and checking fixture clearance.") }
            if setup.planFromFixtureLibrary, let plan = libraryWorkholdingPlan, !plan.complete {
                return StageStatus(state: .blocked, why: "No complete setup sequence. Resolve the workholding issues below.")
            }
            if !programs.isEmpty {
                // Some toolpaths made is not the job done: what no setup cuts stays open.
                if let gaps = coverageGapNote { return StageStatus(state: .attention, why: "\(gaps) See Setups below.") }
                if setup.planFromFixtureLibrary, libraryWorkholdingPlan?.reviewed != true {
                    return StageStatus(state: .attention, why: "Job proposed. Review each setup below, then inspect the toolpaths.")
                }
                return StageStatus(state: .done, why: "Job proposed. Inspect the toolpaths next.")
            }
            return StageStatus(state: .todo, why: "See what the part needs, then build the toolpaths from your tools and workholding.")
        case .holding:
            guard hasPart && hasStock else { return StageStatus(state: .later, why: "After the part and stock.") }
            if setup.planFromFixtureLibrary {
                return StageStatus(state: .done, why: "Automatic workholding from your library. Generate a CAM plan to compare actual cuts with defined jig assemblies.")
            }
            let a = holdingAssessment(holdingPath)
            return StageStatus(state: a.possible ? .done : .blocked, why: "\(holdingPath.title): \(a.why)")
        case .prep:
            guard hasPart && hasStock else { return StageStatus(state: .later, why: "After the part and stock.") }
            if !setup.usesClampKit { return StageStatus(state: .notNeeded, why: "No automatic clamp-kit stock prep for this holding method.") }
            guard let plan = flatPrepPlan else { return StageStatus(state: .notNeeded, why: "No prep: the stock goes straight into the clamp kit.") }
            if plan.issues.contains(where: { $0.severity == .warning }) {
                return StageStatus(state: .attention, why: plan.issues.first { $0.severity == .warning }!.message)
            }
            return StageStatus(state: .done, why: "\(plan.stages.count) clamping\(plan.stages.count == 1 ? "" : "s") on the bed, then the stock fits the kit.")
        case .clampKit:
            guard hasPart && hasStock else { return StageStatus(state: .later, why: "After the part and stock.") }
            if automaticWorkholding {
                let fitted = automaticFixtures(inventoryLookup()).fitted.map(\.name)
                if fitted.isEmpty {
                    return StageStatus(state: .todo, why: "None of your fixtures fits this stock by itself. Choose one to place by hand.")
                }
                return StageStatus(state: .done, why: "Automatic: \(fitted.joined(separator: ", ")) fit\(fitted.count == 1 ? "s" : "") this stock. The plan picks for each cut.")
            }
            if setup.planFromFixtureLibrary || setup.holding == nil {
                if (setup.selectedFixtureIDs ?? []).isEmpty {
                    return StageStatus(state: .todo, why: "Choose the workholding for this stock, then continue to Plan.")
                }
                return StageStatus(state: .done, why: "Workholding chosen. Next, check the part and build the plan.")
            }
            if let error = setupIssues.first(where: { $0.severity == .error }) {
                return StageStatus(state: .blocked, why: error.message)
            }
            if setup.holding == .custom && !setup.planFromFixtureLibrary {
                return StageStatus(state: .attention, why: "\(setup.customFixture.name). Check its placement and notes. Custom fixture geometry is not included in collision checks.")
            }
            if setup.onBed {
                if let w = bedJobPlacement?.issues.first(where: { $0.severity == .warning }) { return StageStatus(state: .attention, why: w.message) }
                return StageStatus(state: .done, why: "On the bed instead of the clamp kit: the stop, the riser and two C-clamps; face \(Length.mm(bedJobStage?.protrusion ?? 0)) mm past the stop.")
            }
            return StageStatus(state: setupIssues.contains { $0.severity == .warning } ? .attention : .done,
                               why: "Universal clamps across both T-slots\(setup.clampSoftJaw ? "" : ", soft jaws off"); face \(Length.mm(effectiveProtrusion)) mm past the jaws.")
        case .machining:
            guard hasPart && hasStock else { return StageStatus(state: .later, why: "After the setup.") }
            if operations.isEmpty { return StageStatus(state: .todo, why: "Build the plan first.") }
            if isGenerating { return StageStatus(state: .todo, why: "Generating in the background: look at and simulate what's ready while the rest is made.") }
            if failedOperationCount > 0 { return StageStatus(state: .blocked, why: "\(failedOperationCount) operation\(failedOperationCount == 1 ? "" : "s") failed: Retry redoes only \(failedOperationCount == 1 ? "it" : "them").") }
            if programs.isEmpty { return StageStatus(state: .todo, why: "Next: generate the toolpaths for the \(operations.filter(\.enabled).count) operations.") }
            if !(programs + prepPrograms).allSatisfy(\.report.passed) { return StageStatus(state: .blocked, why: "A program failed its safety check.") }
            if let gaps = coverageGapNote { return StageStatus(state: .attention, why: "Toolpaths ready. \(gaps) See Plan.") }
            if setup.planFromFixtureLibrary {
                return StageStatus(state: libraryWorkholdingPlan?.reviewed == true ? .done : .attention,
                                   why: "Toolpaths ready. Review the proposed setups in Plan, then simulate and check the cuts here.")
            }
            if setup.holding == .custom {
                return StageStatus(state: .attention, why: "Toolpaths ready. Review the simulation and check your custom fixture's clearance; its geometry is not modelled.")
            }
            return StageStatus(state: .done, why: "Toolpaths ready and safety-checked.")
        case .review:
            guard !programs.isEmpty else { return StageStatus(state: .later, why: "After the toolpaths.") }
            return StageStatus(state: .todo, why: "Next: walk through the steps (Tour), then export the guided job for the sender.")
        }
    }

    /// Goes to a stage: the inspector shows it and the 3D view shows what it's about.
    func enter(_ stage: JobStage) {
        self.stage = stage
        switch stage {
        case .partStock, .stock:
            // Only the stock as bought and the part in it (no machine, no clamps).
            switchingView = true
            viewSide = 0
            prepStage = 0
            switchingView = false
            inspectorTab = .setup
            layoutScene()
            focusWork()
        case .holding:
            if hasPrep { show(side: -1, stage: -1) } else { show(side: 0, stage: 0) }
            inspectorTab = .setup
            layoutScene()
        case .planning:
            inspectorTab = .setup
            show(side: 0, stage: 0)
            layoutScene()
        case .prep:
            if hasPrep { show(side: -1, stage: 0) }
            inspectorTab = .setup
            layoutScene()
        case .clampKit:
            show(side: 0, stage: 0)
            inspectorTab = .setup
            layoutScene()
        case .machining, .review:
            inspectorTab = .machining
            // Back from a setup step: rebuild the side's paths and simulation (the setup steps
            // showed the plain stock).
            if !sideResults.isEmpty || !prepResults.isEmpty {
                if viewSide < 0 && prepResults.isEmpty { viewSide = 0 }
                showSide()
            }
            layoutScene()
        }
    }

    func canVisit(_ stage: JobStage) -> Bool {
        switch stage {
        case .partStock: true
        case .stock: part != nil
        case .planning, .holding, .prep, .clampKit: part != nil && stock != nil
        case .machining: !operations.isEmpty || !programs.isEmpty
        case .review: !programs.isEmpty && !isGenerating
        }
    }
}
