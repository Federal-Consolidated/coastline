import AppKit
import CoastlineCore
import Foundation
import simd
import Viewport

struct FixturePlacementSession {
    let id = UUID()
    var fixture: Fixture
    var selectedComponent: String?
    var pickingGrip = false
    var error: String?
    var loading = false
    var snapEnabled = true
    var snapLocks: [FixtureEdgeSnap.Constraint] = []
    var returnPage: SidebarItem
    var returnStage: JobStage
    var camera: OrbitCamera
}

struct FixturePlacementResume: Codable {
    var fixture: Fixture
    var selectedComponent: String?
    var returnPage: String
    var returnStage: Int
    var snapEnabled: Bool? = nil
    var machineContextVersion: Int? = nil
}

extension AppModel {
    static let placementMeshPrefix = "fixture.placement."

    var placementStockSize: SIMD3<Double>? { stock.map { setup.rawStockSize($0) } }
    var placementDragScale: Double { NSEvent.modifierFlags.contains(.option) ? 100 : 2 }

    func beginFixturePlacement(_ fixture: Fixture) async {
        guard part != nil, stock != nil else { errorMessage = "Load a part and choose stock, then place the fixture around it."; return }
        guard !isGenerating, !isPlanningJob, !isFindingPlans else { errorMessage = "Finish or cancel the current generation before placing a fixture."; return }
        guard !isSwitchingPlanningMachine else { errorMessage = "Wait for the selected machine to finish loading before placing a fixture."; return }
        pause(); measuring = false; inspecting = false; gumballPrompt = nil; bedSelection = nil
        var draft: Fixture
        do { draft = try preparedFixture(setup.fixtureAssemblies?.first { $0.id == fixture.id } ?? fixture) }
        catch { errorMessage = error.localizedDescription; return }
        var p = draft.planning ?? FixturePlanningProfile()
        if let size = placementStockSize {
            let nextSize = Vec3(size.x, size.y, size.z)
            if p.stockSize != nextSize { p.assemblyState?.mounted = false; p.gripDefinitionReviewed = false }
            p.stockSize = nextSize
        }
        p.enabled = true
        draft.planning = p
        let session = FixturePlacementSession(fixture: draft, returnPage: page, returnStage: stage, camera: renderer.destinationCamera)
        for mesh in renderer.scene.meshes where mesh.id.hasPrefix(Self.placementMeshPrefix) { renderer.scene.remove(id: mesh.id) }
        fixturePlacementGeometry = nil
        fixturePlacement = session
        page = .workspace; showInspector = true
        show(side: 0, stage: 0)
        if machineModel == nil { await loadMachine() }
        await reloadPlacementGeometry(centreUnconfigured: true)
        guard fixturePlacement?.id == session.id else { return }
        focusPlacementContext()
        status = draft.assembly?.bookends != nil ? "Slide a bookend along its T-slots, or select the side screw to release and advance it."
            : FixtureMechanism.has(draft.assembly) ? "\(draft.name) is fitted to the stock. Drag a clamp or screw to adjust it."
            : "Place \(draft.name) around the stock. Pick a piece; drag arrows to move and rings to rotate."
    }

