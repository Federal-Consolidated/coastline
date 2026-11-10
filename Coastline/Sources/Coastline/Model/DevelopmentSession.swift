import CoastlineCore
import Foundation
import simd

/// Debug rebuilds save separately from the user's project files. Hardware connections and
/// machine position are never restored; development mode always uses Digital Machine.
private struct DevelopmentSession: Codable {
    var project: ProjectFile
    var projectPath: String?
    var dirty: Bool
    var page: String
    var stage: Int
    var viewSide: Int
    var prepStage: Int
    var selectedSetup: UUID?
    var playhead: Double
    var inspector: Bool
    var cameraTarget: SIMD3<Float>
    var cameraDistance: Float
    var cameraYaw: Float
    var cameraPitch: Float
    var orthographic: Bool
    var placement: FixturePlacementResume? = nil
}

extension AppModel {
    private var developmentSessionURL: URL? {
        guard ProcessInfo.processInfo.environment["COASTLINE_DEV"] == "1",
              let path = ProcessInfo.processInfo.environment["COASTLINE_DEV_STATE"] else { return nil }
        return URL(fileURLWithPath: path)
    }

    func saveDevelopmentSession() {
        guard let url = developmentSessionURL else { return }
        var project = projectSnapshot
        project.results = savedResults
        let c = renderer.destinationCamera
        var session = DevelopmentSession(project: project, projectPath: projectURL?.path, dirty: projectDirty,
            page: page.rawValue, stage: stage.rawValue, viewSide: viewSide, prepStage: prepStage,
            selectedSetup: selectedLibraryStep, playhead: playhead, inspector: showInspector,
            cameraTarget: c.target, cameraDistance: c.distance, cameraYaw: c.yaw, cameraPitch: c.pitch,
            orthographic: c.orthographic)
        if let editing = fixturePlacement {
            session.placement = .init(fixture: editing.fixture, selectedComponent: editing.selectedComponent,
                returnPage: editing.returnPage.rawValue, returnStage: editing.returnStage.rawValue,
                snapEnabled: editing.snapEnabled, machineContextVersion: 1)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: url, options: .atomic)
        } catch { print("Debug session could not be saved: \(error)") }
    }

    func restoreDevelopmentSession() async {
        guard let url = developmentSessionURL, !restoredDevelopmentSession else { return }
        restoredDevelopmentSession = true
        showStart = false
        await loadMachine()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let session = try JSONDecoder().decode(DevelopmentSession.self, from: Data(contentsOf: url))
                guard await apply(session.project) else {
                    errorMessage = (errorMessage ?? "Couldn't restore the debug session.") + "\n\n" + preserveFailedSession(at: url)
                    return
                }
                var restoredResults = true
                if let results = session.project.results, part != nil { restoredResults = restore(results) }
                projectURL = session.projectPath.map { URL(fileURLWithPath: $0) }
                projectDirty = session.dirty
                enter(JobStage(rawValue: session.stage) ?? .partStock)
                if session.viewSide != viewSide || session.prepStage != prepStage {
                    show(side: session.viewSide, stage: session.prepStage)
                }
                if !timeline.entries.isEmpty { seek(session.playhead) }
                selectedLibraryStep = session.selectedSetup
                showInspector = session.inspector
                page = SidebarItem(rawValue: session.page) ?? .workspace
                if let placement = session.placement {
                    await beginFixturePlacement(placement.fixture)
                    fixturePlacement?.selectedComponent = placement.selectedComponent
                    fixturePlacement?.snapEnabled = placement.snapEnabled ?? true
                    fixturePlacement?.returnPage = SidebarItem(rawValue: placement.returnPage) ?? .workspace
                    fixturePlacement?.returnStage = JobStage(rawValue: placement.returnStage) ?? .planning
                }
                layoutScene()
                perspective = !session.orthographic
                renderer.moveCamera(animated: false) { camera in
                    camera.target = session.cameraTarget; camera.distance = session.cameraDistance
                    camera.yaw = session.cameraYaw; camera.pitch = session.cameraPitch
                    camera.orthographic = session.orthographic
                }
                if fixturePlacement != nil, session.placement?.machineContextVersion != 1 {
                    focusPlacementContext()
                }
                status = restoredResults ? "Debug · session restored" : "Debug · session restored · Regenerate toolpaths for this machine"
            } else {
                await restoreSession()
                showStart = part == nil
            }
        } catch {
            errorMessage = "Couldn't restore the debug session: \(error)\n\n" + preserveFailedSession(at: url)
            showStart = part == nil
        }
        if let page = ProcessInfo.processInfo.environment["COASTLINE_DEV_PAGE"].flatMap(SidebarItem.init(rawValue:)) {
            self.page = page
        }
    }

    /// A rebuild may save a new session after restoration fails. Preserve the original
    /// unsaved work first; a unique sibling file is never allowed to replace an older backup.
    private func preserveFailedSession(at url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let name = url.deletingPathExtension().lastPathComponent
            + ".recovery-" + formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8) + ".json"
        let recovery = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: recovery)
            return "Your previous debug session is preserved at \(recovery.path)."
        } catch {
            return "The original debug session is still at \(url.path), but a recovery copy could not be created: \(error.localizedDescription)"
        }
    }
}
