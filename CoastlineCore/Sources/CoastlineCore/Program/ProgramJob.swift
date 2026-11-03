import Foundation

/// A guided job built around G-code that already exists: an old .dd job, another CAM
/// program's output, or your own. Coastline adds the guided steps, the 3D setup views, the
/// checks and the live run; the toolpaths stay as written (only converted to mm for the machine).
///
/// On disk a job is a folder: `job.json`, `programs/*.nc` and `models/*.step`.
public struct ProgramJob: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var summary: String
    /// The machines it is made for (shown as badges; each job names its own).
    public var machines: [String] = []
    public var material: String?
    /// What must be true before the job starts (shown first, all must be ticked).
    public var requirements: [String] = []
    public var options: [Option] = []
    public var tools: [ToolSpec] = []
    public var models: [Model] = []
    public var programs: [ProgramFile] = []
    public var setups: [Setup] = []

    public init(id: String, title: String, summary: String) {
        self.id = id
        self.title = title
        self.summary = summary
    }

    // MARK: Parts

    /// A choice the operator makes before starting (pocket width, where to start…).
    public struct Option: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String?
        public var choices: [Choice]
        public var defaultChoice: String
        /// The option only matters when these hold (e.g. a size that only applies to one start).
        public var when: [Condition] = []

        public init(id: String, title: String, detail: String? = nil, choices: [Choice], defaultChoice: String, when: [Condition] = []) {
            self.id = id
            self.title = title
            self.detail = detail
            self.choices = choices
            self.defaultChoice = defaultChoice
            self.when = when
        }
    }

    public struct Choice: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String?

        public init(id: String, title: String, detail: String? = nil) {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    /// True when the option's chosen value is one of `oneOf`.
    public struct Condition: Codable, Sendable, Equatable {
        public var option: String
        public var oneOf: [String]

        public init(option: String, oneOf: [String]) {
            self.option = option
            self.oneOf = oneOf
        }
    }

    public struct ToolSpec: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        /// "End mill" or "Drill".
        public var kind: String
        /// mm.
        public var diameter: Double
        /// The collet it goes in, e.g. "1/4\"" or "4 mm (5/32\")".
        public var collet: String
        /// How to fit it: push all the way in, wrenches…
        public var fitting: String?
        public var note: String?
        /// The cutting shape for the cut simulation: "flat" (default), "ball", "drill" (118° point)
        /// or "disc" (a slotting cutter: a disc of `diameter` and `discThickness` on a shank).
        public var shape: String?
        public var discThickness: Double?
        /// The shank above a disc (mm); a disc without it is all disc.
        public var shankDiameter: Double?

        public init(id: String, name: String, kind: String, diameter: Double, collet: String,
                    fitting: String? = nil, note: String? = nil, shape: String? = nil,
                    discThickness: Double? = nil, shankDiameter: Double? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
            self.diameter = diameter
            self.collet = collet
            self.fitting = fitting
            self.note = note
            self.shape = shape
            self.discThickness = discThickness
            self.shankDiameter = shankDiameter
        }
    }

    /// A 3D model shown in the setup views (the part, the stock blank, the jig parts).
    public struct Model: Codable, Sendable, Equatable, Identifiable {
        public enum Role: String, Codable, Sendable { case part, stock, fixture }
        public var id: String
        public var title: String
        /// Relative to the job folder, e.g. `models/left_jig.step`.
        public var file: String
        public var role: Role
    }

    /// Model → work frame: each work axis is a model axis (`"x"`, `"-z"`…), then the offset (mm).
    public struct Placement: Codable, Sendable, Equatable {
        public var axes: [String]
        public var offset: [Double]

        public init(axes: [String] = ["x", "y", "z"], offset: [Double] = [0, 0, 0]) {
            self.axes = axes
            self.offset = offset
        }

        /// The 3×3 rotation (rows: work X, Y, Z) as model-axis index and sign per row.
        public var rows: [(axis: Int, sign: Double)] {
            axes.prefix(3).map { a in
                let sign: Double = a.hasPrefix("-") ? -1 : 1
                let axis = ["x": 0, "y": 1, "z": 2][String(a.drop { $0 == "-" || $0 == "+" }).lowercased()] ?? 0
                return (axis, sign)
            }
        }

        /// A model point in the work frame.
        public func apply(_ p: (Double, Double, Double), normal: Bool = false) -> (Double, Double, Double) {
            let v = [p.0, p.1, p.2], r = rows
            let o = normal ? [0, 0, 0] : (0..<3).map { $0 < offset.count ? offset[$0] : 0 }
            return (r[0].sign * v[r[0].axis] + o[0], r[1].sign * v[r[1].axis] + o[1], r[2].sign * v[r[2].axis] + o[2])
        }
    }

    public struct ProgramFile: Codable, Sendable, Equatable, Identifiable {
        public enum Purpose: String, Codable, Sendable {
            /// Homes or moves the machine to a position (tool change, loading).
            case move
            /// Spindle warm-up.
            case warmup
            /// Finds the part and sets the work offset (G38, G10, M100…).
            case probe
            /// Removes material.
            case cut
        }
        public var id: String
        public var title: String
        /// Relative to the job folder, e.g. `programs/05_Mill_Pocket.nc`.
        public var file: String
        public var purpose: Purpose
        /// The tool in the spindle while it runs.
        public var tool: String?
        /// What Coastline changed to run it on the machine (inches to mm, spindle limit…).
        public var changes: [String] = []
        /// The original file name, for reference.
        public var source: String?
    }

    /// One clamping of the part, with the steps done in it.
    public struct Setup: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var summary: String
        public var when: [Condition] = []
        /// Where each model sits in this setup's work frame (model id → placement). Models with
        /// no placement here are not shown with this setup's programs.
        public var placements: [String: Placement] = [:]
        /// Where the machine sits in this setup, so the 3D view can show it around the part.
        public var machine: MachinePose?
        public var steps: [Step]

        public init(id: String, title: String, summary: String, when: [Condition] = [], placements: [String: Placement] = [:],
                    machine: MachinePose? = nil, steps: [Step]) {
            self.id = id
            self.title = title
            self.summary = summary
            self.when = when
            self.placements = placements
            self.machine = machine
            self.steps = steps
        }
    }

    /// A setup's work zero in machine coordinates (what `$#` reports for its work offset after
    /// probing, nominally), with the tool's stick-out from the collet nut it was found with.
    public struct MachinePose: Codable, Sendable, Equatable {
        public var workZero: [Double]
        public var stickout: Double

        public init(workZero: [Double], stickout: Double) {
            self.workZero = workZero
            self.stickout = stickout
        }
    }

    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            /// Text to read and do, then Next.
            case instruction
            /// Fit a tool (`tool`): the tool-change card.
            case toolChange
            /// Assemble the fixture and the part (`items` in order); the 3D view shows it.
            case mount
            /// Run a program (`program`); a cut offers an air cut first.
            case run
            /// Measure something (`check`) and record it in the journal.
            case measure
        }
        public var id: String
        public var kind: Kind
        public var title: String
        public var text: String?
        /// A numbered list (mount steps, safety checks).
        public var items: [String] = []
        /// Shown as a warning above the step (hot part, no compressed air…).
        public var caution: String?
        public var program: String?
        public var tool: String?
        public var check: Check?
        public var when: [Condition] = []

        public init(id: String, kind: Kind, title: String, text: String? = nil, items: [String] = [], caution: String? = nil,
                    program: String? = nil, tool: String? = nil, check: Check? = nil, when: [Condition] = []) {
            self.id = id
            self.kind = kind
            self.title = title
            self.text = text
            self.items = items
            self.caution = caution
            self.program = program
            self.tool = tool
            self.check = check
            self.when = when
        }
    }

    public struct Check: Codable, Sendable, Equatable {
        public var what: String
        /// mm.
        public var expected: Double
        public var tolerance: Double
    }

    // MARK: Choosing options

    /// The chosen value of every option (defaults where none is given).
    public func choices(_ chosen: [String: String] = [:]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: options.map { ($0.id, chosen[$0.id] ?? $0.defaultChoice) })
    }

    public func applies(_ conditions: [Condition], _ chosen: [String: String]) -> Bool {
        let c = choices(chosen)
        return conditions.allSatisfy { cond in c[cond.option].map { cond.oneOf.contains($0) } ?? false }
    }

    /// The setups and steps that run for these choices, in order.
    public func plan(_ chosen: [String: String]) -> [(setup: Setup, steps: [Step])] {
        setups.filter { applies($0.when, chosen) }.map { setup in
            (setup, setup.steps.filter { applies($0.when, chosen) })
        }.filter { !$0.steps.isEmpty }
    }

    public func program(_ id: String?) -> ProgramFile? { programs.first { $0.id == id } }

    /// The setup that runs this program with these choices (the first one, if several do).
    public func setup(running programID: String, _ chosen: [String: String]) -> Setup? {
        plan(chosen).first { $0.steps.contains { $0.program == programID } }?.setup
    }
    public func tool(_ id: String?) -> ToolSpec? { tools.first { $0.id == id } }

    // MARK: Files

    public static func load(_ folder: URL) throws -> ProgramJob {
        try JSONDecoder().decode(ProgramJob.self, from: Data(contentsOf: folder.appendingPathComponent("job.json")))
    }

    public func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: folder.appendingPathComponent("job.json"))
    }

    /// Problems that stop the job from running: missing programs or tools, dangling ids.
    public func problems(in folder: URL) -> [String] {
        var problems: [String] = []
        for p in programs where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(p.file).path) {
            problems.append("Program file \(p.file) is missing.")
        }
        for s in setups {
            for step in s.steps {
                if step.kind == .run, program(step.program) == nil { problems.append("\(s.title) ▸ \(step.title): no program \(step.program ?? "-").") }
                if step.kind == .toolChange, tool(step.tool) == nil { problems.append("\(s.title) ▸ \(step.title): no tool \(step.tool ?? "-").") }
            }
        }
        let modelIDs = Set(models.map(\.id))
        for s in setups {
            for id in s.placements.keys where !modelIDs.contains(id) {
                problems.append("\(s.title) uses the unknown model \(id).")
            }
        }
        for s in setups {
            if let m = s.machine, m.workZero.count != 3 || m.stickout <= 0 {
                problems.append("\(s.title): the machine entry needs a work zero (X, Y, Z) and a stick-out above 0.")
            }
        }
        for m in models where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(m.file).path) {
            problems.append("Model file \(m.file) is missing.")
        }
        let optionIDs = Set(options.map(\.id))
        for c in setups.flatMap({ $0.when + $0.steps.flatMap(\.when) }) + options.flatMap(\.when) where !optionIDs.contains(c.option) {
            problems.append("A condition uses the unknown option \(c.option).")
        }
        return problems
    }
}

