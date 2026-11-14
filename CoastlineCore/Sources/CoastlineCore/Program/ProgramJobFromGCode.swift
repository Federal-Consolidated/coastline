import Foundation

extension ProgramJob {
    /// A job around your own G-code (from any CAM program or by hand): Coastline adds homing,
    /// the tool card, mounting and setting the work zero, then runs each file in order, with an
    /// air cut offered first. The files are converted for the machine (mm, spindle limit) and kept
    /// in the job folder.
    public static func fromGCode(_ files: [(name: String, text: String)], title: String, tool: ToolSpec,
                                 workOffset: Int = 54, machine: MachineProfile = .standard, into folder: URL) throws -> ProgramJob {
        var job = ProgramJob(id: PackageImport.slug(title), title: title,
                             summary: "Your G-code: \(files.map(\.name).joined(separator: ", ")).")
        job.tools = [tool]
        job.machines = [machine.name]
        let programsFolder = folder.appendingPathComponent("programs")
        try FileManager.default.createDirectory(at: programsFolder, withIntermediateDirectories: true)

        let home = "(Home, then go to the tool position)\n" + machine.toolChangeMoves.joined(separator: "\n") + "\n"
        try home.write(to: programsFolder.appendingPathComponent("home.nc"), atomically: true, encoding: .utf8)
        job.programs.append(ProgramFile(id: "home", title: "Home and go to the tool position", file: "programs/home.nc", purpose: .move))

        var cutSteps: [Step] = []
        for (k, f) in files.enumerated() {
            let prepared = GCodeConvert.prepare(f.text, machine: machine)
            let stem = ((f.name as NSString).deletingPathExtension as NSString).lastPathComponent
            let id = "p\(k + 1)-" + PackageImport.slug(stem)
            let file = "programs/\(String(format: "%02d", k + 1))_\(stem).nc"
            try prepared.text.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
            let read = GCodeReader.read(prepared.text)
            // Your files are the cuts (the air cut is offered for each), whatever their size.
            job.programs.append(ProgramFile(id: id, title: stem, file: file, purpose: read.moves.isEmpty ? .move : .cut,
                                            tool: tool.id, changes: prepared.changes, source: f.name))
            cutSteps.append(Step(id: "run-\(id)", kind: .run, title: "Run \(stem)", program: id))
        }

        let g = "G\(workOffset)"
        job.setups = [
            Setup(id: "prepare", title: "Prepare", summary: "Home the machine and fit the tool.", steps: [
                Step(id: "clear", kind: .instruction, title: "Clear the Machine",
                     text: "Take off the chip cover if there is one. Nothing may be in the work area."),
                Step(id: "home", kind: .run, title: "Home and Go to the Tool Position", program: "home"),
                Step(id: "fit-tool", kind: .toolChange, title: "Fit the \(tool.name)", tool: tool.id),
            ]),
            Setup(id: "zero", title: "Mount and Set the Work Zero", summary: "Clamp the stock, then tell Coastline where your program's zero is.", steps: [
                Step(id: "mount", kind: .instruction, title: "Clamp the Stock",
                     text: "Clamp the stock so that the tool can reach every cut and no clamp is in the path."),
                Step(id: "set-zero", kind: .instruction, title: "Set the Work Zero (\(g))",
                     text: "In Machine Control, jog the tool tip to the point your CAM program uses as zero (usually X0 Y0 at a corner or the middle, Z0 on top of the stock). Then press Set Work Zero. Your program runs in \(g)."),
            ]),
            Setup(id: "cut", title: "Cut", summary: "\(files.count) program\(files.count == 1 ? "" : "s").",
                  steps: cutSteps + [
                    Step(id: "finish", kind: .instruction, title: "Finish",
                         text: "Vacuum the chips. Never use compressed air on the machine."),
                  ]),
        ]
        try job.save(to: folder)
        return job
    }
}
