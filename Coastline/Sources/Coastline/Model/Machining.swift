import CoastlineCore
import Foundation
import simd
import Viewport

/// One G-code program: consecutive operations that use the same tool (a tool change between
/// programs is a guided step in the sender).
struct ToolProgram: Identifiable {
    var id: String { "\(index)" }
    var index: Int
    /// 0 = side A, 1 = side B (two-sided jobs).
    var side: Int = 0
    var tool: Tool
    var operations: [Operation]
    var rpm: Double
    var gcode: String
    var report: GCodeValidator.Report
    var seconds: Double
    /// Engine warnings for this program's operations, and the shortest safe stick-out.
    var warnings: [String] = []
    var minStickout: Double?
    /// Where the tool would come too close to a clamp, stop or the table.
    var clearanceHits: [FixtureClearance.Hit] = []
    /// A name for programs that aren't a list of operations (prep on the side clamps).
    var title: String?
    /// The surface probing that comes first, for an engraving that follows the real face.
    var surfaceProbe: String?
    var workholdingStep: LibraryWorkholdingPlan.Step? = nil
    var opsTitle: String { title ?? operations.map(\.title).joined(separator: ", ") }

    var fileName: String {
        let toolName = tool.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\"", with: "in")
            .replacingOccurrences(of: "·", with: "-")
        return String(format: "%02d %@%@ - %@.nc", index + 1, side == 1 ? "Side B " : side >= 2 ? SetupSide.words(side).capitalized + " " : "", operations.map(\.title).joined(separator: " + "), toolName)
    }
}

extension AppModel {
    /// Display colours per move role (sRGB 0–255; rapids dashed).
    static func colour(_ role: Move.Role) -> SIMD4<UInt8> {
        switch role {
        case .rapid: PathColor.rapid
        case .cut: PathColor.cut
        case .plunge: PathColor.plunge
        case .ramp, .lead: PathColor.lead
        case .link: SceneColor.line(150)
        }
    }

    /// Asks the engine for holes and floors, then proposes operations from the inventory.
    func suggestOperations(inventory: Inventory) async {
        guard planningMachineReady else { errorMessage = planningMachineProblem ?? "Load a machine before planning."; return }
        let machineReference = planningMachineReference
        guard let part, let stock else { return }
        status = "Finding features…"
        do {
            let engine = try await liveEngine()
            let m = workTransform(part)
            let f: PartFeatures
            if let cached = cachedFeatures(part, transform: m) {
                f = cached
            } else {
                f = try await engine.features(partID: part.partID, transform: m)
                guard planningMachineReady, planningMachineReference == machineReference else { return }
                features = f
                featuresKey = (part.partID, m)
            }
            if analysis == nil {
                // With access, as runAnalysis: the Machinability section reads the same analysis.
                let result = try? await engine.analyse(partID: part.partID, transform: m, access: true)
                guard planningMachineReady, planningMachineReference == machineReference else { return }
                if result != nil { analysisTransform = m }
                analysis = result
            }
            guard planningMachineReady, planningMachineReference == machineReference else { return }
            let p = OperationPlanner.propose(inventory: inventory, holeDiameters: f.holes.map(\.diameter),
                                             hasFloors: f.floorLevels.contains { $0 < -1e-6 }, freeform: (analysis?.freeformArea ?? 0) > 1,
                                             minConcaveRadius: analysis?.minConcaveRadius, faceDepth: min(0.25, setup.topAllowance), machine: machine)
            operations = p.operations + operations.filter { [.thread, .engrave].contains($0.kind) }
            planNotes = p.notes
            _ = stock
            status = "\(p.operations.count) operations suggested"
        } catch {
            errorMessage = "Couldn't analyse the part: \(error)"
        }
    }

    func workTransform(_ part: PartInfo) -> simd_double4x4 {
        setup.partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
    }

    /// The holes and floors found before, when they were found for this part (engine ID) where
    /// it sits now: their positions and depths are in that work frame.
    func cachedFeatures(_ part: PartInfo, transform m: simd_double4x4) -> PartFeatures? {
        guard let f = features, let key = featuresKey, key.partID == part.partID,
              (0..<4).allSatisfy({ simd_distance(key.transform[$0], m[$0]) < 1e-9 }) else { return nil }
        return f
    }

    /// The angle the stock turns between two sides' setups, degrees (0 for the same side).
    func turnAngle(from a: Int, to b: Int) -> Double {
        guard a != b else { return 0 }
        let base = setup.partRotation.transpose
        let r = (setupFor(side: b).partRotation * base) * (setupFor(side: a).partRotation * base).transpose
        let c = min(max((r[0][0] + r[1][1] + r[2][2] - 1) / 2, -1), 1)
        return acos(c) * 180 / .pi
    }

    /// The setup orders worth comparing, the planner's own first (the side setups on the whole
    /// block, then A and B). Side B stays last (it frees the part). Up to three others: every
    /// order; more: the planner's and the one turning least step by step.
    static func setupOrders(_ sides: [Int], turn: (Int, Int) -> Double) -> [[Int]] {
        var unique: [Int] = []
        for s in sides where !unique.contains(s) { unique.append(s) }
        let last = unique.contains(1) ? [1] : []
        let movable = unique.filter { $0 != 1 }
        var out = [movable + last]
        func permutations(_ a: [Int]) -> [[Int]] {
            guard a.count > 1 else { return [a] }
            return a.indices.flatMap { i -> [[Int]] in
                var rest = a; let x = rest.remove(at: i)
                return permutations(rest).map { [x] + $0 }
            }
        }
        if movable.count <= 3 {
            for p in permutations(movable) where p != movable { out.append(p + last) }
        } else if let start = movable.first {
            var order = [start], left = Array(movable.dropFirst())
            while !left.isEmpty {
                let next = left.min { turn(order.last!, $0) < turn(order.last!, $1) }!
                order.append(next); left.removeAll { $0 == next }
            }
            if order != movable { out.append(order + last) }
        }
        return out
    }

    /// The setup for a side (0 = A, 1 = B, the stock turned front-to-back).
    func setupFor(side: Int) -> Setup {
        guard side > 0, let part, let stock else { return setup }
        return setup.forSide(side, partMin: part.boundsMin, partMax: part.boundsMax, stock: stock) ?? setup
    }

    /// The split between the sides in side-A work Z: the parting level (widest section).
    var splitZ: Double? {
        guard twoSided, let part else { return nil }
        if let z = analysis?.partingZ { return z }
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        return -setup.topAllowance - (hi.z - lo.z) / 2
    }

    /// The least stock the clamp jaws must hold when the face is stood out past them, mm.
    static let minimumGrip = 3.0

    /// How far side B cuts past the split when it frees the part on tabs, mm: clears the skin
    /// side A's roughing left (its floor allowance) so only the tabs hold the part.
    static let throughOvershoot = 0.3
    /// One side cut through: what the roughing leaves over the bar's back, mm (the finishing
    /// contour's slot goes through it; the tabs bridge into it).
    static let throughSkin = 0.5

    /// An adaptive roughing operation split into up to four depth slices (each from where the
    /// one above stops), when it has four or more levels; anything else as it is.
    nonisolated static func depthSlices(_ p: EngineClient.PlannedOperation, partBottom: Double) -> [EngineClient.PlannedOperation] {
        guard p.operation.kind == .adaptive, p.data.stepdown > 0.05 else { return [p] }
        let top = p.zTop, bottom = max(p.zMin ?? partBottom, partBottom)
        let depth = top - bottom
        let levels = Int((depth / p.data.stepdown - 1e-9).rounded(.up))
        guard levels >= 4 else { return [p] }
        let count = min(4, levels / 2)
        return (0..<count).map { i in
            var q = p
            let a = Double(levels * i / count), b = Double(levels * (i + 1) / count)
            q.zTop = top - depth * a / Double(levels)
            q.zMin = i == count - 1 ? p.zMin : top - depth * b / Double(levels)
            q.frameTop = p.frameTop ?? p.zTop  // the frame is still at the top for the holder check
            return q
        }
    }

