import CoastlineCore
import Foundation

/// The guided workflow: six stages, each with a status and the reason
/// for it, free to go back and forth. Coastline proposes; every stage shows why.
enum JobStage: Int, CaseIterable, Identifiable {
    // Raw values are kept from older sessions.
    case partStock = 0, setups = 3, machining = 4, review = 5
    case stock = 6, planning = 7
    // Setups (workholding, orientation, work zero) before Plan: the plan's cuts are checked
    // against the chosen fixtures, and Plan shows what the part needs (Machinability).
    static let workflow: [Self] = [.partStock, .stock, .setups, .planning, .machining, .review]
    var number: Int { (Self.workflow.firstIndex(of: self) ?? 0) + 1 }
    var next: Self? { Self.workflow.dropFirst(number).first }
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .partStock: "Part"
        case .stock: "Stock"
        case .planning: "Plan"
        case .setups: "Setups"
        case .machining: "Toolpaths"
        case .review: "Review"
        }
    }
    var symbol: String {
        switch self {
        case .partStock: "cube.transparent"
        case .stock: "shippingbox"
        case .planning: "sparkles"
        case .setups: "square.and.arrow.down.on.square"
        case .machining: "point.topleft.down.to.point.bottomright.curvepath"
        case .review: "checklist"
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
    /// A stage's name for this job.
    func title(_ stage: JobStage) -> String {
        stage.title
    }

    /// Why Generate can't run yet (nil: it can): an earlier step still blocked, no operations,
    /// or an operation without a tool.
    var generationBlocker: String? {
        if fixturePlacement != nil { return "Save or cancel the fixture placement before generating the job." }
        for st in [JobStage.partStock, .stock, .setups] where status(st).state == .blocked {
            return "First: \(st.title), \(status(st).why.prefix(1).lowercased() + status(st).why.dropFirst())"
        }
        let ops = operations.filter(\.enabled)
        if ops.isEmpty { return "First: find the best plan (or a quick suggestion) above." }
        if ops.contains(where: { $0.toolID == nil || jobTool($0.toolID!) == nil }) {
            return "First: choose a tool for every operation."
        }
        return nil
    }

    /// Each stage's state and the reason, shown in the stage bar.
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
        case .setups:
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
            return StageStatus(state: .attention, why: "\(setup.customFixture.name). Check its placement and notes. Custom fixture geometry is not included in collision checks.")
        case .machining:
            guard hasPart && hasStock else { return StageStatus(state: .later, why: "After the setup.") }
            if operations.isEmpty { return StageStatus(state: .todo, why: "Build the plan first.") }
            if isGenerating { return StageStatus(state: .todo, why: "Generating in the background: look at and simulate what's ready while the rest is made.") }
            if failedOperationCount > 0 { return StageStatus(state: .blocked, why: "\(failedOperationCount) operation\(failedOperationCount == 1 ? "" : "s") failed: Retry redoes only \(failedOperationCount == 1 ? "it" : "them").") }
            if programs.isEmpty { return StageStatus(state: .todo, why: "Next: generate the toolpaths for the \(operations.filter(\.enabled).count) operations.") }
            if !programs.allSatisfy(\.report.passed) { return StageStatus(state: .blocked, why: "A program failed its safety check.") }
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
            return StageStatus(state: .todo, why: "Next: simulate the job, then run it from Control.")
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
            switchingView = false
            inspectorTab = .setup
            layoutScene()
            focusWork()
        case .planning, .setups:
            inspectorTab = .setup
            show(side: 0)
            layoutScene()
        case .machining, .review:
            inspectorTab = .machining
            // Back from a setup step: rebuild the side's paths and simulation (the setup steps
            // showed the plain stock).
            if !sideResults.isEmpty {
                if viewSide < 0 { viewSide = 0 }
                showSide()
            }
            layoutScene()
        }
    }

    func canVisit(_ stage: JobStage) -> Bool {
        switch stage {
        case .partStock: true
        case .stock: part != nil
        case .planning, .setups: part != nil && stock != nil
        case .machining: !operations.isEmpty || !programs.isEmpty
        case .review: !programs.isEmpty && !isGenerating
        }
    }
}