    func reloadPlacementGeometry(centreUnconfigured: Bool = false) async {
        guard let session = fixturePlacement else { return }
        let machineReference = planningMachineReference
        fixturePlacementGeometry = nil
        for mesh in renderer.scene.meshes where mesh.id.hasPrefix(Self.placementMeshPrefix) { renderer.scene.remove(id: mesh.id) }
        renderer.scene.remove(id: "placement.snap")
        fixturePlacement?.snapLocks = []
        fixturePlacement?.error = nil
        fixturePlacement?.loading = session.fixture.modelPath != nil
        if session.fixture.modelPath == nil { layoutScene(); return }
        do {
            let (geometry, signature) = try await loadFixtureGeometry(session.fixture)
            guard fixturePlacement?.id == session.id, planningMachineReference == machineReference,
                  !isSwitchingPlanningMachine,
                  fixturePlacement?.fixture.modelPath == session.fixture.modelPath else { return }
            var draft = fixturePlacement!
            if let selected = draft.selectedComponent, !geometry.components.contains(where: { $0.id == selected }) { draft.selectedComponent = nil }
            var p = draft.fixture.planning ?? FixturePlanningProfile()
            if (p.componentModelSignature != nil && p.componentModelSignature != signature) || !geometry.placementsMatch(p) {
                p.componentPlacements = nil; p.gripDefinitionReviewed = false; p.workspacePlaced = false
            }
            p.componentModelSignature = signature; p.componentLayoutID = geometry.layoutID
            if draft.fixture.assembly?.bookends != nil {
                let solver = try bookendSolver(for: draft.fixture)
                var needsFitting = p.assemblyState?.mounted != true || p.workspacePlaced != true
                if !needsFitting {
                    // The machine may have changed since this job's last placement.
                    // Refit stale mounting datums instead of hiding the recovery controls.
                    do { try solver.validate(p) }
                    catch { needsFitting = true }
                }
                if needsFitting {
                    p = try solver.seat(p)
                    // Locks fix the digital arrangement; grip/load approval remains explicit.
                    p.assemblyState?.lockedComponents = [BookendSetup.fixed, BookendSetup.clamp]
                }
                draft.fixture.height = 0
                if draft.selectedComponent == nil { draft.selectedComponent = BookendSetup.pressure }
            } else if let mechanism = try mechanism(for: draft.fixture) {
                var needsFitting = p.assemblyState?.mounted != true || p.workspacePlaced != true
                if !needsFitting {
                    do { try mechanism.validate(p) } catch { needsFitting = true }
                }
                if needsFitting { p = try mechanism.seat(p) }
                draft.fixture.height = mechanism.height
                if draft.selectedComponent == nil { draft.selectedComponent = mechanism.controls.first?.componentID }
            } else if centreUnconfigured, !p.gripDefinitionReviewed, p.workspacePlaced != true, let size = placementStockSize {
                let b = geometry.bounds(profile: p), delta = SIMD3(0, 0, -size.z / 2) - (b.min + b.max) / 2
                p = p.moved(inWork: Vec3(delta.x, delta.y, delta.z))
            }
            p.workspacePlaced = true
            draft.fixture.planning = p; draft.error = nil; draft.loading = false
            fixturePlacementGeometry = geometry
            fixturePlacement = draft
        } catch {
            guard fixturePlacement?.id == session.id, planningMachineReference == machineReference else { return }
            fixturePlacement?.loading = false
            fixturePlacement?.error = error.localizedDescription
        }
    }

    func updatePlacementFixture(_ fixture: Fixture) {
        guard var session = fixturePlacement else { return }
        let changedModel = fixture.modelPath != session.fixture.modelPath
        session.fixture = fixture
        if changedModel { session.fixture.planning?.workspacePlaced = false }
        fixturePlacement = session
        if changedModel { Task { await reloadPlacementGeometry(centreUnconfigured: true); focusPlacementContext() } }
    }

    func setPlacementProfile(_ profile: FixturePlanningProfile) {
        guard var session = fixturePlacement, session.fixture.planning != profile else { return }
        var next = profile
        if placingBookends, var previous = session.fixture.planning {
            previous.gripDefinitionReviewed = false
            var comparison = next; comparison.gripDefinitionReviewed = false
            if previous != comparison { next.gripDefinitionReviewed = false }
        }
        session.fixture.planning = next
        session.snapLocks = []
        fixturePlacement = session
    }

    func selectPlacementComponent(_ id: String?) {
        guard var session = fixturePlacement else { return }
        session.selectedComponent = id; session.snapLocks = []
        fixturePlacement = session
    }

    func setPlacementSnapping(_ enabled: Bool) {
        guard var session = fixturePlacement else { return }
        session.snapEnabled = enabled; session.snapLocks = []
        fixturePlacement = session
    }