// MARK: - Decoding with defaults

// Jobs are written by hand too: a missing key takes its default instead of failing.

extension ProgramJob {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        machines = try c.decodeIfPresent([String].self, forKey: .machines) ?? []
        material = try c.decodeIfPresent(String.self, forKey: .material)
        requirements = try c.decodeIfPresent([String].self, forKey: .requirements) ?? []
        options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
        tools = try c.decodeIfPresent([ToolSpec].self, forKey: .tools) ?? []
        models = try c.decodeIfPresent([Model].self, forKey: .models) ?? []
        programs = try c.decodeIfPresent([ProgramFile].self, forKey: .programs) ?? []
        setups = try c.decodeIfPresent([Setup].self, forKey: .setups) ?? []
    }
}

extension ProgramJob.Option {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        choices = try c.decode([ProgramJob.Choice].self, forKey: .choices)
        defaultChoice = try c.decodeIfPresent(String.self, forKey: .defaultChoice) ?? choices.first?.id ?? ""
        when = try c.decodeIfPresent([ProgramJob.Condition].self, forKey: .when) ?? []
    }
}

extension ProgramJob.ProgramFile {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        file = try c.decode(String.self, forKey: .file)
        purpose = try c.decode(Purpose.self, forKey: .purpose)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        changes = try c.decodeIfPresent([String].self, forKey: .changes) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

extension ProgramJob.Setup {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        when = try c.decodeIfPresent([ProgramJob.Condition].self, forKey: .when) ?? []
        placements = try c.decodeIfPresent([String: ProgramJob.Placement].self, forKey: .placements) ?? [:]
        machine = try c.decodeIfPresent(ProgramJob.MachinePose.self, forKey: .machine)
        steps = try c.decode([ProgramJob.Step].self, forKey: .steps)
    }
}

extension ProgramJob.Step {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        items = try c.decodeIfPresent([String].self, forKey: .items) ?? []
        caution = try c.decodeIfPresent(String.self, forKey: .caution)
        program = try c.decodeIfPresent(String.self, forKey: .program)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        check = try c.decodeIfPresent(ProgramJob.Check.self, forKey: .check)
        when = try c.decodeIfPresent([ProgramJob.Condition].self, forKey: .when) ?? []
    }
}
