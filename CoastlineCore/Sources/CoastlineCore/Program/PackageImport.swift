import MillCore
import Foundation
import simd

/// Turns an old `.dd` (or the sender `.crproj`) package into a `ProgramJob` folder: every
/// G-code file converted for the machine and checked to follow the same path as the original, each
/// old job as a choice of one "Job" option, text steps as instructions. Photos are left out:
/// Coastline's setup views replace them. A curated job (options, mount lists, checks) is then
/// written by hand on top of the converted programs.
public enum PackageImport {
    public struct Report: Sendable {
        public var job: ProgramJob
        /// Per program: what was changed, or why it could not be converted.
        public var notes: [String]
    }

    public enum ImportError: Error, CustomStringConvertible {
        case pathChanged(String, String)
        public var description: String {
            switch self {
            case .pathChanged(let file, let why): "Converting \(file) changed its path: \(why)"
            }
        }
    }

    public static func run(_ source: URL, into folder: URL, machine: MachineProfile = .standard) throws -> Report {
        let project = try JobPackage.open(url: source)
        let name = source.deletingPathExtension().lastPathComponent
        var job = ProgramJob(id: slug(name), title: name, summary: "Imported from \(source.lastPathComponent).")
        var notes: [String] = []
        var converted: [String: String] = [:]  // source path → program id
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("programs"), withIntermediateDirectories: true)

        func program(for step: Step) throws -> String {
            if let id = converted[step.gcodePath] { return id }
            let original = try project.gcodeLines(for: step).joined(separator: "\n")
            let prepared = GCodeConvert.prepare(original, machine: machine)
            try samePath(original, prepared.text, file: step.gcodePath)
            let base = (step.gcodePath as NSString).lastPathComponent
            let id = slug((base as NSString).deletingPathExtension)
            let file = "programs/\((base as NSString).deletingPathExtension).nc"
            try prepared.text.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
            let read = GCodeReader.read(prepared.text)
            job.programs.append(ProgramJob.ProgramFile(id: id, title: title(base), file: file, purpose: purpose(read),
                                                       tool: nil, changes: prepared.changes, source: step.gcodePath))
            notes.append("\(base): \(read.lineCount) lines, \(read.moves.count) moves" + (prepared.changes.isEmpty ? "" : " — " + prepared.changes.joined(separator: " "))
                         + read.issues.map { "\n      \($0.severity): \($0.message)" }.joined())
            converted[step.gcodePath] = id
            return id
        }

        let choices = project.jobs.enumerated().map { k, j in ProgramJob.Choice(id: "job\(k + 1)", title: j.title, detail: j.prompt) }
        job.options = [ProgramJob.Option(id: "job", title: "Job", detail: nil, choices: choices, defaultChoice: choices.first?.id ?? "")]
        for (k, old) in project.jobs.enumerated() {
            var steps: [ProgramJob.Step] = []
            for (n, s) in old.steps.enumerated() {
                let text = s.prompt.isEmpty ? s.markdown : s.prompt
                if s.hasGCode {
                    if !text.isEmpty {
                        steps.append(ProgramJob.Step(id: "j\(k + 1)s\(n + 1)", kind: .instruction, title: s.title, text: text))
                    }
                    steps.append(ProgramJob.Step(id: "j\(k + 1)s\(n + 1)run", kind: .run, title: s.title, program: try program(for: s)))
                } else {
                    steps.append(ProgramJob.Step(id: "j\(k + 1)s\(n + 1)", kind: .instruction, title: s.title, text: text))
                }
            }
            job.setups.append(ProgramJob.Setup(id: "job\(k + 1)", title: old.title, summary: old.prompt,
                                               when: [ProgramJob.Condition(option: "job", oneOf: ["job\(k + 1)"])], steps: steps))
        }
        try job.save(to: folder)
        return Report(job: job, notes: notes)
    }

    /// The converted program must make the same moves as the original, within 0.1 µm.
    static func samePath(_ original: String, _ converted: String, file: String) throws {
        let a = GCodeReader.read(original), b = GCodeReader.read(converted)
        guard a.moves.count == b.moves.count, a.machineMoves == b.machineMoves, a.probes == b.probes else {
            throw ImportError.pathChanged(file, "\(a.moves.count) moves became \(b.moves.count)")
        }
        for (k, (m, n)) in zip(a.moves, b.moves).enumerated() {
            let ok = m.role == n.role && m.motion == n.motion && simd_distance(m.position, n.position) <= 1e-4
                && abs(m.i - n.i) <= 1e-4 && abs(m.j - n.j) <= 1e-4 && abs(m.feed - n.feed) <= 1e-3
            if !ok { throw ImportError.pathChanged(file, "move \(k + 1) (line \(a.lineOfMove[k])) differs") }
        }
    }

    static func purpose(_ p: GCodeReader.Program) -> ProgramJob.ProgramFile.Purpose {
        if p.probes > 0 || p.offsetWrites > 0 || !p.macros.isEmpty { return .probe }
        if p.moves.count > 50 { return .cut }
        if !p.spindleSpeeds.isEmpty, p.moves.count < 5 { return .warmup }
        return .move
    }

    /// "05_Mill_Pocket_Wide.nc" → "Mill Pocket Wide".
    static func title(_ file: String) -> String {
        let stem = (file as NSString).deletingPathExtension
        let words = stem.split(separator: "_").drop { $0.allSatisfy(\.isNumber) }
        return words.joined(separator: " ")
    }

    public static func slug(_ s: String) -> String {
        s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { r, c in
            if c != "-" || r.last != "-" { r.append(c) }
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
