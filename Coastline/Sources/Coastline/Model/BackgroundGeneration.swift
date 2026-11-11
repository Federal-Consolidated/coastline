import CoastlineCore
import Foundation
import simd

/// Where one operation (on one side) is in a generation, for the operation list.
enum GenState: Equatable {
    case queued, running, ready
    case failed(String)
}

/// One generation in progress, rendered in the background like a video editor renders a
/// timeline: the operations of every side are jobs, several engine processes take them in
/// machining order, and each side's toolpaths appear (timeline, simulation) as soon as the
/// operations from its start are done. A failed operation doesn't stop the others; generating
/// again redoes only it (everything else comes from the cache).
@MainActor
final class GenerationRun {
    struct SidePlan {
        var side: Int
        var setup: Setup
        var planned: [EngineClient.PlannedOperation]
        var materialTop: Double
        var tabSpec: HoldingTabs?
        var tabBottom: Double
        var transform: simd_double4x4
        /// The part's outline box in this side's work frame (X, Y), for the reach check.
        var partX: ClosedRange<Double> = 0...0
        var partY: ClosedRange<Double> = 0...0
        /// This setup's stock box when it isn't side A's (a turned setup).
        var boxMin: SIMD3<Double>? = nil
        var boxMax: SIMD3<Double>? = nil
        /// The work X the tool tip reaches in this setup (the machine's travel from the fixture).
        var reachX: ClosedRange<Double>? = nil
        /// The fixtures fitted to this setup's stock, as the clearance check sees them (the tool,
        /// shank and collet nut keep out of them; their dilation caches fill as the paths come).
        var fields: [FixtureField] = []
        /// The part's length (work Y) in a long-face setup that leaves the end pieces on
        /// (AppModel.endPieces): the tool never goes past it, the end setups face them off.
        var keepY: ClosedRange<Double>? = nil
        /// An end setup held by the vise to buy (StandInVise): its clampings, and which one
        /// each planned operation is cut in. Empty: held by a fixture you own.
        var clampings: [StandInClamping] = []
        var clampOf: [Int] = []
    }

    /// One clamping of an end setup in the vise to buy: what earlier clampings faced off (work Z0
    /// stays at the original face), where the jaws' fronts are (work Z), how much this one faces
    /// (nil: the features), and the clearance field of the vise and the table there.
    struct StandInClamping {
        var facedBefore: Double
        var jawFront: Double
        var facing: Double?
        var field: FixtureField
    }

    var sides: [SidePlan] = []
    /// The stock box and grip strips, kept here (on the heap): over-aligned SIMD values passed
    /// into async calls trip Swift's task allocator ("freed pointer was not the last allocation").
    var boxMin = SIMD3<Double>(repeating: 0)
    var boxMax = SIMD3<Double>(repeating: 0)
    var jobs: [(side: Int, k: Int)] = []
    var next = 0
    /// Per side, per operation: the toolpaths once done.
    var done: [[[OperationToolpath]?]] = []
    var failed: [(side: Int, k: Int, message: String)] = []
    /// Per side: how many operations from its start are shown.
    var published: [Int] = []
    var lastPublish = Date.distantPast
    var publishScheduled = false
    /// Side B's tab frame (from side A's simulated clearing): being made, and made.
    var frameTask: Task<TabFrame, Never>?
    var frameReady = false
    /// What the job looked like when it started: a change on the way stops it.
    let signature: String
    let machine: MachineProfile

    init(signature: String, machine: MachineProfile) {
        self.signature = signature
        self.machine = machine
    }

    var finished: Int { done.reduce(0) { $0 + $1.filter { $0 != nil }.count } }
    var total: Int { jobs.count }
    func prefix(_ si: Int) -> Int { done[si].prefix { $0 != nil }.count }
}

extension AppModel {
    /// A program whose moves had to be pulled into the part to stay within the travel fails.

