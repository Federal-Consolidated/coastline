import CoastlineCore
import CryptoKit
import Foundation
import simd
import Viewport

extension AppModel {
    var libraryJobSteps: [JobStep] {
        guard let plan = libraryWorkholdingPlan else { return [] }
        var out: [JobStep] = []
        let checks = checkpoints()
        for step in plan.steps {
            let chapter = JobChapter(id: "library.\(step.id)", title: step.title, side: step.side)
            out.append(JobStep(id: "library.\(step.id)", kind: .setup, number: out.count + 1,
                               title: step.title, detail: "Secure stock in \(step.fixture.name), verify grip and reset work zero.",
                               symbol: "hand.raised", side: step.side, chapter: chapter))
            for program in programs where program.workholdingStep?.id == step.id {
                out.append(JobStep(id: "p\(program.index)", kind: .program, number: out.count + 1,
                                   title: program.tool.name, detail: program.opsTitle, symbol: "wrench.and.screwdriver",
                                   side: step.side, program: program.index, minutes: program.seconds / 60, chapter: chapter))
                for (index, check) in checks.enumerated() where check.afterProgram == program.index {
                    out.append(JobStep(id: "lc\(program.index).\(index)", kind: .measure, number: out.count + 1,
                                       title: "Measure", detail: check.what, symbol: "ruler", side: step.side,
                                       program: program.index, checkpoint: check, chapter: chapter))
                }
            }
        }
        if let step = plan.steps.last {
            out.append(JobStep(id: "finish", kind: .finish, number: out.count + 1, title: "Finish", detail: "Unclamp and deburr",
                               symbol: "scissors", side: step.side, chapter: JobChapter(id: "library.finish", title: "Finish", side: step.side)))
        }
        return out
    }
    var currentLibraryStep: LibraryWorkholdingPlan.Step? {
        guard setup.planFromFixtureLibrary, let plan = libraryWorkholdingPlan else { return nil }
        return plan.steps.first { $0.id == selectedLibraryStep } ?? plan.steps.first { $0.side == max(viewSide, 0) } ?? plan.steps.first
    }

    /// Keep the chosen assembly visible while designing a job, before CAM creates steps.
    /// This display choice does not establish eligibility or approve the physical setup.
    var displayedJobFixture: Fixture? {
        if let step = currentLibraryStep { return step.fixture }
        guard setup.planFromFixtureLibrary, let stock else { return nil }
        let size = setup.stockSize(stock)
        let snapshots = setup.fixtureAssemblies ?? []
        let candidates = automaticWorkholding ? automaticPreviewFixtures : setup.selectedFixtureIDs.map { ids in
            ids.compactMap { id in snapshots.first { $0.id == id } }
        } ?? snapshots
        return candidates.first { fixture in
            guard let profile = fixture.planning else { return false }
            let defined = SIMD3(profile.stockSize.x, profile.stockSize.y, profile.stockSize.z)
            return simd_distance(defined, size) <= 0.1
        }
    }

    func enableLibraryPlanning() {
        choose(.custom)
        var s = setup
        s.planFromFixtureLibrary = true
        setup = s
        twoSidedChosen = false
        if let analysis { chooseSides(analysis) }
        status = "Automatic setups from your fixture library. Find a CAM plan, then Generate to compare the actual cuts with your fixtures."
    }

    func fixtureModelURL(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : Self.repoRoot.appendingPathComponent("resources").appendingPathComponent(path)
    }

    func libraryOrigin(fixture: Fixture, stock s: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(prepTable.topX + fixture.height + s.x / 2, travelCentreY,
              prepTable.northZ + (fixture.planning?.facePastTable ?? 0))
    }

    /// Machine coordinates of stock zero with zero tool stick-out. The planner subtracts
    /// each operation's actual stick-out, so one fixture is checked with every tool used.
    func libraryMachineOrigin(fixture: Fixture, stock: SIMD3<Double>) -> SIMD3<Double>? {
        guard let mm = machineModel else { return nil }
        let o = libraryOrigin(fixture: fixture, stock: stock), tip = tipAtModelPose(stickout: 0)
        return SIMD3(mm.modelPose.x - tip.x + o.x, mm.modelPose.y + o.y - tip.y, mm.modelPose.z + o.z - tip.z)
    }

