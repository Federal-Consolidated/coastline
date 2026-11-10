import CoastlineCore
import Foundation
@testable import MillCore

private func generatedInput() -> GuidedJobBuilder.Input {
    let tool = Tool(name: "Uncoated flat", kind: .flatEndMill, diameter: 6, shankDiameter: 6,
                    flutes: 2, fluteLength: 12, stickout: 28, overallLength: 50)
    let stock = StockItem(materialID: "al-6061", sizeX: 60, sizeY: 30, sizeZ: 10)
    var input = GuidedJobBuilder.Input(partName: "Small cut", material: MaterialLibrary.material(id: "al-6061")!,
        stock: stock, stockSize: SIMD3(30, 60, 10), setupName: "Setup 1",
        programs: [.init(tool: tool, gcode: "(One short cut)\nG21 G90\nM3 S5000\nG0 X0 Y0 Z2\nG1 Z-0.1 F20\nG1 Y0.05 F50\nG0 Z2\nM5\n",
                         operationNames: ["Tiny contour"], minutes: 0.1)],
        checkpoints: [.init(afterProgram: 0, what: "Stock thickness", expected: 10, tolerance: 0.05)],
        measuring: [MeasuringTool(name: "Digital caliper", kind: .caliper)], setupImage: nil)
    return input
}