    /// How many engine processes generate at once (the main one and workers).
    static var generationWorkers: Int {
        if let n = ProcessInfo.processInfo.environment["COASTLINE_WORKERS"].flatMap(Int.init), n >= 1 { return n }
        if AppSettings.shared.engines > 0 { return AppSettings.shared.engines }
        // Each engine also runs several threads inside (roughing levels, drop-cutter batches):
        // about one engine per 2–3 cores.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return cores >= 10 ? 4 : cores >= 8 ? 3 : 2
    }

    /// The job's shape that toolpaths depend on (a change while generating stops it).
    var generationSignature: String {
        let s = setup
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys  // dictionaries encode in a stable order
        let ops = (try? enc.encode(operations)).map { $0.hashValue } ?? 0
        let fixture = (try? enc.encode(s)).map { $0.hashValue } ?? 0
        let profile = (try? planningMachineReference.fingerprint()) ?? String(describing: machine)
        let resources = (try? enc.encode(savedResourceSnapshot)).map { $0.hashValue } ?? 0
        return "\(profile)|\(ops)|\(resources)|\(stockID?.uuidString ?? "")|\(twoSided)|\(fixture)"
    }

    func genState(for opID: UUID) -> GenState? {
        guard let bySide = opGenState[opID], !bySide.isEmpty else { return nil }
        let states = bySide.keys.sorted().map { bySide[$0]! }
        if let f = states.first(where: { if case .failed = $0 { true } else { false } }) { return f }
        if states.contains(.running) { return .running }
        if states.contains(.queued) { return .queued }
        return .ready
    }

    var failedOperationCount: Int {
        opGenState.values.reduce(0) { $0 + $1.values.filter { if case .failed = $0 { true } else { false } }.count }
    }

    /// Runs the jobs on the main engine and worker engines (started on the way, each with the
    /// part loaded), then returns. Cancellation and failures are recorded in `run`.
    func runInBackground(_ run: GenerationRun, partURL url: URL, partID fallbackID: String) async throws {
        let main = try await liveEngine()
        let mainPartID = self.part?.partID ?? fallbackID
        // Workers only when there's real work: cached operations come back instantly.
        let uncached = run.jobs.filter { j in
            opCache[jobKey(run, j.side, j.k, mainPartID: mainPartID)] == nil && !ToolpathDiskCache.has(diskKey(run, j.side, j.k, partURL: url))
        }.count
        let extra = max(min(Self.generationWorkers - 1, uncached - 1), 0)
        // Plain tasks on the main actor (each waits on its own engine process, so they run in
        // parallel); a task group here tripped the task allocator with this SDK and runtime.
        var tasks = [Task { @MainActor in
            await self.work(run, engine: main, partID: mainPartID, mainPartID: mainPartID, partURL: url)
        }]
        for i in 0..<extra {
            tasks.append(Task { @MainActor in
                guard let w = await self.worker(i, url: url) else { return }
                await self.work(run, engine: w.engine, partID: w.partID, mainPartID: mainPartID, partURL: url)
            })
        }
        for t in tasks { await t.value }
        guard generationSignature == run.signature, !cancelGeneration else { throw CancellationError() }
    }

    /// A worker engine with the part loaded (kept between generations, restarted if it died
    /// or the part changed).
    private func worker(_ i: Int, url: URL) async -> (engine: EngineClient, partID: String)? {
        if workerEngines.indices.contains(i) {
            let w = workerEngines[i]
            if w.partURL == url, await w.engine.isRunning() { return (w.engine, w.partID) }
            w.engine.terminate()
        }
        do {
            let e = try EngineClient.development(repoRoot: Self.repoRoot)
            let m = try await e.importPart(url)
            let w = (engine: e, partURL: url, partID: m.partID)
            if workerEngines.indices.contains(i) { workerEngines[i] = w } else { workerEngines.append(w) }
            return (e, m.partID)
        } catch {
            return nil  // the main engine carries on alone
        }
    }