    /// - turned: the stock's size in the job's turned setups (side setups): automatic
    ///   workholding fits each fixture to those too, as further candidates.
    func prepareLibraryFixtures(inventory: Inventory, stock base: SIMD3<Double>, turned: [SIMD3<Double>] = [],
                                useJobSnapshots: Bool = true) async throws -> [LibraryWorkholdingPlanner.Candidate] {
        let machineReference = planningMachineReference
        let inputSignature = generationSignature
        func checkCurrentInputs() throws {
            guard planningMachineReference == machineReference, generationSignature == inputSignature,
                  !isSwitchingPlanningMachine else { throw CancellationError() }
        }
        libraryFixtureFields = [:]
        var candidates: [LibraryWorkholdingPlanner.Candidate] = []
        var rejected: [String] = []
        if machineModel == nil { await loadMachine() }
        guard let machineTree = await machineCollisionTree() else {
            throw EngineClient.EngineError(type: "Machine", message: "Load the machine geometry before planning library fixtures.")
        }
        try checkCurrentInputs()
        let fixtures = useJobSnapshots ? jobFixtureInventory(inventory).fixtures : inventory.fixtures
        var pairs = fixtures.map { ($0, base) }
        if useJobSnapshots, automaticWorkholding {
            var sizes: [SIMD3<Double>] = []
            for t in turned where simd_length(t - base) > 0.1 && !sizes.contains(where: { simd_length($0 - t) < 0.1 }) { sizes.append(t) }
            for t in sizes { pairs += automaticFixtures(inventory, stockSize: t).fitted.map { ($0, t) } }
        } else if !useJobSnapshots {
            // Saved plans: each fixture snapshot holds the stock size it was fitted to.
            pairs = fixtures.map { f in (f, f.planning.map { SIMD3($0.stockSize.x, $0.stockSize.y, $0.stockSize.z) } ?? base) }
        }
        for (fixture, s) in pairs where fixture.quantity > 0 {
            let issues = LibraryWorkholdingPlanner.eligibility(fixture, stock: s)
            guard issues.isEmpty, let profile = fixture.planning, fixture.modelPath != nil else {
                rejected.append("\(fixture.name): \(issues.joined(separator: " "))")
                continue
            }
            do {
                let (geometry, signature) = try await loadFixtureGeometry(fixture)
                try checkCurrentInputs()
                try geometry.validate(profile: profile)
                if FixtureMechanism.has(fixture.assembly) {
                    guard let table = bookendMountTable,
                          let mechanism = try FixtureMechanism.make(fixture, table: table, stock: s),
                          abs(fixture.height - mechanism.height) < 0.001 else {
                        throw EngineClient.EngineError(type: "Fixture", message: "\(fixture.name) needs the machine's measured table, with the stock seated as fitted.")
                    }
                    let issues = mechanism.planningIssues(profile)
                    guard issues.isEmpty else { throw EngineClient.EngineError(type: "Fixture", message: issues.joined(separator: " ")) }
                }
                let solids = geometry.solids
                let hasSavedPlacement = profile.workspacePlaced == true || !(profile.componentPlacements ?? []).isEmpty
                guard geometry.placementsMatch(profile), !hasSavedPlacement || profile.componentModelSignature == signature else {
                    throw EngineClient.EngineError(type: "Fixture", message: "The CAD assembly changed. Place its pieces in the workspace again before planning.")
                }
                libraryFixtureGeometries[fixture.id] = geometry
                libraryFixtureGeometrySignatures[fixture.id] = signature
                let placedMesh = geometry.workMesh(profile: profile)
                let stateKey = fixtureStateKey(fixture)
                libraryFixtureMeshes[stateKey] = placedMesh
                let origin = libraryOrigin(fixture: fixture, stock: s), table = prepTable
                let centre = travelCentreY
                guard let machineOrigin = libraryMachineOrigin(fixture: fixture, stock: s) else {
                    throw EngineClient.EngineError(type: "Machine", message: "The machine placement isn't available.")
                }
                let envelope = machine.machineEnvelope
                let regionMin = SIMD2(envelope.x.lowerBound - machineOrigin.x - 24, envelope.y.lowerBound - machineOrigin.y - 24)
                let regionMax = SIMD2(envelope.x.upperBound - machineOrigin.x + 24, envelope.y.upperBound - machineOrigin.y + 24)
                let built = await Task.detached(priority: .userInitiated) {
                    var triangles: [SIMD3<Double>] = []
                    triangles.reserveCapacity(placedMesh.indices.count + 36)
                    for index in placedMesh.indices {
                        let i = Int(index) * 3
                        triangles.append(SIMD3(Double(placedMesh.vertices[i]), Double(placedMesh.vertices[i + 1]), Double(placedMesh.vertices[i + 2])))
                    }
                    let fixtureTriangles = triangles
                    var bodies = [Collision.Body(name: fixture.name, triangles: triangles.map { $0 + origin })]
                    bodies.append(.init(name: "machine", tree: machineTree))
                    let collisions = Collision.check(bodies, tolerance: 0.2)
                    let cell = max(0.2, max(s.x, s.y) / 400)
                    var occupied = DexelGrid(min: SIMD2(-s.x / 2, -s.y / 2), max: SIMD2(s.x / 2, s.y / 2), cell: cell)
                    for (index, solid) in solids.enumerated() where geometry.physicalSolidIndices.contains(index) {
                        let transform = geometry.solidTransform(index, profile: profile)
                        var vertices: [Float] = []
                        vertices.reserveCapacity(solid.vertices.count)
                        for i in stride(from: 0, to: solid.vertices.count, by: 3) {
                            let p = transform * SIMD4(Double(solid.vertices[i]), Double(solid.vertices[i + 1]), Double(solid.vertices[i + 2]), 1)
                            vertices += [Float(p.x), Float(p.y), Float(p.z)]
                        }
                        var body = DexelGrid(min: SIMD2(-s.x / 2, -s.y / 2), max: SIMD2(s.x / 2, s.y / 2), cell: cell)
                        body.fill(vertices: vertices, indices: solid.indices)
                        for i in body.spans.indices {
                            for span in body.spans[i] { occupied.add(i, span.x, span.y) }
                        }
                    }
                    triangles += FixtureField.boxTriangles(
                        min: SIMD3(table.topX - table.thickness, table.minimumY ?? (centre - 200), table.backZ) - origin,
                        max: SIMD3(table.topX, table.maximumY ?? (centre + 200), table.northZ) - origin)
                    return (FixtureField(triangles: triangles, regionMin: regionMin,
                                        regionMax: regionMax), fixtureTriangles, collisions, occupied)
                }.value
                try checkCurrentInputs()
                guard built.2.isEmpty else {
                    throw EngineClient.EngineError(type: "Placement", message: "The fixture placement intersects the machine: " + built.2.map { "\($0.a) × \($0.b)" }.joined(separator: ", "))
                }
                let field = built.0
                libraryFixtureTriangles[stateKey] = built.1
                libraryFixtureFields[stateKey] = field
                candidates.append(.init(fixture: fixture, field: field, occupied: built.3, machineOrigin: libraryMachineOrigin(fixture: fixture, stock: s), modelSignature: signature))
            } catch is CancellationError { throw CancellationError() }
            catch { rejected.append("\(fixture.name): couldn't load its CAD model (\(error)).") }
        }
        guard !candidates.isEmpty else {
            throw EngineClient.EngineError(type: "Workholding", message: "No eligible fixture for this stock. Open Fixtures and define an assembled stock size, datum, and reviewed grip patches.\n" + rejected.joined(separator: "\n"))
        }
        return candidates
    }