    func movePlacement(_ delta: SIMD3<Double>, from start: FixturePlanningProfile? = nil, componentID: String? = nil,
                       useSelection: Bool = true, snapViewSize: CGSize? = nil, snapAxes: Set<Int> = [0, 1, 2]) {
        guard let geometry = fixturePlacementGeometry, let session = fixturePlacement, let profile = start ?? session.fixture.planning,
              [delta.x, delta.y, delta.z].allSatisfy({ $0.isFinite && abs($0) < 100_000 }) else { return }
        let id = useSelection ? session.selectedComponent : componentID
        if session.fixture.assembly?.bookends != nil {
            guard let id else { return }
            do {
                let solver = try bookendSolver(for: session.fixture)
                let next = id == BookendSetup.pressure
                    ? try solver.settingPressure(profile, to: solver.value(profile, jointID: BookendSetup.pressureExtension) - delta.y)
                    : try solver.sliding(profile, componentID: id, to: solver.value(profile, jointID: id == BookendSetup.fixed ? BookendSetup.fixedSlide : BookendSetup.clampSlide) + delta.y)
                setPlacementProfile(next); fixturePlacement?.error = nil
            } catch { fixturePlacement?.error = error.localizedDescription }
            return
        }
        if FixtureMechanism.has(session.fixture.assembly) {
            guard let id else { return }
            do {
                guard let mechanism = try mechanism(for: session.fixture),
                      let control = mechanism.controls.first(where: { $0.componentID == id }),
                      let joint = session.fixture.assembly?.components.first(where: { $0.id == id })?.joint else { return }
                let along = delta.x * joint.axis.x + delta.y * joint.axis.y + delta.z * joint.axis.z
                setPlacementProfile(try mechanism.setting(profile, joint: control.id, to: mechanism.value(profile, joint: control.id) + along))
                fixturePlacement?.error = nil
            } catch { fixturePlacement?.error = error.localizedDescription }
            return
        }
        let moved = geometry.moved(profile, componentID: id, by: delta)
        var next = session
        if let size = snapViewSize, session.snapEnabled, !NSEvent.modifierFlags.contains(.option), let stock = placementStockSize {
            let result = FixtureEdgeSnap.snap(moved, geometry: geometry, componentID: id, stock: stock, axes: snapAxes,
                tolerance: placementSnapTolerance(size), previous: session.snapLocks)
            next.fixture.planning = result.profile; next.snapLocks = result.constraints
        } else {
            next.fixture.planning = moved; next.snapLocks = []
        }
        fixturePlacement = next
    }

    private func placementSnapTolerance(_ viewSize: CGSize) -> SIMD3<Double> {
        guard let size = placementStockSize, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let group = renderer.scene.groupTransform("x")
        let o = group * SIMD4(SIMD3<Float>(workToModel(stockSize: size)), 1)
        let origin = SIMD3(o.x, o.y, o.z)
        guard let start = project(origin, viewSize) else { return .zero }
        var tolerance = SIMD3<Double>(repeating: 0)
        for axis in 0..<3 {
            var unit = SIMD4<Float>(repeating: 0); unit[axis] = 1
            let v = group * unit
            guard let end = project(origin + SIMD3(v.x, v.y, v.z), viewSize) else { continue }
            let pixels = hypot(end.x - start.x, end.y - start.y)
            // Eight screen points to catch; thirteen to release. Do not snap along an
            // axis viewed end-on, where a small cursor movement means a huge depth jump.
            if pixels > 0.05 { tolerance[axis] = min(8 / pixels, 20) }
        }
        return tolerance
    }

    func snapPlacementToStock() {
        if placingBookends || placingMechanism { seatPlacementBookends(); return }
        guard let session = fixturePlacement, let p = session.fixture.planning, let geometry = fixturePlacementGeometry,
              let stock = placementStockSize else { return }
        let result = FixtureEdgeSnap.snap(p, geometry: geometry, componentID: session.selectedComponent,
            stock: stock, tolerance: SIMD3(repeating: 3))
        var next = session; next.fixture.planning = result.profile; next.snapLocks = result.constraints
        fixturePlacement = next
        status = result.constraints.isEmpty ? "Move the selected piece closer to a stock edge, then snap again." : "Snapped to " + result.constraints.map(\.label).joined(separator: ", ")
    }