private func generatedScratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("generated-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Run exactly the checker used by the live sender, without connecting to any controller.
private func checkNativePrograms(_ job: ProgramJob, at folder: URL) throws {
    let machine = MachineProfile.standard
    var settings = MillSettings()
    for (key, value, _) in MockGRBL.standardSettings { settings.update(key, value) }
    settings.update(30, machine.spindleRPM.upperBound)
    let limits = machine.machineEnvelope
    let envelope = MillEnvelope(x: limits.x, y: limits.y, z: limits.z)
    for program in job.programs {
        let text = try String(contentsOf: folder.appendingPathComponent(program.file), encoding: .utf8)
        if case .failure(let refusal) = JobProgramCheck.clean(text.components(separatedBy: "\n"), settings: settings, envelope: envelope) {
            throw TestFailure(description: "\(program.file) cannot run: \(refusal.text)")
        }
    }
}

let generatedJobTests: [TestCase] = [
    TestCase(name: "codeCatalogKeepsShortCutsAndOriginalBytes") {
        let input = generatedInput()
        let source = GuidedJobBuilder.build(input)
        let files = GeneratedJob.codeFiles(input)
        try expectEqual(Set(files.map(\.path)).count, files.count, "Shared helper files appear once")
        try expectEqual(files.first { $0.path == "Code/T1_cut.nc" }?.kind, .cut)
        try expectEqual(files.first { $0.path == "Code/T1_aircut.nc" }?.kind, .airCut)
        try expectEqual(files.first { $0.path == "Code/home.nc" }?.kind, .setup)
        for file in files {
            try expectEqual(Data(file.text.utf8), source.files[file.path], file.path)
            try expect(source.jobs.flatMap(\.steps).contains { $0.gcodePath == file.path }, "Only referenced files are offered")
        }
    },
    TestCase(name: "cutOnlyExportContainsExactlySelectedOriginalPrograms") {
        let input = generatedInput()
        let files = GeneratedJob.codeFiles(input)
        let selected = Set(files.filter { $0.kind == .cut }.map(\.id))
        try expect(!selected.isEmpty)
        let scratch = try generatedScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let destination = scratch.appendingPathComponent("Cuts")
        let written = try GeneratedJob.export(files, selected: selected, to: destination)
        let relative = written.map { $0.path.replacingOccurrences(of: destination.path + "/", with: "") }
        try expectEqual(Set(relative), selected)
        let original = GuidedJobBuilder.build(input).files
        for path in relative {
            try expectEqual(try Data(contentsOf: destination.appendingPathComponent(path)), original[path], path)
        }
        for file in files where !selected.contains(file.id) {
            try expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(file.path).path), file.path)
        }
        try expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("job.json").path))
    },
    TestCase(name: "selectiveExportNeverOverwritesAndNeedsASelection") {
        let files = GeneratedJob.codeFiles(generatedInput())
        let scratch = try generatedScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let existing = scratch.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let sentinel = existing.appendingPathComponent("keep.nc")
        try "Keep these bytes\n".write(to: sentinel, atomically: true, encoding: .utf8)
        try expectThrows { _ = try GeneratedJob.export(files, selected: Set(files.map(\.id)), to: existing) }
        try expectEqual(try String(contentsOf: sentinel, encoding: .utf8), "Keep these bytes\n")
        let empty = scratch.appendingPathComponent("Empty")
        try expectThrows { _ = try GeneratedJob.export(files, selected: [], to: empty) }
        try expect(!FileManager.default.fileExists(atPath: empty.path))
        try expectThrows { _ = try GeneratedJob.export(files, selected: ["unknown.nc"], to: empty) }
        try expect(!FileManager.default.fileExists(atPath: empty.path))
    },
    TestCase(name: "nativeJobKeepsProgramOrderAndOperatorConfirmations") {
        var input = generatedInput()
        let source = GuidedJobBuilder.build(input)
        let scratch = try generatedScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let destination = scratch.appendingPathComponent("Native")
        let job = try GeneratedJob.writeNative(input, to: destination)
        try expectEqual(job.setups.map(\.title), ["Setup 1 · Small cut"])
        try expect(job.options.isEmpty)
        try expect(job.setups.allSatisfy { $0.when.isEmpty && $0.steps.allSatisfy { $0.when.isEmpty } })
        try expectEqual(try ProgramJob.load(destination), job)
        try expect(job.problems(in: destination).isEmpty)
        try checkNativePrograms(job, at: destination)
        let catalog = Dictionary(uniqueKeysWithValues: GeneratedJob.codeFiles(input).map { ($0.path, $0.kind) })
        for (k, original) in source.jobs.enumerated() {
            let expected = original.steps.filter { $0.hasGCode && catalog[$0.gcodePath] != .airCut }.map(\.gcodePath)
            try expectEqual(job.setups[k].steps.filter { $0.kind == .run }.compactMap(\.program), expected)
            for (n, step) in original.steps.enumerated() where step.hasPopup && step.title != "Air Cut First?" {
                let confirmation = try unwrap(job.setups[k].steps.first { $0.id == "s\(k)-\(n)" })
                try expectEqual(confirmation.kind, .instruction)
                try expectEqual(confirmation.caution, step.popupText)
                try expectEqual(confirmation.text, step.markdown.isEmpty ? step.prompt : step.markdown)
            }
        }
        try expect(job.setups.flatMap(\.steps).allSatisfy { $0.title != "Air Cut First?" && $0.title != "Out of Tolerance" })
        try expectEqual(job.programs.first { $0.file == "Code/T1_cut.nc" }?.purpose, .cut)
        try expect(job.programs.allSatisfy { !$0.file.lowercased().contains("aircut") })
        for program in job.programs {
            try expectEqual(try Data(contentsOf: destination.appendingPathComponent(program.file)), source.files[program.file], program.file)
        }
        try expectThrows { _ = try GeneratedJob.writeNative(input, to: destination) }
        try expectEqual(try ProgramJob.load(destination), job, "Existing generated job was preserved")
    },
    TestCase(name: "nativeJobRejectsUnsupportedSurfaceMapAndEmptyPrograms") {
        var input = generatedInput()
        input.programs[0].surfaceProbe = "M114\nM111 Z-2 F20\n"
        let scratch = try generatedScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let destination = scratch.appendingPathComponent("Native")
        do {
            _ = try GeneratedJob.writeNative(input, to: destination)
            throw TestFailure(description: "Surface-map program must be refused")
        } catch let error as NSError {
            try expect(error.localizedDescription.contains("contour-map"), error.localizedDescription)
        }
        try expect(!FileManager.default.fileExists(atPath: destination.path))
        input.programs[0].surfaceProbe = nil
        input.programs[0].gcode += "M112\n"
        try expectThrows { _ = try GeneratedJob.writeNative(input, to: destination) }
        try expect(!FileManager.default.fileExists(atPath: destination.path))
        input.programs = []
        try expectThrows { _ = try GeneratedJob.writeNative(input, to: destination) }
        try expect(!FileManager.default.fileExists(atPath: destination.path))
    },
    TestCase(name: "nativeJobRejectsReferenceBoresWithUnsupportedHostMacros") {
        var input = generatedInput()
        input.programs[0].reference = .bores
        var back = input.programs[0]
        back.side = 1
        back.reference = .windows
        input.programs.append(back)
        input.probing.bores = .init(centresA: [SIMD2(7, -15), SIMD2(7, 15)], depthA: 7, thickness: 10)
        let scratch = try generatedScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let destination = scratch.appendingPathComponent("Native")
        do {
            _ = try GeneratedJob.writeNative(input, to: destination)
            throw TestFailure(description: "Reference-bore macros must be refused")
        } catch let error as NSError {
            try expect(error.localizedDescription.contains("M102") && error.localizedDescription.contains("guided job"), error.localizedDescription)
        }
        try expect(!FileManager.default.fileExists(atPath: destination.path))
    },
]