    func reloadSavedLibraryGeometry() async {
        guard setup.planFromFixtureLibrary, let stock else { return }
        guard let plan = libraryWorkholdingPlan else {
            await reloadSelectedFixturePreview()
            return
        }
        let inputSignature = generationSignature
        let machineReference = planningMachineReference
        var inv = Inventory()
        inv.fixtures = plan.steps.map(\.fixture).reduce(into: [Fixture]()) { result, fixture in
            if !result.contains(fixture) { result.append(fixture) }
        }
        do {
            _ = try await prepareLibraryFixtures(inventory: inv, stock: setup.stockSize(stock), useJobSnapshots: false)
            guard generationSignature == inputSignature, planningMachineReference == machineReference else { return }
            layoutScene()
        } catch is CancellationError { return }
        catch {
            guard generationSignature == inputSignature, planningMachineReference == machineReference else { return }
            errorMessage = "Saved workholding geometry couldn't be rechecked: \(error)"
        }
    }

    /// Restore only the saved assembly mesh; full cut/fixture checks still run during CAM.
    func reloadSelectedFixturePreview() async {
        guard let fixture = displayedJobFixture, let profile = fixture.planning else { return }
        let key = fixtureStateKey(fixture), inputSignature = generationSignature
        let machineReference = planningMachineReference
        func isCurrent() -> Bool {
            planningMachineReference == machineReference && generationSignature == inputSignature
                && !isSwitchingPlanningMachine && fixturePlacement == nil && libraryWorkholdingPlan == nil
                && displayedJobFixture.map(fixtureStateKey) == key
        }
        do {
            if machineModel == nil { await loadMachine() }
            guard isCurrent() else { return }
            let (geometry, signature) = try await loadFixtureGeometry(fixture)
            guard isCurrent() else { return }
            try geometry.validate(profile: profile)
            guard geometry.placementsMatch(profile), profile.componentModelSignature == signature else {
                throw EngineClient.EngineError(type: "Fixture", message: "The saved fixture CAD changed. Review its placement again.")
            }
            if let mechanism = try mechanism(for: fixture) { try mechanism.validate(profile) }
            libraryFixtureMeshes[key] = geometry.workMesh(profile: profile)
            layoutScene()
        } catch is CancellationError { return }
        catch {
            guard isCurrent() else { return }
            libraryFixtureMeshes.removeValue(forKey: key)
            libraryFixtureTriangles.removeValue(forKey: key)
            layoutScene()
            errorMessage = "Saved workholding preview couldn't be loaded: \(error.localizedDescription)"
        }
    }