    func focusPlacementContext() { focusWork(machineContext: true) }

    func rotatePlacement(axis: Int, turns: Int, from start: FixturePlanningProfile? = nil, componentID: String? = nil, useSelection: Bool = true) {
        guard !placingBookends, !placingMechanism else { return }
        guard let geometry = fixturePlacementGeometry, let session = fixturePlacement, let profile = start ?? session.fixture.planning else { return }
        setPlacementProfile(geometry.turned(profile, componentID: useSelection ? session.selectedComponent : componentID, axis: axis, quarterTurns: turns % 4))
    }

    func centrePlacementOnStock() {
        if placingBookends || placingMechanism { seatPlacementBookends(); return }
        guard let geometry = fixturePlacementGeometry, let p = fixturePlacement?.fixture.planning, let size = placementStockSize else { return }
        let b = geometry.bounds(profile: p)
        let delta = SIMD3(0, 0, -size.z / 2) - (b.min + b.max) / 2
        setPlacementProfile(p.moved(inWork: Vec3(delta.x, delta.y, delta.z)))
        focusPlacementContext()
    }

    func alignPlacementPair() {
        if placingBookends || placingMechanism { seatPlacementBookends(); return }
        guard let geometry = fixturePlacementGeometry, let p = fixturePlacement?.fixture.planning, let size = placementStockSize else { return }
        setPlacementProfile(geometry.alignedPair(p, stock: size))
        focusPlacementContext()
        status = "Pair aligned by its bounding faces. Adjust the actual gripping faces and hardware, then mark the stock's grip patches."
    }

    func finishFixturePlacement(save: Bool, inventory: InventoryModel) {
        guard let session = fixturePlacement else { return }
        if save {
            guard let geometry = fixturePlacementGeometry, let p = session.fixture.planning, geometry.placementsMatch(p) else {
                fixturePlacement?.error = "Load the assembly model before saving its placement."; return
            }
            guard let path = session.fixture.modelPath,
                  (try? fixtureModelSignature(fixtureModelURL(path))) == p.componentModelSignature else {
                fixturePlacement?.error = "The CAD model changed while placing it. Reload the model before saving."; return
            }
            guard let owned = inventory.inventory.fixtures.first(where: { $0.id == session.fixture.id }), owned.quantity > 0 else {
                fixturePlacement?.error = "This fixture was removed from the library."; return
            }
            let definitionIssues = p.definitionIssues + (session.fixture.assembly?.planningIssues ?? [])
            guard definitionIssues.isEmpty else {
                fixturePlacement?.error = definitionIssues.joined(separator: " "); return
            }
            if session.fixture.assembly?.bookends != nil {
                do {
                    let solver = try bookendSolver(for: session.fixture)
                    try solver.validate(p); try geometry.validate(profile: p)
                    let issues = solver.planningIssues(p)
                    guard issues.isEmpty else { fixturePlacement?.error = issues.joined(separator: " "); return }
                }
                catch { fixturePlacement?.error = error.localizedDescription; return }
            } else if FixtureMechanism.has(session.fixture.assembly) {
                do {
                    guard let mechanism = try mechanism(for: session.fixture) else { return }
                    try mechanism.validate(p); try geometry.validate(profile: p)
                    let issues = mechanism.planningIssues(p)
                    guard issues.isEmpty else { fixturePlacement?.error = issues.joined(separator: " "); return }
                }
                catch { fixturePlacement?.error = error.localizedDescription; return }
            }
            var used = session.fixture
            used.quantity = owned.quantity
            var savedSetup = setup.selectingHolding(.custom)
            savedSetup.planFromFixtureLibrary = true
            savedSetup.fixtureAssemblies = (savedSetup.fixtureAssemblies ?? []).filter { $0.id != used.id } + [used]
            var selected = savedSetup.selectedFixtureIDs ?? []
            if !selected.contains(used.id) { selected.append(used.id) }
            savedSetup.selectedFixtureIDs = selected
            setup = savedSetup
            clearToolpathResults()
            libraryFixtureMeshes[fixtureStateKey(used)] = geometry.workMesh(profile: p)
        }
        fixturePlacement = nil; fixturePlacementGeometry = nil
        for mesh in renderer.scene.meshes where mesh.id.hasPrefix("placement.grip.") { renderer.scene.remove(id: mesh.id) }
        renderer.scene.remove(id: "placement.snap")
        gumballDrag = nil; gumballPrompt = nil
        if save {
            enter(.clampKit); page = .workspace
        } else {
            enter(session.returnStage); page = session.returnPage
            renderer.moveCamera(animated: false) { $0 = session.camera }
        }
        status = save ? "\(session.fixture.name) is selected for this job. Continue to Plan to check the part and build the cuts." : "Workholding selection cancelled."
    }

