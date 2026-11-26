import AppKit
import CoastlineCore
import Foundation
import simd
import UniformTypeIdentifiers
import Viewport

/// K12: a sharp snapshot, as saved in the project. Heights are whole µm (SharpSim.encode).
struct SharpSnapshotRecord: Codable, Identifiable, Equatable {
    enum Region: String, Codable { case whole, around }
    var id = UUID()
    var name: String
    var note = ""
    var side: Int
    /// The playhead it was made at, and the moves applied (the timeline entry index).
    var time: Double
    var entryIndex: Int
    var originX: Double
    var originY: Double
    var cell: Double
    var cols: Int
    var rows: Int
    var top: Double
    var bottom: Double
    var region: Region
    /// The toolpaths it was made from (`AppModel.simSignature`): another one makes it out of date.
    var signature: String
    var created = Date()
    var heights: Data

    var heightmap: Heightmap? {
        SharpSim.decode(heights, cols: cols, rows: rows).map {
            Heightmap(origin: SIMD2(originX, originY), cell: cell, cols: cols, rows: rows, top: top, bottom: bottom, heights: $0)
        }
    }
    var resolutionText: String { "\((cell * 1000).formatted(.number.precision(.fractionLength(cell < 0.01 ? 1 : 0)))) µm" }
}

/// An exact section through the simulated stock, for the section sheet.
struct ExactSection: Identifiable {
    let id = UUID()
    var title: String
    var axis: String
    /// Positions along the line (work mm) and heights (work Z, mm).
    var positions: [Double]
    var exact: [Double]
    var grid: [Double]
    var part: [Double]?
    var gridCell: Double

    /// How far the material is from the part at each point: against the range of the part's
    /// heights within a couple of samples (as the deviation map does), so a steep wall a few µm
    /// to the side doesn't count as a gouge. nil off the part and at its outline.
    var partGap: [Double?]? {
        guard let p = part else { return nil }
        return exact.indices.map { i in
            let w = max(i - 2, 0)...min(i + 2, p.count - 1)
            let near = w.map { p[$0] }
            guard near.allSatisfy(\.isFinite) else { return nil }
            let lo = near.min()!, hi = near.max()!, e = exact[i]
            return e > hi ? e - hi : (e < lo ? e - lo : 0)
        }
    }
    /// Most material left above the part and deepest cut into it, mm (nil without a part).
    var leftAbovePart: Double? { partGap.map { g in g.compactMap { $0 }.max() ?? 0 } }
    var cutIntoPart: Double? { partGap.map { g in max(-(g.compactMap { $0 }.min() ?? 0), 0) } }
}

extension AppModel {
    /// Snapshots kept in a project file, bytes; the oldest go first past it.
    static let snapshotBudget = 200_000_000

    /// Identifies the toolpaths of the side on screen: a change makes snapshots out of date.
    var simSignature: String {
        let e = timeline.entries
        let last = e.last.map { "\($0.move.position)" } ?? "-"
        return "\(viewSide)|\(e.count)|\(Int((timeline.duration * 1000).rounded()))|\(plannedTools.map { String($0.id.uuidString.prefix(8)) }.joined())|\(last)"
    }

    func snapshotIsCurrent(_ r: SharpSnapshotRecord) -> Bool { r.side == viewSide && r.signature == simSignature }

    /// The work origin the simulation meshes are drawn at.
    var simWorkOrigin: SIMD3<Double>? {
        guard let stock else { return nil }
        return workOrigin(stockSize: displayStockSize ?? setup.stockSize(stock))
    }

    /// The cutting stretches of the moves applied so far (cached per playhead position).
    func cutSegments() async -> [CutSegment] {
        let key = "\(simSignature)|\(simIndex)"
        if let s = sharpSegments, s.key == key { return s.segs }
        let entries = timeline.entries, tools = plannedTools, upTo = min(simIndex, timeline.entries.count)
        let segs = await Task.detached(priority: .userInitiated) { () -> [CutSegment] in
            var moves: [(move: Move, start: SIMD3<Double>, radius: Double, corner: Double)] = []
            moves.reserveCapacity(upTo)
            for e in entries[0..<upTo] {
                guard tools.indices.contains(e.operation), e.operation != 0, !EdgeFinding.isEdgeFinder(tools[e.operation]) else { continue }
                let t = tools[e.operation]
                moves.append((e.move, e.start, t.diameter / 2, t.cornerRadius))
            }
            return SharpSim.segments(moves)
        }.value
        sharpSegments = (key, segs)
        return segs
    }

