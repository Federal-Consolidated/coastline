import AppKit
import CoastlineCore
import Foundation
import Metal
import Observation
import simd
import Viewport

/// What the inspector shows about the imported part.
struct PartInfo: Equatable {
    var url: URL
    var fileName: String
    var kind: String
    var exact: Bool
    var faceCount: Int
    var triangleCount: Int
    var size: Vec3
    var boundsMin: SIMD3<Double>
    var boundsMax: SIMD3<Double>
    var partID: String
    var warnings: [String]
}

/// How much of the machine to draw.
enum MachineDisplay: String, CaseIterable, Identifiable {
    case full, open, ghost, moving, hidden
    var id: Self { self }
    var title: String {
        switch self {
        case .ghost: "Ghosted (see-through)"
        case .full: "Whole machine"
        case .open: "Without enclosure"
        case .moving: "Moving parts only"
        case .hidden: "Hidden"
        }
    }
}

/// One measuring click.
struct MeasurePoint: Equatable {
    var world: SIMD3<Float>
    var info: FaceInfo?
}

/// App state: navigation plus the workspace (machine, part, stock, setup, measuring).
///
/// Scene frame: the machine assembly's own coordinates, which are the machine axes (X up,
/// Y right, Z toward the spindle). The work frame of `Setup` is placed into it with
/// `workToModel` (a pure translation: the axes are the same).
@MainActor
@Observable
final class AppModel {
    var planningMachineReference = PlanningMachineReference.legacy
    var machine: MachineProfile { planningMachineReference.profile }
    /// Physical control remains on its commissioned legacy machine until instance calibration exists.
    let controlMachine = MachineProfile.standard
    let machineProfiles = MachineProfileLibrary()
    var isSwitchingPlanningMachine = false
    var planningMachineProblem: String?
    @ObservationIgnored var planningGeometry: MachinePlanningGeometry?
    @ObservationIgnored var planningMachineInitialized = false
    @ObservationIgnored var machineSceneComponents: [String: String] = [:]
    @ObservationIgnored var machineSceneRoles: [String: String] = [:]
    @ObservationIgnored var legacyControlModel: MachineModel?
    @ObservationIgnored var profileCollisionTrees: [String: TriangleTree]?
    let renderer: ViewportRenderer

    // Navigation
    var page: SidebarItem = .workspace
    var showInspector = true
    /// Section the inspector should scroll to ("tuner").
    var inspectorScrollTarget: String?
    enum InspectorTab { case setup, machining }
    var inspectorTab = InspectorTab.setup {
        didSet {
            // Old callers still switch tabs: keep the stage in step.
            if inspectorTab == .machining, ![.machining, .review].contains(stage) { stage = .machining }
            if inspectorTab == .setup, [.machining, .review].contains(stage) { stage = .partStock }
        }
    }
    /// The workflow stage on screen (StageBar).
    /// A Machinability finding picked on one step isn't on screen on the next: its highlight goes.
    var stage = JobStage.partStock { didSet { if stage != oldValue { selectFinding(nil) } } }
    var isPlanningJob = false
    @ObservationIgnored var restoredDevelopmentSession = false

    // Workspace
    var part: PartInfo?
    var setup = Setup() {
        didSet {
            guard setup != oldValue else { return }
            clearToolpathResults(); layoutScene(); saveSession(); scheduleAnalysis(); keepStockWorkable(); noteProjectChange()
        }
    }
    /// Collision engine results for what's on the bed now (CollisionCheck.swift).
    var collisions: [Collision.Contact] = []
    @ObservationIgnored var collisionPrefixes: [String: String] = [:]
    @ObservationIgnored var collisionGeneration = 0
    @ObservationIgnored var machineTree: TriangleTree?
    @ObservationIgnored var machineTreeKey: String?
    /// The spindle head (z group) and the translator (y group) at the modelled pose, for the
    /// tool-change path check (ToolChange.swift).
    @ObservationIgnored var headTrees: (z: TriangleTree, y: TriangleTree)?
    /// What's on the table (fixtures, parallels, stock) as last laid out, and its tree.
    @ObservationIgnored var bedBodies: [BedBody] = []
    @ObservationIgnored var bedTree: (generation: Int, tree: TriangleTree)?
    @ObservationIgnored var machineTreeTask: Task<TriangleTree?, Never>?
    @ObservationIgnored var machineTreeTaskID = UUID()
    /// Generated operations by everything that shapes them (Machining.swift).
    @ObservationIgnored var opCache: [String: ([OperationToolpath], [PlacedTab])] = [:]
    @ObservationIgnored var opCacheOrder: [String] = []
    @ObservationIgnored var cachedOps = 0
    @ObservationIgnored var clampFieldCache: (key: String, field: FixtureField?)?
    @ObservationIgnored var clearanceRecheck: Task<Void, Never>?
    @ObservationIgnored var partMeshData: (positions: [Float], normals: [Float], indices: [UInt32])?
    /// The stock as each setup step starts ("step:<id>", or "side:<n>" for a side's first cut),
    /// from the last generation's stock model; and their meshes once drawn.
    @ObservationIgnored var inProcessSnapshots: [String: StockModel] = [:]
    @ObservationIgnored var inProcessMeshes: [String: (positions: [Float], normals: [Float], indices: [UInt32])] = [:]
    /// The job journal.
    let journal = JournalModel()
    /// The live connection to the machine (Control page).
    let mill = MillControl()
    /// Guided jobs around existing G-code (the G-code projects on the Projects page).
    let jobs = JobsModel()
    /// A typed move waiting for its value (GumballTyping.swift).
    var gumballPrompt: GumballPrompt?
    var stockID: StockItem.ID? { didSet { if stockID != oldValue {
        if stockSnapshot?.id != stockID { stockSnapshot = stockID.flatMap(stockLookup) }
        clearToolpathResults(); layoutScene(); saveSession(); keepStockWorkable(); noteProjectChange()
    } } }
    // The job as a document: its file, unsaved changes, and undo history (ProjectDocument.swift).
    var projectURL: URL?
    var projectDirty = false
    var undoHistory: [ProjectFile] = []
    var redoHistory: [ProjectFile] = []
    @ObservationIgnored var restoringProject = false
    /// Jog panel: open, and what's in the collet (nil: no bit).
    var jogOpen = false
    var jogTool: Tool?
    @ObservationIgnored var lastSnapshot: ProjectFile?
    @ObservationIgnored var lastChangeAt = Date.distantPast
    /// The whole machine at start; it turns see-through once there's work inside to look at.
    var machineDisplay = MachineDisplay.full { didSet { applyMachineDisplay() } }
    /// The chip guards (clear covers on the table, the carriage and the front): shown see-through,
    /// or hidden to look inside.
    var showChipGuards = UserDefaults.standard.object(forKey: "showChipGuards") as? Bool ?? true {
        didSet {
            if ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil { UserDefaults.standard.set(showChipGuards, forKey: "showChipGuards") }
            applyMachineDisplay()
        }
    }
    /// Clear polycarbonate for the chip guards.
    static let chipGuardSurface = SurfaceMaterial(metallic: 0, roughness: 0.05, edges: 0.8)
    var machineLoaded = false
    /// Perspective is optional; orthographic (no distortion) is the default.
    var perspective = false {
        didSet { if renderer.destinationCamera.orthographic == perspective { renderer.moveCamera(animated: false) { $0.orthographic = !perspective } } }
    }
    /// Mirror of the renderer's camera for SwiftUI (the view cube).
    var camera = OrbitCamera()
    var showWorkArea = true { didSet { layoutScene() } }
    /// Live machine coordinates (X, Y, Z) of the modelled machine.
    var machinePosition = SIMD3<Double>(0, 0, 0)
    /// The tool in the collet (the playing program's, or the first planned one).
    var currentTool: Tool?
    var status = "Ready"
    var isBusy = false
    var errorMessage: String?
    var toolpathSegments = 0

