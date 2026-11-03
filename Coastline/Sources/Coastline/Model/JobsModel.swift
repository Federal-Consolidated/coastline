import AppKit
import MillCore
import CoastlineCore
import Foundation
import Metal
import Observation
import UniformTypeIdentifiers
import Viewport
import simd

/// G-code projects (program jobs): guided jobs around G-code that already exists, listed on the
/// Projects page with the planned projects. Those you import (a job folder, a shared zip, an
/// older `.dd`) or make from your own G-code are kept in Application Support/Coastline/Jobs; a
/// build can also ship presets in resources/jobs (none by default).
@MainActor @Observable
final class JobsModel {
    struct Entry: Identifiable, Equatable {
        let folder: URL
        let job: ProgramJob
        let preset: Bool
        var id: URL { folder }
    }

    private(set) var entries: [Entry] = []
    var selection: URL?
    /// The option choices made per job (job id → option id → choice id).
    var choices: [String: [String: String]] = [:]
    /// The program shown in the 3D preview.
    var previewProgram: String?
    var showNewJob = false
    /// G-code files chosen in Import, for the New Project from G-code sheet.
    var pendingGCode: [URL] = []
    var lastError: String?
    /// Read programs, by `folder|program id`.
    private(set) var programs: [String: GCodeReader.Program] = [:]

    @ObservationIgnored let renderer: ViewportRenderer
    @ObservationIgnored private var shownKey: String?
    /// The geometry engine (AppModel's), for reading the jobs' STEP models.
    @ObservationIgnored var engine: (() throws -> EngineClient)?
    /// The models as read (model space), by `folder|model id`.
    @ObservationIgnored private var meshes: [String: MeshData] = [:]
    /// The `folder|setup id` the models in the scene are placed for.
    @ObservationIgnored private var placedFor: String?