    // MARK: Making

    /// Re-simulates up to the playhead at high resolution: the whole stock (~10 µm, finer on a
    /// small block) or a square around a point (2.5 µm).
    func sharpen(around centre: SIMD2<Double>? = nil, size: Double = 5) {
        guard simulate, let coarse = heightmap, let start = simStart, sharpProgress == nil else { return }
        pause()
        let lo0 = SIMD2(coarse.origin.x - coarse.cell / 2, coarse.origin.y - coarse.cell / 2)
        let hi0 = lo0 + SIMD2(Double(coarse.cols), Double(coarse.rows)) * coarse.cell
        var lo = lo0, hi = hi0, target = 0.01
        if let c = centre {
            lo = simd_max(c - size / 2, lo0)
            hi = simd_min(c + size / 2, hi0)
            target = 0.0025
        }
        guard hi.x > lo.x, hi.y > lo.y else { return }
        let cell = SharpSim.cell(region: lo, hi, target: target)
        let regionLo = lo, regionHi = hi
        let side = viewSide, time = playhead, index = simIndex, signature = simSignature
        sharpProgress = -1
        sharpPhase = "Collecting the moves"
        status = "Sharpening at \((cell * 1000).formatted(.number.precision(.fractionLength(cell < 0.01 ? 1 : 0)))) µm…"
        let started = Date()
        let cancel = Counter()
        sharpTask = Task { [weak self] in
            guard let self else { return }
            let segs = await self.cutSegments()
            self.sharpPhase = "Sharpening"
            self.sharpProgress = 0
            let box = ProgressBox()
            let poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    if self?.sharpProgress != nil { self?.sharpProgress = box.value }
                }
            }
            let hm = await Task.detached(priority: .userInitiated) {
                SharpSim.sharpen(segs, start: start, coarse: coarse, region: regionLo, regionHi, cell: cell, progress: { box.value = $0 },
                                 cancelled: { cancel.value > 0 })
            }.value
            poll.cancel()
            guard let hm, !Task.isCancelled else { self.sharpProgress = nil; self.status = "Sharpening cancelled."; return }
            // Drawing it takes a moment on the main thread: show that first.
            self.sharpPhase = "Drawing"
            self.sharpProgress = -1
            try? await Task.sleep(for: .milliseconds(60))
            let n = self.sharpSnapshots.filter { $0.side == side }.count + 1
            let rec = SharpSnapshotRecord(name: "\(Self.setupTitle(side: side, twoSided: self.twoSided)) · \(AppModel.clock(time))" + (centre == nil ? "" : " · detail") + (n > 1 ? "" : ""),
                                          side: side, time: time, entryIndex: index, originX: hm.origin.x, originY: hm.origin.y,
                                          cell: hm.cell, cols: hm.cols, rows: hm.rows, top: hm.top, bottom: hm.bottom,
                                          region: centre == nil ? .whole : .around, signature: signature, heights: SharpSim.encode(hm))
            self.sharpSnapshots.append(rec)
            self.sharpCache[rec.id] = hm
            self.projectDirty = true
            if self.playhead == time { self.displaySharp(rec, hm) }
            self.sharpProgress = nil
            self.status = "Sharp snapshot at \(rec.resolutionText): \(hm.cols) × \(hm.rows) cells in \(String(format: "%.1f", Date().timeIntervalSince(started))) s."

        }
        sharpCancel = cancel
    }

    func cancelSharpen() {
        sharpCancel?.add()
        sharpTask?.cancel()
        sharpProgress = nil
    }

    // MARK: Showing

    /// Goes to a snapshot's moment and shows it.
    func showSnapshot(_ id: UUID) {
        guard let rec = sharpSnapshots.first(where: { $0.id == id }), snapshotIsCurrent(rec) else { return }
        pause()
        if abs(playhead - rec.time) > 1e-6 { seek(rec.time) }
        guard let hm = sharpCache[id] ?? rec.heightmap else { return }
        sharpCache[id] = hm
        // Playback may still be catching up to the moment: show it once the grid is there.
        Task { @MainActor [weak self] in
            for _ in 0..<200 {
                guard let self else { return }
                if self.simIndex >= rec.entryIndex - 1 { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            self?.displaySharp(rec, hm)
        }
    }

    /// Draws a snapshot (at most ~2.5 million cells; the readouts and export use all of it).
    func displaySharp(_ rec: SharpSnapshotRecord, _ hm: Heightmap) {
        guard let origin = simWorkOrigin, let stock else { return }
        renderer.scene.remove(id: "simstock.sharp")
        let stride = max(Int((Double(hm.cols * hm.rows) / 1_500_000).squareRoot().rounded(.up)), 1)
        let d = Self.downsample(hm, stride: stride)
        let c = stock.material?.linearSwatch ?? SIMD3(0.5, 0.5, 0.5)
        // Two-sided and later setups: the back the earlier side left (the playback grid's), so
        // what was cut through stays open and the other side's work stays visible.
        var back: [Float]?
        if let coarseBack = simBack, let coarse = heightmap {
            var b = [Float](repeating: Float(d.bottom), count: d.cols * d.rows)
            for r in 0..<d.rows {
                let y = d.origin.y + Double(r) * d.cell
                let cr = min(max(Int(((y - coarse.origin.y) / coarse.cell).rounded()), 0), coarse.rows - 1)
                for col in 0..<d.cols {
                    let x = d.origin.x + Double(col) * d.cell
                    let cc = min(max(Int(((x - coarse.origin.x) / coarse.cell).rounded()), 0), coarse.cols - 1)
                    b[r * d.cols + col] = coarseBack[cr * coarse.cols + cc]
                }
            }
            back = b
        }
        guard let mesh = SceneMesh.grid(device: renderer.device, id: "simstock.sharp", x0: Float(d.origin.x), y0: Float(d.origin.y),
                                        cell: Float(d.cell), cols: d.cols, rows: d.rows, z: Float(d.top), color: SIMD4(c * 0.85, 1),
                                        transform: simd_float4x4(translation: SIMD3<Float>(origin)), bottom: Float(d.bottom),
                                        bottomFace: back == nil) else { return }
        mesh.group = renderer.scene.mesh("simstock")?.group
        mesh.updateGrid(values: d.heights, top: d.heights, back: back, cols: d.cols, rows: d.rows, cell: Float(d.cell),
                        c0: 0, r0: 0, c1: d.cols - 1, r1: d.rows - 1, downward: false, floor: Float(d.bottom))
        renderer.scene.setMesh(mesh)
        // The coarse grid steps aside where the sharp one is.
        if rec.region == .whole {
            renderer.scene.mesh("simstock")?.isVisible = false
        } else if let coarse = heightmap, let sim = renderer.scene.mesh("simstock") {
            var h = coarse.heights
            if let (c0, r0, c1, r1) = coarse.cellRange(SIMD2(rec.originX, rec.originY),
                                                       SIMD2(rec.originX + Double(rec.cols - 1) * rec.cell, rec.originY + Double(rec.rows - 1) * rec.cell)) {
                for r in r0...r1 { for col in c0...c1 { h[r * coarse.cols + col] = Float(coarse.bottom) } }
            }
            sim.updateGrid(values: h, top: h, back: simBack, cols: coarse.cols, rows: coarse.rows, cell: Float(coarse.cell),
                           c0: 0, r0: 0, c1: coarse.cols - 1, r1: coarse.rows - 1, downward: false, floor: Float(coarse.bottom))
        }
        shownSnapshot = rec.id
        if showDeviation { Task { await updateDeviation() } }
    }

    func hideSharp(restore: Bool = true) {
        renderer.scene.remove(id: "simstock.sharp")
        shownSnapshot = nil
        guard restore else { return }
        renderer.scene.mesh("simstock")?.isVisible = true
        if var hm = heightmap { hm.markAllDirty(); heightmap = hm; refreshSimMesh() }
        if showDeviation { Task { await updateDeviation() } }
    }

    /// The grid the deviation map compares: the shown snapshot (at most a million cells), else
    /// the playback grid.
    var deviationGrid: Heightmap? {
        if let id = shownSnapshot, let hm = sharpCache[id] {
            let s = max(Int((Double(hm.cols * hm.rows) / 1_000_000).squareRoot().rounded(.up)), 1)
            return Self.downsample(hm, stride: s)
        }
        return heightmap
    }

    static func downsample(_ hm: Heightmap, stride s: Int) -> Heightmap {
        guard s > 1 else { return hm }
        let cols = (hm.cols + s - 1) / s, rows = (hm.rows + s - 1) / s
        var h = [Float](repeating: 0, count: cols * rows)
        for r in 0..<rows { for c in 0..<cols { h[r * cols + c] = hm.heights[min(r * s, hm.rows - 1) * hm.cols + min(c * s, hm.cols - 1)] } }
        return Heightmap(origin: hm.origin, cell: hm.cell * Double(s), cols: cols, rows: rows, top: hm.top, bottom: hm.bottom, heights: h)
    }

    // MARK: Managing

    func deleteSnapshot(_ id: UUID) {
        if shownSnapshot == id { hideSharp() }
        sharpSnapshots.removeAll { $0.id == id }
        sharpCache[id] = nil
        projectDirty = true
    }

    /// What goes into the project file: the newest snapshots within the budget.
    var savedSnapshots: [SharpSnapshotRecord] {
        var total = 0
        return sharpSnapshots.sorted { $0.created > $1.created }.filter { total += $0.heights.count; return total <= Self.snapshotBudget }
            .sorted { $0.created < $1.created }
    }

    func loadSnapshots(_ list: [SharpSnapshotRecord]) {
        hideSharp(restore: false)
        sharpSnapshots = list
        sharpCache = [:]
    }

    @discardableResult
    func exportSnapshot(_ id: UUID, to url: URL) -> Bool {
        guard let rec = sharpSnapshots.first(where: { $0.id == id }), let hm = sharpCache[id] ?? rec.heightmap else { return false }
        // At most ~3 million triangles (about 150 MB of STL).
        let stride = max(Int((Double(hm.cols * hm.rows) * 2 / 3_000_000).squareRoot().rounded(.up)), 1)
        let m = SharpSim.mesh(hm, stride: stride)
        let data = url.pathExtension.lowercased() == "obj" ? SharpSim.obj(m, name: rec.name) : SharpSim.stl(m, name: rec.name)
        do { try data.write(to: url, options: .atomic) } catch { errorMessage = "Couldn't export: \(error.localizedDescription)"; return false }
        status = "Exported \(url.lastPathComponent): \(m.triangles.count.formatted()) triangles\(stride > 1 ? " (every \(stride) cells)" : ""), work coordinates in mm."
        return true
    }

    func exportSnapshotWithPanel(_ id: UUID, format: String) {
        guard let rec = sharpSnapshots.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .data]
        panel.nameFieldStringValue = rec.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "." + format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportSnapshot(id, to: url)
    }

    // MARK: Exact readouts

    /// Where a view ray meets the simulated surface (the shown snapshot, else the playback grid):
    /// the work point and the scene point.
    func simRayHit(origin o: SIMD3<Float>, direction dir: SIMD3<Float>) -> (work: SIMD3<Double>, world: SIMD3<Float>)? {
        if let id = shownSnapshot, let sharp = sharpCache[id], let hit = rayHit(sharp, origin: o, direction: dir) { return hit }
        return heightmap.flatMap { rayHit($0, origin: o, direction: dir) }
    }

    private func rayHit(_ hm: Heightmap, origin o: SIMD3<Float>, direction dir: SIMD3<Float>) -> (work: SIMD3<Double>, world: SIMD3<Float>)? {
        guard let wo = simWorkOrigin else { return nil }
        let toWorld = renderer.scene.groupTransform(renderer.scene.mesh("simstock")?.group) * simd_float4x4(translation: SIMD3<Float>(wo))
        let inv = toWorld.inverse
        let o4 = inv * SIMD4(o, 1), d4 = inv * SIMD4(dir, 0)
        let p0 = SIMD3<Double>(Double(o4.x), Double(o4.y), Double(o4.z)), d = simd_normalize(SIMD3<Double>(Double(d4.x), Double(d4.y), Double(d4.z)))
        let lo = SIMD3(hm.origin.x - hm.cell / 2, hm.origin.y - hm.cell / 2, hm.bottom)
        let hi = SIMD3(lo.x + Double(hm.cols) * hm.cell, lo.y + Double(hm.rows) * hm.cell, hm.top)
        // The ray's stretch inside the block.
        var t0 = 0.0, t1 = 1e6
        for k in 0..<3 {
            if abs(d[k]) < 1e-12 { if p0[k] < lo[k] || p0[k] > hi[k] { return nil }; continue }
            let a = (lo[k] - p0[k]) / d[k], b = (hi[k] - p0[k]) / d[k]
            t0 = max(t0, min(a, b)); t1 = min(t1, max(a, b))
        }
        guard t0 <= t1 else { return nil }
        func below(_ t: Double) -> Bool { let p = p0 + d * t; return p.z <= hm.sample(SIMD2(p.x, p.y)) }
        let step = hm.cell * 0.5
        var t = t0, prev = t0
        while t <= t1 {
            if below(t) {
                var a = prev, b = t
                for _ in 0..<30 { let m = (a + b) / 2; if below(m) { b = m } else { a = m } }
                let p = p0 + d * b
                let w = toWorld * SIMD4(Float(p.x), Float(p.y), Float(p.z), 1)
                return (p, SIMD3(w.x, w.y, w.z))
            }
            prev = t
            t += step
        }
        return nil
    }

    /// Fills a measure point with the exact material height and how it stands to the part.
    func probeExact(index: Int, work p: SIMD3<Double>) {
        guard let coarse = heightmap else { return }
        let start = simStart?.sample(SIMD2(p.x, p.y)) ?? coarse.top, bottom = coarse.bottom
        let grid = coarse.sample(SIMD2(p.x, p.y))
        Task { [weak self] in
            guard let self else { return }
            let segs = await self.cutSegments()
            let exact = await Task.detached { SharpSim.exactHeight(at: SIMD2(p.x, p.y), segments: segs, start: start, bottom: bottom) }.value
            var partTop: Double?
            if let part = self.part {
                let t = self.setupFor(side: self.twoSided || self.viewSide >= 2 ? self.viewSide : 0).partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
                if let engine = try? await self.liveEngine(),
                   let h = try? await engine.heightField(partID: part.partID, transform: t, origin: SIMD2(p.x, p.y), cell: 0.01, cols: 1, rows: 1),
                   let v = h.first, v.isFinite { partTop = Double(v) }
            }
            guard index < self.measurePoints.count else { return }
            self.measurePoints[index].exactHeight = exact
            self.measurePoints[index].gridHeight = grid
            self.measurePoints[index].leftOnPart = partTop.map { exact - $0 }
        }
    }

    /// An exact section along the section plane (X or Y), across the stock.
    func computeExactSection() async {
        guard sectionOn, sectionAxis != .z, let coarse = heightmap else { return }
        // The plane's position in work coordinates: through the part's centre (the stock's
        // without a part) plus the offset, as the section view places it.
        var centre = SIMD3<Double>(0, 0, 0)
        if let part {
            let t = setupFor(side: twoSided || viewSide >= 2 ? viewSide : 0).partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
            let c = (part.boundsMin + part.boundsMax) / 2
            let w = t * SIMD4(c.x, c.y, c.z, 1)
            centre = SIMD3(w.x, w.y, w.z)
        }
        let k = sectionAxis == .x ? 0 : 1
        let at = centre[k] + sectionOffset
        let lo0 = SIMD2(coarse.origin.x - coarse.cell / 2, coarse.origin.y - coarse.cell / 2)
        let hi0 = lo0 + SIMD2(Double(coarse.cols), Double(coarse.rows)) * coarse.cell
        let a = k == 0 ? SIMD2(at, lo0.y) : SIMD2(lo0.x, at), b = k == 0 ? SIMD2(at, hi0.y) : SIMD2(hi0.x, at)
        let len = simd_length(b - a)
        let n = min(max(Int(len / 0.005), 200), 4000)
        let segs = await cutSegments()
        let start = simStart ?? coarse, bottom = coarse.bottom
        status = "Working out the exact section…"
        let exact = await Task.detached { SharpSim.exactProfile(from: a, to: b, count: n, segments: segs, start: { start.sample($0) }, bottom: bottom) }.value
        let positions = (0..<n).map { (k == 0 ? a.y : a.x) + len * Double($0) / Double(n - 1) }
        let grid = (0..<n).map { i in coarse.sample(a + (b - a) * (Double(i) / Double(n - 1))) }
        var partLine: [Double]?
        if let part, let engine = try? await liveEngine() {
            let t = setupFor(side: twoSided || viewSide >= 2 ? viewSide : 0).partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
            let step = len / Double(n - 1)
            if let h = try? await engine.heightField(partID: part.partID, transform: t, origin: a, cell: step, cols: k == 0 ? 1 : n, rows: k == 0 ? n : 1) {
                partLine = h.map { Double($0) }
            }
        }
        status = "Exact section: \(n) points, \(Length.mm(len / Double(n - 1) * 1000)) µm apart."
        exactSection = ExactSection(title: "Exact section at \(k == 0 ? "X" : "Y") \(Length.mm(at)) mm", axis: k == 0 ? "Y" : "X",
                                    positions: positions, exact: exact, grid: grid, part: partLine, gridCell: coarse.cell)
    }
}

/// Progress handed from the worker threads to the main actor.
final class ProgressBox: @unchecked Sendable {
    private var v = 0.0
    private let lock = NSLock()
    var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