    // Machining
    var operations: [Operation] = [] { didSet { if operations != oldValue { captureJobTools(); clearToolpathResults(); noteProjectChange(); layoutEngravingPreview() } } }
    var planNotes: [String] = []
    var libraryWorkholdingPlan: LibraryWorkholdingPlan?
    var selectedLibraryStep: UUID? { didSet { if selectedLibraryStep != oldValue { layoutScene() } } }
    @ObservationIgnored var libraryFixtureMeshes: [String: MeshData] = [:]
    /// The automatic workholding preview last asked for, so a failed load isn't retried on every layout.
    @ObservationIgnored var automaticPreviewRequested: String?
    @ObservationIgnored var libraryFixtureTriangles: [String: [SIMD3<Double>]] = [:]
    @ObservationIgnored var libraryFixtureFields: [String: FixtureField] = [:]
    @ObservationIgnored var libraryFixtureGeometries: [UUID: LibraryFixtureGeometry] = [:]
    @ObservationIgnored var libraryFixtureGeometrySignatures: [UUID: String] = [:]
    @ObservationIgnored var fixturePlacementGeometry: LibraryFixtureGeometry?
    var fixturePlacement: FixturePlacementSession? { didSet { layoutScene() } }
    @ObservationIgnored var renderedLibraryStep: UUID?
    /// Smart planner: every candidate, the three recommended, and the chosen one's
    /// per-operation estimate (compared with the simulation after generating).
    var planCandidates: [StrategyEngine.Candidate] = []
    var planOptions: [StrategyEngine.Candidate] = []
    var chosenPlan: String?
    /// The plan Coastline recommends (with tools to buy when your own can't do it safely).
    var recommendedPlan: String?
    @ObservationIgnored var planEstimate: [UUID: Double] = [:]
    @ObservationIgnored var calibration = AppModel.loadCalibration()
    /// Quality ↔ time tuner: the setting being explored, the one the current
    /// toolpaths were generated with, rates for the cost, and the batch size.
    var tuning = Tuning()
    var generatedTuning = Tuning()
    var batchQuantity = 1
    var features: PartFeatures?
    /// The part and work transform `features` were found for: reused only when both match.
    @ObservationIgnored var featuresKey: (partID: String, transform: simd_double4x4)?
    var toolpaths: [UUID: OperationToolpath] = [:]
    var programs: [ToolProgram] = []
    var isGenerating = false {
        // Done: the timeline is final, so its simulation checkpoints can be made now.
        didSet { if oldValue && !isGenerating, let start = simStart { precomputeCheckpoints(from: start) } }
    }
    /// 0…1 while generating; Cancel stops between operations.
    var generationProgress: Double?
    @ObservationIgnored var cancelGeneration = false
    /// Background generation: each operation's state per side (queued, running, ready, failed).
    var opGenState: [UUID: [Int: GenState]] = [:]
    /// Extra engine processes that generate in parallel with the main one, each with the part.
    @ObservationIgnored var workerEngines: [(engine: EngineClient, partURL: URL, partID: String)] = []
    /// Set when the job needs more travel than the machine has with this stock placement.
    var travelIssue: String?
    /// Two-sided job: side B is machined after turning the stock front-to-back.
    var twoSided = false { didSet { if twoSided != oldValue { clearToolpathResults(); keepStockWorkable(); layoutScene(); noteProjectChange() } } }
    /// Set once the user picks one or two sides themselves; until then the analysis decides (two
    /// sides when the back has shape, one when it is flat).
    var twoSidedChosen = false
    /// The job step last chosen (strip, step card or tour) and the playhead it set.
    var selectedStep: (id: String, time: Double)?
    /// The instruction card over the 3D view (toggle in the view options).
    var showStepCard = true
    /// What the Projects page selects when it opens: "project:<path>" or
    /// "job:<folder path>" (imports, automation and links).
    var projectsPick: String?
    /// The operation just added from the menu: its row opens, ready to set up.
    @ObservationIgnored var justAddedOperation: UUID?
    /// The tint on the stock face the next cut works on (view options; off unless you want it).
    var showCutFace = UserDefaults.standard.bool(forKey: "showCutFace") {
        didSet {
            guard showCutFace != oldValue else { return }
            if ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil { UserDefaults.standard.set(showCutFace, forKey: "showCutFace") }
            cutFaceKey = ""
            layoutCutFace()
        }
    }
    /// The red overlay on faces turned away from the spindle (what side A can't reach). Off
    /// until asked for (view options, or the Analysis section's undercut warning).
    var showUndercutOverlay = false { didSet { if showUndercutOverlay != oldValue { showUndercuts() } } }
    /// Whether that overlay is on screen now (for its legend).
    var undercutOverlayShown = false
    /// The part's work transform the analysis was made with: the overlay follows the part when
    /// it only moved, and waits for the next analysis when it turned or scaled.
    @ObservationIgnored var analysisTransform: simd_double4x4?
    /// While generating: the programs as planned (side, tool, operations), numbered as the
    /// finished ones will be, and how many operations each side has. The chapters and their
    /// steps show from these before the toolpaths exist.
    var plannedPrograms: [(index: Int, side: Int, tool: Tool, operations: [Operation])] = []
    var plannedOperationCount: [Int: Int] = [:]
    /// The planner is comparing plans (the button shows it).
    var isFindingPlans = false
    /// Pieces the simulation shows cut loose (nothing joins them to where the clamps hold).
    var loosePieces = 0
    /// Two-sided registration: where side A bores its reference holes (nil: none this job).
    var referencePlan: ReferenceBores.Plan?
    @ObservationIgnored var simSurfacesAt = Date.distantPast
    @ObservationIgnored var simSurfacesPending = false
    /// Which side A result `sideAFinal` was made from (its move count).
    @ObservationIgnored var sideAFinalKey = -1
    /// The stock is moving between clampings (overlays wait for it to land).
    /// The finding highlight sits on the part, which hides while it moves.
    var stockAnimating = false { didSet { if stockAnimating != oldValue { showDFMHighlight() } } }
    /// Numbers drawn over the 3D view, model coordinates.
    var sceneLabels: [SceneLabel] = []
    @ObservationIgnored var measuringToolNames: [String] = []
    /// The cutter's turn while playing (radians).
    @ObservationIgnored var toolSpin: Float = 0
    @ObservationIgnored var pendingPlay = false
    /// A tool change playback stopped at (ToolChange.swift): its panel shows while set.
    var toolChangeStop: ToolChangeStop?
    @ObservationIgnored var toolChangeTask: Task<Void, Never>?
    /// Tool changes confirmed where the playhead is (cleared when you move it yourself).
    @ObservationIgnored var toolChangesDone: Set<Int> = []
    /// Set while playback or a tool change moves the playhead (not you).
    @ObservationIgnored var internalSeek = false
    @ObservationIgnored var gumballDrag: GumballDrag?
    /// Which side the viewport shows.
    var viewSide = 0 {
        didSet {
            guard viewSide != oldValue, !switchingView else { return }
            transition(from: oldValue)
        }
    }
    @ObservationIgnored var switchingView = false
    /// Material left between the sides, holding the part in the frame, mm (when not using tabs).
    var webThickness = 0.3 { didSet { if webThickness != oldValue { clearToolpathResults() } } }
    /// Hold the part with tabs (it cuts free except for a few bridges) instead of a full web.
    var holdWithTabs = true { didSet { if holdWithTabs != oldValue { clearToolpathResults(); noteProjectChange() } } }
    var tabs = HoldingTabs() {
        didSet {
            // Tabs go in mirrored pairs (older projects may hold an odd count).
            if tabs.count % 2 == 1 { tabs.count += 1 }
            if tabs != oldValue { clearToolpathResults(); noteProjectChange() }
        }
    }
    /// Where the engine put the tabs (side B work frame).
    var placedTabs: [PlacedTab] = []
    /// Their Z range as generated (side B work frame): what the engine kept, even if the
    /// analysis' split has moved since.
    var placedTabZ: ClosedRange<Double>?
    /// The job's tool-change spot (ToolChange.swift), for the setup, stock and tools it was found for.
    @ObservationIgnored var toolChangeSpotCache: (key: String, spot: ToolChangeSpot)?
    @ObservationIgnored var sideResults: [SideResult] = []

    // Toolpath viewer
    var timeline = ToolpathTimeline()
    var playhead: Double = 0
    var isPlaying = false
    var playSpeed: Double = 1
    var colorMode = PathColorMode.moveType { didSet { if colorMode != oldValue { showToolpaths() } } }
    var simulate = true { didSet { if simulate != oldValue { resetSimulation(); updatePlayback() } } }
    var inspecting = false { didSet { if !inspecting { inspected = nil } } }
    var inspected: InspectedMove?
    @ObservationIgnored var entrySegmentEnd: [Int] = []
    @ObservationIgnored var heightmap: Heightmap?
    @ObservationIgnored var simIndex = 0
    /// Saved simulation states along the timeline: scrubbing back restores the nearest one
    /// instead of replaying every move from the start.
    @ObservationIgnored var simCheckpoints: [(index: Int, map: Heightmap)] = []
    @ObservationIgnored var simCatchUp: Task<Void, Never>?
    /// Simulates the whole side in the background once, saving checkpoints at every
    /// operation's start, so a click anywhere on the timeline starts close by (Playback.swift).
    @ObservationIgnored var simPrecompute: Task<Void, Never>?
    /// The fresh stock the simulation of the side on screen starts from.
    @ObservationIgnored var simStart: Heightmap?
    /// Side A as it leaves the machine (every move applied): side B's simulation starts from it,
    /// turned front-to-back, so the back shows what side A already cut.
    @ObservationIgnored var sideAFinal: Heightmap?
    /// What each timeline operation is (the edge finding first).
    @ObservationIgnored var timelineTitles: [String] = []
    @ObservationIgnored var sideAFinalTask: Task<Void, Never>?
    /// Side B's back surface (side A's result mirrored), per simulation cell, work Z.
    @ObservationIgnored var simBack: [Float]?
    @ObservationIgnored var playTimer: Timer?
    @ObservationIgnored var operationProgram: [Int] = []
    @ObservationIgnored var operationLines: [[Int?]] = []
    @ObservationIgnored var plannedTools: [Tool] = []
    @ObservationIgnored var toolMeshID: UUID?