    /// One engine's loop: takes the next job until there are none (or it's cancelled).
    private func work(_ run: GenerationRun, engine: EngineClient, partID: String, mainPartID: String, partURL: URL) async {
        while !cancelGeneration, run.next < run.jobs.count {
            if generationSignature != run.signature {
                if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil { print("signature changed:\n  \(run.signature)\n  \(generationSignature)") }
                cancelGenerationNow()
                status = "The job changed while generating: generate again (finished operations are kept)."
                return
            }
            // Side B's tabs are made long enough for side A's channel: its jobs wait for that.
            if run.jobs[run.next].side > 0, run.sides[run.jobs[run.next].side].tabSpec != nil, !run.frameReady {
                await awaitTabFrame(run, side: run.jobs[run.next].side)
                continue
            }
            let (si, k) = run.jobs[run.next]
            run.next += 1
            let side = run.sides[si].side
            let opID = run.sides[si].planned[k].operation.id
            setGenState(opID, side: side, .running)
            updateGenerationStatus(run)
            let opStart = Date()
            let key = jobKey(run, si, k, mainPartID: mainPartID)
            do {
                let one: [OperationToolpath], placed: [PlacedTab]
                let dkey = diskKey(run, si, k, partURL: partURL)
                if let hit = opCache[key] {
                    (one, placed) = hit
                    cachedOps += 1
                } else if let hit = ToolpathDiskCache.load(dkey) {
                    // The same request in an earlier run (this session or another).
                    (one, placed) = hit
                    storeInCache(key, hit)
                    cachedOps += 1
                } else {
                    (one, placed) = try await generateJob(run, si, k, engine: engine, partID: partID)
                    storeInCache(key, (one, placed))
                    ToolpathDiskCache.store(dkey, (one, placed))
                }
                if cancelGeneration || generationSignature != run.signature { return }
                run.done[si][k] = finishJob(one, k: k, si: si, run: run)
                if !placed.isEmpty {
                    placedTabs = placed
                    if let h = run.sides[si].tabSpec?.height { placedTabZ = run.sides[si].tabBottom...(run.sides[si].tabBottom + h) }
                }
                // Ready once every depth slice of it is.
                let allDone = run.sides[si].planned.indices.allSatisfy { j in
                    run.sides[si].planned[j].operation.id != opID || run.done[si][j] != nil
                }
                if allDone { setGenState(opID, side: side, .ready) }
                if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
                    let p = run.sides[si].planned[k]
                    print("timing op side \(side) \(p.operation.title) \(p.tool.name.prefix(18)) \(String(format: "%.1f", Date().timeIntervalSince(opStart))) s, \(one.first?.moves.count ?? 0) moves")
                }
                updateGenerationStatus(run)
                publishPartial(run)
            } catch {
                if cancelGeneration || generationSignature != run.signature { return }
                let message = (error as? EngineClient.EngineError).map { $0.type == "EngineExited" ? "The geometry engine crashed on this operation (a native library failed on this geometry)." : $0.message } ?? "\(error)"
                run.failed.append((si, k, message))
                setGenState(opID, side: side, .failed(message))
                if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil { print("generate failed side \(side): \(message)") }
                updateGenerationStatus(run)
                if !(await engine.isRunning()) { return }  // this engine died: the others carry on
            }
        }
    }

    /// What every operation's result goes through: warnings the plan handles become notes.
    private func finishJob(_ one: [OperationToolpath], k: Int, si: Int, run: GenerationRun) -> [OperationToolpath] {
        let sp = run.sides[si]
        let p = sp.planned[k]
        var clipped = one
        // "Too big for these pockets" is no warning when a smaller tool comes later for exactly
        // that: the plan handles it.
        for i in clipped.indices {
            let t = WarningTriage.split(clipped[i].warnings, at: k, in: sp.planned)
            clipped[i].warnings = t.warnings
            clipped[i].notes += t.notes
        }
        // Beyond the machine's X travel in this fixture (the lowest few millimetres of a bar
        // standing on the table, say): the pass lifts over it, as over a fixture. What it skips
        // stays uncut, for a setup from the other side or a higher stand.
        if let xr = sp.reachX {
            var skipped = 0.0
            for i in clipped.indices {
                let (m, s) = Self.liftOutside(clipped[i].moves, x: xr, safeZ: Self.safeHeight(p), plungeFeed: p.data.plungeFeed)
                clipped[i].moves = m
                skipped += s
            }
            if skipped > 1, !clipped.isEmpty {
                clipped[0].warnings.append("\(Length.mm(skipped)) mm of this pass lies beyond the machine's X travel with the stock held like this: left uncut here (another setup may reach it; to cut it from this side, stand the stock \(xr.lowerBound > -1e3 ? "higher" : "lower") in the fixture).")
            }
        }
        // The end pieces stay on (keepY): what would cut into them (the outline round the part's
        // ends) lifts over them. Not the reference bores and windows, which are in them on purpose.
        if let ky = sp.keepY, p.operation.reference == nil {
            let band = (ky.lowerBound - 0.05)...(ky.upperBound + 0.05)
            var skipped = 0.0
            for i in clipped.indices {
                let (m, s) = Self.liftWhere(clipped[i].moves, blocked: { !band.contains($0.y) }, safeZ: Self.safeHeight(p), plungeFeed: p.data.plungeFeed)
                clipped[i].moves = m
                skipped += s
            }
            if skipped > 1, !clipped.isEmpty {
                clipped[0].notes.append("\(Length.mm(skipped)) mm of this pass is on the stock past the part's ends: left for the end setups, which face it off.")
            }
        }
        // The fixtures and the table: where the cutter, shank or collet nut would meet them, the
        // pass lifts over (roughing keeps out of them already; finishing along a stock edge that
        // is the part's own face has nothing to cut there anyway).
        // The vise to buy, in this operation's clamping: the same lift over its jaws and floor.
        if run.sides[si].clampOf.indices.contains(k), p.operation.kind != .facing {
            let c = run.sides[si].clampOf[k]
            var skipped = 0.0
            for i in clipped.indices {
                let (m, s) = FixtureClearance.clip(clipped[i].moves, tool: p.tool, field: &run.sides[si].clampings[c].field, safeZ: Self.safeHeight(p),
                                                   plungeFeed: p.data.plungeFeed)
                clipped[i].moves = m
                skipped += s
            }
            if skipped > 1, !clipped.isEmpty {
                clipped[0].warnings.append("\(Length.mm(skipped)) mm of this pass was lifted to keep the tool clear of the vise's jaws: what it skips stays uncut.")
            }
        }
        if !run.sides[si].fields.isEmpty, p.operation.kind != .facing {
            var skipped = 0.0
            for i in clipped.indices {
                for f in run.sides[si].fields.indices {
                    let (m, s) = FixtureClearance.clip(clipped[i].moves, tool: p.tool, field: &run.sides[si].fields[f], safeZ: Self.safeHeight(p),
                                                       plungeFeed: p.data.plungeFeed)
                    clipped[i].moves = m
                    skipped += s
                }
            }
            if skipped > 1, !clipped.isEmpty {
                clipped[0].warnings.append("\(Length.mm(skipped)) mm of this pass was lifted to keep the \(p.tool.stickout < 20 ? "collet nut" : "tool") clear of the fixture or the table: what it skipped stays uncut. To cut there, stand the stock higher in the fixture (parallels under it) or use a longer stick-out.")
            }
        }
        return clipped
    }

    private func jobKey(_ run: GenerationRun, _ si: Int, _ k: Int, mainPartID: String) -> String {
        let sp = run.sides[si]
        return Self.generationKey(partID: mainPartID, sp.planned[k], sp.transform, sp.boxMin ?? run.boxMin, sp.boxMax ?? run.boxMax, sp.tabSpec, sp.tabBottom, machine: run.machine)
    }

    /// The moves with every stretch outside `x` lifted out: the tool rises to `safeZ`, crosses,
    /// and comes back down where the path is within reach again. Rapids are left as they are
    /// (above the work). Returns the new moves and how much cutting (mm) was skipped.
    nonisolated static func liftOutside(_ moves: [Move], x: ClosedRange<Double>, safeZ: Double = 3, plungeFeed: Double) -> (moves: [Move], skipped: Double) {
        liftWhere(moves, blocked: { $0.x < x.lowerBound || $0.x > x.upperBound }, inside: { min(max($0, x.lowerBound), x.upperBound) },
                  safeZ: safeZ, plungeFeed: plungeFeed)
    }

    /// The moves with every stretch where `blocked` lifted out (as `liftOutside`). `inside`
    /// brings a rapid's X back where the tool may go (identity: rapids stay as they are).
    nonisolated static func liftWhere(_ moves: [Move], blocked: (SIMD3<Double>) -> Bool, inside: (Double) -> Double = { $0 },
                                      safeZ: Double = 3, plungeFeed: Double) -> (moves: [Move], skipped: Double) {
        guard let first = moves.first else { return (moves, 0) }
        var out: [Move] = []
        out.reserveCapacity(moves.count)
        var skipped = 0.0
        var prev = first.position
        var lifted = false
        for (k, m) in moves.enumerated() {
            defer { prev = m.position }
            if k == 0 || m.role == .rapid {
                // Rapids travel above the work: one past the limit is brought back to it (its
                // endpoint, so the cut it leads to starts within reach).
                var q = m
                q.x = inside(m.x)
                if lifted {
                    out.append(Move(.rapid, x: q.x, y: q.y, z: max(q.z, safeZ)))
                    if q.z < safeZ { out.append(Move(.rapid, x: q.x, y: q.y, z: q.z)) }
                    lifted = false
                } else {
                    out.append(q)
                }
                continue
            }
            let pts = FixtureClearance.samples(from: prev, m, step: 0.5)
            if !lifted, !blocked(prev), !pts.contains(where: blocked) { out.append(m); continue }
            var last = prev
            for q in pts {
                if blocked(q) {
                    if !lifted { out.append(Move(.rapid, x: inside(last.x), y: last.y, z: safeZ)); lifted = true }
                    skipped += simd_length(q - last)
                } else {
                    if lifted {
                        out.append(Move(.rapid, x: q.x, y: q.y, z: safeZ))
                        out.append(Move(.plunge, x: q.x, y: q.y, z: q.z, feed: plungeFeed))
                        lifted = false
                    } else {
                        out.append(Move(m.role, x: q.x, y: q.y, z: q.z, feed: m.feed))
                    }
                }
                last = q
            }
        }
        if lifted, let l = out.last { out.append(Move(.rapid, x: inside(l.x), y: l.y, z: safeZ)) }
        return (out, skipped)
    }

    /// The disk cache's key: what the session's key holds, with the part file's contents in place
    /// of the engine's session id, the operation by its content (a plan gives it a new id every
    /// time it is chosen), and the engine's own code.
    private func diskKey(_ run: GenerationRun, _ si: Int, _ k: Int, partURL: URL) -> String {
        let sp = run.sides[si]
        var op = sp.planned[k]
        op.operation.id = ToolpathDiskCache.sameID
        return Self.generationKey(partID: ToolpathDiskCache.fileFingerprint(partURL), op, sp.transform, sp.boxMin ?? run.boxMin,
                                  sp.boxMax ?? run.boxMax, sp.tabSpec, sp.tabBottom, machine: run.machine) + "|engine:" + ToolpathDiskCache.engineFingerprint
    }

    /// The engine call, with everything read from the run inside (no SIMD values in the async
    /// frame of the caller).
    private func generateJob(_ run: GenerationRun, _ si: Int, _ k: Int, engine: EngineClient, partID: String) async throws -> ([OperationToolpath], [PlacedTab]) {
        let sp = run.sides[si]
        let r = try await engine.generate(partID: partID, transform: sp.transform, stockMin: sp.boxMin ?? run.boxMin, stockMax: sp.boxMax ?? run.boxMax,
                                          operations: [sp.planned[k]], safeZ: Self.safeHeight(sp.planned[k]), tabs: sp.tabSpec, tabBottom: sp.tabBottom,
                                          machine: run.machine)
        return (r.paths, r.tabs)
    }

    func setGenState(_ id: UUID, side: Int, _ s: GenState) {
        opGenState[id, default: [:]][side] = s
    }

    private func updateGenerationStatus(_ run: GenerationRun) {
        let running = opGenState.values.reduce(0) { $0 + $1.values.filter { $0 == .running }.count }
        let failed = run.failed.isEmpty ? "" : " · \(run.failed.count) failed"
        status = "Generating: \(run.finished) of \(run.total) ready · \(running) at a time\(failed)"
        generationProgress = Double(run.finished) / Double(max(run.total, 1))
    }

    /// Shows each side's toolpaths from its start up to the first operation still being made:
    /// the timeline and simulation work on them while the rest generates. At most every 2.5 s
    /// (a side that completes shows at once); the playhead stays where you left it.
    func publishPartial(_ run: GenerationRun, force: Bool = false) {
        guard generationSignature == run.signature, !cancelGeneration else { return }
        let grew = run.sides.indices.contains { run.prefix($0) > run.published[$0] }
        guard grew else { return }
        let sideDone = run.sides.indices.contains { run.prefix($0) == run.sides[$0].planned.count && run.published[$0] < run.prefix($0) }
        let wait = 2.5 - Date().timeIntervalSince(run.lastPublish)
        if !force && !sideDone && wait > 0 {
            if !run.publishScheduled {
                run.publishScheduled = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    run.publishScheduled = false
                    guard let self, self.isGenerating, !self.cancelGeneration else { return }
                    self.publishPartial(run, force: true)
                }
            }
            return
        }
        run.lastPublish = Date()
        var results: [SideResult] = []
        var program = 0
        let lastSide = run.sides.indices.last { run.prefix($0) > 0 } ?? 0
        for si in run.sides.indices where si <= lastSide {
            let sp = run.sides[si]
            let n = run.prefix(si)
            run.published[si] = n
            let planned = Array(sp.planned.prefix(n))
            let paths = (0..<n).flatMap { run.done[si][$0] ?? [] }
            // Programs as they'll be: consecutive operations with the same tool share one.
            var opProgram: [Int] = []
            for (k, p) in planned.enumerated() {
                if k > 0 && planned[k - 1].tool.id != p.tool.id { program += 1 }
                opProgram.append(program)
            }
            if !planned.isEmpty { program += 1 }
            results.append(SideResult(side: sp.side, setup: sp.setup, planned: planned, paths: paths,
                                      operationProgram: opProgram, operationLines: Array(repeating: [], count: planned.count)))
        }
        let first = sideResults.isEmpty
        let keep = playhead
        let atEnd = timeline.entries.isEmpty || playhead >= timeline.duration - 1e-6
        sideResults = results
        toolpaths = Dictionary(((results.first { $0.side == 0 } ?? results.first)?.paths ?? []).map { ($0.operationID, $0) }, uniquingKeysWith: { a, _ in a })
        if viewSide >= 0, !results.contains(where: { $0.side == viewSide }) { viewSide = results.first?.side ?? 0 }
        // The first toolpaths show on side A from its start.
        if first && viewSide < 0 && (stage == .machining || stage == .review) {
            switchingView = true
            viewSide = 0
            switchingView = false
        }
        // Side A complete: its final state for side B's simulation (the back) from now on.
        if twoSided, let a = results.first, a.planned.count >= (plannedOperationCount[0] ?? .max) { computeSideAFinal() }
        if first {
            if viewSide >= 0 { showSide(at: 0) }  // chapter 1, step 1
            focusWork()
        } else if viewSide >= 0 {
            // Never onto the steps that just arrived: at the end of what was there, stay on
            // its last step.
            showSide(at: atEnd ? max(keep - 1e-3, 0) : keep)
        }
        if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
            print("publish ready \(run.sides.indices.map { "\(run.prefix($0))/\(run.sides[$0].planned.count)" }) of \(run.finished)/\(run.total) done, timeline \(Int(timeline.duration)) s, playhead \(Int(playhead)) s")
        }
    }
}