    var placingBookends: Bool { fixturePlacement?.fixture.assembly?.bookends != nil }
    /// A reviewed mechanism other than the bookends: C-clamps, a vise.
    var placingMechanism: Bool { !placingBookends && FixtureMechanism.has(fixturePlacement?.fixture.assembly) }
    var placementMechanism: FixtureMechanism? { fixturePlacement.flatMap { try? mechanism(for: $0.fixture) } }

    /// The axis a mechanism piece moves along (0 X, 1 Y, 2 Z), nil when it doesn't move.
    func mechanismAxis(_ id: String?) -> Int? {
        guard let id, placementMechanism?.controls.contains(where: { $0.componentID == id }) == true,
              let a = fixturePlacement?.fixture.assembly?.components.first(where: { $0.id == id })?.joint?.axis else { return nil }
        let v = [abs(a.x), abs(a.y), abs(a.z)]
        return v.firstIndex(of: v.max()!)
    }

    func setPlacementJoint(_ joint: String, to value: Double) {
        guard let session = fixturePlacement, let profile = session.fixture.planning else { return }
        do {
            guard let mechanism = try mechanism(for: session.fixture) else { return }
            setPlacementProfile(try mechanism.setting(profile, joint: joint, to: value)); fixturePlacement?.error = nil
        } catch { fixturePlacement?.error = error.localizedDescription }
    }

    func bookendSolver(for fixture: Fixture) throws -> BookendSetup {
        guard let assembly = fixture.assembly else {
            throw BookendSetup.PlacementError.invalid("Reload the Bookends model to restore its mounting definition.")
        }
        guard let stock = placementStockSize else {
            throw BookendSetup.PlacementError.invalid("Choose the stock block for this job first.")
        }
        guard !isSwitchingPlanningMachine else {
            throw BookendSetup.PlacementError.invalid("Loading \(planningMachineTitle)…")
        }
        guard let table = bookendMountTable else {
            let message = planningMachineReference.isLegacy
                ? "This job still uses an older machine definition without table mounting data. Apply your machine profile below."
                : "\(planningMachineTitle) does not provide compatible table slots for these Bookends."
            throw BookendSetup.PlacementError.invalid(message)
        }
        return try BookendSetup(assembly: assembly, table: table, stock: stock)
    }

    var placementBookendSolver: BookendSetup? {
        guard let fixture = fixturePlacement?.fixture else { return nil }
        return try? bookendSolver(for: fixture)
    }

    func canMoveBookendComponent(_ id: String?) -> Bool {
        guard let id, fixturePlacement?.fixture.planning?.assemblyState?.mounted == true else { return false }
        if id == BookendSetup.pressure { return true }
        return [BookendSetup.fixed, BookendSetup.clamp].contains(id) && fixturePlacement?.fixture.planning?.assemblyState?.lockedComponents.contains(id) != true
    }