    // Analysis
    var analysis: PartAnalysis? { didSet { analysisVersion += 1 } }
    /// The last analysis failed (Machinability offers to try again).
    var analysisFailed = false
    /// The Machinability finding picked in the inspector (its faces lit: `showDFMHighlight`).
    var selectedFindingID: String?
    @ObservationIgnored var dfmHighlight: (faces: [Int], category: DFMFinding.Category)?
    /// Every problem's faces by kind, coloured on the part in Plan (`showDFMHighlight`).
    @ObservationIgnored var dfmOverlayFaces: [DFMFinding.Category: [Int]] = [:]
    /// Problems drawn on the part in Plan; the legend's eye hides them.
    var showFindingsOverlay = true { didSet { if showFindingsOverlay != oldValue { showDFMHighlight() } } }
    /// Bumped with every new analysis: the Machinability cache's key.
    @ObservationIgnored var analysisVersion = 0
    @ObservationIgnored var dfmCache: (key: DFMCacheKey, findings: [DFMFinding], anchors: [String: [SIMD3<Double>]])?
    @ObservationIgnored var setupRoomCache: (key: String, room: SetupRoom)?
    /// What the part's features are (quiddity), for the findings' titles: found in the
    /// background once per file; empty until then, or when there are none.
    var namedFeatures: [NamedFeature] = []
    @ObservationIgnored var namedFeaturesFile: URL?
    @ObservationIgnored var recognitionTask: Task<Void, Never>?
    /// A tool for the Tools page to select when it opens (Machinability's ways forward).
    var toolToShow: Tool.ID?
    var partChangedOnDisk = false
    @ObservationIgnored var analysisTask: Task<Void, Never>?
    @ObservationIgnored var partWatcher: DispatchSourceFileSystemObject?

    // Measuring
    var measuring = false { didSet { if !measuring { clearMeasurements() } } }
    var measurePoints: [MeasurePoint] = []

    // Section
    enum SectionAxis: String, CaseIterable, Identifiable { case x, y, z; var id: Self { self } }
    var sectionOn = false { didSet { applySection() } }
    var sectionAxis = SectionAxis.y { didSet { applySection() } }
    /// Offset from the stock centre along the section axis, mm.
    var sectionOffset: Double = 0 { didSet { applySection() } }

    /// The stock currently used (resolved against the inventory by the view).
    @ObservationIgnored var stockLookup: (StockItem.ID) -> StockItem? = { _ in nil }
    @ObservationIgnored var fixtureLookup: (UUID) -> Fixture? = { _ in nil }
    @ObservationIgnored var toolLookup: (Tool.ID) -> Tool? = { _ in nil }
    /// The whole library (stock, tools, collets): for checks the stage bar shows without a view's inventory.
    @ObservationIgnored var inventoryLookup: () -> Inventory = { Inventory() }
    /// Adds tools and stock to the inventory (a project's own copies of what it uses).
    @ObservationIgnored var addToInventory: ([Tool], [StockItem]) -> Void = { _, _ in }
    @ObservationIgnored private(set) var engine: EngineClient?
    @ObservationIgnored var machineModel: MachineModel?
    /// Turning the stock over on screen when switching to side B.
    @ObservationIgnored var flipTask: Task<Void, Never>?
    /// Realistic (physically based) shading or the flat CAD look; remembered.
    var realistic = UserDefaults.standard.object(forKey: "realistic") as? Bool ?? true {
        didSet {
            renderer.realistic = realistic
            if ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil { UserDefaults.standard.set(realistic, forKey: "realistic") }
            applyStockDisplay()
        }
    }
    /// How the stock is drawn, and "show only the work" (hides the machine and fixtures).
    var stockDisplay = StockDisplay.realistic { didSet { applyStockDisplay() } }
    var isolateWork = false { didSet { applyMachineDisplay() } }
    /// Show the toolpaths (off: just the solid stock being cut and the tool).
    var pathsVisible = true { didSet { renderer.scene.lineSet("toolpath")?.isVisible = pathsVisible } }
    @ObservationIgnored var cutFaceKey = ""
    /// Where to seek once a side switch has finished (job strip clicks).
    @ObservationIgnored var pendingSeek: (() -> Void)?
    /// Nominal tool for placing the stock under the spindle in the 3D view.
    @ObservationIgnored private let nominalStickout = 25.0

    init() {
        // A write to the engine after it died must be an error, not SIGPIPE ending the app.
        signal(SIGPIPE, SIG_IGN)
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal isn't available on this Mac.") }
        do {
            renderer = try ViewportRenderer(device: device)
        } catch {
            fatalError("The 3D viewport couldn't start: \(error)")
        }
        renderer.worldToDisplay = ViewportRenderer.machineToDisplay
        renderer.camera.set(.iso)
        jobs.engine = { [unowned self] in try self.connectedEngine() }
        jobs.machineSource = { [unowned self] in
            try? await self.loadControlMachineModel()
        }
        renderer.animationsEnabled = ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil
            || ProcessInfo.processInfo.environment["COASTLINE_ANIMATE"] != nil
        renderer.realistic = realistic
        camera = renderer.camera
        renderer.onCameraChange = { [weak self] c in
            self?.camera = c
            if self?.gumballTarget != nil { self?.layoutGumball() }  // arrows keep their size on screen
        }
        // Motion groups: the table (X) carries the work; the translator (Y) and spindle (Z, which
        // rides on Y) carry the tool.
        let onTable: Set<String> = ["part", "stock", "stock.edges", "simstock", "simstock.back", "stock.anim", "clearance", "toolpath", "workarea", "workarea.edges", "travel.trace",
                                    "undercuts", "measure", "section.plane", "section.edges", "deviation", "cutface", "cutface.edges",
                                    "prep.cut", "prep.cut.edges", "prep.next", "simstock.walls", "simstock.loose"]
        renderer.scene.groupForID = { id in
            if id.hasPrefix("machine.x.") { return "x" }
            if id.hasPrefix("machine.y.") { return "y" }
            if id.hasPrefix("machine.z.") || id == "tool" || id.hasPrefix("tool.") { return "z" }
            if id.hasPrefix("fixture.") || id.hasPrefix("tabs") { return "x" }
            return onTable.contains(id) ? "x" : nil
        }
        if let axes = SceneLines(device: device, id: "axes", segments: LineSegment.axes(length: 20)) {
            renderer.scene.setLines(axes)
        }
    }