    /// Raster-style 3D finishing (steep & shallow, parallel, waterline) in three strips across
    /// the stock's length, each its own job: the engines share the longest operations. (Scallop
    /// follows distances from the region's edge, so it stays whole.)
    nonisolated static func finishStrips(_ p: EngineClient.PlannedOperation, yRange: ClosedRange<Double>) -> [EngineClient.PlannedOperation] {
        guard [.steepShallow, .parallel, .waterline].contains(p.operation.kind), yRange.upperBound - yRange.lowerBound > 20 else { return [p] }
        let n = 3, w = (yRange.upperBound - yRange.lowerBound) / Double(n)
        return (0..<n).map { i in
            var q = p
            // A hair of overlap so no line is lost at a seam.
            // A hair of overlap so no line is lost at a seam; the outer strips reach past the part.
            q.tile = (i == 0 ? -1e4 : yRange.lowerBound + Double(i) * w - 0.05)...(i == n - 1 ? 1e4 : yRange.lowerBound + Double(i + 1) * w + 0.05)
            return q
        }
    }

    /// Side B's tab range (side B work Z): from the bottom of its through-cut to `tabs.height`
    /// above the split.
    func tabRange(sideB s: Setup, stock: StockItem, split: Double) -> ClosedRange<Double> {
        let at = s.sideBZ(split, stock: stock)
        return (at - Self.throughOvershoot) ... (at + tabs.height)
    }