    func seatPlacementBookends() {
        guard var session = fixturePlacement, let p = session.fixture.planning else { return }
        do {
            guard let mechanism = try mechanism(for: session.fixture) else { return }
            session.fixture.planning = try mechanism.seat(p)
            session.fixture.height = mechanism.height; session.error = nil; session.snapLocks = []
            fixturePlacement = session
            status = "\(session.fixture.name) fitted to the stock. Review the grip before using this setup."
        } catch { fixturePlacement?.error = error.localizedDescription }
    }

    func setBookendBaseLocked(_ id: String, locked: Bool) {
        guard [BookendSetup.fixed, BookendSetup.clamp].contains(id), var p = fixturePlacement?.fixture.planning,
              p.assemblyState?.mounted == true else { return }
        if locked { p.assemblyState?.lockedComponents.insert(id) }
        else { p.assemblyState?.lockedComponents.remove(id); p.gripDefinitionReviewed = false }
        setPlacementProfile(p)
    }

    func setBookendPressure(_ value: Double) {
        guard let session = fixturePlacement, let profile = session.fixture.planning else { return }
        do { setPlacementProfile(try bookendSolver(for: session.fixture).settingPressure(profile, to: value)); fixturePlacement?.error = nil }
        catch { fixturePlacement?.error = error.localizedDescription }
    }

    func placementGumballOrigin(_ id: String?) -> SIMD3<Float>? {
        guard let g = fixturePlacementGeometry, let p = fixturePlacement?.fixture.planning, let size = placementStockSize else { return nil }
        let b = g.bounds(profile: p, componentID: id), centre = (b.min + b.max) / 2
        guard centre.x.isFinite else { return nil }
        let world = renderer.scene.groupTransform("x") * SIMD4(SIMD3<Float>(centre + workToModel(stockSize: size)), 1)
        return SIMD3(world.x, world.y, world.z)
    }

    func pickPlacementComponent(_ point: CGPoint, size: CGSize) -> (String, SIMD3<Float>)? {
        let ray = renderer.ray(at: point, viewSize: size)
        guard let hit = renderer.scene.pick(origin: ray.origin, direction: ray.direction), hit.id.hasPrefix(Self.placementMeshPrefix) else { return nil }
        let id = String(hit.id.dropFirst(Self.placementMeshPrefix.count))
        guard fixturePlacementGeometry?.components.contains(where: { $0.id == id }) == true else { return nil }
        return (id, hit.world)
    }

    func handlePlacementClick(_ point: CGPoint, size: CGSize) {
        guard let session = fixturePlacement else { return }
        if session.pickingGrip { pickPlacementGrip(point, size: size); return }
        if let (id, _) = pickPlacementComponent(point, size: size) { selectPlacementComponent(id) }
    }

    private func pickPlacementGrip(_ point: CGPoint, size: CGSize) {
        guard let stockSize = placementStockSize, var p = fixturePlacement?.fixture.planning else { return }
        let ray = renderer.ray(at: point, viewSize: size)
        let inv = renderer.scene.groupTransform("x").inverse
        let a = inv * SIMD4(ray.origin, 1), b = inv * SIMD4(ray.direction, 0)
        let ro = SIMD3<Double>(SIMD3(a.x, a.y, a.z)) - workToModel(stockSize: stockSize)
        let rd = SIMD3<Double>(SIMD3(b.x, b.y, b.z))
        let lo = SIMD3(-stockSize.x / 2, -stockSize.y / 2, -stockSize.z), hi = SIMD3(stockSize.x / 2, stockSize.y / 2, 0)
        var near = -Double.infinity, far = Double.infinity, face = 2
        for axis in 0..<3 {
            if abs(rd[axis]) < 1e-9 { if ro[axis] < lo[axis] || ro[axis] > hi[axis] { return }; continue }
            let x = (lo[axis] - ro[axis]) / rd[axis], y = (hi[axis] - ro[axis]) / rd[axis]
            let enter = min(x, y), leave = max(x, y)
            if enter > near { near = enter; face = axis }
            far = min(far, leave)
        }
        guard near >= 0, near <= far else { status = "Click a face of the stock to mark a grip patch."; return }
        let point = ro + rd * near
        var patch = FixturePlanningProfile.Contact(point: Vec3(point.x, point.y, point.z), radius: 1)
        patch.normal = face == 0 ? .x : face == 1 ? .y : .z
        p.contacts.append(patch); p.gripDefinitionReviewed = false
        fixturePlacement?.pickingGrip = false
        setPlacementProfile(p)
        status = "Grip patch added. Check its radius and location in the inspector."
    }