    /// The repository root during development (Sources/Coastline/Model/AppModel.swift → 5 levels
    /// up), or the standalone app's copy of it.
    static let repoRoot: URL = {
        // A standalone app (scripts/make-app.sh --standalone) carries the repo's engine/,
        // resources/ and its own python/ in Contents/Resources/Coastline.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Coastline"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("engine/coastline_engine").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }()

    /// The engine, restarted if it died (a crash in a native library ends its process), with the
    /// part imported into the new one so its ID is valid again. The setup is untouched.
    func liveEngine() async throws -> EngineClient {
        if let e = engine, await e.isRunning() { return e }
        let restarted = engine != nil
        engine = nil
        let e = try connectedEngine()
        if restarted, let p = part {
            let mesh = try await e.importPart(p.url)
            part?.partID = mesh.partID
            status = "The geometry engine restarted; \(p.fileName) was loaded into it again."
        }
        return e
    }

    func connectedEngine() throws -> EngineClient {
        if let engine { return engine }
        let e = try EngineClient.development(repoRoot: Self.repoRoot)
        engine = e
        return e
    }

    /// Jobs keep their selected definitions even if the library is edited or removed.
    var stock: StockItem? {
        guard let id = stockID else { return nil }
        return (stockSnapshot?.id == id ? stockSnapshot : nil) ?? stockLookup(id)
    }
    var jobResources = JobResourceSnapshot()
    var stockSnapshot: StockItem? {
        get { jobResources.stock }
        set {
            jobResources.stock = newValue.map { item in
                var copy = item
                if copy.materialSnapshot == nil { copy.materialSnapshot = copy.material }
                return copy
            }
        }
    }

    // MARK: Machine

    /// Loads the machine assembly (cached by the engine after the first run, ~6 s → 0.1 s).
    func loadMachine() async {
        guard !machineLoaded, !isSwitchingPlanningMachine else { return }
        do {
            let reference = try await initialPlanningMachineReference()
            while isSwitchingPlanningMachine { try await Task.sleep(for: .milliseconds(25)) }
            // A project opened during discovery owns its explicit assignment.
            guard !machineLoaded else { return }
            try await restorePlanningMachine(reference)
        } catch {
            planningMachineProblem = error.localizedDescription
            errorMessage = "Couldn't load the machine model: \(error)"
        }
    }

    func applyMachineDisplay() {
        for m in renderer.scene.meshes where m.id.hasPrefix("machine.") {
            let parts = m.id.split(separator: ".")
            let group = machineSceneComponents[m.id] ?? (parts.count > 1 ? String(parts[1]) : "static")
            let role = machineSceneRoles[m.id] ?? (parts.count > 2 ? String(parts[2]) : "")
            let moving = planningGeometry?.isMoving(componentID: group) ?? (group != "static")
            let shell = planningGeometry?.isEnclosure(componentID: group) ?? role.hasPrefix("enclosure")
            if fixturePlacement != nil {
                // Keep the real working assemblies as placement context, without the shell
                // or guards hiding the stock. Their existing motion groups remain intact.
                m.isVisible = moving && !shell && !role.hasSuffix("guard")
                m.color.w = 1
                continue
            }
            // The shell and everything mounted only on it (its screws, the E-stop) go together.
            // Ghosted: the whole machine see-through, the enclosure shell fainter still.
            m.color.w = machineDisplay == .ghost ? (shell ? 0.12 : 0.24) : 1
            switch machineDisplay {
            case .ghost: m.isVisible = true
            case .full: m.isVisible = true
            case .open: m.isVisible = !shell
            case .moving: m.isVisible = moving && !shell
            case .hidden: m.isVisible = false
            }
            // Chip guards are clear, so the work shows through them; they can be hidden too.
            if role.hasSuffix("guard") {
                m.color.w = machineDisplay == .ghost ? 0.1 : 0.2
                if !showChipGuards { m.isVisible = false }
            }
            if isolateWork || showingStockOnly { m.isVisible = false }
        }
        applyFixtureDisplay()
        applySurfaces()
        updatePivot()
    }

    /// Orbit around the centre of the mill while it's shown, otherwise around the work.
    private func updatePivot() {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        let machineShown = machineDisplay != .hidden && machineLoaded && !showingStockOnly && !isolateWork && fixturePlacement == nil
        for m in renderer.scene.meshes where m.isVisible && (machineShown ? m.id.hasPrefix("machine.") : ["part", "stock"].contains(m.id)) {
            for i in 0..<8 {
                let c = SIMD3(i & 1 == 0 ? m.boundsMin.x : m.boundsMax.x, i & 2 == 0 ? m.boundsMin.y : m.boundsMax.y,
                              i & 4 == 0 ? m.boundsMin.z : m.boundsMax.z)
                let group = m.group.flatMap { renderer.scene.groupTransforms[$0] } ?? matrix_identity_float4x4
                let w = group * m.transform * SIMD4(c, 1)
                lo = simd_min(lo, SIMD3(w.x, w.y, w.z))
                hi = simd_max(hi, SIMD3(w.x, w.y, w.z))
            }
        }
        renderer.setPivot(world: lo.x <= hi.x ? (lo + hi) / 2 : nil)
    }

    // MARK: Layout

    /// Where the work origin (stock top-face centre) sits in model coordinates: stock standing
    /// on the table (lifted by the fixture), centred on the spindle axis in Y, with its face a
    /// nominal tool length in front of the collet nut.
    func workOrigin(stockSize: SIMD3<Double>) -> SIMD3<Double> { workToModel(stockSize: stockSize) }

    /// Where the work origin (centre of the stock face toward the spindle) sits in the model,
    /// with the table at the model's pose: in the job's fixture, centred on the Y travel.
    func workToModel(stockSize: SIMD3<Double>) -> SIMD3<Double> {
        if let fixture = fixturePlacement?.fixture { return libraryOrigin(fixture: fixture, stock: stockSize) }
        return customWorkOrigin(stockSize: stockSize)
    }

    func customWorkOrigin(stockSize s: SIMD3<Double>) -> SIMD3<Double> {
        let fixture = displayedJobFixture
        let standIn = fixture == nil && showsStandInVise
        return SIMD3(tableGeometry.topX + (fixture?.height ?? (standIn ? StandInVise.floor : setup.customFixture.height)) + s.x / 2,
              travelCentreY, tableGeometry.northZ + (fixture?.planning?.facePastTable ?? (standIn ? StandInVise.facePast : setup.customFixture.faceProtrusion)))
    }

    /// Where work X0 Y0 Z0 is in machine coordinates for a tool sticking out `stickout`,
    /// whatever is on screen (the job's fixture or the custom one).
    func machineOrigin(stickout: Double) -> SIMD3<Double>? {
        guard let stock else { return nil }
        return machineOrigin(modelOrigin: customWorkOrigin(stockSize: setup.stockSize(stock)), stickout: stickout)
    }

    /// The same for work zero at a model position `o`.
    func machineOrigin(modelOrigin o: SIMD3<Double>, stickout: Double) -> SIMD3<Double>? {
        guard let mm = machineModel else { return nil }
        let t = tipAtModelPose(stickout: stickout), m = mm.modelPose
        return SIMD3(m.x - t.x + o.x, m.y + o.y - t.y, m.z + o.z - t.z)
    }


    /// Machining and Review show toolpaths and the simulated stock; the setup steps before
    /// them show the stock as it is going in.
    var showsMachiningResults: Bool { fixturePlacement == nil && (stage == .machining || stage == .review) }


    /// The stock as the viewport shows it.
    var displayStockSize: SIMD3<Double>? {
        if fixturePlacement != nil { return placementStockSize }
        if showingStockOnly, let stock { return setup.rawStockSize(stock) }  // stage 1: as bought
        return stock.map { setupFor(side: viewSide >= 2 ? viewSide : 0).stockSize($0) }
    }

    /// The machine position the machine assembly is modelled at (calibrated, machine_travel.py).
    var modelPose: SIMD3<Double>? { machineModel.map { SIMD3($0.modelPose.x, $0.modelPose.y, $0.modelPose.z) } }

    /// Model y of the spindle axis when the gantry is in the middle of its Y travel.
    var travelCentreY: Double {
        guard let mm = machineModel else { return 0 }
        let e = machine.machineEnvelope.y
        return mm.spindleNose.y + ((e.lowerBound + e.upperBound) / 2 - mm.modelPose.y)
    }



    /// Re-places the part, stock and markers after any setup change.
    func layoutScene() {
        let scene = renderer.scene
        let stockSize = displayStockSize ?? SIMD3(0, 0, 0)
        var origin = workToModel(stockSize: stockSize)
        let partOrigin = origin
        let originT = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(partOrigin, 1)))