    static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Coastline/Jobs")
    }
    static var presetFolder: URL { AppModel.repoRoot.appendingPathComponent("resources/jobs") }

    init() {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = try? ViewportRenderer(device: device) else {
            fatalError("The 3D viewport couldn't start.")
        }
        renderer.worldToDisplay = ViewportRenderer.machineToDisplay
        // From the spindle side: the face the programs cut.
        renderer.camera.set(.toolIso)
        renderer.animationsEnabled = ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil
        if let axes = SceneLines(device: device, id: "axes", segments: LineSegment.axes(length: 10)) {
            renderer.scene.setLines(axes)
        }
        self.renderer = renderer
        reload()
    }

    var selected: Entry? { entries.first { $0.folder == selection } }

    func reload() {
        var list: [Entry] = []
        for (base, preset) in [(Self.presetFolder, true), (Self.userFolder, false)] {
            let folders = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let job = try? ProgramJob.load(folder) { list.append(Entry(folder: folder, job: job, preset: preset)) }
            }
        }
        entries = list
        if selected == nil { selection = list.first?.folder }
    }

    func chosen(_ job: ProgramJob) -> [String: String] { job.choices(choices[job.id] ?? [:]) }

    func choose(_ job: ProgramJob, _ option: String, _ value: String) {
        choices[job.id, default: [:]][option] = value
    }

    // MARK: Programs

    func key(_ entry: Entry, _ id: String) -> String { entry.folder.path + "|" + id }

    func cached(_ entry: Entry, _ id: String) -> GCodeReader.Program? { programs[key(entry, id)] }

    /// Reads a program off the main thread (long programs run to tens of thousands of lines).
    func load(_ entry: Entry, _ id: String) async {
        let key = key(entry, id)
        guard programs[key] == nil, let file = entry.job.program(id)?.file else { return }
        let url = entry.folder.appendingPathComponent(file)
        let program = await Task.detached { GCodeReader.read((try? String(contentsOf: url, encoding: .utf8)) ?? "") }.value
        programs[key] = program
        if previewProgram == id { show(entry, id) }
    }

    /// Puts a program's toolpath in the preview, framed.
    func show(_ entry: Entry, _ id: String) {
        previewProgram = id
        placeModels(entry, for: id)
        setMachineTool(entry, id)
        if entry.job.setups.contains(where: { $0.machine != nil }) { Task { await loadMachine() } }
        showCuts(entry, id)
        let key = key(entry, id)
        guard let program = programs[key] else { return }
        guard shownKey != key else { return }
        shownKey = key
        let segments = Self.segments(program)
        renderer.scene.remove(id: "toolpath")
        if let lines = SceneLines(device: renderer.device, id: "toolpath", segments: segments) {
            lines.xray = 0.45  // seen through the part: the cuts are inside the blank
            renderer.scene.setLines(lines)
        }
        // The toolpath with the part around it (the models are in the work frame too).
        var lo = program.cutMin.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        var hi = program.cutMax.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        if let (mlo, mhi) = modelBounds() {
            lo = lo.map { simd_min($0, mlo) } ?? mlo
            hi = hi.map { simd_max($0, mhi) } ?? mhi
        }
        if let lo, let hi { renderer.frame(worldMin: lo - 2, worldMax: hi + 2) } else { renderer.frameAll() }
    }

    /// The program's moves as coloured line segments (arcs as short lines), in order.
    static func segments(_ program: GCodeReader.Program) -> [LineSegment] {
        var segments: [LineSegment] = []
        segments.reserveCapacity(program.moves.count)
        var previous: SIMD3<Double>?
        for move in program.moves {
            defer { previous = move.position }
            guard let start = previous else { continue }
            let color = switch move.role {
            case .rapid: PathColor.rapid
            case .plunge: PathColor.plunge
            case .lead, .link: PathColor.lead
            default: PathColor.cut
            }
            var a = start
            for p in ToolpathGeometry.points(of: move, from: start) {
                segments.append(LineSegment(SIMD3<Float>(a), SIMD3<Float>(p), color: color))
                a = p
            }
        }
        return segments
    }

    // MARK: Cut check

    /// What the shown cut program removes, checked against the finished part (see `CutCheck`).
    struct CutSummary: Equatable {
        var program: String
        var removed: Double
        var gouge: Double
        var rapidHits: Double
    }

    private(set) var cutSummary: CutSummary?
    private(set) var cutChecking = false
    var showCuts = true { didSet { for m in renderer.scene.meshes where m.id.hasPrefix("cut.") { m.isVisible = showCuts } } }
    /// The part model as placed for the shown setup (work frame), for the check.
    @ObservationIgnored private var placedPart: (vertices: [Float], indices: [UInt32])?
    @ObservationIgnored private var cutKey: String?
    @ObservationIgnored private var cutTask: Task<Void, Never>?

    /// Runs the cut check for a cut program off the main thread and shows its result: what it
    /// removes (light), gouges into the finished part (red), rapids through it (yellow).
    func showCuts(_ entry: Entry, _ id: String) {
        guard let program = entry.job.program(id), program.purpose == .cut, let spec = entry.job.tool(program.tool) else {
            clearCuts()
            return
        }
        let key = key(entry, id) + "|" + (placedFor ?? "") + (placedPart == nil ? "" : "|part")
        guard cutKey != key else { return }
        clearCuts()
        cutKey = key
        let stickout = entry.job.setup(running: id, chosen(entry.job))?.machine?.stickout ?? 30
        let part = placedPart
        cutChecking = true
        cutTask = Task { [weak self] in
            guard let self else { return }
            await self.load(entry, id)
            guard let read = self.cached(entry, id), !Task.isCancelled else { self.cutChecking = false; return }
            let tool = ToolShape(spec, stickout: stickout)
            typealias Mesh = (positions: [Float], normals: [Float], indices: [UInt32])
            let result = await Task.detached { () -> (Mesh, Mesh?, Mesh?, Double, Double, Double)? in
                guard let r = CutCheck.run(read, tool: tool, part: part) else { return nil }
                let g = r.gougeVolume > 0.01 ? r.gouge?.mesh() : nil
                let h = r.rapidHitVolume > 0.01 ? r.rapidHits?.mesh() : nil
                return (r.removed.mesh(), g, h, r.removed.volume, r.gougeVolume, r.rapidHitVolume)
            }.value
            guard !Task.isCancelled, self.cutKey == key else { return }
            self.cutChecking = false
            guard let result else { return }
            let colors: [(String, Mesh?, SIMD4<Float>)] = [
                ("cut.removed", result.0, SIMD4(0.9, 0.9, 0.9, 0.55)),
                ("cut.gouge", result.1, SIMD4(1, 0.16, 0.14, 1)),
                ("cut.rapid", result.2, SIMD4(1, 0.84, 0.04, 1)),
            ]
            for (meshID, mesh, color) in colors {
                guard let mesh, !mesh.indices.isEmpty,
                      let scene = SceneMesh(device: self.renderer.device, id: meshID, positions: mesh.positions,
                                            normals: mesh.normals, indices: mesh.indices, color: color) else { continue }
                scene.isVisible = self.showCuts
                self.renderer.scene.setMesh(scene)
            }
            self.cutSummary = CutSummary(program: id, removed: result.3, gouge: result.4, rapidHits: result.5)
        }
    }

    private func clearCuts() {
        cutTask?.cancel()
        cutTask = nil
        cutKey = nil
        cutSummary = nil
        cutChecking = false
        for id in ["cut.removed", "cut.gouge", "cut.rapid"] { renderer.scene.remove(id: id) }
    }

    // MARK: Machine

    /// The machine around the part, for setups that say where it sits (`machine` in job.json).
    var showMachine = true { didSet { placeMachine() } }
    /// Loads the machine model (AppModel's, shared with the workspace).
    @ObservationIgnored var machineSource: (() async -> MachineModel?)?
    @ObservationIgnored private var machine: MachineModel?
    @ObservationIgnored private var machineLoading = false
    /// The shown setup's machine pose (nil: no machine shown).
    @ObservationIgnored private var machinePose: ProgramJob.MachinePose?
    /// The tool drawn in the collet (diameter, stick-out).
    @ObservationIgnored private var toolShown: (Double, Double)?

    var hasMachine: Bool { machine != nil }

    func loadMachine() async {
        guard machine == nil, !machineLoading, let source = machineSource else { return }
        machineLoading = true
        defer { machineLoading = false }
        guard let model = await source() else { return }
        machine = model
        // The shell is left out: it hides the work.
        for (i, p) in model.parts.enumerated() where !p.role.hasPrefix("enclosure") {
            guard let mesh = SceneMesh(device: renderer.device, id: "machine.\(p.group).\(p.role).\(i)", positions: p.mesh.vertices,
                                       normals: p.mesh.normals, indices: p.mesh.indices,
                                       color: SIMD4(AppModel.displayColor(role: p.role, p.color), 0.28)) else { continue }
            // See-through, so the part and the jig inside it stay in view.
            mesh.group = "m." + p.group
            renderer.scene.setMesh(mesh)
        }
        if let entry = selected, let id = previewProgram { toolShown = nil; setMachineTool(entry, id) }
        placeMachine()
    }

    /// Puts the machine where the shown setup has it, with the tool tip at `tip` (work frame;
    /// 10 mm above the work zero when nil). The table stays put (it carries the work); the frame,
    /// the carriage and the spindle move around it.
    private func placeMachine(tip: SIMD3<Double>? = nil) {
        guard let model = machine else { return }
        let n = model.spindleNose, m = model.modelPose
        let pose = machinePose
        // Machine model → work frame: the work zero is where the tool tip is at `workZero`.
        var c = SIMD3<Double>(repeating: 0)
        if let pose {
            let w = pose.workZero
            c = SIMD3(n.x + w[0] - m.x, n.y + w[1] - m.y, n.z + w[2] - m.z - pose.stickout)
        }
        let shift = simd_float4x4(translation: SIMD3(Float(-c.x), Float(-c.y), Float(-c.z)))
        for mesh in renderer.scene.meshes where mesh.id.hasPrefix("machine.") || mesh.id == "jobtool" {
            mesh.transform = shift
            mesh.isVisible = showMachine && pose != nil
        }
        guard let pose else { return }
        let t = tip ?? SIMD3(0, 0, 10)
        let q = SIMD3(t.x + pose.workZero[0], t.y + pose.workZero[1], t.z + pose.workZero[2])
        let dx = Float(q.x - m.x), dy = Float(q.y - m.y), dz = Float(q.z - m.z)
        let scene = renderer.scene
        scene.groupTransforms["m.x"] = matrix_identity_float4x4
        scene.groupTransforms["m.static"] = simd_float4x4(translation: SIMD3(dx, 0, 0))
        scene.groupTransforms["m.y"] = simd_float4x4(translation: SIMD3(dx, dy, 0))
        scene.groupTransforms["m.z"] = simd_float4x4(translation: SIMD3(dx, dy, dz))
    }

    /// The program's tool in the collet: a cylinder of its diameter and the setup's stick-out.
    private func setMachineTool(_ entry: Entry, _ id: String) {
        guard let model = machine else { return }
        let setup = entry.job.setup(running: id, chosen(entry.job))
        guard let pose = setup?.machine, let tool = entry.job.tool(entry.job.program(id)?.tool) else {
            renderer.scene.remove(id: "jobtool")
            toolShown = nil
            return
        }
        guard toolShown.map({ $0 != (tool.diameter, pose.stickout) }) ?? true else { return }
        toolShown = (tool.diameter, pose.stickout)
        let n = model.spindleNose
        let c = Self.cylinder(top: SIMD3(Float(n.x), Float(n.y), Float(n.z)), length: Float(pose.stickout), radius: Float(tool.diameter / 2))
        if let mesh = SceneMesh(device: renderer.device, id: "jobtool", positions: c.positions, normals: c.normals,
                                indices: c.indices, color: SIMD4(0.85, 0.85, 0.85, 1)) {
            mesh.group = "m.z"
            renderer.scene.setMesh(mesh)
        }
        placeMachine()
    }

    /// A closed cylinder hanging down (−Z) from `top`.
    static func cylinder(top: SIMD3<Float>, length: Float, radius: Float, sides: Int = 24) -> (positions: [Float], normals: [Float], indices: [UInt32]) {
        var p: [Float] = [], nrm: [Float] = [], idx: [UInt32] = []
        func vertex(_ v: SIMD3<Float>, _ n: SIMD3<Float>) -> UInt32 {
            p += [v.x, v.y, v.z]; nrm += [n.x, n.y, n.z]
            return UInt32(p.count / 3 - 1)
        }
        let bottom = top - SIMD3(0, 0, length)
        for k in 0..<sides {
            let a0 = Float(k) / Float(sides) * 2 * .pi, a1 = Float(k + 1) / Float(sides) * 2 * .pi
            let d0 = SIMD3(cos(a0), sin(a0), 0), d1 = SIMD3(cos(a1), sin(a1), 0)
            let i0 = vertex(top + d0 * radius, d0), i1 = vertex(top + d1 * radius, d1)
            let i2 = vertex(bottom + d1 * radius, d1), i3 = vertex(bottom + d0 * radius, d0)
            idx += [i0, i3, i2, i0, i2, i1]
            let c = vertex(bottom, SIMD3(0, 0, -1)), e0 = vertex(bottom + d0 * radius, SIMD3(0, 0, -1)), e1 = vertex(bottom + d1 * radius, SIMD3(0, 0, -1))
            idx += [c, e1, e0]
        }
        return (p, nrm, idx)
    }

    /// The box of the job's models (not the machine), for framing.
    private func modelBounds() -> (SIMD3<Float>, SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for m in renderer.scene.meshes where m.isVisible && m.id.hasPrefix("model.") {
            for corner in 0..<8 {
                let c = SIMD3<Float>(corner & 1 == 0 ? m.boundsMin.x : m.boundsMax.x, corner & 2 == 0 ? m.boundsMin.y : m.boundsMax.y,
                                     corner & 4 == 0 ? m.boundsMin.z : m.boundsMax.z)
                let w = m.transform * SIMD4(c, 1)
                lo = simd_min(lo, SIMD3(w.x, w.y, w.z))
                hi = simd_max(hi, SIMD3(w.x, w.y, w.z))
            }
        }
        return lo.x <= hi.x ? (lo, hi) : nil
    }

    /// Reads the job's 3D models (the part, the jig) once; `show` places them per setup.
    func loadModels(_ entry: Entry) async {
        for model in entry.job.models where meshes[entry.folder.path + "|" + model.id] == nil {
            let url = entry.folder.appendingPathComponent(model.file)
            do {
                if url.pathExtension.lowercased() == "stl" {
                    // Meshes only (no exact geometry): read here, the engine reads CAD.
                    meshes[entry.folder.path + "|" + model.id] = try await Task.detached { try STLReader.read(url) }.value
                } else if let engine = try? engine?() {
                    meshes[entry.folder.path + "|" + model.id] = try await engine.importPart(url)
                }
            } catch {
                lastError = "Couldn't read \(model.title): \(error)"
            }
        }
        if let id = previewProgram {
            placeModels(entry, for: id)
            showCuts(entry, id)  // again, now with the part to check against
        }
    }

    /// The 3D view for a step: its program's toolpath, with the models where the setup places them.
    func showStep(_ entry: Entry, _ step: ProgramJob.Step) {
        guard let id = step.program else { return }
        show(entry, id)
        Task { await load(entry, id) }
    }

    /// Shows the models where they sit in the setup that runs this program; models the setup
    /// has no placement for are hidden (a guessed position would mislead).
    private func placeModels(_ entry: Entry, for programID: String) {
        let setup = entry.job.setup(running: programID, chosen(entry.job))
        let key = entry.folder.path + "|" + (setup?.id ?? "-")
        guard placedFor != key else { return }
        for mesh in renderer.scene.meshes where mesh.id.hasPrefix("model.") { renderer.scene.remove(id: mesh.id) }
        placedFor = key
        placedPart = nil
        machinePose = setup?.machine
        placeMachine()
        guard let setup else { return }
        for model in entry.job.models {
            guard let placement = setup.placements[model.id], let data = meshes[entry.folder.path + "|" + model.id] else { continue }
            var positions = data.vertices, normals = data.normals
            for k in stride(from: 0, to: positions.count - 2, by: 3) {
                let p = placement.apply((Double(positions[k]), Double(positions[k + 1]), Double(positions[k + 2])))
                let n = placement.apply((Double(normals[k]), Double(normals[k + 1]), Double(normals[k + 2])), normal: true)
                (positions[k], positions[k + 1], positions[k + 2]) = (Float(p.0), Float(p.1), Float(p.2))
                (normals[k], normals[k + 1], normals[k + 2]) = (Float(n.0), Float(n.1), Float(n.2))
            }
            // A mirrored axis mapping turns the triangles inside out: flip their winding.
            var indices = data.indices
            if Self.mirrors(placement) {
                for t in stride(from: 0, to: indices.count - 2, by: 3) { indices.swapAt(t + 1, t + 2) }
            }
            if model.role == .part { placedPart = (positions, indices) }
            // The part a little see-through, so the toolpaths inside it show.
            let color: SIMD4<Float> = model.role == .fixture ? SceneColor.dark : SceneColor.surface(0.56, alpha: 0.6)
            if let mesh = SceneMesh(device: renderer.device, id: "model.\(model.id)", positions: positions,
                                    normals: normals, indices: indices, color: color) {
                renderer.scene.setMesh(mesh)
            }
        }
    }

    /// True when the axis mapping is a reflection (an odd number of sign flips and swaps).
    static func mirrors(_ p: ProgramJob.Placement) -> Bool {
        let r = p.rows
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        for (i, row) in r.enumerated() { m[i][row.axis] = row.sign }
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        return det < 0
    }

    /// Minutes for a program: feed moves at their feed, rapids at the axis limits.
    func minutes(_ program: GCodeReader.Program) -> Double {
        let path = OperationToolpath(operationID: UUID(), moves: program.moves)
        return (TimeEstimate.seconds([path]) + program.dwell) / 60
    }

    // MARK: Running a job

    /// A job running on the machine, one step at a time.
    struct Run: Equatable {
        struct Item: Equatable, Identifiable {
            let setup: ProgramJob.Setup
            let step: ProgramJob.Step
            var id: String { setup.id + "/" + step.id }
        }
        let folder: URL
        let choices: [String: String]
        let items: [Item]
        /// On the Simulated Mill only: no machine moves, the preview draws each program as it runs.
        var simulated = false
        /// -1: the requirements, before the first step.
        var index = -1
        var done: Set<String> = []
        /// The name of the program this run started last (matches the mill's program status).
        var started: String?
        var startedAirCut = false
        var current: Item? { items.indices.contains(index) ? items[index] : nil }
    }

    var run: Run?

    func startRun(_ entry: Entry, simulated: Bool = false) {
        let chosen = chosen(entry.job)
        let items = entry.job.plan(chosen).flatMap { item in item.steps.map { Run.Item(setup: item.setup, step: $0) } }
        run = Run(folder: entry.folder, choices: chosen, items: items, simulated: simulated)
    }

    func endRun() {
        stopAnimation()
        run = nil
    }

    func next() {
        stopAnimation()
        guard var r = run else { return }
        if let item = r.current, item.step.kind != .run { r.done.insert(item.id) }
        r.index = min(r.index + 1, r.items.count)
        r.started = nil
        run = r
        showCurrent()
    }

    func back() {
        stopAnimation()
        guard var r = run, r.index > -1 else { return }
        r.index -= 1
        r.started = nil
        run = r
        showCurrent()
    }

    /// The current step's program in the 3D view.
    func showCurrent() {
        guard let r = run, let entry = entries.first(where: { $0.folder == r.folder }), let step = r.current?.step else { return }
        showStep(entry, step)
    }

    /// Runs the current step's program on the machine (as an air cut: spindle off, 10 mm up).
    func runCurrent(on mill: MillControl, airCut: Bool) async {
        guard var r = run, let item = r.current, let entry = entries.first(where: { $0.folder == r.folder }),
              let program = entry.job.program(item.step.program) else { return }
        // A simulation runs on the Simulated Mill only, never on a connected machine.
        if r.simulated, !mill.isSimulated {
            mill.message = mill.isOpen ? "A machine is connected. Disconnect it to simulate." : "Start the Simulated Mill first."
            return
        }
        let url = entry.folder.appendingPathComponent(program.file)
        let lines = await Task.detached { () -> [String] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return (airCut ? AirCut.make(from: text) : text).components(separatedBy: "\n")
        }.value
        let name = "\(r.index + 1). \(item.step.title)\(airCut ? " · air cut" : "")"
        if mill.runJob(name, lines: lines) {
            r.started = name
            r.startedAirCut = airCut
            run = r
            if r.simulated { animate(entry, program.id) }
        }
    }

    // MARK: Simulation playback

    /// 0…1 while the preview draws the simulated program, else nil.
    private(set) var animation: Double?
    @ObservationIgnored private var animationTask: Task<Void, Never>?

    /// Draws the program's toolpath move by move with the tool at its tip: the Simulated Mill
    /// runs a program at once, this shows what it does. Faster than real time (2–20 s).
    func animate(_ entry: Entry, _ id: String) {
        stopAnimation()
        animationTask = Task { [weak self] in
            guard let self else { return }
            await self.load(entry, id)
            guard !Task.isCancelled, let program = self.cached(entry, id), program.moves.count > 1 else { return }
            self.show(entry, id)
            let segments = Self.segments(program)
            let seconds = min(max(self.minutes(program) * 60 / 30, 2), 20)
            let frames = Int(seconds * 20)
            self.animation = 0
            for frame in 1...frames {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                let f = Double(frame) / Double(frames)
                self.drawPartial(segments, count: max(1, Int(Double(segments.count) * f)))
                self.animation = f
            }
            self.animationTask = nil
            self.finishAnimation()
        }
    }

    func stopAnimation() {
        guard animationTask != nil || animation != nil else { return }
        animationTask?.cancel()
        animationTask = nil
        finishAnimation()
    }

    /// The whole toolpath again, the tool marker gone.
    private func finishAnimation() {
        animation = nil
        renderer.scene.remove(id: "simtool")
        placeMachine()
        if let entry = run.flatMap({ r in entries.first { $0.folder == r.folder } }), let id = previewProgram {
            shownKey = nil
            show(entry, id)
        }
    }

    private func drawPartial(_ segments: [LineSegment], count: Int) {
        let part = Array(segments.prefix(count))
        renderer.scene.remove(id: "toolpath")
        if let lines = SceneLines(device: renderer.device, id: "toolpath", segments: part) {
            lines.xray = 0.45
            renderer.scene.setLines(lines)
        }
        // The tool: a short line up the spindle axis from the tip, and a small cross at the tip.
        guard let end = part.last?.b else { return }
        let tip = SIMD3<Float>(end.0, end.1, end.2)
        placeMachine(tip: SIMD3(Double(end.0), Double(end.1), Double(end.2)))
        let c = PathColor.cut, r: Float = 1.5
        let tool = [LineSegment(tip, tip + SIMD3(0, 0, 12), color: c),
                    LineSegment(tip - SIMD3(r, 0, 0), tip + SIMD3(r, 0, 0), color: c),
                    LineSegment(tip - SIMD3(0, r, 0), tip + SIMD3(0, r, 0), color: c)]
        renderer.scene.remove(id: "simtool")
        if let lines = SceneLines(device: renderer.device, id: "simtool", segments: tool) { renderer.scene.setLines(lines) }
    }

    /// The mill's status of the program this run started last.
    func status(_ mill: MillControl) -> MillProgramStatus? {
        guard let name = run?.started, let program = mill.snapshot.program, program.name == name else { return nil }
        return program
    }

    /// Called when the current program finished: a real run (not an air cut) completes the step.
    func programFinished(_ outcome: MillProgramStatus.Outcome) {
        guard var r = run, let item = r.current, outcome == .completed, !r.startedAirCut else { return }
        r.done.insert(item.id)
        run = r
    }

    /// An air cut is offered for cuts without incremental moves (it raises every work Z).
    func offersAirCut(_ entry: Entry, _ programID: String) -> Bool {
        guard entry.job.program(programID)?.purpose == .cut, let read = cached(entry, programID) else { return false }
        return read.relativeMoves == 0
    }

    // MARK: New jobs

    /// Imports an old .dd job: each of its jobs becomes a choice, its photos are left out.
    func importDD(_ url: URL) {
        let folder = Self.userFolder.appendingPathComponent(PackageImport.slug(url.deletingPathExtension().lastPathComponent))
        do {
            try? FileManager.default.removeItem(at: folder)
            _ = try PackageImport.run(url, into: folder)
            reload()
            selection = folder
        } catch {
            lastError = "Couldn't import \(url.lastPathComponent): \(error)"
        }
    }

    /// A guided job around your own G-code files.
    func newJob(files: [URL], title: String, tool: ProgramJob.ToolSpec, workOffset: Int) {
        let folder = Self.userFolder.appendingPathComponent(PackageImport.slug(title).isEmpty ? UUID().uuidString : PackageImport.slug(title))
        do {
            let texts = try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
            try? FileManager.default.removeItem(at: folder)
            _ = try ProgramJob.fromGCode(texts, title: title, tool: tool, workOffset: workOffset, into: folder)
            reload()
            selection = folder
        } catch {
            lastError = "Couldn't make the job: \(error)"
        }
    }

    func delete(_ entry: Entry) {
        guard !entry.preset else { return }
        try? FileManager.default.removeItem(at: entry.folder)
        if selection == entry.folder { selection = nil }
        reload()
    }

    /// Adds a job folder (with its job.json) to your jobs: a copy, so the original can move.
    func addJobFolder(_ url: URL) {
        do {
            let job = try ProgramJob.load(url)
            let problems = job.problems(in: url)
            guard problems.isEmpty else {
                lastError = "\(url.lastPathComponent) can't be added: \(problems.joined(separator: " "))"
                return
            }
            let folder = Self.userFolder.appendingPathComponent(PackageImport.slug(job.id).isEmpty ? UUID().uuidString : PackageImport.slug(job.id))
            try FileManager.default.createDirectory(at: Self.userFolder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.copyItem(at: url, to: folder)
            reload()
            selection = folder
        } catch {
            lastError = "Couldn't add \(url.lastPathComponent): \(error)"
        }
    }

    func chooseJobFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add a Job"
        panel.message = "Choose a job folder (it holds job.json, programs and models)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { addJobFolder(url) }
    }

    func chooseDDFile() {
        let panel = NSOpenPanel()
        panel.title = "Import a .dd Job"
        panel.allowedContentTypes = [.init(filenameExtension: "dd"), .init(filenameExtension: "crproj"), .zip].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url { importDD(url) }
    }
}

