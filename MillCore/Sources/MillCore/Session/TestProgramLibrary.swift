import Foundation

/// A reusable program. Motion checks use `ProgramCheck`; setup programs use the guided
/// runner's `JobProgramCheck` for probing, work offsets, homing and spindle commands.
public struct SavedTestProgram: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case motionCheck, setup

        public var title: String { self == .motionCheck ? "Motion Check" : "Setup Program" }
    }

    public var id: UUID
    public var title: String
    public var detail: String
    public var code: String
    public var isFavorite: Bool
    public var kind: Kind

    public init(id: UUID = UUID(), title: String, detail: String = "", code: String = "G21\nG90\nM5\n", isFavorite: Bool = false, kind: Kind = .motionCheck) {
        self.id = id
        self.title = title
        self.detail = detail
        self.code = code
        self.isFavorite = isFavorite
        self.kind = kind
    }

    public init(_ builtIn: TestProgram) {
        self.init(title: builtIn.title, detail: builtIn.detail, code: builtIn.lines.joined(separator: "\n"))
    }

    public var homesFirst: Bool {
        kind == .setup && code.components(separatedBy: .newlines).map(Self.cleaned).first { !$0.isEmpty } == "$H"
    }

    /// Establish millimeters, absolute distance mode, and spindle off independently of the
    /// controller's previous program. The same lines are previewed, checked, and sent.
    public var lines: [String] {
        let startup = ["G21", "G90", "M5"]
        let source = code.components(separatedBy: .newlines)
        if kind == .setup, let first = source.firstIndex(where: { !Self.cleaned($0).isEmpty }),
           Self.cleaned(source[first]) == "$H" {
            // `$H` remains the first executable line so a setup can home an unhomed machine.
            return Array(source[...first]) + startup + Array(source.dropFirst(first + 1))
        }
        return startup + source
    }

    private static func cleaned(_ line: String) -> String {
        line.replacingOccurrences(of: #"\(.*?\)|;.*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "").uppercased()
    }

    private enum CodingKeys: String, CodingKey { case id, title, detail, code, isFavorite, kind }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        detail = try values.decode(String.self, forKey: .detail)
        code = try values.decode(String.self, forKey: .code)
        isFavorite = try values.decode(Bool.self, forKey: .isFavorite)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .motionCheck
    }

    public var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the program a name." }
        let executable = code.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: #"\(.*?\)|;.*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if executable.allSatisfy(\.isEmpty) { return "Add G-code to the program." }
        return nil
    }
}

/// Stored as a whole so an intentionally empty library stays empty across launches.
public struct TestProgramLibrary: Codable, Equatable, Sendable {
    public private(set) var programs: [SavedTestProgram]

    public init(programs: [SavedTestProgram] = TestProgram.allCases.map(SavedTestProgram.init)) {
        self.programs = programs
    }

    /// Keep the user's creation order within each group.
    public var ordered: [SavedTestProgram] {
        programs.filter(\.isFavorite) + programs.filter { !$0.isFavorite }
    }

    public mutating func save(_ program: SavedTestProgram) {
        if let index = programs.firstIndex(where: { $0.id == program.id }) {
            programs[index] = program
        } else {
            programs.append(program)
        }
    }

    public mutating func remove(id: UUID) { programs.removeAll { $0.id == id } }

    public mutating func toggleFavorite(id: UUID) {
        guard let index = programs.firstIndex(where: { $0.id == id }) else { return }
        programs[index].isFavorite.toggle()
    }
}
