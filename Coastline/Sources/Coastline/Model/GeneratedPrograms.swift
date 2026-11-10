import Foundation
import CoastlineCore

extension AppModel {
    func openGuidedMode() {
        if let folder = jobs.run?.folder ?? jobs.selection {
            projectsPick = "job:" + folder.path
        }
        page = .projects
    }

    /// A generated job is a snapshot. Preparing it never connects or starts the machine.
    func prepareGeneratedRun(measuring: [MeasuringTool]) throws {
        guard planningMachineReference.isLegacy else {
            throw MachineDefinitionError("This machine profile is ready for planning and workspace simulation. Commission its physical machine before running generated jobs through Machine Control.")
        }
        guard jobs.run == nil else {
            throw NSError(domain: "Coastline", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "A guided job is already open. Return to Guided Mode and finish or end it first."])
        }
        let input = try checkedGuidedInput(measuring: measuring)
        let folder = JobsModel.userFolder.appendingPathComponent("generated-" + UUID().uuidString)
        let job = try GeneratedJob.writeNative(input, to: folder, machine: machine)
        let problems = job.problems(in: folder)
        guard problems.isEmpty else {
            try? FileManager.default.removeItem(at: folder)
            throw NSError(domain: "Coastline", code: 1, userInfo: [NSLocalizedDescriptionKey: problems.joined(separator: " ")])
        }
        jobs.reload()
        guard let entry = jobs.entries.first(where: { $0.folder == folder }) else { return }
        jobs.selection = folder
        jobs.startRun(entry)
        openGuidedMode()
    }
}
