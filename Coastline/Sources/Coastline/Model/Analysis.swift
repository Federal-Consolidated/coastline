import CryptoKit
import CoastlineCore
import Foundation
import simd
import Viewport

extension AppModel {
    /// Re-runs the part analysis for the current orientation (debounced; ~1 s in the engine).
    func scheduleAnalysis() {
        if analysisFailed { analysisFailed = false }  // checking again
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.runAnalysis()
        }
    }

    func runAnalysis() async {
        guard part?.exact == true else { analysis = nil; showDFMHighlight(); return }
        if let url = part?.url { recogniseFeatures(url) }
        do {
            let engine = try await liveEngine()
            // After the engine is up: a restarted engine gave the part a new ID.
            guard let part else { return }
            let t = workTransform(part)
            // With access: line of sight, floors, holes and holder depth for Machinability.
            let a = try await engine.analyse(partID: part.partID, transform: t, access: true)
            // Another part was imported meanwhile: its own analysis follows.
            guard self.part?.partID == part.partID else { return }
            // An exact part always comes back with access data: none means the check couldn't run.
            analysisFailed = a.access == nil
            analysisTransform = t
            analysis = a
            showUndercuts()
            chooseSides(a)
        } catch {
            analysisFailed = true
            errorMessage = "Analysis failed: \(error)"
        }
    }

    /// Names the part's features (quiddity) in the background, on an engine of its own: on a
    /// busy part it takes tens of seconds, which mustn't hold up analysis or toolpaths. Once
    /// per file (kept in Caches by content); the findings take the names when they arrive.
    func recogniseFeatures(_ url: URL) {
        guard url != namedFeaturesFile else { return }
        namedFeaturesFile = url
        namedFeatures = []
        recognitionTask?.cancel()
        guard ["step", "stp"].contains(url.pathExtension.lowercased()) else { return }
        let root = Self.repoRoot
        recognitionTask = Task { [weak self] in
            let found: [NamedFeature]? = await Task.detached(priority: .utility) {
                if let cached = NamedFeatureCache.load(url) { return cached }
                guard let engine = try? EngineClient.development(repoRoot: root) else { return nil }
                defer { engine.terminate() }
                guard let features = try? await engine.recognise(path: url) else { return nil }
                NamedFeatureCache.save(features, for: url)
                return features
            }.value
            guard let self, !Task.isCancelled, self.namedFeaturesFile == url, let found else { return }
            self.namedFeatures = found
        }
    }

    /// Parts with shape on the back (faces turned away from the spindle) are machined from
    /// both sides; a flat back can be done from one side, so that stays the default there. A
    /// choice the user made themselves is kept.
    func chooseSides(_ a: PartAnalysis) {
        guard !twoSidedChosen else { return }
        // Or a setup from the back is among the sides the part check proposes.
        let want = Self.backHasShape(a)
            || dfmFindings(inventory: inventoryLookup()).map { PlanCoverage.propose($0).contains("-z") } == true
        if twoSided != want {
            twoSided = want
            status = want ? "The back has shape (shown red): planned from both sides." : "The back is flat: planned from one side."
        }
    }

    static func backHasShape(_ a: PartAnalysis) -> Bool { a.undercutArea > 0.5 }

    /// Faces that point away from the spindle, drawn red over the part.
    func showUndercuts() {
        // Every layout and analysis comes through here: the finding highlight follows the part too.
        defer { showDFMHighlight() }
        renderer.scene.remove(id: "undercuts")
        undercutOverlayShown = false
        // Drawn on the part in side A's clamping only (the prep shows the bare stock; side B has
        // the part turned over).
        guard showUndercutOverlay, let a = analysis, !a.undercutTriangles.isEmpty, let stock, let part, !showingMillDown, viewSide != 1 else { return }
        // The triangles are in the work frame of the analysis. Moved since: follow the part at
        // once. Turned or scaled: those are different faces, so nothing until the new analysis.
        let now = workTransform(part)
        guard let partMesh = renderer.scene.mesh("part"), partMesh.isVisible else { return }
        if let then = analysisTransform {
            let same = (0..<3).allSatisfy { c in simd_distance(now[c], then[c]) < 1e-9 }
            guard same else { return }
        }
        _ = stock
        let (t, normals) = Self.overlay(a.undercutTriangles)
        // On the part wherever it's drawn: the part's model transform, back through the work
        // transform the triangles were made with.
        let placed = partMesh.transform * (analysisTransform ?? now).inverse.float
        if let m = SceneMesh(device: renderer.device, id: "undercuts", positions: t, normals: normals,
                             indices: (0..<UInt32(t.count / 3)).map { $0 }, color: SceneColor.surface(0.97, alpha: 0.8),
                             transform: placed) {
            renderer.scene.setMesh(m)
            undercutOverlayShown = true
        }
    }

    /// Triangles (9 floats each) with flat normals, lifted 0.03 mm off the surface along them so
    /// the overlay never z-fights the part.
    static func overlay(_ triangles: [Float]) -> (positions: [Float], normals: [Float]) {
        var t = triangles
        var normals = [Float](repeating: 0, count: t.count)
        var k = 0
        while k + 8 < t.count {
            let p0 = SIMD3(t[k], t[k + 1], t[k + 2]), p1 = SIMD3(t[k + 3], t[k + 4], t[k + 5]), p2 = SIMD3(t[k + 6], t[k + 7], t[k + 8])
            let c = simd_cross(p1 - p0, p2 - p0)
            let n = simd_length(c) > 1e-12 ? simd_normalize(c) : SIMD3<Float>(0, 0, 1)
            for v in 0..<3 {
                normals[k + 3 * v] = n.x; normals[k + 3 * v + 1] = n.y; normals[k + 3 * v + 2] = n.z
                t[k + 3 * v] += n.x * 0.03; t[k + 3 * v + 1] += n.y * 0.03; t[k + 3 * v + 2] += n.z * 0.03
            }
            k += 9
        }
        return (t, normals)
    }

    // MARK: Machinability (DFM)

    /// The analysis when it describes the part as it is turned and scaled now, with the access
    /// data. Moving the part changes none of the measures DFM uses (all are relative to the part),
    /// so, as for the undercut overlay, a move alone keeps it.
    func currentAccessAnalysis(_ part: PartInfo) -> PartAnalysis? {
        guard let a = analysis, a.access != nil, let then = analysisTransform else { return nil }
        let now = workTransform(part)
        return (0..<3).allSatisfy { simd_distance(now[$0], then[$0]) < 1e-9 } ? a : nil
    }

    /// The machine's room for the stock turned to each side: the table toward the spindle, and
    /// how far the stock may hang past its far edge with and without the enclosure, swept over
    /// the travel in the job machine's model. nil for a profile without one (not checked).
    /// Cached per machine, stock size and travel centre: each side pair takes one sweep each way.
    var setupRoom: SetupRoom? {
        guard let g = planningGeometry, let stock else { return nil }
        let size = setup.stockSize(stock), centre = travelCentreY
        let key = "\(g.definition.id)#\(g.definition.revision)|\(size)|\(centre)"
        if let cached = setupRoomCache, cached.key == key { return cached.room }
        let enclosure = Set(g.definition.components.filter { g.isEnclosure(componentID: $0.id) }.map(\.id))
        var turns: [String: SetupRoom.Turn] = [:]
        for axis in ["z", "x", "y"] {
            let s = SetupRoom.size(size, facing: "+" + axis)
            guard let a = try? g.roomBehindTable(height: s.x, width: s.y, centreY: centre),
                  let b = try? g.roomBehindTable(height: s.x, width: s.y, centreY: centre, skip: enclosure) else { continue }
            turns["+" + axis] = .init(behind: a.distance, behindOpen: b.distance)
            turns["-" + axis] = turns["+" + axis]
        }
        let room = SetupRoom(tableDepth: g.supportBounds.size.z, turns: turns)
        setupRoomCache = (key, room)
        return room
    }

    /// Machinability of the part as set up, against the library's tools, collets and stock and
    /// the job's machine; nil until the analysis for this orientation is in. Mesh parts get the
    /// stock fit and "Exact CAD needed". Cached: the pins re-render with every camera move.
    func dfmFindings(inventory: Inventory) -> [DFMFinding]? {
        guard let part else { return nil }
        let key = DFMCacheKey(analysisVersion: analysisVersion, named: namedFeatures, partID: part.partID, setup: setup, stock: stock,
                              inventory: inventory, machine: machine, twoSided: twoSided, room: setupRoom)
        if let c = dfmCache, c.key == key { return c.findings }
        let a: PartAnalysis
        if part.exact {
            guard let current = currentAccessAnalysis(part) else { return nil }
            a = current
        } else {
            a = PartAnalysis()
        }
        let findings = DFM.assess(DFM.Input(analysis: a, setup: setup, partMin: part.boundsMin, partMax: part.boundsMax,
                                            stock: stock, inventory: inventory, machine: machine, twoSided: twoSided,
                                            named: namedFeatures, room: setupRoom))
        var anchors: [String: [SIMD3<Double>]] = [:]
        if let access = a.access {
            for f in findings where f.category != .ok { anchors[f.id] = Self.anchors(f.areas, access) }
        }
        dfmCache = (key, findings, anchors)
        return findings
    }

    /// One point per place, on the surface: the triangle nearest the place's middle, lifted
    /// half a millimetre off it (work frame of the analysis).
    nonisolated static func anchors(_ areas: [[Int]], _ access: PartAccess) -> [SIMD3<Double>] {
        areas.compactMap { faces in
            let t = access.triangles(forFaces: faces)
            guard t.count >= 9 else { return nil }
            var mid = SIMD3<Double>.zero
            for k in stride(from: 0, to: t.count - 2, by: 3) { mid += SIMD3(Double(t[k]), Double(t[k + 1]), Double(t[k + 2])) }
            mid /= Double(t.count / 3)
            var best: (d: Double, p: SIMD3<Double>, n: SIMD3<Double>)?
            for k in stride(from: 0, to: t.count - 8, by: 9) {
                let a = SIMD3(Double(t[k]), Double(t[k + 1]), Double(t[k + 2]))
                let b = SIMD3(Double(t[k + 3]), Double(t[k + 4]), Double(t[k + 5]))
                let c = SIMD3(Double(t[k + 6]), Double(t[k + 7]), Double(t[k + 8]))
                let centre = (a + b + c) / 3, cross = simd_cross(b - a, c - a)
                guard simd_length(cross) > 1e-12 else { continue }
                let d = simd_distance(centre, mid)
                if best == nil || d < best!.d { best = (d, centre, simd_normalize(cross)) }
            }
            return best.map { $0.p + $0.n * 0.5 }
        }
    }

    /// The pins of a finding in world coordinates, where the part is drawn now.
    func findingPinPoints(_ id: String) -> [SIMD3<Float>] {
        guard let points = dfmCache?.anchors[id], let then = analysisTransform,
              let partMesh = renderer.scene.mesh("part"), partMesh.isVisible else { return [] }
        let m = renderer.scene.groupTransform(partMesh.group) * partMesh.transform * then.inverse.float
        return points.map { p in
            let w = m * SIMD4(Float(p.x), Float(p.y), Float(p.z), 1)
            return SIMD3(w.x, w.y, w.z)
        }
    }

    /// Problems are drawn on the part in Plan (all at once, by kind), unless hidden.
    var showsFindingsInView: Bool {
        showFindingsOverlay && stage == .planning && fixturePlacement == nil && !showsMachiningResults && part != nil
    }

    /// Picks a finding (nil: none). Its faces light up on the part and, when asked, the view
    /// frames them.
    func selectFinding(_ f: DFMFinding?, frame: Bool = true) {
        if selectedFindingID != f?.id { selectedFindingID = f?.id }
        dfmHighlight = f.map { ($0.faces, $0.category) }
        showDFMHighlight()
        if frame, let f { frameFinding(f) }
    }

    /// The findings were made again (tools, stock, machine, orientation changed): the part's
    /// colours follow, the highlight follows its finding, and goes when the finding does, is
    /// solved (it folds into the passed checks) or the analysis is being redone.
    func syncFindingSelection(_ findings: [DFMFinding]?) {
        var faces: [DFMFinding.Category: [Int]] = [:]
        for f in findings ?? [] where f.category != .ok { faces[f.category, default: []] += f.faces }
        if faces != dfmOverlayFaces { dfmOverlayFaces = faces; showDFMHighlight() }
        guard let id = selectedFindingID else { return }
        guard let f = findings?.first(where: { $0.id == id }),
              f.category != .ok || dfmHighlight?.category == .ok else { selectFinding(nil); return }
        if dfmHighlight?.faces != f.faces || dfmHighlight?.category != f.category { selectFinding(f, frame: false) }
    }

    /// Every problem's faces in its colour (Plan), and the selected finding's faces drawn over
    /// everything, so a face on the back or inside the part still shows where it is. Placed like
    /// the undercuts: the part's model transform, back through the analysis' work transform.
    func showDFMHighlight() {
        renderer.scene.remove(id: "dfm.highlight")
        for c in DFMFinding.Category.allCases { renderer.scene.remove(id: "dfm.cat.\(c.rawValue)") }
        guard !stockAnimating, let access = analysis?.access, let then = analysisTransform,
              let partMesh = renderer.scene.mesh("part"), partMesh.isVisible else { return }
        let transform = partMesh.transform * then.inverse.float
        func add(_ id: String, _ faces: [Int], _ colour: SIMD4<Float>, onTop: Bool) {
            let (t, normals) = Self.overlay(access.triangles(forFaces: faces))
            guard t.count >= 9, let m = SceneMesh(device: renderer.device, id: id, positions: t, normals: normals,
                                                  indices: (0..<UInt32(t.count / 3)).map { $0 }, color: colour,
                                                  transform: transform) else { return }
            m.group = partMesh.group  // on the table with the part, or on its own on the Part step
            m.depthBias = 1  // as the undercuts: wins against the part face it lies on
            m.onTop = onTop
            renderer.scene.setMesh(m)
        }
        if showsFindingsInView {
            for (c, faces) in dfmOverlayFaces where !faces.isEmpty {
                var colour = Self.highlightColor(c)
                colour.w = 0.9
                add("dfm.cat.\(c.rawValue)", faces, colour, onTop: false)
            }
        }
        if let h = dfmHighlight, !h.faces.isEmpty {
            var colour = Self.highlightColor(h.category)
            colour.w = 0.55
            add("dfm.highlight", h.faces, colour, onTop: true)
        }
    }

    /// Red: can't be machined; amber: a tool or stock is missing; blue: a setup change; grey:
    /// information needed; green: fine (the faces that stay as supplied).
    static func highlightColor(_ c: DFMFinding.Category) -> SIMD4<Float> {
        switch c {
        case .notSupported: SIMD4(0.92, 0.12, 0.08, 1)
        case .missingResource: SIMD4(0.98, 0.68, 0.08, 1)
        case .setupChange: SIMD4(0.22, 0.55, 1.0, 1)
        case .missingInformation: SIMD4(0.72, 0.72, 0.78, 1)
        case .ok: SIMD4(0.30, 0.80, 0.42, 1)
        }
    }

    /// Frames the finding's faces with room around them.
    private func frameFinding(_ f: DFMFinding) {
        guard let access = analysis?.access, let b = access.bounds(forFaces: f.faces), let then = analysisTransform,
              let partMesh = renderer.scene.mesh("part"), partMesh.isVisible else { return }
        let m = renderer.scene.groupTransform(partMesh.group) * partMesh.transform * then.inverse.float
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in 0..<8 {
            let c = SIMD3<Float>(Float(i & 1 == 0 ? b.min.x : b.max.x), Float(i & 2 == 0 ? b.min.y : b.max.y),
                                 Float(i & 4 == 0 ? b.min.z : b.max.z))
            let w = m * SIMD4(c, 1)
            lo = simd_min(lo, SIMD3(w.x, w.y, w.z))
            hi = simd_max(hi, SIMD3(w.x, w.y, w.z))
        }
        // The view keeps its direction: turned to the back it would look through the table and
        // fixtures. Never a close-up of a small hole: the part around it stays in view.
        let c = (lo + hi) / 2, half = simd_max((hi - lo) / 2 * 1.4, SIMD3(repeating: 15))
        renderer.frame(worldMin: c - half, worldMax: c + half, animated: true)
    }

    /// A finding's way forward. Only stock and navigation: nothing about a tool is changed here.
    func applyDFMRemedy(_ r: DFMFinding.Remedy, inventory library: InventoryModel) {
        let inventory = library.inventory
        switch r {
        case .useStock(let id, let axes):
            // As choosing it from the library does (useGuidedStock): the stock, then how it sits.
            guard let item = inventory.stock.first(where: { $0.id == id }) else { return }
            useStock(inventory.resolvedStock(item))
            useStockAxes(axes)
        case .showTool(let id), .buyTool(let id):
            toolToShow = id
            page = .tools
        case .addCollet:
            page = .accessories
        case .addTool(let t):
            // Added as a tool to buy (quantity 0): plans "with tools to buy" may use it.
            if !inventory.tools.contains(where: { $0.id == t.id }) { library.add(t, to: \.tools) }
            status = "Added the \(t.name) to your tools, to buy."
        case .reviewSetups:
            enter(.clampKit)
        case .setStickout:
            break  // a value to set on the tool yourself (shown as text)
        }
    }

    // MARK: Watching the CAD file

    /// Watches the imported file; a re-export from Rhino shows a Reload banner.
    func watchPartFile(_ url: URL) {
        partWatcher?.cancel()
        partChangedOnDisk = false
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.partChangedOnDisk = true }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        partWatcher = source
    }

    /// Re-imports the changed file, keeping the orientation, stock and operations.
    func reloadPart() async {
        guard let url = part?.url else { return }
        let keepSetup = setup, keepOps = operations, keepStock = stockID, keepSides = (twoSided, twoSidedChosen)
        await importPart(url)
        (twoSided, twoSidedChosen) = keepSides
        setup = keepSetup
        stockID = keepStock
        operations = keepOps
        partChangedOnDisk = false
        status = "Reloaded \(url.lastPathComponent): orientation, stock and operations kept. Generate again."
    }
}

/// Named features per file content, in ~/Library/Caches/Coastline/Features: recognition is slow
/// on busy parts and the answer only changes with the file.
enum NamedFeatureCache {
    /// Bumped when the names change (engine labels or the quiddity version).
    static let version = 1

    static func file(for url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coastline/Features", isDirectory: true)
        return dir.appendingPathComponent("\(digest)-v\(version).json")
    }

    static func load(_ url: URL) -> [NamedFeature]? {
        guard let f = file(for: url), let data = try? Data(contentsOf: f) else { return nil }
        return try? JSONDecoder().decode([NamedFeature].self, from: data)
    }

    static func save(_ features: [NamedFeature], for url: URL) {
        guard let f = file(for: url), let data = try? JSONEncoder().encode(features) else { return }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: f, options: .atomic)
    }
}