    /// Generates toolpaths for each side, posts them per tool and runs the safety validator on
    /// the text. Two-sided jobs: side A cuts down to the split; side B (turned front-to-back)
    /// cuts from the back through to the split, leaving holding tabs so the part floats in the
    /// frame until it's cut free (or, without tabs, a thin web between the sides).
    func generateToolpaths(inventory library: Inventory) async {
        captureJobTools()
        let inventory = planningInventory(library)
        guard planningMachineReady else { errorMessage = planningMachineProblem ?? "Load a machine before planning."; return }
        let machine = self.machine, machineReference = planningMachineReference
        guard fixturePlacement == nil else { errorMessage = "Save or cancel the fixture placement before generating."; return }
        guard !isGenerating else { return }
        guard let part, let stock, let material = stock.material else {
            errorMessage = "Choose a part and stock first."
            return
        }
        guard material.validationIssues.isEmpty else {
            errorMessage = "\(material.name): " + material.validationIssues.joined(separator: " ")
            return
        }
        for operation in operations where operation.enabled {
            guard let id = operation.toolID, let tool = inventory.tools.first(where: { $0.id == id }) else {
                errorMessage = "Choose a tool for \(operation.title) before generating."
                return
            }
            let issues = InventoryChecks.check(tool, machine: machine, inventory: inventory).filter { $0.severity == .error }
            guard issues.isEmpty else {
                errorMessage = "\(tool.name): " + issues.map(\.message).joined(separator: " ")
                return
            }
        }
        isGenerating = true
        cancelGeneration = false
        defer { isGenerating = false; generationProgress = nil }
        var libraryCandidates: [LibraryWorkholdingPlanner.Candidate] = []
        let inputSignature = generationSignature
        if setup.planFromFixtureLibrary {
            libraryWorkholdingPlan = nil
            selectedLibraryStep = nil
            status = "Loading eligible fixture assemblies from your library…"
            let size = setup.stockSize(stock)
            let turned = sideSetupSides(part: part, stock: stock).map { SetupSide.stockSize(size, side: $0) }
            do { libraryCandidates = try await prepareLibraryFixtures(inventory: inventory, stock: size, turned: turned) }
            catch { errorMessage = "\(error)"; return }
            guard generationSignature == inputSignature else { status = "Setup changed: generate again."; return }
        }
        // Cut free on tabs (one side, a bar barely thicker than the part): the part at the back of
        // the bar, the extra off the face, so the outline cut goes right through around it.
        if let e = oneSidedThroughExcess, holdWithTabs, abs(setup.topAllowance - e) > 0.01 {
            setup.topAllowance = e
        }
        // The split, the holes and the floors come from the analysis: never from one made before
        // the part was last scaled or turned (both sides would cut to the old split).
        if let pending = analysisTask { await pending.value }
        if part.exact, analysisTransform != workTransform(part) { await runAnalysis() }
        guard planningMachineReady, planningMachineReference == machineReference else { return }
        var base: [EngineClient.PlannedOperation] = operations.compactMap { op in
            guard op.enabled, let id = op.toolID, let tool = inventory.tools.first(where: { $0.id == id }) else { return nil }
            // What the journal learned (chatter → slower) scales the feeds for this tool kind.
            var data = op.cuttingData(tool: tool, material: material, machine: machine)
            let f = learnedFeedFactor(tool: tool, material: material)
            if abs(f - 1) > 1e-6 {
                data.feed = min(data.feed * f, machine.maxFeedAnyDirection)
                data.plungeFeed = min(data.plungeFeed * f, machine.maxFeedAnyDirection)
                data.rampFeed = min(data.rampFeed * f, machine.maxFeedAnyDirection)
            }
            return .init(operation: op, tool: tool, data: data)
        }
        base = Self.threadsLast(base)
        // Rest finishing works where the largest earlier 3D finishing tool couldn't reach.
        for k in base.indices where base[k].operation.kind == .rest {
            base[k].refTool = base[..<k].filter { $0.operation.kind.is3D && $0.tool.diameter > base[k].tool.diameter }
                .map(\.tool).max { $0.diameter < $1.diameter }
        }
        guard !base.isEmpty else { errorMessage = "No enabled operations with a tool."; return }
        errorMessage = nil
        status = "Generating toolpaths…"
        do {
            var box = setup.stockBox(stock)
            // Cutting through: the tools may go a little past the bar's back (air there between
            // the clamps; the fixture check still guards the parallels and the clamp bodies).
            let through = cutsThroughWithTabs
            if through { box.min.z -= 3 }
            let started = Date()
            cachedOps = 0
            var results: [SideResult] = []
            var allPrograms: [ToolProgram] = []
            var generated: [(side: Int, setup: Setup, planned: [EngineClient.PlannedOperation], paths: [OperationToolpath], materialTop: Double)] = []
            // Roughing keeps clear of the fixtures (the planner's clearance check holds every tool to it).
            let keepOut = fixtureKeepOut(candidates: libraryCandidates, stockSize: setup.stockSize(stock))
            let keepOutBelow = 0.5
            // The end pieces stay on through the long-face setups (SideSetups.endPieces): nothing
            // there cuts into them and the part never hangs on tabs; the end setups face them off.
            let ends = endPieces(part: part, stock: stock)
            if let ends {
                let note = "The stock past the part's ends (\(Length.mm(ends.low)) and \(Length.mm(ends.high)) mm) stays on through the long-face setups: the fixture grips it and the bar sits on full-length faces. The end setups face it off."
                if !planNotes.contains(note) { planNotes.append(note) }
            }
            if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
                print("keepout below \(keepOutBelow) rects \(keepOut.count) stock \(setup.stockSize(stock)) inside the stock: \(keepOut.filter { $0.max.x > -setup.stockSize(stock).x / 2 && $0.min.x < setup.stockSize(stock).x / 2 && $0.max.y > -setup.stockSize(stock).y / 2 && $0.min.y < setup.stockSize(stock).y / 2 }.map { String(format: "x %.1f…%.1f y %.1f…%.1f", $0.min.x, $0.max.x, $0.min.y, $0.max.y) })")
            }
            let run = GenerationRun(signature: generationSignature, machine: machine)
            referencePlan = nil
            for side in 0..<(twoSided ? 2 : 1) {
                let s = setupFor(side: side)
                // Text is engraved on the side it was put on, never mirrored onto the other.
                var planned = base.filter { $0.operation.kind != .engrave || ($0.operation.engraving?.side ?? 0) == side }
                // Placement may have changed since this plan was chosen. Facing can only
                // remove the allowance that actually exists, never the finished CAD face.
                var facingLeft = max(s.topAllowance, 0)
                planned = planned.compactMap { p in
                    guard p.operation.kind == .facing else { return p }
                    let depth = min(max(p.operation.faceDepth, 0), facingLeft)
                    guard depth > 1e-6 else { return nil }
                    facingLeft -= depth
                    var p = p
                    p.operation.faceDepth = depth
                    return p
                }
                // The side nobody sees (the tuner's "hidden side"): coarser 3D finishing there.
                if twoSided, tuning.hiddenSide == side {
                    planned = planned.map { p in
                        guard p.operation.kind.is3D else { return p }
                        var p = p
                        p.operation.scallop = min(p.operation.scallop * Tuning.hiddenCuspFactor, 0.03)
                        p.data = p.operation.cuttingData(tool: p.tool, material: material, machine: machine)
                        return p
                    }
                }
                var materialTop = 0.0
                var tabSpec: HoldingTabs?
                var tabBottom = 0.0
                if let split = splitZ {
                    let z: Double
                    if setup.holding == .custom {
                        z = side == 0 ? split : s.sideBZ(split, stock: stock) - Self.throughOvershoot
                    } else if holdWithTabs || ends != nil {
                        z = side == 0 ? split : s.sideBZ(split, stock: stock) - Self.throughOvershoot
                        if side == 1, ends == nil {
                            let r = tabRange(sideB: s, stock: stock, split: split)
                            tabSpec = tabs
                            tabSpec?.height = r.upperBound - r.lowerBound
                            // Out past the widest roughing channel (1.6 diameters + 1 mm) into the frame.
                            let rough = planned.filter { $0.operation.kind == .adaptive }.map(\.tool.diameter).max() ?? 6.35
                            tabSpec?.reach = 1.6 * rough + 3.75
                            tabBottom = r.lowerBound
                        }
                    } else {
                        z = side == 0 ? split + webThickness / 2 : s.sideBZ(split - webThickness / 2, stock: stock)
                    }
                    planned = planned.map { var p = $0; p.zMin = z; return p }
                } else if side == 0, through {
                    // One side, cut through: roughing stops at a thin skin over the bar's back;
                    // the finishing contour cuts its slot through the skin to 0.3 mm past the
                    // back, lifting over the tabs, which bridge the slot into the skin (and the
                    // skin is joined to the whole bar).
                    let r = oneSidedTabRange(stock: stock)
                    let skin = -setup.stockSize(stock).z + Self.throughSkin
                    let contourTool = planned.filter { $0.operation.kind == .contour }.map(\.tool.diameter).max() ?? 3.175
                    tabSpec = tabs
                    tabSpec?.height = r.upperBound - r.lowerBound
                    tabSpec?.reach = contourTool + 2.5
                    tabSpec?.lift = true
                    tabSpec?.skinTop = skin
                    tabBottom = r.lowerBound
                    planned = planned.map { p in
                        var p = p
                        switch p.operation.kind {
                        case .adaptive: p.zMin = skin
                        case .contour: p.zMin = r.lowerBound; p.through = true
                        // 3D finishing doesn't know the tabs (gaps, not geometry): it stops at
                        // their top; the contour finishes the walls below it.
                        case let k where k.is3D: p.zMin = max(p.zMin ?? -.infinity, r.upperBound)
                        default: break
                        }
                        return p
                    }
                }
                // Side B: face the backing down to 0.5 mm above the part (to thickness) first, so
                // everything after starts there instead of 15 mm up in thick stock.
                // Side B: the backing over the part comes off first, so everything after starts
                // 0.5 mm above the part instead of 15 mm up in thick stock. Only around the part
                // (adaptive, a band wide enough for the later tools' collet nuts): the frame
                // keeps its full thickness, rigid, and there's 2–3× less to cut than facing the
                // whole back down.
                if side == 1, s.topAllowance > 1 {
                    materialTop = -(s.topAllowance - 0.5)
                    let widest = planned.map(\.tool.diameter).max() ?? 6.35
                    let nutBand = widest + 1 + FixtureClearance.nutRadius + 0.5
                    planned = planned.map { p in
                        var p = p
                        if p.operation.kind == .facing {
                            p.operation.kind = .adaptive
                            p.data = FeedsEngine.compute(tool: p.tool, material: material, kind: .adaptive, machine: machine)
                            p.zMin = materialTop
                            p.band = nutBand
                        } else {
                            p.zTop = materialTop
                            p.frameTop = 0  // the frame wasn't faced
                            if p.operation.kind == .adaptive { p.band = nil }
                        }
                        return p
                    }
                }
                // Each roughing tool works only what the larger ones before it left: in the
                // pockets they took, their sweep counts as cleared (a 1/16" after a 1/8" works
                // the corners, not the whole pocket again).
                for k in planned.indices where planned[k].operation.kind == .adaptive {
                    planned[k].restFrom = planned[..<k]
                        .filter { $0.operation.kind == .adaptive && $0.tool.diameter > planned[k].tool.diameter + 1e-6 }
                        .map { ($0.tool.diameter, $0.operation.minPocket ?? Operation.defaultMinPocket, $0.operation.leaveRadial) }
                }
                let reach = reachInSetup(candidates: libraryCandidates, stockSize: s.stockSize(stock))
                if reach == nil, ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil { print("reach unknown for side \(side) stock \(s.stockSize(stock))") }
                let (eplo, ephi) = s.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
                let lengthY = (s.partOffsetY - (ephi.y - eplo.y) / 2)...(s.partOffsetY + (ephi.y - eplo.y) / 2)
                let endKeepOut = ends == nil ? [] : Self.endKeepOut(partY: lengthY, stock: s.stockSize(stock))
                let sideKeepOut = keepOut + Self.outOfReachStrips(reach) + endKeepOut
                if !sideKeepOut.isEmpty {
                    planned = planned.map { p in
                        var p = p
                        if p.operation.kind == .adaptive, p.operation.reference == nil { p.keepOut = sideKeepOut; p.keepOutBelow = keepOutBelow }
                        return p
                    }
                }
                let transform = s.partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
                // Deep roughing in depth slices: each is its own job, so the engines share one long
                // operation and the timeline grows slice by slice.
                let (plo, phi) = s.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
                let partBottom = -(s.topAllowance + (phi.z - plo.z))
                planned = planned.flatMap { Self.depthSlices($0, partBottom: partBottom) }
                    .flatMap { Self.finishStrips($0, yRange: (s.partOffsetY - (phi.y - plo.y) / 2 - 3) ... (s.partOffsetY + (phi.y - plo.y) / 2 + 3)) }
                planned = addReferenceFeatures(planned, side: side, material: material, stock: stock)
                // The tabs end where every tool can go round their ends (within the X travel).
                // The tabs keep clear of the windows side B opens over the reference bores.
                if side == 1, tabSpec != nil, let plan = referencePlan {
                    let windowTool = planned.first { $0.operation.reference == .windows }?.tool.diameter ?? 0
                    tabSpec?.avoid = plan.centresB.map { SIMD3($0.x, $0.y, max(ReferenceBores.windowDiameter, windowTool) / 2 + 0.75) }
                }
                var partLo = SIMD2<Double>(repeating: .infinity), partHi = -partLo
                for i in 0..<8 {
                    let c = SIMD3(i & 1 == 0 ? part.boundsMin.x : part.boundsMax.x, i & 2 == 0 ? part.boundsMin.y : part.boundsMax.y,
                                  i & 4 == 0 ? part.boundsMin.z : part.boundsMax.z)
                    let w = transform * SIMD4(c, 1)
                    partLo = simd_min(partLo, SIMD2(w.x, w.y)); partHi = simd_max(partHi, SIMD2(w.x, w.y))
                }
                // Only what the tool reaches here: the depth per tool now, the X travel on the paths.
                if let reach {
                    planned = withinReach(planned, reach: reach, stockDepth: s.stockSize(stock).z, setupName: Self.setupTitle(side: side, twoSided: twoSided))
                }
                run.sides.append(.init(side: side, setup: s, planned: planned, materialTop: materialTop,
                                       tabSpec: tabSpec, tabBottom: tabBottom, transform: transform,
                                       partX: partLo.x...partHi.x, partY: partLo.y...partHi.y, reachX: reach?.x,
                                       fields: fixtureFields(candidates: libraryCandidates, stockSize: s.stockSize(stock)),
                                       keepY: ends == nil ? nil : partLo.y...partHi.y))
            }
            // Setups from the other sides (upper, lower side, ends): each cuts only the features
            // that need it. They come first at the machine, while the stock is still a whole block.
            if setup.planFromFixtureLibrary {
                let sidePlans = sideSetupPlans(base: base, part: part, stock: stock)
                for sp in sidePlans {
                    let transform = sp.setup.partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
                    var partLo = SIMD2<Double>(repeating: .infinity), partHi = -partLo
                    for i in 0..<8 {
                        let c = SIMD3(i & 1 == 0 ? part.boundsMin.x : part.boundsMax.x, i & 2 == 0 ? part.boundsMin.y : part.boundsMax.y,
                                      i & 4 == 0 ? part.boundsMin.z : part.boundsMax.z)
                        let w = transform * SIMD4(c, 1)
                        partLo = simd_min(partLo, SIMD2(w.x, w.y)); partHi = simd_max(partHi, SIMD2(w.x, w.y))
                    }
                    var sideBox = sp.setup.stockBox(stock)
                    // The other end faced first (its end setup comes before this one): that much
                    // less stock at this setup's back.
                    if sp.side == 5, sidePlans.contains(where: { $0.side == 4 }) { sideBox.min.z += endPieceThickness(side: 4) }
                    var planned = sp.planned
                    let endPiece = endPieceThickness(side: sp.side)
                    // Nothing in the library holds the stock turned this way: no cuts from it (the
                    // workholding plan would fail the whole job); its features stay open. An end
                    // setup that faces its end piece off is planned with the vise to buy.
                    let turnedSize = sp.setup.stockSize(stock)
                    let owned = libraryCandidates.contains(where: { c in
                        c.fixture.planning.map { simd_distance(SIMD3($0.stockSize.x, $0.stockSize.y, $0.stockSize.z), turnedSize) < 0.1 } ?? false
                    })
                    let standIn = setup.planFromFixtureLibrary && !owned && endPiece > 0.5
                    if setup.planFromFixtureLibrary, !owned, !standIn {
                        planNotes.append("\(Self.setupTitle(side: sp.side, twoSided: twoSided)): no fixture you own holds the stock this way, so this setup is left out until you have a vise that opens to \(Int((turnedSize.y + 1).rounded(.up))) mm or more (on the Shopping List). Its features stay open until then.")
                        continue
                    }
                    let reach = standIn ? standInReach(stockSize: turnedSize, facedBefore: 0) : reachInSetup(candidates: libraryCandidates, stockSize: sp.setup.stockSize(stock))
                    if reach == nil, ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil { print("reach unknown for side \(sp.side) stock \(sp.setup.stockSize(stock))") }
                    // The upper and lower sides are long faces too: they leave the end pieces on.
                    let keepsEnds = ends != nil && sp.side <= 3
                    let sideKeepOut = fixtureKeepOut(candidates: libraryCandidates, stockSize: sp.setup.stockSize(stock)) + Self.outOfReachStrips(reach)
                        + (keepsEnds ? Self.endKeepOut(partY: partLo.y...partHi.y, stock: sp.setup.stockSize(stock)) : [])
                    if !sideKeepOut.isEmpty {
                        planned = planned.map { p in
                            var p = p
                            if p.operation.kind == .adaptive { p.keepOut += sideKeepOut; p.keepOutBelow = min(p.keepOutBelow, keepOutBelow) }
                            return p
                        }
                    }
                    // Below a faced end piece the work starts at the faced surface.
                    let sideTop = endPiece > 0.5 ? -endPiece : 0
                    let setupName = Self.setupTitle(side: sp.side, twoSided: twoSided)
                    var clampings: [GenerationRun.StandInClamping] = [], clampOf: [Int] = []
                    if standIn, let first = reach {
                        // In the vise to buy the face always stands at the table edge: the end piece
                        // comes off in as many clampings as the facing tool reaches (the bar slid
                        // toward the spindle between them, the jaws behind what each faces), then a
                        // last clamping, the faced end at the edge again, cuts the end's features.
                        var ops: [EngineClient.PlannedOperation] = []
                        var done = 0.0
                        if let f = planned.first(where: { $0.operation.kind == .facing }) {
                            let most = max(1, -first.zFloor(stickout: f.tool.stickout) - 1)
                            while done < endPiece - 1e-6 {
                                let c = min(most, endPiece - done)
                                var p = f
                                p.zTop = -done; p.zMin = -(done + c); p.operation.faceDepth = c
                                if done > 0 { p.clearance = -done + 3 }
                                let jaw = -done - c - 3
                                clampOf.append(clampings.count)
                                clampings.append(.init(facedBefore: done, jawFront: jaw, facing: c,
                                                       field: StandInVise.field(stockSize: turnedSize, facedBefore: done, jawFront: jaw, table: tableGeometry)))
                                ops.append(p)
                                done += c
                            }
                        }
                        let features = planned.filter { $0.operation.kind != .facing }
                        if !features.isEmpty, let r = standInReach(stockSize: turnedSize, facedBefore: endPiece) {
                            let kept = withinReach(features, reach: r, stockDepth: turnedSize.z, setupName: setupName, materialTop: -endPiece)
                                .map { p -> EngineClient.PlannedOperation in var p = p; p.clearance = -endPiece + 3; return p }
                            if !kept.isEmpty {
                                let jaw = -endPiece - StandInVise.facePast
                                clampOf += Array(repeating: clampings.count, count: kept.count)
                                clampings.append(.init(facedBefore: endPiece, jawFront: jaw, facing: nil,
                                                       field: StandInVise.field(stockSize: turnedSize, facedBefore: endPiece, jawFront: jaw, table: tableGeometry)))
                                ops += kept
                            }
                        }
                        planned = ops
                    } else if let reach {
                        planned = withinReach(planned, reach: reach, stockDepth: sp.setup.stockSize(stock).z, setupName: setupName,
                                              materialTop: sideTop)
                    }
                    guard !planned.isEmpty else { continue }
                    if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
                        for p in planned { print("side \(sp.side) op \(p.operation.title) \(p.tool.name.prefix(18)) zTop \(p.zTop) zMin \(p.zMin.map { String(format: "%.1f", $0) } ?? "-") window \(p.window.map { "\($0.min) \($0.max)" } ?? "-")") }
                    }
                    run.sides.append(.init(side: sp.side, setup: sp.setup, planned: planned, materialTop: sideTop,
                                           tabSpec: nil, tabBottom: 0, transform: transform,
                                           partX: partLo.x...partHi.x, partY: partLo.y...partHi.y,
                                           boxMin: sideBox.min, boxMax: sideBox.max, reachX: reach?.x,
                                           fields: standIn ? [] : fixtureFields(candidates: libraryCandidates, stockSize: sp.setup.stockSize(stock)),
                                           keepY: keepsEnds ? partLo.y...partHi.y : nil, clampings: clampings, clampOf: clampOf))
                }
            }
            // Machining order: side A's operations, then side B's. Several engines take them in
            // turn; each side shows as soon as the operations from its start are ready.
            run.jobs = run.sides.indices.flatMap { si in run.sides[si].planned.indices.map { (side: si, k: $0) } }
            run.done = run.sides.map { Array(repeating: nil, count: $0.planned.count) }
            run.published = Array(repeating: 0, count: run.sides.count)
            opGenState = [:]
            for sp in run.sides { for p in sp.planned { setGenState(p.operation.id, side: sp.side, .queued) } }
            sideResults = []
            programs = []
            // The chapters and steps, known now: programs group consecutive operations with
            // the same tool, numbered across the sides (as the finished ones will be).
            var planned: [(index: Int, side: Int, tool: Tool, operations: [Operation])] = []
            for sp in run.sides {
                for p in sp.planned {
                    if let last = planned.last, last.side == sp.side, last.tool.id == p.tool.id,
                       last.operations.last?.reference != .windows, p.operation.reference != .windows {
                        planned[planned.count - 1].operations.append(p.operation)
                    } else {
                        planned.append((planned.count, sp.side, p.tool, [p.operation]))
                    }
                }
            }
            plannedPrograms = planned
            // The job starts at chapter 1: the stock as bought (or side A's clamping without a prep).
            selectedStep = nil
            plannedOperationCount = Dictionary(uniqueKeysWithValues: run.sides.map { ($0.side, $0.planned.count) })
            run.boxMin = box.min
            run.boxMax = box.max
            try await runInBackground(run, partURL: part.url, partID: part.partID)
            if !run.failed.isEmpty {
                publishPartial(run, force: true)
                let names = run.failed.map { f in
                    let sp = run.sides[f.side]
                    return "\(sp.side >= 2 ? SetupSide.words(sp.side) + " · " : twoSided ? (sp.side == 0 ? "A · " : "B · ") : "")\(sp.planned[f.k].operation.title)"
                }
                errorMessage = "\(names.count == 1 ? "One operation" : "\(names.count) operations") failed (\(names.joined(separator: ", "))): \(run.failed[0].message) The rest is ready to look at; Retry redoes only the failed ones."
                status = "\(run.finished) of \(run.total) operations ready · \(run.failed.count) failed"
                return
            }
            // The clamping (vise to buy) of each generated path, per side.
            var generatedClamping: [Int: [Int]] = [:]
            func flatten(_ si: Int) -> (side: Int, setup: Setup, planned: [EngineClient.PlannedOperation], paths: [OperationToolpath], materialTop: Double) {
                let sp = run.sides[si]
                // An operation with nothing to cut on this side (its pockets all done from the
                // other side, say) gets no program: no tool change for nothing.
                var planned: [EngineClient.PlannedOperation] = [], paths: [OperationToolpath] = []
                var clamps: [Int] = []
                for k in sp.planned.indices {
                    let ps = run.done[si][k] ?? []
                    guard ps.contains(where: { $0.moves.contains { $0.role == .cut || $0.role == .ramp || $0.role == .plunge } }) else { continue }
                    // Keep every returned path paired with its operation. Some generators
                    // return more than one path; zip must not drop their later cuts.
                    planned.append(contentsOf: repeatElement(sp.planned[k], count: ps.count))
                    if sp.clampOf.indices.contains(k) { clamps.append(contentsOf: repeatElement(sp.clampOf[k], count: ps.count)) }
                    paths += ps
                }
                if !sp.clampings.isEmpty { generatedClamping[sp.side] = clamps }
                return (sp.side, sp.setup, planned, paths, sp.materialTop)
            }
            for si in run.sides.indices { generated.append(flatten(si)) }
            // At the machine the side setups come first, on the whole block; then side A and B.
            generated = generated.filter { $0.side >= 2 } + generated.filter { $0.side < 2 }
            if setup.planFromFixtureLibrary {
                status = "Comparing generated cuts with library fixtures and remaining stock…"
                // Setups held by the vise to buy aren't the planner's: their steps follow its own.
                let standInSides = Set(run.sides.filter { !$0.clampings.isEmpty }.map(\.side))
                let cuts = generated.filter { !standInSides.contains($0.side) }.flatMap { g in
                    zip(g.planned, g.paths).enumerated().map { index, pair in
                        LibraryWorkholdingPlanner.Cut(key: "\(g.side):\(index)", side: g.side,
                            operation: pair.0.operation, tool: pair.0.tool, moves: pair.1.moves)
                    }
                }
                let candidates = libraryCandidates, size = setup.stockSize(stock), machine = machine, flip = setupFor(side: 1).flipAxis
                // The order of the setups: of the ones the planner can hold all the way (it
                // tracks the stock each setup leaves for the next), the one that turns the stock
                // least between them; the side setups first (the whole block) when that ties.
                let orders = Self.setupOrders(generated.map(\.side).filter { !standInSides.contains($0) }, turn: { self.turnAngle(from: $0, to: $1) })
                var angles: [String: Double] = [:]
                for a in orders[0] { for b in orders[0] { angles["\(a)>\(b)"] = turnAngle(from: a, to: b) } }
                let turns = angles
                let chosen = await Task.detached(priority: .userInitiated) { () -> (LibraryWorkholdingPlan, [Int]) in
                    var best: (plan: LibraryWorkholdingPlan, turn: Double, order: [Int])?
                    var first: LibraryWorkholdingPlan?
                    for order in orders {
                        let ordered = order.flatMap { side in cuts.filter { $0.side == side } }
                        let p = LibraryWorkholdingPlanner.plan(cuts: ordered, candidates: candidates, stock: size, machine: machine, flipAxis: flip)
                        if first == nil { first = p }
                        guard p.complete else { continue }
                        let sides = p.steps.map(\.side)
                        let turn = zip(sides, sides.dropFirst()).reduce(0.0) { $0 + (turns["\($1.0)>\($1.1)"] ?? 0) }
                        if best == nil || turn < best!.turn - 1e-6 { best = (p, turn, order) }
                    }
                    return best.map { ($0.plan, $0.order) } ?? (first ?? LibraryWorkholdingPlan(), orders[0])
                }.value
                var plan = chosen.0
                let order = chosen.1
                guard generationSignature == run.signature, !cancelGeneration else { throw CancellationError() }
                if plan.complete {
                    for g in generated where standInSides.contains(g.side) {
                        guard let sp = run.sides.first(where: { $0.side == g.side }) else { continue }
                        // One step per clamping; its clearance field checks the posted programs too.
                        for (c, clamping) in sp.clampings.enumerated() {
                            let clamps = generatedClamping[g.side] ?? []
                            let keys = g.planned.indices.filter { clamps.indices.contains($0) && clamps[$0] == c }
                            guard !keys.isEmpty else { continue }
                            let fixture = standInFixture(side: g.side, clamping: c, stockSize: g.setup.stockSize(stock), facedBefore: clamping.facedBefore,
                                                         jawFront: clamping.jawFront, facing: clamping.facing)
                            libraryFixtureFields[fixtureStateKey(fixture)] = clamping.field
                            plan.steps.append(.init(number: plan.steps.count + 1, side: g.side, fixture: fixture,
                                                    cutKeys: keys.map { "\(g.side):\($0)" }, operations: keys.map { g.planned[$0].operation.title },
                                                    reasons: ["Held in a vise you don't have yet (on the Shopping List): running waits until it is in your fixtures."]))
                        }
                    }
                }
                // The programs follow the setups' order (the end setups last, + Y end first).
                let rank = { (side: Int) -> Int in order.firstIndex(of: side) ?? (order.count + side) }
                generated.sort { rank($0.side) < rank($1.side) }
                libraryWorkholdingPlan = plan
                selectedLibraryStep = plan.steps.first?.id
                guard plan.complete else {
                    // Partial/background programs have not been assigned workholding and must
                    // never remain exportable after a failed sequence search.
                    programs = []; plannedPrograms = []
                    errorMessage = "No complete workholding sequence. " + plan.issues.joined(separator: "\n")
                    status = "Workholding needs attention; no cutting program is ready to run."
                    return
                }
            }
            // Every pass against the stock as the cuts before it leave it (StockModel: all setups,
            // in the order they run, each operation in turn): roughing, finishing, floors, holes
            // and threads lift over stretches where their cutter meets nothing (an earlier setup
            // or operation already cut there).
            if let mesh = partMeshData {
                status = "Checking each pass against the stock the cuts before it leave…"
                let t0Air = Date()
                let t = setup.partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
                var verts = [Float](repeating: 0, count: mesh.positions.count)
                var vi = 0
                while vi + 2 < mesh.positions.count {
                    let w = t * SIMD4(Double(mesh.positions[vi]), Double(mesh.positions[vi + 1]), Double(mesh.positions[vi + 2]), 1)
                    verts[vi] = Float(w.x); verts[vi + 1] = Float(w.y); verts[vi + 2] = Float(w.z)
                    vi += 3
                }
                let entries = generated, size = setup.stockSize(stock), flip = setupFor(side: 1).flipAxis, indices = mesh.indices
                // The stock as each setup step starts (for the workspace and the simulation).
                var stepOfKey: [String: String] = [:]
                for s in libraryWorkholdingPlan?.steps ?? [] { for key in s.cutKeys { stepOfKey[key] = "step:\(s.id)" } }
                let keys = stepOfKey
                let (filtered, snapshots) = await Task.detached(priority: .userInitiated) { () -> ([[OperationToolpath]], [String: StockModel]) in
                    var model = StockModel(stock: size, partVertices: verts, indices: indices, flipAxis: flip)
                    var out: [[OperationToolpath]] = []
                    var snapshots: [String: StockModel] = [:]
                    for g in entries {
                        var paths = g.paths
                        for i in paths.indices where g.planned.indices.contains(i) {
                            let at = keys["\(g.side):\(i)"] ?? "side:\(g.side)"
                            if snapshots[at] == nil { snapshots[at] = model }
                            if snapshots["side:\(g.side)"] == nil { snapshots["side:\(g.side)"] = model }
                            let op = g.planned[i]
                            if Self.checksForAir(op.operation) {
                                let roughing = op.operation.kind == .adaptive
                                let (moves, skipped) = model.liftAir(paths[i].moves, side: g.side, tool: op.tool, step: roughing ? 1 : 0.5,
                                                                     safeZ: Self.safeHeight(op), slice: roughing ? op.data.stepdown : nil,
                                                                     plungeFeed: op.data.plungeFeed)
                                paths[i].moves = moves
                                if skipped > 1 {
                                    paths[i].notes.append("\(Length.mm(skipped)) mm of this pass met no stock (a cut before it had already taken it): lifted over.")
                                }
                            }
                            model.sweep(paths[i].moves, side: g.side, tool: op.tool, slice: op.data.stepdown)
                        }
                        out.append(paths)
                    }
                    return (out, snapshots)
                }.value
                guard generationSignature == run.signature, !cancelGeneration else { throw CancellationError() }
                for gi in generated.indices where filtered.indices.contains(gi) { generated[gi].paths = filtered[gi] }
                inProcessSnapshots = snapshots
                inProcessMeshes = [:]
                if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil { print("timing air check \(String(format: "%.1f", Date().timeIntervalSince(t0Air))) s") }
            }
            let t0Post = Date()
            let stockSize = setup.stockSize(stock)
            status = "Posting and checking the programs…"
            // Every program is posted and checked at once (they're independent), then collected
            // in order.
            typealias Posted = (posted: (text: String, lines: [[Int?]]), report: GCodeValidator.Report, seconds: Double, hits: [FixtureClearance.Hit],
                                probe: String?)
            // Engraving that follows the probed face needs electrical probing, which this workholding hasn't.
            let probeBlocked: String? = "The engraving can't follow the probed face: that needs electrical probing, which this workholding doesn't have. It follows the CAD."
            struct Pending {
                var side: Int
                var group: [(EngineClient.PlannedOperation, OperationToolpath)]
                var rpm: Double
                var task: Task<Posted, Never>
                var workholdingStep: LibraryWorkholdingPlan.Step?
            }
            var pendingBySide: [[Pending]] = []
            for (side, _, planned, paths, materialTop) in generated {
                // Group consecutive operations with the same tool into programs.
                var groups: [(step: LibraryWorkholdingPlan.Step?, cuts: [(EngineClient.PlannedOperation, OperationToolpath)])] = []
                for (index, pair) in zip(planned, paths).enumerated() {
                    let step = libraryWorkholdingPlan?.step(for: "\(side):\(index)")
                    if let last = groups.last?.cuts.last, last.0.tool.id == pair.0.tool.id,
                       groups.last?.step?.id == step?.id,
                       last.0.operation.reference != .windows, pair.0.operation.reference != .windows {
                        groups[groups.count - 1].cuts.append(pair)
                    } else { groups.append((step, [pair])) }
                }
                let setupName = Self.setupTitle(side: side, twoSided: twoSided)
                let sideBox = side >= 2 ? setupFor(side: side).stockBox(stock) : box
                let fileName = part.fileName, stockName = "\(material.name) \(stock.sizeDescription)"
                var pending: [Pending] = []
                for grouped in groups {
                    let group = grouped.cuts, step = grouped.step
                    let tool = group[0].0.tool
                    let rpm = group.map(\.0.data.rpm).max() ?? machine.spindleRPM.upperBound
                    let groupPaths = group.map(\.1), names = group.map { $0.0.operation.title }
                    // Where this program's material starts: in a clamping of the vise to buy, what
                    // the clampings before it faced away (the side's own top otherwise).
                    let top = step.flatMap { s in isStandIn(s.fixture) ? -max((s.fixture.planning?.facePastTable ?? StandInVise.facePast) - StandInVise.facePast, 0) : nil } ?? materialTop
                    let bmin = sideBox.min, bmax = sideBox.max
                    let standInStep = step.map { isStandIn($0.fixture) } ?? false
                    let facingOnly = group.allSatisfy { $0.0.operation.kind == .facing }
                    let faced = group.reduce(0.0) { $0 + $1.0.operation.faceDepth }
                    let fixtures = step.flatMap { libraryFixtureFields[fixtureStateKey($0.fixture)] }
                    let setupName = step?.title ?? setupName
                    // Posting and the safety check are heavy for 3D programs (tens of thousands of
                    // lines): off the main thread, so the app stays responsive.
                    let probing = group.filter { $0.0.operation.kind == .engrave && $0.0.operation.engraving?.probeSurface == true }
                        .map { (depth: $0.0.operation.engraving?.depth ?? 0.15, moves: $0.1.moves) }
                    let task = Task.detached(priority: .userInitiated) { () -> Posted in
                        var posted = GRBLPost.programWithLineMap(
                            header: .init(programName: fileName, setupName: setupName, tool: tool, operationNames: names,
                                          stockDescription: stockName),
                            rpm: rpm, paths: groupPaths, machine: machine)
                        // Follow the probed face (SurfaceProbe): on a flat face only.
                        let (probe, probeNote) = Self.followProbedFace(&posted, probing: probing, blocked: probeBlocked, machine: machine)
                        var ctx = GCodeValidator.Context(stockMin: bmin, stockMax: bmax, tool: tool)
                        ctx.materialTop = top
                        // Facing the whole face leaves no wall for the collet nut to meet: its depth
                        // counts from the faced surface.
                        if facingOnly { ctx.materialTop = top - faced }
                        // In a later clamping of the vise to buy the face is lower: rapids stay above it.
                        if standInStep { ctx.safeZ = min(top, 0) + 1 }
                        var report = GCodeValidator(machine: machine).validate(posted.text, context: ctx)
                        // The clamps, parallels and table: the tool, shank and collet nut keep clear.
                        var hits: [FixtureClearance.Hit] = []
                        if var field = fixtures {
                            hits = FixtureClearance.check(groupPaths.flatMap(\.moves), tool: tool, field: &field)
                            if let text = FixtureClearance.describe(hits) { report.issues.append(Issue(.error, text)) }
                        }
                        if let probeNote { report.issues.append(Issue(.info, probeNote)) }
                        if probe != nil {
                            report.issues.append(Issue(.info, "The engraving follows the face as probed: a probing step comes first in the guided job (M111), the program turns the sender's compensation on (M112) and off (M113)."))
                        }
                        return (posted, report, TimeEstimate.seconds(groupPaths, machine: machine), hits, probe)
                    }
                    pending.append(Pending(side: side, group: group, rpm: rpm, task: task, workholdingStep: step))
                }
                pendingBySide.append(pending)
            }
            for ((side, s, planned, paths, _), pending) in zip(generated, pendingBySide) {
                var opProgram: [Int] = [], opLines: [[Int?]] = []
                for p in pending {
                    let index = allPrograms.count
                    let r = await p.task.value
                    guard generationSignature == run.signature, !cancelGeneration else { throw CancellationError() }
                    opProgram += Array(repeating: index, count: p.group.count)
                    opLines += r.posted.lines
                    allPrograms.append(ToolProgram(index: index, side: side, tool: p.group[0].0.tool, operations: p.group.map(\.0.operation), rpm: p.rpm,
                                                   gcode: r.posted.text, report: r.report, seconds: r.seconds,
                                                   warnings: p.group.flatMap(\.1.warnings),
                                                   minStickout: p.group.compactMap(\.1.minStickout).max(), clearanceHits: r.hits,
                                                   surfaceProbe: r.probe, workholdingStep: p.workholdingStep))
                }
                results.append(SideResult(side: side, setup: s, planned: planned, paths: paths, operationProgram: opProgram, operationLines: opLines))
            }
            if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
                print("timing posting+checks \(String(format: "%.3f", Date().timeIntervalSince(t0Post))) s")
            }
            programs = allPrograms
            sideResults = results
            toolpaths = Dictionary((results.first { $0.side == 0 } ?? results[0]).paths.map { ($0.operationID, $0) }, uniquingKeysWith: { a, _ in a })
            // Check the whole job against the real travel, with each tool's own stick-out, in the
            // clamping it runs in (not the one on screen). A program with any move outside fails
            // its safety check: a safety net behind the generation keeping inside the travel.
            var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
            let env = machine.machineEnvelope
            for r in results {
                for (k, path) in r.paths.enumerated() where k < r.planned.count {
                    let step = libraryWorkholdingPlan?.step(for: "\(r.side):\(k)")
                    let libraryOrigin = step.flatMap { libraryMachineOrigin(fixture: $0.fixture, stock: r.setup.stockSize(stock)) }
                        .map { $0 + SIMD3(0, 0, r.planned[k].tool.stickout) } // as machineOrigin(stickout:)
                    guard let origin = libraryOrigin ?? machineOrigin(stickout: r.planned[k].tool.stickout) else { continue }
                    var outside = 0, first: SIMD3<Double>?
                    for m in path.moves {
                        let q = origin + m.position
                        if m.role != .rapid { lo = simd_min(lo, q); hi = simd_max(hi, q) }
                        if !(env.x.contains(q.x) && env.y.contains(q.y) && env.z.contains(q.z)) {
                            outside += 1
                            if first == nil { first = q }
                        }
                    }
                    if outside > 0, r.operationProgram.indices.contains(k),
                       let pi = allPrograms.firstIndex(where: { $0.index == r.operationProgram[k] }), let q = first {
                        allPrograms[pi].report.issues.append(Issue(.error, "\(outside) move\(outside == 1 ? "" : "s") leave the machine's travel (first at machine \(String(format: "X%.2f Y%.2f Z%.2f", q.x, q.y, q.z)))."))
                    }
                }
            }
            for i in allPrograms.indices {
                if setup.holding == .custom && !setup.planFromFixtureLibrary {
                    allPrograms[i].report.issues.append(Issue(.warning, "Custom fixture geometry is not included in collision checks. Verify clearance to \(setup.customFixture.name), its jaws and fasteners."))
                }
            }
            programs = allPrograms
            await checkTabs()
            guard generationSignature == run.signature, !cancelGeneration else { throw CancellationError() }
            travelIssue = lo.x.isFinite ? (travelProblem(lo) ?? travelProblem(hi)) : nil
            generatedTuning = Tuning(cusp: operations.first { $0.kind.is3D }?.scallop ?? tuning.cusp,
                                     pace: operations.first?.feedScale ?? 1,
                                     roughing: operations.first { $0.kind == .adaptive }?.roughing,
                                     hiddenSide: twoSided ? tuning.hiddenSide : nil)
            tuning = generatedTuning
            var mark = Date()
            func lap(_ what: String) {
                if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
                    print("timing \(what) \(String(format: "%.3f", Date().timeIntervalSince(mark))) s")
                }
                mark = Date()
            }
            lap("travel check")
            // (The stock prep was made first, before the side jobs.)
            lap("prep")
            learnFromGeneration()
            lap("learn")
            // Where the user is looking stays put: the partial results already showed (from
            // chapter 1, step 1), and he may have moved on to another step or view meanwhile.
            let shownBefore = run.published.contains { $0 > 0 }
            let keepView = viewSide, keepTime = playhead
            viewSide = min(viewSide, results.count - 1)
            computeSideAFinal()
            prepareToolChangeSpot()
            showSide(at: shownBefore && viewSide == keepView ? keepTime : 0)
            lap("showSide")
            if !shownBefore {
                revealWork()
                setView(.iso)
                focusWork()
            }
            lap("view")
            let secs = programs.reduce(0) { $0 + $1.seconds }
            status = "Toolpaths ready in \(String(format: "%.1f", Date().timeIntervalSince(started))) s · about \(Self.duration(secs)) of machining"
                + (cachedOps > 0 ? " · \(cachedOps) unchanged operation\(cachedOps == 1 ? "" : "s") reused" : "")
        } catch is CancellationError {
            status = "Generation cancelled"
        } catch let e as EngineClient.EngineError where e.type == "EngineExited" && cancelGeneration {
            _ = e
            status = "Generation cancelled"
        } catch let e as EngineClient.EngineError where e.type == "EngineExited" {
            errorMessage = "The geometry engine crashed while generating (a native library failed on this geometry). It restarts by itself: generate again. If it keeps happening, change the finishing strategy or cusp height."
            status = "Generation failed: the engine crashed"
        } catch {
            errorMessage = "Toolpath generation failed: \(error)"
            status = "Generation failed"
        }
    }

    /// An engraving program made to follow the probed face (SurfaceProbe), with its probe program;
    /// or why it can't (not here, or not on a flat face). Synchronous: kept out of the posting
    /// task's async frame (large async frames trip Swift's task allocator).
    nonisolated static func followProbedFace(_ posted: inout (text: String, lines: [[Int?]]), probing: [(depth: Double, moves: [Move])],
                                             blocked: String?, machine: MachineProfile) -> (probe: String?, note: String?) {
        guard !probing.isEmpty else { return (nil, nil) }
        if let blocked { return (nil, blocked) }
        let cuts = probing.flatMap { $0.moves.filter { $0.role == .cut } }
        let flat = SurfaceProbe.flatFace(cuts: cuts.map(\.position), depth: probing[0].depth)
        guard let face = flat.face, let points = SurfaceProbe.points(cuts: cuts.map { SIMD2($0.x, $0.y) }) else {
            return (nil, "The engraving can't follow the probed face: the face under it isn't flat (its deepest cuts vary by \(Length.mm(flat.spread)) mm; the compensation would add that a second time). It follows the CAD.")
        }
        let f = SurfaceProbe.follow(posted.text, face: face)
        posted.text = f.text
        posted.lines = posted.lines.map { $0.map { $0.map { l in f.moved.indices.contains(l - 1) ? f.moved[l - 1] + 1 : l } } }
        return (SurfaceProbe.program(points: points, face: face, machine: machine), nil)
    }

    /// Fixed ids, so the generation cache knows the reference operations again.
    static let referenceBoresID = UUID(uuidString: "5EF0B0E5-0000-4000-8000-00000000000A")!
    static let referenceWindowsID = UUID(uuidString: "5EF0B0E5-0000-4000-8000-00000000000B")!

    /// Two-sided jobs (Settings ▸ Machining, on by default): side A bores two reference holes in
    /// the frame with its roughing tool, right after that tool's last operation (no extra tool
    /// change); side B opens them from the back first, in a program of its own, so the guided
    /// job can probe them and set side B's zero from them (ReferenceBores).
    func addReferenceFeatures(_ planned: [EngineClient.PlannedOperation], side: Int, material: Material,
                              stock: StockItem) -> [EngineClient.PlannedOperation] {
        guard !setup.planFromFixtureLibrary, twoSided, AppSettings.shared.referenceBores, let part else { return planned }
        let flat: (Tool) -> Bool = { $0.kind == .flatEndMill || $0.kind == .bullNoseEndMill }
        if side == 0 {
            // The roughing tool (the biggest flat one that fits the bore with room to helix).
            guard let tool = planned.filter({ flat($0.tool) && $0.tool.diameter <= ReferenceBores.diameter - 2.5 })
                .map(\.tool).max(by: { $0.diameter < $1.diameter }) else { return planned }
            let size = setup.stockSize(stock)
            let t = setup.partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
            var lo = SIMD2<Double>(repeating: .infinity), hi = -lo
            for i in 0..<8 {
                let c = SIMD3(i & 1 == 0 ? part.boundsMin.x : part.boundsMax.x, i & 2 == 0 ? part.boundsMin.y : part.boundsMax.y,
                              i & 4 == 0 ? part.boundsMin.z : part.boundsMax.z)
                let w = t * SIMD4(c, 1)
                lo = simd_min(lo, SIMD2(w.x, w.y)); hi = simd_max(hi, SIMD2(w.x, w.y))
            }
            // Past the widest clearing band and the tabs' reach into the frame.
            let rough = planned.filter { $0.operation.kind == .adaptive }.map(\.tool.diameter).max() ?? 6.35
            let clear = max(1.6 * rough + 1, holdWithTabs ? 1.6 * rough + 3.75 : 0) + 0.5
            let strips: [(min: SIMD2<Double>, max: SIMD2<Double>)] = []
            guard var plan = ReferenceBores.place(stock: size, partMin: lo, partMax: hi, clear: clear, keepOut: strips,
                                                  xReach: nil, toolDiameter: tool.diameter,
                                                  maxDepth: tool.stickout - 2) else { return planned }
            plan.flipAxis = setupFor(side: 1).flipAxis  // side B's windows land where its flip puts the bores
            referencePlan = plan
            var op = Operation(id: Self.referenceBoresID, kind: .bore, toolID: tool.id)
            op.reference = .bores
            var p = EngineClient.PlannedOperation(operation: op, tool: tool, data: FeedsEngine.compute(tool: tool, material: material, kind: .bore, machine: machine))
            p.holes = plan.centresA.map { ($0, ReferenceBores.diameter, 0, -plan.depthA) }
            var out = planned
            let at = (out.lastIndex { $0.tool.id == tool.id } ?? out.count - 1) + 1
            out.insert(p, at: at)
            return out
        }
        guard let plan = referencePlan else { return planned }
        // The window tool also probes the bores: flat, with room in the bore.
        // Typed in steps: Swift 6.3 cannot infer the one-line form in time.
        let tools: [Tool] = planned.map(\.tool)
        let fits: (Tool) -> Bool = { flat($0) && $0.diameter <= 8 }
        let first: Tool? = tools.first.flatMap { fits($0) ? $0 : nil }
        let widest: Tool? = tools.filter(fits).max { $0.diameter < $1.diameter }
        guard let tool = first ?? widest else {
            referencePlan = nil
            return planned
        }
        var op = Operation(id: Self.referenceWindowsID, kind: .bore, toolID: tool.id)
        op.reference = .windows
        var p = EngineClient.PlannedOperation(operation: op, tool: tool, data: FeedsEngine.compute(tool: tool, material: material, kind: .bore, machine: machine))
        p.holes = plan.centresB.map { ($0, ReferenceBores.windowDiameter, 0, -plan.windowDepth) }
        return [p] + planned
    }

    /// Cancel now, even in the middle of a long operation: the engine is stopped (it restarts,
    /// with the part, on the next action) and generation ends as cancelled.
    func cancelGenerationNow() {
        cancelGeneration = true
        status = "Cancelling…"
        engine?.terminate()
        for w in workerEngines { w.engine.terminate() }  // restarted, with the part, next time
    }

    /// Keep-out strips for what lies beyond the X travel in a setup (roughing stays out of them;
    /// the other passes lift over). Far wider than any stock.
    static func outOfReachStrips(_ reach: SetupReach?) -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        guard let r = reach else { return [] }
        let far = 1e4
        return [(SIMD2(-far, -far), SIMD2(r.x.lowerBound, far)), (SIMD2(r.x.upperBound, -far), SIMD2(far, far))]
    }

    /// The timeline's pseudo-program for the edge finding after a clamping.
    static func edgeFindProgram(side: Int, stage: Int) -> Int { 2000 + (side + 1) * 100 + stage }

    func result(forSide side: Int) -> SideResult? {
        return sideResults.first { $0.side == side }
    }

    /// Shows the chosen side's toolpaths, playback and simulation, the playhead at `time`
    /// (nil: the end, the side finished).
    func showSide(at time: Double? = nil) {
        guard let r = result(forSide: viewSide) else { return }
        // Side B cuts what side A left: its simulation starts from side A's final state.
        if viewSide == 1 && sideAFinal == nil { computeSideAFinal() }
        let timing = ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil
        var mark = Date()
        func lap(_ what: String) { if timing { print("timing   \(what) \(String(format: "%.3f", Date().timeIntervalSince(mark))) s") }; mark = Date() }
        plannedTools = r.planned.map(\.tool)
        currentTool = r.planned.first?.tool
        operationProgram = r.operationProgram
        operationLines = r.operationLines
        // The edge finder goes first after every clamping: its visit to each edge plays like a
        // program (it removes nothing).
        let size = displayStockSize ?? stock.map { setup.stockSize($0) } ?? SIMD3(10, 10, 10)
        let protrusion = displayedJobFixture?.planning?.facePastTable ?? setup.customFixture.faceProtrusion
        let probeTool = EdgeFinding.tool
        let probeMoves = EdgeFinding.moves(stock: size, depth: min(1.5, max(protrusion - 0.5, 0.5)), radius: probeTool.diameter / 2)
        let probe = OperationToolpath(operationID: UUID(), moves: probeMoves)
        let probeProgram = Self.edgeFindProgram(side: viewSide, stage: 0)
        if setup.planFromFixtureLibrary {
            timelineTitles = r.planned.map { $0.operation.title }
            timeline = ToolpathTimeline(paths: r.paths, programOf: r.operationProgram, lines: r.operationLines, machine: machine)
        } else {
            plannedTools = [probeTool] + plannedTools
            timelineTitles = ["Edge finding"] + r.planned.map { $0.operation.title }
            timeline = ToolpathTimeline(paths: [probe] + r.paths, programOf: [probeProgram] + r.operationProgram, lines: [[]] + r.operationLines, machine: machine)
        }
        lap("timeline")
        playhead = min(max(time ?? timeline.duration, 0), timeline.duration)
        layoutScene()
        lap("layout")
        resetSimulation()
        lap("reset sim")
        showToolpaths()
        lap("paths + playback")
        updatePlayback()
        lap("playback")
        if let seek = pendingSeek {
            pendingSeek = nil
            seek()
        }
        if pendingPlay {  // Play pressed on the stock as bought: carry on here
            pendingPlay = false
            togglePlay()
        }
    }

    /// Writes one .nc file per tool program into a folder.
    func exportPrograms(to folder: URL) throws -> [URL] {
        try requirePlanningMachine()
        try validateLibraryPlanForExport()
        guard !isGenerating else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Wait for toolpath generation to finish."])
        }
        guard !programs.isEmpty else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Generate toolpaths first."])
        }
        guard programs.allSatisfy(\.report.passed) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Fix the safety errors before exporting."])
        }
        return try programs.map { p in
            let url = folder.appendingPathComponent(p.fileName)
            try p.gcode.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m < 60 ? "\(max(m, 1)) min" : "\(m / 60) h \(m % 60) min"
    }
}