extension Automation {
    /// `jobpreview <program id>`: reads the selected job's program and shows it in the preview.
    static func jobPreviewCommand(_ model: AppModel, _ id: String) async {
        guard let entry = model.jobs.selected else { return }
        model.showInspector = true
        await model.jobs.load(entry, id)
        model.jobs.show(entry, id)
        let read = model.jobs.cached(entry, id)
        print("jobpreview \(id): moves \(read?.moves.count ?? -1) issues \(read?.issues.count ?? -1)")
    }
}

extension Automation {
    /// Scripted runs of the selected job on the Simulated Mill: `jobstart`, `jobsim` (a simulated
    /// run, the Simulated Mill started), `jobnext`, `jobback`, `jobrun`, `jobair`, `jobstatus`.
    static func jobCommand(_ model: AppModel, _ command: String) async {
        let jobs = model.jobs
        switch command {
        case "jobstart": if let entry = jobs.selected { jobs.startRun(entry) }
        case "jobsim":
            if let entry = jobs.selected { jobs.startRun(entry, simulated: true) }
            model.mill.connectSimulator()
        case "jobnext": jobs.next()
        case "jobback": jobs.back()
        case "jobrun": await jobs.runCurrent(on: model.mill, airCut: false)
        case "jobair": await jobs.runCurrent(on: model.mill, airCut: true)
        default: break
        }
        let status = jobs.status(model.mill)
        print("\(command): step \((jobs.run?.index ?? -2) + 1) \(jobs.run?.current?.step.title ?? "-") program \(status.map { "\($0.name) \($0.outcome) \($0.done)/\($0.total)" } ?? "-") message \(model.mill.message ?? "-")")
    }
}