        scene.mesh("part")?.isVisible = true
        if let part, let mesh = scene.mesh("part") {
            var t = originT * setupFor(side: twoSided || viewSide >= 2 ? viewSide : 0).partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
            if stage == .partStock && fixturePlacement == nil {
                // Inspect the CAD independently of stock, a fixture or a moving machine
                // group. Only Setups places it relative to the machine's table.
                let k = setup.partScale
                let centre = (part.boundsMin + part.boundsMax) / 2
                t = simd_double4x4(diagonal: SIMD4(k, k, k, 1))
                t.columns.3 = SIMD4(-centre * k, 1)
                mesh.group = nil
            } else { mesh.group = "x" }
            mesh.transform = t.float
        }
        if true {
            for id in ["toolpath", "simstock", "simstock.back", "simstock.walls", "simstock.loose", "tabs"] { scene.lineSet(id)?.isVisible = true; scene.mesh(id)?.isVisible = true }
        }
        scene.lineSet("toolpath")?.isVisible = pathsVisible
        scene.remove(id: "stock")
        scene.remove(id: "stock.edges")
        if let stock {
            let trim = displayStockTrim
            let box = (min: SIMD3(-stockSize.x / 2, -stockSize.y / 2, -stockSize.z + trim.back), max: SIMD3(stockSize.x / 2, stockSize.y / 2, -trim.front))
            _ = stock
            let lo = SIMD3<Float>(box.min + origin), hi = SIMD3<Float>(box.max + origin)
            let c = stock.material?.linearSwatch ?? SIMD3(0.5, 0.5, 0.5)
                if let m = SceneMesh.box(device: renderer.device, id: "stock", min: lo, max: hi, color: SIMD4(c, 0.22)) {
                    scene.setMesh(m)
                }
                if let edges = SceneLines(device: renderer.device, id: "stock.edges",
                                          segments: LineSegment.box(min: lo, max: hi, color: SceneColor.edge)) {
                    scene.setLines(edges)
                }
        }
        layoutClamps(stockSize: stockSize)
        layoutInProcessStock(stockSize: stockSize, origin: origin)
        origin = partOrigin
        layoutTabs(origin: origin)
        layoutWorkArea(stockSize: stockSize, origin: origin)
        if showingStockOnly || fixturePlacement != nil { for id in ["workarea", "workarea.edges"] { scene.mesh(id)?.isVisible = false; scene.lineSet(id)?.isVisible = false } }
        cutFaceKey = ""
        layoutCutFace()
        if showingStockOnly || !showsMachiningResults {
            // The stock as bought, or a setup step: the
            // plain stock, never a simulated (cut) one, no paths or tool. Machining and Review
            // bring the simulation back (enter → showSide).
            for id in ["toolpath", "clearance"] { scene.lineSet(id)?.isVisible = false }
            for id in ["simstock", "simstock.back", "simstock.walls", "simstock.loose", "tool", "tool.shank"] { scene.mesh(id)?.isVisible = false }
            scene.mesh("stock")?.isVisible = true
        }
        applyMachineDisplay()  // visibility rules (display mode, show-only-the-work) win over layout
        applyStockDisplay()
        applySection()
        refreshMeasureMarkers()
        showUndercuts()
        if timeline.entries.isEmpty { parkMachine() }
        updatePivot()
        layoutGumball()
        layoutEngravingPreview()
    }

    /// The fixture on the table (it moves with X): the job's library fixture, drawn where the
    /// stock sits in it. Meshes are made once per fixture and then only moved.
    private func layoutClamps(stockSize: SIMD3<Double>) {
        if fixturePlacement != nil { layoutFixturePlacement(stockSize: stockSize); return }
        let scene = renderer.scene
        var used = Set<String>()
        // Everything placed here, for the collision check (CollisionCheck.swift).
        var bodies: [BedBody] = []
        defer { scheduleCollisionCheck(bodies, stockSize: stockSize) }
        if stock != nil {
            if setup.planFromFixtureLibrary, !showingStockOnly, automaticWorkholding, libraryWorkholdingPlan == nil || currentLibraryStep == nil,
               fixturePlacement == nil, let fixture = displayedJobFixture, libraryFixtureMeshes[fixtureStateKey(fixture)] == nil,
               automaticPreviewRequested != fixtureStateKey(fixture) {
                automaticPreviewRequested = fixtureStateKey(fixture)
                Task { await reloadSelectedFixturePreview() }
            }
            if setup.planFromFixtureLibrary, !showingStockOnly, let fixture = displayedJobFixture,
               let mesh = libraryFixtureMeshes[fixtureStateKey(fixture)] {
                let id = "fixture.library.\(fixture.id)"
                let t = simd_double4x4(translation: workToModel(stockSize: stockSize))
                if let model = SceneMesh(device: renderer.device, id: id, positions: mesh.vertices, normals: mesh.normals,
                                         indices: mesh.indices, color: SceneColor.part, transform: t.float) {
                    model.group = "x"
                    scene.setMesh(model)
                    used.insert(id)
                }
                if let local = libraryFixtureTriangles[fixtureStateKey(fixture)] {
                    let origin = workToModel(stockSize: stockSize)
                    bodies.append(BedBody(name: fixture.name, meshPrefix: id, shape: .triangles(local.map { $0 + origin })))
                }
            }
        }
        if stock != nil, showsStandInVise {
            for id in layoutStandInVise(stockSize: stockSize) { used.insert(id) }
        }
        for m in scene.meshes where m.id.hasPrefix("fixture.") && !used.contains(m.id) { m.isVisible = false }
        applyFixtureDisplay()
    }

    /// The stand-in vise (StandInVise) around the stock as shown, see-through orange: the same
    /// boxes the clearance check uses (the table's is drawn by the machine). Its ids.
    private func layoutStandInVise(stockSize s: SIMD3<Double>) -> [String] {
        let o = workToModel(stockSize: s)
        var ids: [String] = []
        for b in StandInVise.boxes(stockSize: s, facedBefore: standInFacedBefore, jawFront: standInJawFront(side: viewSide), table: tableGeometry)
        where b.name != "table" {
            let id = "fixture.standin.\(b.name)"
            if let m = SceneMesh.box(device: renderer.device, id: id, min: SIMD3<Float>(b.min + o), max: SIMD3<Float>(b.max + o),
                                     color: SIMD4(0.95, 0.62, 0.25, 0.55)) {
                m.group = "x"
                m.material.metallic = 0; m.material.roughness = 0.05  // drawn see-through (applyFixtureDisplay)
                renderer.scene.setMesh(m)
                ids.append(id)
            }
        }
        return ids
    }

    /// The snapshot of the stock for the step (or side) shown: what is left when it starts.
    var shownInProcessKey: String? {
        guard !showingStockOnly, fixturePlacement == nil, stock != nil else { return nil }
        let key = currentLibraryStep.map { "step:\($0.id)" } ?? "side:\(max(viewSide, 0))"
        return inProcessSnapshots[key] == nil ? nil : key
    }

    /// Side A's frame into this side's work frame (SetupSide.fromA, side B's flip included).
    func sideFromA(_ side: Int, stockA a: SIMD3<Double>) -> simd_double4x4 {
        let s = SetupSide.stockSize(a, side: side)
        let r = SetupSide.rotation(side, flipAxis: setupFor(side: 1).flipAxis)
        let rot = simd_double4x4(columns: (SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(0, 0, 0, 1)))
        return simd_double4x4(translation: SIMD3(0, 0, -s.z / 2)) * rot * simd_double4x4(translation: SIMD3(0, 0, a.z / 2))
    }

    /// The stock as the shown setup step starts: what every cut before it left (the plain box
    /// otherwise). Drawn in place of the box in the setup steps, not over the simulation.
    private func layoutInProcessStock(stockSize: SIMD3<Double>, origin: SIMD3<Double>) {
        let scene = renderer.scene
        guard !showsMachiningResults, let key = shownInProcessKey, let model = inProcessSnapshots[key], let stock else {
            scene.remove(id: "stock.inprocess")
            return
        }
        let mesh: (positions: [Float], normals: [Float], indices: [UInt32])
        if let m = inProcessMeshes[key] { mesh = m } else {
            mesh = DexelMesher.mesh(model.material(axis: 2), axis: 2)
            inProcessMeshes[key] = mesh
        }
        guard !mesh.indices.isEmpty else { scene.remove(id: "stock.inprocess"); return }
        let t = simd_double4x4(translation: origin) * sideFromA(max(viewSide, 0), stockA: setup.stockSize(stock))
        let c = stock.material?.linearSwatch ?? SIMD3(0.5, 0.5, 0.5)
        if let m = SceneMesh(device: renderer.device, id: "stock.inprocess", positions: mesh.positions, normals: mesh.normals,
                             indices: mesh.indices, color: SIMD4(c, 0.22), transform: t.float) {
            m.group = "x"
            scene.setMesh(m)
        }
    }

    /// What is gone from the shown stock before this clamping (mm off its front and back): an
    /// end setup's earlier clampings faced its front; the other end setup, done first, its back.
    var displayStockTrim: (front: Double, back: Double) {
        guard viewSide >= 4, !showingStockOnly else { return (0, 0) }
        let front = standInFacedBefore
        var back = 0.0
        if viewSide == 5, let plan = libraryWorkholdingPlan,
           let mine = plan.steps.firstIndex(where: { $0.id == currentLibraryStep?.id }),
           plan.steps[..<mine].contains(where: { $0.side == 4 }) { back = endPieceThickness(side: 4) }
        return (front, back)
    }

    /// Fixtures follow the machine display: see-through when the machine is ghosted.
    private func applyFixtureDisplay() {
        for m in renderer.scene.meshes where m.id.hasPrefix("fixture.") {
            let clear = m.material.metallic == 0 && m.material.roughness <= 0.05  // insulators
            m.color.w = clear ? 0.35 : machineDisplay == .ghost ? 0.5 : 1
            if fixturePlacement != nil { m.isVisible = m.id.hasPrefix(Self.placementMeshPrefix) }
            else if isolateWork || showingStockOnly { m.isVisible = false }
        }
    }

    /// The holding tabs, as orange outlines over their Z range, on the side that cuts through.
    private func layoutTabs(origin: SIMD3<Double>) {
        renderer.scene.remove(id: "tabs")
        guard (twoSided && holdWithTabs) || cutsThroughWithTabs, viewSide == tabSide, !placedTabs.isEmpty, let r = tabZ else { return }
        let bottom = r.lowerBound, top = r.upperBound
        let o = SIMD3<Float>(origin)
        var segs: [LineSegment] = []
        let c = SceneColor.highlight
        for t in placedTabs where t.corners.count >= 3 {
            for k in t.corners.indices {
                let a = t.corners[k], n = t.corners[(k + 1) % t.corners.count]
                for z in [bottom, top] {
                    segs.append(LineSegment(SIMD3<Float>(Float(a.x), Float(a.y), Float(z)) + o, SIMD3<Float>(Float(n.x), Float(n.y), Float(z)) + o, color: c))
                }
                segs.append(LineSegment(SIMD3<Float>(Float(a.x), Float(a.y), Float(bottom)) + o, SIMD3<Float>(Float(a.x), Float(a.y), Float(top)) + o, color: c))
            }
        }
        if let set = SceneLines(device: renderer.device, id: "tabs", segments: segs) { renderer.scene.setLines(set) }
    }

    /// Another tool came into the spindle (playback): only what its stick-out moves, the work
    /// area (the tip's reach), not the whole scene. The previews that shift the part re-lay all.
    func toolChanged() {
        guard !showingStockOnly else { layoutScene(); return }
        let size = displayStockSize ?? SIMD3(0, 0, 0)
        layoutWorkArea(stockSize: size, origin: workToModel(stockSize: size))
    }

    /// The machine's work area: every point the tool tip can reach, in the table's frame (drawn on
    /// the table, so it moves with it). The table moves X, the spindle Y and Z, so relative to the
    /// table the tip covers the full X, Y and Z travel from the modelled pose.
    private func layoutWorkArea(stockSize: SIMD3<Double>, origin: SIMD3<Double>) {
        let scene = renderer.scene
        scene.remove(id: "workarea")
        scene.remove(id: "workarea.edges")
        guard machineModel != nil, showWorkArea else { return }
        let (lo, hi) = reachBox()
        if let m = SceneMesh.box(device: renderer.device, id: "workarea", min: SIMD3<Float>(lo), max: SIMD3<Float>(hi),
                                 color: SceneColor.surface(0.9, alpha: 0.06)) {
            scene.setMesh(m)
        }
        if let e = SceneLines(device: renderer.device, id: "workarea.edges",
                              segments: LineSegment.box(min: SIMD3<Float>(lo), max: SIMD3<Float>(hi), color: SceneColor.line(170, alpha: 254))) {
            scene.setLines(e)
        }
    }

    // MARK: Machine kinematics

    /// Tool tip at the modelled pose (model frame), for the current tool's stick-out.
    var tipAtModelPose: SIMD3<Double> { tipAtModelPose(stickout: currentStickout) }

    func tipAtModelPose(stickout: Double) -> SIMD3<Double> {
        guard let mm = machineModel else { return .zero }
        return SIMD3(mm.spindleNose.x, mm.spindleNose.y, mm.spindleNose.z - stickout)
    }

    var currentStickout: Double { currentTool?.stickout ?? nominalStickout }

    /// The reachable box of the tool tip in the table frame (model coordinates, table at the
    /// modelled pose).
    func reachBox() -> (SIMD3<Double>, SIMD3<Double>) {
        guard let mm = machineModel else { return (.zero, .zero) }
        let t = tipAtModelPose, p = mm.modelPose, e = machine.machineEnvelope
        // Table shift dx = Xm − X; the tip relative to the table moves by −dx.
        let xs = [t.x - (p.x - e.x.lowerBound), t.x - (p.x - e.x.upperBound)]
        let ys = [t.y + (e.y.lowerBound - p.y), t.y + (e.y.upperBound - p.y)]
        let zs = [t.z + (e.z.lowerBound - p.z), t.z + (e.z.upperBound - p.z)]
        return (SIMD3(xs.min()!, ys.min()!, zs.min()!), SIMD3(xs.max()!, ys.max()!, zs.max()!))
    }

    /// Machine coordinates that put the tool tip at work-frame point `p`.
    func machinePosition(forWork p: SIMD3<Double>, stickout: Double? = nil) -> SIMD3<Double>? {
        machineMapper(stickout: stickout).map { $0(p) }
    }

    /// Work → machine coordinates for one tool, worked out once (the work origin needs the
    /// whole clamp placement): use it for many points.
    func machineMapper(stickout: Double? = nil) -> ((SIMD3<Double>) -> SIMD3<Double>)? {
        guard let mm = machineModel, let stock else { return nil }
        let o = workToModel(stockSize: displayStockSize ?? setup.stockSize(stock)), t = tipAtModelPose(stickout: stickout ?? currentStickout), m = mm.modelPose
        return { p in
            let dx = t.x - (o.x + p.x), dy = o.y + p.y - t.y, dz = o.z + p.z - t.z
            return SIMD3(m.x - dx, m.y + dy, m.z + dz)
        }
    }

    /// Moves the machine's table, translator and spindle to machine coordinates.
    func setMachinePosition(_ q: SIMD3<Double>) {
        guard let mm = machineModel else { return }
        if let geometry = planningGeometry {
            do {
                let translations = try geometry.componentTranslations(at: Vec3(q.x, q.y, q.z))
                var transforms: [String: simd_float4x4] = [:]
                for (id, p) in translations {
                    transforms["profile." + id] = simd_float4x4(translation: SIMD3(Float(p.x), Float(p.y), Float(p.z)))
                }
                transforms["x"] = transforms["profile." + geometry.tableComponentID]
                transforms["z"] = transforms["profile." + geometry.headComponentID]
                renderer.scene.groupTransforms = transforms
                machinePosition = q
            } catch { errorMessage = error.localizedDescription }
            return
        }
        let m = mm.modelPose
        let scene = renderer.scene
        scene.groupTransforms["x"] = simd_float4x4(translation: SIMD3(Float(m.x - q.x), 0, 0))
        scene.groupTransforms["y"] = simd_float4x4(translation: SIMD3(0, Float(q.y - m.y), 0))
        scene.groupTransforms["z"] = simd_float4x4(translation: SIMD3(0, Float(q.y - m.y), Float(q.z - m.z)))
        machinePosition = q
    }

    /// Parks the tool 10 mm above the work origin (or at home if that's out of reach), with the
    /// current tool in the collet.
    func parkMachine() {
        guard machineModel != nil else { return }
        if let tool = currentTool { ensureToolMesh(tool) }
        let env = machine.machineEnvelope
        if let q = machinePosition(forWork: SIMD3(0, 0, 10)) {
            setMachinePosition(SIMD3(min(max(q.x, env.x.lowerBound), env.x.upperBound),
                                     min(max(q.y, env.y.lowerBound), env.y.upperBound),
                                     min(max(q.z, env.z.lowerBound), env.z.upperBound)))
        } else {
            let home = machine.homePosition ?? Vec3(env.x.lowerBound, env.y.upperBound, env.z.upperBound)
            setMachinePosition(SIMD3(home.x, home.y, home.z))
        }
    }

    /// Whether a machine position is inside the machine's travel, and by how much it isn't.
    func travelProblem(_ q: SIMD3<Double>) -> String? {
        let e = machine.machineEnvelope
        var out: [String] = []
        for (name, v, r) in [("X", q.x, e.x), ("Y", q.y, e.y), ("Z", q.z, e.z)] where !r.contains(v) {
            let over = v < r.lowerBound ? r.lowerBound - v : v - r.upperBound
            out.append("\(name) by \(Length.mm(over)) mm")
        }
        return out.isEmpty ? nil : "Beyond the machine's travel: " + out.joined(separator: ", ")
    }

    // MARK: Import

    func importPart(_ url: URL) async {
        isBusy = true
        status = "Importing \(url.lastPathComponent)…"
        errorMessage = nil
        defer { isBusy = false }
        do {
            let newPart = part?.url.standardizedFileURL != url.standardizedFileURL
            let engine = try await liveEngine()
            let mesh = try await engine.importPart(url)
            // Another part: threads and engraving were for the last one's holes and faces.
            if let old = part?.url, old.standardizedFileURL != url.standardizedFileURL {
                operations.removeAll { [.thread, .engrave].contains($0.kind) }
            }
            guard let sceneMesh = SceneMesh(device: renderer.device, id: "part", positions: mesh.vertices,
                                            normals: mesh.normals, indices: mesh.indices,
                                            color: SceneColor.part, pickable: true) else {
                throw EngineClient.EngineError(type: "Empty", message: "The file has no surfaces to show.")
            }
            renderer.scene.setMesh(sceneMesh)
            // A new import (or the file changed on disk): the last part's analysis, holes and
            // floors, and the finding picked on it describe other faces.
            analysis = nil
            analysisFailed = false
            features = nil
            featuresKey = nil
            selectFinding(nil)
            partMeshData = (mesh.vertices, mesh.normals, mesh.indices)
            for m in renderer.scene.meshes where m.id.hasPrefix("part.copy.") { renderer.scene.remove(id: m.id) }
            let lo = SIMD3(mesh.boundsMin.x, mesh.boundsMin.y, mesh.boundsMin.z)
            let hi = SIMD3(mesh.boundsMax.x, mesh.boundsMax.y, mesh.boundsMax.z)
            part = PartInfo(url: url, fileName: url.lastPathComponent,
                            kind: mesh.exact ? "\(url.pathExtension.uppercased()) · exact NURBS" : "\(url.pathExtension.uppercased()) · render mesh",
                            exact: mesh.exact, faceCount: mesh.faceCount, triangleCount: mesh.triangleCount,
                            size: mesh.size, boundsMin: lo, boundsMax: hi, partID: mesh.partID, warnings: mesh.warnings)
            // Suggest an orientation: thinnest dimension toward the spindle.
            var s = setup
            if newPart && !restoringProject {
                // A new part starts a new proposal, rather than inheriting the old job's
                // scale, offsets and cutting operations from the previous part.
                let stockAxes = s.stockAxes
                s = Setup().selectingHolding(.custom)
                s.stockAxes = stockAxes
                s.planFromFixtureLibrary = true
                operations = []
                holdWithTabs = false
            }
            (s.facing, s.spin) = Setup.defaultOrientation(partMin: lo, partMax: hi)
            setup = s
            if newPart { enter(.partStock) }
            twoSidedChosen = false
            clearMeasurements()
            keepStockWorkable()
            layoutScene()
            revealWork()
            setView(.iso)
            focusWork()
            watchPartFile(url)
            scheduleAnalysis()
            status = "Imported \(url.lastPathComponent)"
            saveSession()
        } catch {
            errorMessage = "\(error)"
            status = "Import failed"
        }
    }

    /// Standard views are engineering views: always orthographic. Eased from the current view.
    func setView(_ view: OrbitCamera.StandardView) {
        perspective = false
        renderer.moveCamera { $0.orthographic = true; $0.set(view) }
    }

    /// Views along a direction (display space), e.g. a view-cube edge or corner.
    func look(from direction: SIMD3<Float>) {
        perspective = false
        renderer.moveCamera { $0.orthographic = true; $0.look(from: direction) }
    }

    /// The enclosure hides the work: once there's a part or toolpaths, show the machine
    /// see-through instead of whole.
    func revealWork() {
        // The whole machine is the default (realistic) by default; the camera looks in through
        // the front opening. Ghosting is one click away in the view bar.
    }

    /// The parts the CAD colours green (the electronics' boards and the cable cover) are black
    /// plastic on the real machine.
    /// Machine parts in the monotone palette: each its own brightness as a gray, the enclosure a
    /// mid gray (a generic machine, not a painted one), the E-stop red (safety).
    static func displayColor(role: String, _ c: SIMD3<Float>) -> SIMD3<Float> {
        switch role {
        case "estop": c
        case "pcb": SIMD3(repeating: 0.022)
        case "guard": SIMD3(repeating: 0.9)  // clear polycarbonate (see-through, applyMachineDisplay)
        case "enclosure": SIMD3(repeating: 0.42)
        default: SIMD3(repeating: SceneColor.luminance(c))
        }
    }

    /// Frames the stock, part and clamps where the table currently is.
    func focusWork(fixtures: Bool = true, machineContext: Bool = false) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        func machineContextIncludes(_ mesh: SceneMesh) -> Bool {
            guard machineContext else { return false }
            if let geometry = planningGeometry, let component = machineSceneComponents[mesh.id] {
                return geometry.isMoving(componentID: component) && !geometry.isEnclosure(componentID: component)
            }
            return mesh.id.hasPrefix("machine.x.") || mesh.id.hasPrefix("machine.z.")
        }
        for m in renderer.scene.meshes where (["part", "stock"].contains(m.id) || (fixtures && m.id.hasPrefix("fixture."))
                || machineContextIncludes(m)) && m.isVisible {
            let t = renderer.scene.groupTransform(m.group) * m.transform
            for i in 0..<8 {
                let c = SIMD3(i & 1 == 0 ? m.boundsMin.x : m.boundsMax.x, i & 2 == 0 ? m.boundsMin.y : m.boundsMax.y,
                              i & 4 == 0 ? m.boundsMin.z : m.boundsMax.z)
                let w = t * SIMD4(c, 1)
                lo = simd_min(lo, SIMD3(w.x, w.y, w.z))
                hi = simd_max(hi, SIMD3(w.x, w.y, w.z))
            }
        }
        guard lo.x < hi.x else { return }
        // Comfortable framing: the work with room around it (×1.3) and never tighter than
        // ~70 mm across, so it's never a super close-up and the clamps stay in context.
        let c = (lo + hi) / 2
        let half = simd_max((hi - lo) / 2 * 1.3, SIMD3(repeating: 35))
        renderer.frame(worldMin: c - half, worldMax: c + half, animated: true)
    }

    /// Picks a sensible default orientation for the stock (thinnest toward the spindle).
    func useStock(_ item: StockItem) {
        clearToolpathResults()
        stockSnapshot = item
        var s = setup
        s.stockAxes = bestStockAxes(item) ?? Setup.defaultStockAxes(item)
        if let part {
            let (lo, hi) = s.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
            s.topAllowance = min(max(s.topAllowance, 0), max(s.stockSize(item).z - (hi.z - lo.z), 0))
        }
        setup = s
        stockID = item.id
        saveSession()
        noteProjectChange()
        focusWork()
    }

    /// The stock in use was edited in its sheet: keep how it sits if that still works, and plan
    /// again (its size, material or faces change the toolpaths and feeds).
    func stockEdited(_ item: StockItem) {
        stockSnapshot = item
        guard item.id == stockID else { return useStock(item) }
        let keep = stockOptions(item).contains { $0.axes == setup.stockAxes && $0.workable }
        clearToolpathResults()
        var s = setup
        if !keep { s.stockAxes = bestStockAxes(item) ?? Setup.defaultStockAxes(item) }
        if s != setup { setup = s } else { layoutScene(); saveSession(); keepStockWorkable(); noteProjectChange() }
        focusWork()
    }

    /// Standard sizes to buy (StockCatalog, in the inventory as not owned) that hold the part, the
    /// least material first; the current stock's material family first.
    func standardStockThatFits(in inventory: Inventory, limit: Int = 3) -> [StockItem] {
        let family = stock?.material?.family
        return inventory.stock.filter { s in
            s.isSuggestion && s.id != stockID && stockOptions(s).contains(where: \.workable)
        }
            .sorted { a, b in
                let fa = a.material?.family == family ? 0 : 1, fb = b.material?.family == family ? 0 : 1
                return fa != fb ? fa < fb : a.volume < b.volume
            }
            .prefix(limit).map { $0 }
    }

    /// The ways the stock can sit for this part, best first (StockOrientation).
    func stockOptions(_ item: StockItem? = nil) -> [StockOrientation.Option] {
        guard let part, let stock = item ?? stock else { return [] }
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        return StockOrientation.options(stock: stock, part: hi - lo, preferredAxes: setup.stockAxes)
    }

    func bestStockAxes(_ item: StockItem) -> [Int]? {
        stockOptions(item).first(where: \.workable)?.axes
    }

    /// Sits the stock another way (only workable ways are offered).
    func useStockAxes(_ axes: [Int]) {
        var s = setup
        s.stockAxes = axes
        setup = s
    }

    /// When the part or sides change and the stock no longer fits as it sits, turn it the best
    /// workable way (the stock never ends up smaller than the part).
    func keepStockWorkable() {
        guard let stock, let part else { return }
        // An exact-thickness blank has no facing stock. Never push the CAD outside it by
        // retaining the default 0.5 mm top allowance after an import, resize or rotation.
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        let maxTop = max(setup.stockSize(stock).z - (hi.z - lo.z), 0)
        if setup.topAllowance > maxTop || setup.topAllowance < 0 {
            setup.topAllowance = min(max(setup.topAllowance, 0), maxTop)
        }
        guard let current = stockOptions().first(where: { $0.axes == setup.stockAxes }), !current.workable,
              let best = bestStockAxes(stock) else { return }
        useStockAxes(best)
        status = "The stock was turned so the part fits: \(stockOptions().first { $0.axes == best }?.summary ?? "")."
    }

    var setupIssues: [Issue] {
        guard stock != nil else { return [] }
        return stockContainmentIssues + collisionIssues
    }

    var stockContainmentIssues: [Issue] {
        guard let part, let stock else { return [] }
        return SetupChecks.check(setup, partMin: part.boundsMin, partMax: part.boundsMax, stock: stock, machine: machine)
    }

    // MARK: Section

    private func applySection() {
        renderer.scene.remove(id: "section.plane")
        renderer.scene.remove(id: "section.edges")
        guard sectionOn else { renderer.scene.clipPlane = .zero; return }
        let stockSize = stock.map { setup.stockSize($0) } ?? SIMD3(0, 0, 0)
        let origin = workToModel(stockSize: stockSize)
        // The section plane passes through the part's centre (or the stock's, without a part),
        // plus the offset; everything on the plane's positive side is cut away.
        var centre = origin + SIMD3(0, 0, -stockSize.z / 2)
        if let part, let mesh = renderer.scene.mesh("part") {
            let c = (part.boundsMin + part.boundsMax) / 2
            let w = mesh.transform * SIMD4(Float(c.x), Float(c.y), Float(c.z), 1)
            centre = SIMD3(Double(w.x), Double(w.y), Double(w.z))
        }
        let n: SIMD3<Double> = switch sectionAxis {
        case .x: SIMD3(1, 0, 0)
        case .y: SIMD3(0, 1, 0)
        case .z: SIMD3(0, 0, 1)
        }
        let d = simd_dot(n, centre) + sectionOffset
        renderer.scene.clipPlane = SIMD4(Float(n.x), Float(n.y), Float(n.z), Float(d))
        // Draw the cut plane itself (a translucent sheet with an outline) so the section
        // doesn't float in space. It sits a hair on the kept side so it isn't clipped.
        let half = max(stockSize.x, stockSize.y, stockSize.z, 40) * 0.75
        let at = centre + n * (sectionOffset - 0.02)
        let (u, v): (SIMD3<Double>, SIMD3<Double>) = switch sectionAxis {
        case .x: (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .y: (SIMD3(1, 0, 0), SIMD3(0, 0, 1))
        case .z: (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        }
        let corners = [at - u * half - v * half, at + u * half - v * half, at + u * half + v * half, at - u * half + v * half].map { SIMD3<Float>($0) }
        var p: [Float] = [], nn: [Float] = []
        for c in corners { p += [c.x, c.y, c.z]; nn += [Float(-n.x), Float(-n.y), Float(-n.z)] }
        if let quad = SceneMesh(device: renderer.device, id: "section.plane", positions: p, normals: nn, indices: [0, 1, 2, 0, 2, 3],
                                color: SceneColor.surface(0.9, alpha: 0.10)) {
            renderer.scene.setMesh(quad)
        }
        let edge = SceneColor.line(225)
        let segs = (0..<4).map { LineSegment(corners[$0], corners[($0 + 1) % 4], color: edge) }
        if let lines = SceneLines(device: renderer.device, id: "section.edges", segments: segs) { renderer.scene.setLines(lines) }
    }

    // MARK: Measuring

    /// Handles a click in the viewport while measuring.
    func handleClick(at point: CGPoint, viewSize: CGSize) {
        if fixturePlacement != nil { handlePlacementClick(point, size: viewSize); return }
        guard measuring else { return }
        let ray = renderer.ray(at: point, viewSize: viewSize)
        guard let hit = renderer.scene.pick(origin: ray.origin, direction: ray.direction), hit.id == "part" else {
            status = "Click on the part to measure"
            return
        }
        if measurePoints.count >= 2 { measurePoints.removeAll() }
        measurePoints.append(MeasurePoint(world: hit.world, info: nil))
        let index = measurePoints.count - 1
        refreshMeasureMarkers()
        guard let part, part.exact else { return }
        let local = hit.local
        Task {
            do {
                let engine = try await liveEngine()
                let info = try await engine.faceInfo(partID: part.partID, point: Vec3(Double(local.x), Double(local.y), Double(local.z)))
                if index < measurePoints.count { measurePoints[index].info = info }
            } catch {
                status = "Measuring failed: \(error)"
            }
        }
    }

    var measuredDistance: Double? {
        guard measurePoints.count == 2 else { return nil }
        return Double(simd_distance(measurePoints[0].world, measurePoints[1].world))
    }

    /// Distance per machine axis between the two points (work-frame axes).
    var measuredDelta: SIMD3<Double>? {
        guard measurePoints.count == 2 else { return nil }
        return SIMD3<Double>(measurePoints[1].world - measurePoints[0].world)
    }

    func clearMeasurements() {
        measurePoints.removeAll()
        refreshMeasureMarkers()
    }

    private func refreshMeasureMarkers() {
        renderer.scene.remove(id: "measure")
        guard !measurePoints.isEmpty else { return }
        var segs: [LineSegment] = []
        let s: Float = 1.5
        let colour = SceneColor.highlight
        for p in measurePoints {
            let w = p.world
            segs += [LineSegment(w - SIMD3(s, 0, 0), w + SIMD3(s, 0, 0), color: colour),
                     LineSegment(w - SIMD3(0, s, 0), w + SIMD3(0, s, 0), color: colour),
                     LineSegment(w - SIMD3(0, 0, s), w + SIMD3(0, 0, s), color: colour)]
        }
        if measurePoints.count == 2 {
            segs.append(LineSegment(measurePoints[0].world, measurePoints[1].world, color: colour))
        }
        if let set = SceneLines(device: renderer.device, id: "measure", segments: segs) { renderer.scene.setLines(set) }
    }

    // MARK: Session (restored on next launch)

    private struct Session: Codable {
        var partPath: String?
        var setup: Setup
        var stockID: UUID?
        var machine: PlanningMachineReference? = nil
        var stock: StockItem? = nil
    }

    private static let sessionKey = "CoastlineSession"

    func saveSession() {
        // Automation runs never touch the user's saved session.
        guard ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil else { return }
        let s = Session(partPath: part?.url.path, setup: setup, stockID: stockID, machine: planningMachineReference, stock: stock)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.sessionKey) }
    }

    /// Restores the last part, stock and setup. Skipped during automation runs.
    /// The part the last session had open (for Continue on the start sheet).
    static var lastSessionPart: URL? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let s = try? JSONDecoder().decode(Session.self, from: data), let path = s.partPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func restoreSession() async {
        guard ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil,
              let data = UserDefaults.standard.data(forKey: Self.sessionKey),
              let s = try? JSONDecoder().decode(Session.self, from: data) else { return }
        do { try await restorePlanningMachine(s.machine ?? .legacy) }
        catch { errorMessage = error.localizedDescription; return }
        stockSnapshot = s.stock ?? s.stockID.flatMap(stockLookup)
        stockID = s.stockID
        if let path = s.partPath, FileManager.default.fileExists(atPath: path) {
            await importPart(URL(fileURLWithPath: path))
        }
        setup = s.setup
        await reloadSavedLibraryGeometry()
    }

    // MARK: Viewport stress test

    func loadStressToolpath(count: Int) {
        var segments: [LineSegment] = []
        segments.reserveCapacity(count)
        let levels = 200
        let perLevel = max(count / levels, 8)
        let base = workToModel(stockSize: stock.map { setup.stockSize($0) } ?? SIMD3(40, 60, 10))
        let o = SIMD3<Float>(base)
        var previous: SIMD3<Float>?
        for level in 0..<levels {
            let z = -Float(level) * 0.05
            let r = 18 + 6 * sin(Float(level) * 0.07)
            var levelStart: SIMD3<Float>?
            for i in 0..<perLevel where segments.count < count {
                let t0 = Float(i) / Float(perLevel) * 2 * .pi
                let t1 = Float(i + 1) / Float(perLevel) * 2 * .pi
                func p(_ t: Float) -> SIMD3<Float> {
                    let c = cos(t), s = sin(t)
                    return o + SIMD3(r * copysign(pow(abs(s), 0.5), s), 1.6 * r * copysign(pow(abs(c), 0.5), c), z)
                }
                if i == 0 { levelStart = p(t0) }
                let k = UInt8(min(255, 80 + level / 2))
                segments.append(LineSegment(p(t0), p(t1), color: SIMD4(46, k, 255, 255)))
            }
            if let prev = previous, let start = levelStart, segments.count < count {
                segments.append(LineSegment(prev, start, color: PathColor.lead))
            }
            previous = segments.last.map { SIMD3($0.b.0, $0.b.1, $0.b.2) }
        }
        if let set = SceneLines(device: renderer.device, id: "toolpath", segments: segments) {
            renderer.scene.setLines(set)
            toolpathSegments = set.count
        }
    }

    /// Generated results no longer match the inputs: drop them (paths, programs, simulation).
    func clearToolpathResults() {
        pause()
        inProcessSnapshots = [:]
        inProcessMeshes = [:]
        if !isGenerating { opGenState = [:] }
        programs = []
        libraryWorkholdingPlan = nil
        selectedLibraryStep = nil
        sideResults = []
        placedTabs = []
        placedTabZ = nil
        renderer.scene.remove(id: "tabs")
        timeline = ToolpathTimeline()
        inspected = nil
        for id in ["toolpath", "tool", "tool.shank", "simstock", "simstock.back", "simstock.walls", "simstock.loose", "clearance"] { renderer.scene.remove(id: id) }
        loosePieces = 0
        sideAFinalTask?.cancel()
        sideAFinal = nil
        sideAFinalKey = -1
        renderer.scene.mesh("stock")?.isVisible = true
        heightmap = nil
        toolpathSegments = 0
    }

}

extension Material {
    /// The swatch in linear RGB for the Metal viewport.
    var linearSwatch: SIMD3<Float> {
        let c = NSColor(swatch).usingColorSpace(.sRGB) ?? .gray
        func lin(_ v: CGFloat) -> Float { Float(pow(Double(v), 2.2)) }
        return SIMD3(lin(c.redComponent), lin(c.greenComponent), lin(c.blueComponent))
    }
}


extension simd_double4x4 {
    /// Single precision, for the GPU.
    var float: simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(columns.0), SIMD4<Float>(columns.1), SIMD4<Float>(columns.2), SIMD4<Float>(columns.3)))
    }
}


/// What Machinability depends on: when none of it changed, the findings are reused.
struct DFMCacheKey: Equatable {
    var analysisVersion: Int
    var named: [NamedFeature]
    var partID: String
    var setup: Setup
    var stock: StockItem?
    var inventory: Inventory
    var machine: MachineProfile
    var twoSided: Bool
    var room: SetupRoom?
}