/// One side's generated job.
struct SideResult {
    var side: Int
    var setup: Setup
    var planned: [EngineClient.PlannedOperation]
    var paths: [OperationToolpath]
    var operationProgram: [Int]
    var operationLines: [[Int?]]
}


// MARK: Operation cache

extension AppModel {
    /// Everything that shapes one operation's toolpath (the part as imported, the operation,
    /// tool, feeds, depth window, keep-outs, band, transform, stock box and tabs).
    nonisolated static func generationKey(partID: String, _ p: EngineClient.PlannedOperation, _ transform: simd_double4x4,
                                          _ lo: SIMD3<Double>, _ hi: SIMD3<Double>, _ tabs: HoldingTabs?, _ tabBottom: Double, machine: MachineProfile) -> String {
        ([partID, String(describing: machine), String(describing: p.operation), String(describing: p.tool), String(describing: p.data),
         String(describing: p.zMin), String(describing: p.through), String(describing: p.zTop), String(describing: p.keepOut), String(describing: p.keepOutBelow),
         String(describing: p.band), String(describing: p.frameTop), String(describing: p.refTool), String(describing: transform),
         String(describing: lo), String(describing: hi), String(describing: tabs), String(describing: tabBottom),
         String(describing: p.tile), String(describing: p.restFrom), String(describing: p.holes), String(describing: p.window)]
            // The clearance height only when it isn't the usual one (keeps the cache's other keys).
            + (safeHeight(p) == 3 ? [] : ["safe:\(safeHeight(p))"])).joined(separator: "|")
    }

    /// The clearance height for an operation's rapids and lifts (work Z): 3 mm above the stock as
    /// its clamping holds it. Not its own start depth (a depth slice starts below material the
    /// slices before it left round the part); lower only in a clamping after part of the stock
    /// was faced away (`clearance`), so the spindle stays within its travel.
    nonisolated static func safeHeight(_ p: EngineClient.PlannedOperation) -> Double { p.clearance ?? 3 }

    /// The passes checked against the stock left (StockModel.liftAir): roughing and finishing
    /// alike; not facing (it takes the whole face), engraving, or the reference bores and windows.
    nonisolated static func checksForAir(_ op: Operation) -> Bool {
        ![.facing, .engrave].contains(op.kind) && op.reference == nil
    }


    func storeInCache(_ key: String, _ value: ([OperationToolpath], [PlacedTab])) {
        opCache[key] = value
        opCacheOrder.removeAll { $0 == key }
        opCacheOrder.append(key)
        // The last few dozen operations (3D paths can be large).
        while opCacheOrder.count > 48 { opCache[opCacheOrder.removeFirst()] = nil }
    }
}
