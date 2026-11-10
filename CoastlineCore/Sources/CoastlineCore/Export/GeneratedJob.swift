import Foundation
import MillCore

/// The individual programs and the native guided run share the same generated source.
public enum GeneratedJob {
    public struct CodeFile: Identifiable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            case cut = "Cutting", probe = "Probing", setup = "Setup", airCut = "Air cuts"
        }
        public var id: String { path }
        public let path: String
        public let title: String
        public let kind: Kind
        public let text: String
    }

    public static func codeFiles(_ input: GuidedJobBuilder.Input, machine: MachineProfile = .standard) -> [CodeFile] {
        let built = GuidedJobBuilder.build(input, machine: machine)
        var seen: Set<String> = []
        return built.jobs.flatMap(\.steps).compactMap { step in
            guard step.hasGCode, seen.insert(step.gcodePath).inserted,
                  let data = built.files[step.gcodePath], let text = String(data: data, encoding: .utf8) else { return nil }
            let read = GCodeReader.read(text)
            let path = step.gcodePath.lowercased()
            let kind: CodeFile.Kind
            if path.contains("aircut") { kind = .airCut }
            else if path.contains("_cut") || path.contains("/square_") || path.contains("/prep_") { kind = .cut }
            else if read.probes > 0 || read.offsetWrites > 0 || !read.macros.isEmpty { kind = .probe }
            else { kind = .setup }
            return CodeFile(path: step.gcodePath, title: step.title, kind: kind, text: text)
        }
    }

    /// Preserve relative code paths; write only explicitly selected files into a new folder.
    /// An existing destination is refused, so export cannot replace an unrelated program.
    public static func export(_ files: [CodeFile], selected: Set<String>, to folder: URL) throws -> [URL] {
        let chosen = files.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { throw failure("Select at least one program to export.") }
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw failure("That export folder already exists. Choose a new folder name.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            return try chosen.map { file in
                let url = folder.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.text.write(to: url, atomically: true, encoding: .utf8)
                return url
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// All prep and part setups run in order. The native runner supplies its own optional air
    /// cut action; the package's popup and retry branches become explicit confirmations.
    public static func writeNative(_ input: GuidedJobBuilder.Input, to folder: URL, machine: MachineProfile = .standard) throws -> ProgramJob {
        try GuidedJobBuilder.validateWorkholding(input)
        guard !input.programs.isEmpty else { throw failure("Generate toolpaths first.") }
        guard input.programs.allSatisfy({ $0.surfaceProbe == nil && GCodeReader.read($0.gcode).macros.isDisjoint(with: Set(111...114)) }) else {
            throw failure("Surface-follow engraving uses contour-map codes that the built-in runner does not support yet. Export a guided job for a compatible sender.")
        }
        let built = GuidedJobBuilder.build(input, machine: machine)
        let files = codeFiles(input, machine: machine)
        for file in files where file.kind != .airCut {
            let unsupported = GCodeReader.read(file.text).macros.subtracting([100, 101]).sorted()
            if !unsupported.isEmpty {
                let codes = unsupported.map { "M\($0)" }.joined(separator: ", ")
                throw failure("\(file.title) uses host codes that the built-in runner does not support yet (\(codes)). Export a guided job for a compatible sender.")
            }
        }
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        var job = ProgramJob(id: UUID().uuidString, title: input.partName,
                             summary: "Generated in Coastline. Stock prep and machining run in order.")
        job.machines = [machine.name]
        job.material = input.material.name
        job.requirements = ["I have reviewed the generated programs and the workholding.",
                            "The tool and stock are secured, the chip cover is on, and I can reach the E-stop."]
        job.programs = files.filter { $0.kind != .airCut }.map { file in
            .init(id: file.path, title: file.title, file: file.path,
                  purpose: file.kind == .cut ? .cut : file.kind == .probe ? .probe : .move,
                  tool: nil, source: file.path)
        }
        for (k, source) in built.jobs.enumerated() {
            var steps: [ProgramJob.Step] = []
            for (n, step) in source.steps.enumerated() {
                // The optional air cut is on each cutting step in the native runner. The
                // out-of-tolerance retry branch is included in the measurement confirmation.
                if step.title == "Air Cut First?" || step.title == "Out of Tolerance" { continue }
                if let file = byPath[step.gcodePath], file.kind == .airCut { continue }
                let id = "s\(k)-\(n)"
                let text = step.markdown.isEmpty ? step.prompt : step.markdown
                if !text.isEmpty || step.hasPopup {
                    let confirmation = step.hasPopup ? step.popupText : nil
                    steps.append(.init(id: id, kind: .instruction, title: step.title, text: text,
                                       caution: confirmation))
                }
                if step.hasGCode {
                    guard byPath[step.gcodePath] != nil else { throw failure("Missing generated code: \(step.gcodePath)") }
                    steps.append(.init(id: id + "-run", kind: .run, title: step.title, program: step.gcodePath))
                }
            }
            job.setups.append(.init(id: "setup\(k)", title: source.title, summary: source.prompt, steps: steps))
        }
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw failure("The generated job folder already exists.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for file in files where file.kind != .airCut {
                let url = folder.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.text.write(to: url, atomically: true, encoding: .utf8)
            }
            try job.save(to: folder)
            return job
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Coastline.GeneratedJob", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