    /// Uses the same per-piece transforms that prepareLibraryFixtures sends to CAM checks.
    func layoutFixturePlacement(stockSize: SIMD3<Double>) {
        let scene = renderer.scene
        for mesh in scene.meshes where mesh.id.hasPrefix("fixture.") { mesh.isVisible = false }
        for mesh in scene.meshes where mesh.id.hasPrefix("placement.grip.") { scene.remove(id: mesh.id) }
        scene.remove(id: "placement.snap")
        guard let session = fixturePlacement, let geometry = fixturePlacementGeometry, let p = session.fixture.planning else { return }
        let origin = simd_double4x4(translation: workToModel(stockSize: stockSize))
        for component in geometry.components {
            let id = Self.placementMeshPrefix + component.id
            if scene.mesh(id) == nil {
                let m = component.mesh
                if let model = SceneMesh(device: renderer.device, id: id, positions: m.vertices, normals: m.normals, indices: m.indices,
                    color: SceneColor.part, pickable: true) { scene.setMesh(model) }
            }
            if let model = scene.mesh(id) {
                model.group = "x"
                model.transform = (origin * geometry.transform(component, profile: p)).float
                model.color = component.id == session.selectedComponent ? SIMD4(0.2, 0.5, 0.95, 1) : SIMD4(0.65, 0.68, 0.72, 1)
                model.isVisible = true
            }
        }
        for contact in p.contacts {
            let centre = SIMD3(contact.point.x, contact.point.y, contact.point.z) + workToModel(stockSize: stockSize)
            let r = Float(min(max(contact.radius, 0.3), 3))
            if let marker = SceneMesh.box(device: renderer.device, id: "placement.grip.\(contact.id)", min: SIMD3<Float>(centre) - SIMD3(repeating: r),
                max: SIMD3<Float>(centre) + SIMD3(repeating: r), color: SIMD4(0.1, 0.5, 1, 1)) {
                marker.group = "x"; marker.onTop = true; scene.setMesh(marker)
            }
        }
        layoutPlacementSnapGuides(stockSize: stockSize)
    }

    private func layoutPlacementSnapGuides(stockSize s: SIMD3<Double>) {
        renderer.scene.remove(id: "placement.snap")
        guard let locks = fixturePlacement?.snapLocks, !locks.isEmpty else { return }
        let lo = SIMD3(-s.x / 2, -s.y / 2, -s.z), hi = SIMD3(s.x / 2, s.y / 2, 0)
        let origin = workToModel(stockSize: s)
        var segments: [LineSegment] = []
        for lock in locks {
            let axes = (0..<3).filter { $0 != lock.axis }
            var corners: [SIMD3<Float>] = []
            for (a, b) in [(false, false), (true, false), (true, true), (false, true)] {
                var p = lo
                p[lock.axis] = lock.upper ? hi[lock.axis] : lo[lock.axis]
                p[axes[0]] = a ? hi[axes[0]] : lo[axes[0]]
                p[axes[1]] = b ? hi[axes[1]] : lo[axes[1]]
                corners.append(SIMD3<Float>(p + origin))
            }
            for i in 0..<4 { segments.append(LineSegment(corners[i], corners[(i + 1) % 4], color: SIMD4(80, 170, 255, 255))) }
        }
        if let lines = SceneLines(device: renderer.device, id: "placement.snap", segments: segments) {
            lines.group = "x"; lines.xray = 0.7; renderer.scene.setLines(lines)
        }
    }
}