    func fixtureModelSignature(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func validateLibraryPlanForExport() throws {
        guard fixturePlacement == nil else {
            throw EngineClient.EngineError(type: "Workholding", message: "Save or cancel fixture placement before exporting or running.")
        }
        guard setup.planFromFixtureLibrary else { return }
        guard let plan = libraryWorkholdingPlan, plan.reviewed,
              programs.allSatisfy({ program in
                  program.workholdingStep.map { step in plan.steps.contains { $0.id == step.id } } ?? false
              }) else {
            throw EngineClient.EngineError(type: "Workholding", message: "Review every proposed fixture setup before exporting or running.")
        }
        for step in plan.steps {
            if let assembly = step.fixture.assembly, !assembly.planningIssues.isEmpty {
                throw EngineClient.EngineError(type: "Workholding", message: assembly.planningIssues.joined(separator: " "))
            }
            guard let path = step.fixture.modelPath, let signature = step.modelSignature,
                  try fixtureModelSignature(fixtureModelURL(path)) == signature else {
                throw EngineClient.EngineError(type: "Workholding", message: "The model for \(step.fixture.name) is missing or changed. Generate and review the setup sequence again.")
            }
            guard let owned = fixtureLookup(step.fixture.id), owned.quantity > 0 else {
                throw EngineClient.EngineError(type: "Workholding", message: "\(step.fixture.name) is not currently marked as owned.")
            }
            let fitted = automaticWorkholding ? automaticPreviewFixtures.first { $0.id == step.fixture.id } : nil
            var current = fitted ?? setup.fixtureAssemblies?.first { $0.id == step.fixture.id } ?? owned
            current.quantity = step.fixture.quantity
            guard current == step.fixture else {
                throw EngineClient.EngineError(type: "Workholding", message: "\(step.fixture.name)'s library definition changed. Generate and review the setup sequence again.")
            }
        }
    }

    func reviewLibraryStep(_ id: UUID, reviewed: Bool) {
        guard let i = libraryWorkholdingPlan?.steps.firstIndex(where: { $0.id == id }) else { return }
        libraryWorkholdingPlan?.steps[i].reviewed = reviewed
        for k in programs.indices where programs[k].workholdingStep?.id == id {
            programs[k].workholdingStep?.reviewed = reviewed
        }
        noteProjectChange()
    }

    func inspectLibraryStep(_ step: LibraryWorkholdingPlan.Step) {
        selectedLibraryStep = step.id
        if viewSide != step.side { show(side: step.side, stage: 0) }
        if let p = programs.first(where: { $0.workholdingStep?.id == step.id }),
           let entry = timeline.entries.first(where: { $0.program == p.index }) { seek(entry.tStart) }
        layoutScene()
        focusWork()
    }
}
