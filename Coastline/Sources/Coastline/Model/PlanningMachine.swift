import CoastlineCore
import Foundation
import simd
import Viewport

extension AppModel {
    static let planningMachinePreference = "planningMachineReference"

    var planningMachineReady: Bool {
        machineLoaded && machineModel != nil && !isSwitchingPlanningMachine && planningMachineProblem == nil
    }

    var canChangePlanningMachine: Bool {
        !isBusy && !isGenerating && !isPlanningJob && !isFindingPlans && !isSwitchingPlanningMachine
            && fixturePlacement?.loading != true && jobs.run == nil
    }

    var planningMachineTitle: String {
        let reference = planningMachineReference
        return reference.isLegacy ? reference.displayName : "\(reference.displayName) · r\(reference.reference.revision)"
    }

    func requirePlanningMachine() throws {
        guard planningMachineReady else {
            throw MachineDefinitionError(planningMachineProblem ?? "Wait for the job's machine to finish loading before planning.")
        }
        if let geometry = planningGeometry, !geometry.supportsVettedFixtureMounting {
            throw MachineDefinitionError("The current vetted workholding library requires two T-slots about 40 mm apart. Add compatible workholding before generating CAM for this machine.")
        }
    }

    /// The default is only for a new workspace. Project/session restore explicitly overrides
    /// it, including the legacy assignment of files written before machine profiles existed.
    func initialPlanningMachineReference() async throws -> PlanningMachineReference {
        if planningMachineInitialized { return planningMachineReference }
        if let data = UserDefaults.standard.data(forKey: Self.planningMachinePreference) {
            return try JSONDecoder().decode(PlanningMachineReference.self, from: data)
        }
        await machineProfiles.reload()
        guard let package = machineProfiles.packages.first(where: { $0.definition.id == "desktop-cnc" }) else {
            throw MachineDefinitionError("Install a machine profile to start planning.")
        }
        return try PlanningMachineReference(definition: package.definition)
    }

    func selectPlanningMachine(_ reference: PlanningMachineReference) async {
        guard planningMachineReference != reference || !planningMachineReady else { return }
        guard canChangePlanningMachine else { return }
        let placementID = fixturePlacement?.id
        if placementID != nil {
            fixturePlacement?.loading = true
            fixturePlacement?.error = nil
            fixturePlacementGeometry = nil
            layoutScene()
        }
        do {
            try await restorePlanningMachine(reference)
            if let placementID, fixturePlacement?.id == placementID {
                // A mounting pose belongs to its machine. Fit against the newly selected
                // table, and require a new grip review rather than carrying approval over.
                fixturePlacement?.fixture.planning?.workspacePlaced = false
                fixturePlacement?.fixture.planning?.gripDefinitionReviewed = false
                fixturePlacement?.fixture.planning?.assemblyState?.mounted = false
                await reloadPlacementGeometry(centreUnconfigured: true)
                if fixturePlacement?.id == placementID { focusPlacementContext() }
            }
            if ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil {
                UserDefaults.standard.set(try JSONEncoder().encode(reference), forKey: Self.planningMachinePreference)
            }
            noteProjectChange()
            saveSession()
            saveDevelopmentSession()
            status = fixturePlacement == nil
                ? "\(planningMachineTitle) selected. Regenerate toolpaths for this machine."
                : "\(planningMachineTitle) selected for this job. Review the workholding on its table."
        } catch {
            if let placementID, fixturePlacement?.id == placementID {
                // restorePlanningMachine leaves the previous machine intact on failure.
                await reloadPlacementGeometry()
            }
            // A failed replacement must not block a valid restored fixture draft.
            errorMessage = error.localizedDescription
        }
    }

    /// Prepare the complete replacement before touching the current job. Resolution never
    /// substitutes a newer revision or a default machine when a saved package is unavailable.
    func restorePlanningMachine(_ reference: PlanningMachineReference) async throws {
        // Opening a saved job can arrive while the default workspace is loading.
        // Join that load, then resolve the saved assignment instead of rejecting it.
        while isSwitchingPlanningMachine { try await Task.sleep(for: .milliseconds(25)) }
        // Jobs saved before machine profiles existed get the installed Desktop CNC profile:
        // the old built-in model has no measured table or T-slots.
        var reference = reference
        if reference.isLegacy {
            await machineProfiles.reload()
            if let package = machineProfiles.packages.first(where: { $0.definition.id == "desktop-cnc" }) {
                reference = try PlanningMachineReference(definition: package.definition)
                if ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil {
                    UserDefaults.standard.set(try JSONEncoder().encode(reference), forKey: Self.planningMachinePreference)
                }
            }
        }
        if planningMachineReady && planningMachineReference == reference { return }
        guard !isGenerating && !isPlanningJob && !isFindingPlans else {
            throw MachineDefinitionError("Finish the current planning task before changing the job's machine.")
        }
        isSwitchingPlanningMachine = true
        defer { isSwitchingPlanningMachine = false }
        let model: MachineModel
        let geometry: MachinePlanningGeometry?
        if reference.isLegacy {
            model = try await loadControlMachineModel()
            geometry = nil
        } else {
            await machineProfiles.reload()
            guard let resolved = try reference.resolve(in: machineProfiles.packages) else {
                throw MachineDefinitionError("The selected machine package is missing.")
            }
            let fresh = try await Task.detached(priority: .userInitiated) {
                try MachineDefinitionPackage.load(from: resolved.rootURL)
            }.value
            guard fresh.definition == reference.definition else {
                throw MachineDefinitionError("The machine profile changed while loading. Restore its original package or select the revised profile explicitly.")
            }
            let engine = try connectedEngine()
            let parts = try await engine.machineProfileParts(fresh.manifestURL)
            geometry = try await Task.detached(priority: .userInitiated) {
                try MachinePlanningGeometry(definition: fresh.definition, parts: parts)
            }.value
            model = geometry!.model
        }
        try Task.checkCancellation()
        var meshes: [SceneMesh] = []
        var components: [String: String] = [:], roles: [String: String] = [:]
        for (index, part) in model.parts.enumerated() {
            let id = "machine.\(part.group).\(part.role).\(index)"
            guard let mesh = SceneMesh(device: renderer.device, id: id,
                                       positions: part.mesh.vertices, normals: part.mesh.normals, indices: part.mesh.indices,
                                       color: SIMD4(Self.displayColor(role: part.role, part.color), 1)) else {
                throw MachineDefinitionError("The graphics device couldn't load the machine model.")
            }
            mesh.group = geometry == nil ? (part.group == "static" ? nil : part.group) : "profile." + part.group
            meshes.append(mesh)
            components[id] = part.group
            roles[id] = part.role
        }
        let fixtureParts: [FixturePart]
        if kitParts.isEmpty {
            let engine = try connectedEngine()
            fixtureParts = try await engine.fixtureKit()
        } else { fixtureParts = kitParts }
        try Task.checkCancellation()

        // Invalidate before replacing the assignment: old results must never acquire the
        // new profile's identity in an autosave or background completion.
        clearToolpathResults()
        analysisTask?.cancel()
        prepRevealTask?.cancel()
        tourTask?.cancel()
        toolChangeTask?.cancel()
        toolChangeStop = nil
        flipTask?.cancel()
        simCatchUp?.cancel()
        simPrecompute?.cancel()
        clearanceRecheck?.cancel()
        machineTreeTask?.cancel()
        machineTreeTask = nil
        machineTreeTaskID = UUID()
        machineTree = nil
        machineTreeKey = nil
        headTrees = nil
        profileCollisionTrees = nil
        bedTree = nil
        collisionGeneration += 1
        collisions = []
        collisionPrefixes = [:]
        opCache.removeAll()
        opCacheOrder.removeAll()
        prepProgramCache = nil
        clampFieldCache = nil
        cClampFrameCache = nil
        toolChangeSpotCache = nil
        kitShiftCache = nil
        referencePlan = nil
        travelIssue = nil
        planCandidates = []
        planOptions = []
        chosenPlan = nil
        recommendedPlan = nil
        planEstimate = [:]
        planNotes = []
        for mesh in renderer.scene.meshes where mesh.id.hasPrefix("machine.") { renderer.scene.remove(id: mesh.id) }
        renderer.scene.groupTransforms.removeAll()
        planningMachineReference = reference
        calibration = Self.loadCalibration(for: reference)
        planningMachineInitialized = true
        planningGeometry = geometry
        machineModel = model
        machineSceneComponents = components
        machineSceneRoles = roles
        kitParts = fixtureParts
        for mesh in meshes { renderer.scene.setMesh(mesh) }
        machineLoaded = true
        planningMachineProblem = geometry.map { $0.supportsVettedFixtureMounting } == false
            ? "The current vetted workholding library needs two compatible T-slots about 40 mm apart. Install compatible workholding before generating CAM for this machine."
            : nil
        let home = reference.profile.homePosition ?? .zero
        setMachinePosition(SIMD3(home.x, home.y, home.z))
        applyMachineDisplay()
        layoutScene()
        if part == nil { renderer.frameAll() } else { focusWork() }
        scheduleAnalysis()
    }

    /// Physical control and old G-code projects use their existing machine, independently
    /// of the current planning profile. Selecting a planning profile grants no hardware use.
    func loadControlMachineModel() async throws -> MachineModel {
        if let legacyControlModel { return legacyControlModel }
        let engine = try connectedEngine()
        let model = try await engine.machineModel(Self.repoRoot.appendingPathComponent("resources/machine/machine.step"))
        legacyControlModel = model
        return model
    }
}
