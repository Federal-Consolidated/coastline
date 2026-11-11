import MillCore
import Foundation

/// Builds the guided job the native runner steps through: mount the stock → edge-find → install
/// each tool → touch off → cut, with air cuts and measuring checkpoints.
public enum GuidedJobBuilder {
    public struct Program: Sendable {
        public var tool: Tool
        public var gcode: String
        public var operationNames: [String]
        public var minutes: Double
        /// 0 = side A, 1 = side B (after flipping the stock).
        public var side: Int
        /// Where the face is when this tool is touched off (work Z): 0 on the stock as clamped,
        /// below it once an earlier program on the side faced it.
        public var touchZ: Double = 0
        /// The program cuts reference features (side A's bores, side B's windows).
        public var reference: Operation.ReferenceFeature?
        /// Probes the face first for an engraving that follows it (SurfaceProbe.program): run
        /// after the touch-off, before the air cut (the program's M112 needs the map).
        public var surfaceProbe: String?
        public var workholding: LibraryWorkholdingPlan.Step?
        public init(tool: Tool, gcode: String, operationNames: [String], minutes: Double, side: Int = 0) {
            self.tool = tool
            self.gcode = gcode
            self.operationNames = operationNames
            self.minutes = minutes
            self.side = side
        }
    }

    /// How the guided job finds the stock's position after each clamping.
    public struct Probing: Sendable {
        /// Which X edges (lower, upper) the machine reaches in this clamping, per side. An edge out
        /// of reach is replaced by the other edge and the stock's height.
        public var lowerXReachable = [true, true]
        public var upperXReachable = [true, true]
        /// Side B's zero from side A's reference bores.
        public var bores: ReferenceBores.Plan?
        public init() {}
    }

    /// A measurement to take after a program, with the expected value.
    public struct Checkpoint: Sendable {
        public var afterProgram: Int
        public var what: String
        public var expected: Double
        public var tolerance: Double
        public init(afterProgram: Int, what: String, expected: Double, tolerance: Double) {
            self.afterProgram = afterProgram
            self.what = what
            self.expected = expected
            self.tolerance = tolerance
        }
    }

    public struct Input: Sendable {
        public var partName: String
        public var material: Material
        public var stock: StockItem
        /// Stock size in the machine: X (vertical), Y (left–right), Z (toward the spindle).
        public var stockSize: SIMD3<Double>
        public var setupName: String
        public var programs: [Program]
        public var checkpoints: [Checkpoint]
        public var measuring: [MeasuringTool]
        /// PNG of the setup (stock and part in the machine), shown on the mounting steps.
        public var setupImage: Data?
        public var faceAllowance: Double
        /// Holding tabs on the side that cuts through (nil: a web holds the part, or one side).
        public var tabs: HoldingTabs?
        /// PNG of side B's setup, shown on the flip step.
        public var flipImage: Data?
        /// How side B turns (Setup.flipAxis): nil or 0 front-to-back about the vertical, 1
        /// rolled over about the stock's length.
        public var flipAxis: Int?
        /// User-supplied workholding (outside the fixture library).
        public var customHolding: Setup.CustomFixture?
        public var probing = Probing()
        /// How far the spindle comes out at the tool-change position (machine Z), when Coast
        /// Runner's own Z would touch the clamps, parallels or stock of this job (worked out
        /// from the fixture's geometry); nil: the maker's.
        public var toolChangeZ: Double?
        /// Where along Y it stops (machine Y), when the maker's Y would put the spindle right
        /// beside the clamps; nil: The maker's.
        public var toolChangeY: Double?

        public init(partName: String, material: Material, stock: StockItem, stockSize: SIMD3<Double>, setupName: String,
                    programs: [Program], checkpoints: [Checkpoint], measuring: [MeasuringTool], setupImage: Data?,
                    faceAllowance: Double = 0.5) {
            self.partName = partName
            self.material = material
            self.stock = stock
            self.stockSize = stockSize
            self.setupName = setupName
            self.programs = programs
            self.checkpoints = checkpoints
            self.measuring = measuring
            self.setupImage = setupImage
            self.faceAllowance = faceAllowance
        }
    }

    // MARK: Fixed helper programs (the maker's conventions [UC])

    static func toolChangeMoves(machine: MachineProfile, z: Double?, y: Double? = nil) -> [String] {
        var moves = machine.toolChangeMoves
        if let z, let k = moves.lastIndex(where: { $0.uppercased().contains("Z") }) {
            moves[k] = "G53 G0 Z\(ReferenceBores.n(z))"
        }
        if let y, let k = moves.lastIndex(where: { $0.uppercased().contains("Y") }) {
            moves[k] = "G53 G0 Y\(ReferenceBores.n(y))"
        }
        return moves
    }

    public static func helperFiles(machine: MachineProfile, toolChangeZ: Double? = nil, toolChangeY: Double? = nil) -> [String: String] {
        [
            "Code/home.nc": "$H\n",
            "Code/tool_change_position.nc": (["G21 G90"] + toolChangeMoves(machine: machine, z: toolChangeZ, y: toolChangeY)).joined(separator: "\n") + "\n",
            "Code/edgefinder_spin.nc": "G21 G90\nM3 S\(Int(machine.probeSpindleRPM))\n",
            "Code/spindle_stop.nc": "M5\n",
            "Code/store_x_low.nc": "G10 L20 P2 X0\nG4 P0.5\n",
            "Code/store_x_high.nc": "G10 L20 P3 X0\nG4 P0.5\n",
            "Code/set_x_centre.nc": "M100 G55X G56X G54X\nG4 P0.5\n",
            "Code/store_y_left.nc": "G10 L20 P2 Y0\nG4 P0.5\n",
            "Code/store_y_right.nc": "G10 L20 P3 Y0\nG4 P0.5\n",
            "Code/set_y_centre.nc": "M100 G55Y G56Y G54Y\nG4 P0.5\n",
            "Code/store_z.nc": "G10 L20 P1 Z0\nG4 P0.5\nG54\n",
        ]
    }

    // MARK: Tool changes, touch-off and finding the stock (Operator manual §4.5–4.6)

    /// Moving to the tool-change position, then changing the tool by hand the way the manual
    /// describes it: both wrenches, the collet snapped into the nut, the stick-out, the chip fan.
    static func toolChangeSteps(_ title: String, tool: Tool, previous: Tool?, note: String = "") -> [Step] {
        let shank = Length.describe(tool.shankDiameter)
        let swapCollet = previous.map { abs($0.shankDiameter - tool.shankDiameter) > 0.01 } ?? true
        let inside = tool.overallLength - tool.stickout
        let collet = swapCollet
            ? (previous == nil
               ? "\n**The collet** must be the **\(shank)** one. If another is in the nut, unscrew the nut completely, pop that collet out and snap the \(shank) one in at a slight angle until it **clicks**. Shake the nut upside down: the collet must not fall out (one that isn't snapped in lets the tool walk out mid-cut). Thread the nut back on a few turns by hand.\n"
               : "\n**Change the collet** to the **\(shank)** one (the last tool had a \(Length.describe(previous!.shankDiameter)) shank): unscrew the nut completely, pop the old collet out and snap the new one in at a slight angle until it **clicks**. Shake the nut upside down: the collet must not fall out. Thread the nut back on a few turns by hand.\n")
            : ""
        return [
            step("Tool Change Position", markdown: """
            Click Next: the machine homes, lowers the table to the bottom of its travel (the stock as far from the spindle as it goes), moves the gantry to where there's room and brings the spindle forward, out of the machine towards you, so the collet nut stands free with room for both wrenches.

            Leave the stock clamped: the zero found for it stays valid.
            """, gcode: "Code/tool_change_position.nc", timeout: 90),
            step(title, markdown: """
            **You need** the 12 mm and 17 mm wrenches\(swapCollet ? " and the \(shank) ER-11 collet" : "").\(note.isEmpty ? "" : " " + note)

            **Take out \(previous.map { "the \($0.name)" } ?? "the tool in the spindle, if there is one")**
            1. Pull the chip fan off the collet nut.
            2. Put the **12 mm wrench on the spindle's flats** and the **17 mm wrench on the collet nut**.
            3. Hold the 12 mm wrench still and turn the 17 mm one to loosen the nut. Unscrew it a little by hand and pull the tool out.
            \(collet)
            **Fit the \(tool.name)**
            4. Slide it into the collet so **\(Length.mm(tool.stickout)) mm sticks out** below the nut (measure it)\(inside < 8 ? "" : "; at least 8 mm of the shank stays in the collet").
            5. Hold it there and tighten the nut by hand as far as it goes.
            6. With both wrenches as before, tighten until it won't easily go further. Don't force it.
            7. Push the chip fan back over the nut, hexagon side first.
            """, popup: ("Tool in?", "Is the \(tool.name) tight in the collet with \(Length.mm(tool.stickout)) mm sticking out?"), noStep: "-0"),
        ]
    }

    /// Paper touch-off by hand (manual §4.6.2): the spindle stopped, 1 → 0.1 → 0.01 mm steps.
    static func paperTouchOff(_ where_: String, extra: String = "") -> String {
        """
        The spindle stays **stopped**. In **Machine Control**:
        1. Jog the tool over \(where_) and toward the face in 1 mm steps until it's 1–2 mm away.
        2. Slide a strip of paper between the tip and the face and keep wiggling it.
        3. Jog in 0.1 mm steps until the paper drags. If it's pinched tight, back off 0.1 mm.
        4. Switch to 0.01 mm steps and jog until the paper just stops moving. Stop there.\(extra)
        """
    }

    /// Where the stock should be in the CURRENT zero (G54) after it was clamped again, from the
    /// last clamping's geometry: the machine moves near each edge, the last millimetres are
    /// found by hand or by probing. `zShift`: how much longer the tool in the spindle is than
    /// the one that set Z0 (the commanded Z is the old tool's tip).
    public struct Approach: Sendable {
        public var centre: SIMD3<Double>
        public var size: SIMD3<Double>
        public var zShift: Double
        public init(centre: SIMD3<Double>, size: SIMD3<Double>, zShift: Double) {
            self.centre = centre
            self.size = size
            self.zShift = zShift
        }

        /// The position beside an edge (axis 0 = X, 1 = Y; side −1/+1), `gap` mm outside it.
        func beside(axis: Int, side: Double, gap: Double, radius: Double) -> SIMD2<Double> {
            var p = SIMD2(centre.x, centre.y)
            let half = axis == 0 ? size.x / 2 : size.y / 2
            p[axis] += side * (half + gap + radius)
            return p
        }

        /// The edge finder's start: back to safe Z, beside the edge, then in to `front` mm
        /// in front of the expected face (never below it: the last part is by hand).
        func program(axis: Int, side: Double, radius: Double, front: Double = 6) -> String {
            let p = beside(axis: axis, side: side, gap: 4, radius: radius)
            let z = centre.z + front + zShift
            return """
            G21 G90
            G53 G0 Z-1
            G54 G0 X\(ReferenceBores.n(p.x)) Y\(ReferenceBores.n(p.y))
            G0 Z\(ReferenceBores.n(z + 6))
            G1 Z\(ReferenceBores.n(z)) F400

            """
        }

        /// The probing tool's start (electrical, Z0 just set on this face with this tool):
        /// beside the edge, then down with G38.3, which stops without an alarm if it touches.
        func probeProgram(axis: Int, side: Double, radius: Double, depth: Double) -> String {
            let p = beside(axis: axis, side: side, gap: 3, radius: radius)
            return """
            G21 G90
            G54 G0 Z5
            G0 X\(ReferenceBores.n(p.x)) Y\(ReferenceBores.n(p.y))
            G38.3 Z\(ReferenceBores.n(-depth)) F150

            """
        }
    }

    // MARK: Build

    public static func build(_ input: Input, machine: MachineProfile = .standard) -> (jobs: [Job], files: [String: Data]) {
        var files: [String: Data] = helperFiles(machine: machine, toolChangeZ: input.toolChangeZ, toolChangeY: input.toolChangeY).mapValues { Data($0.utf8) }
        if let img = input.setupImage { files["Image/setup.png"] = img }
        if let img = input.flipImage { files["Image/flip.png"] = img }
        var jobs: [Job] = []
        jobs.append(partJob(input, machine: machine, files: &files))
        return (jobs, files)
    }

    public static func validateWorkholding(_ input: Input) throws {
        for program in input.programs {
            if let step = program.workholding, !step.reviewed {
                throw NSError(domain: "Coastline.Workholding", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Review placement and secure grip for \(step.title) before exporting or running."])
            }
        }
    }

    // MARK: The part job

    static func partJob(_ i: Input, machine: MachineProfile, files: inout [String: Data]) -> Job {
        var job = Job(title: "\(i.setupName) · \(i.partName)",
                      prompt: "Machines \(i.partName) from \(i.material.name), in \(i.programs.count) tool program\(i.programs.count == 1 ? "" : "s").")
        var steps: [Step] = []
        let size = i.stockSize
        let toolList = i.programs.enumerated().map { k, p in
            "\(k + 1). **\(p.tool.name)**, stick-out \(Length.mm(p.tool.stickout)) mm (\(p.operationNames.joined(separator: ", ")), about \(Int(p.minutes.rounded())) min)"
        }.joined(separator: "\n")
        steps.append(step("Before You Start", markdown: """
        This job was planned by **Coastline** for your machine.

        **Material** \(i.material.name). \(i.material.lubricant)

        **Stock** \(Length.mm(size.x)) mm tall (X) × \(Length.mm(size.y)) mm wide (Y) × \(Length.mm(size.z)) mm thick (toward the spindle).

        **Tools, in order**
        \(toolList)

        Stay with the machine while it cuts, and keep a hand near the E-stop. Never use compressed air on the machine; vacuum chips instead.
        """))
        steps.append(step("Home the Machine", text: "Click Next to home all axes.", gcode: "Code/home.nc", timeout: 60))
        if let custom = i.customHolding {
            steps.append(step("Mount the Stock", markdown: """
            Secure the stock in **\(custom.name)** with its \(Length.mm(size.x)) × \(Length.mm(size.y)) mm face toward the spindle.

            Stock bottom: **\(Length.mm(custom.height)) mm above the table**. Stock face: **\(Length.mm(custom.faceProtrusion)) mm past the table's front edge**.

            \(custom.notes)

            The face toward the spindle is **Z0**; its centre is **X0 Y0**. Edge-find and touch off after mounting.

            **Custom fixture geometry is not included in collision checks.** Check cutter, shank and holder clearance to your jaws and fasteners. Keep the part secured independently of material removed by these programs.
            """, image: i.setupImage == nil ? "" : "Image/setup.png",
                              popup: ("Stock secured?", "Is the stock secured in your fixture, with cutter and holder clearance checked?")))
        } else if let holding = i.programs.first?.workholding {
            steps.append(step("Mount the Stock · \(holding.title)", markdown: """
            \(holding.instructions)

            The face toward the spindle is **Z0**; its centre is **X0 Y0**. The next steps establish work zero.
            """, image: i.setupImage == nil ? "" : "Image/setup.png",
                              popup: ("Stock secured?", "Is the stock secured in \(holding.fixture.name), with the defined grip patches intact?")))
        } else {
            steps.append(step("Mount the Stock", markdown: """
            Secure the stock with its **\(Length.mm(size.y)) × \(Length.mm(size.x)) mm face toward the spindle**, square to the spindle.

            The face toward the spindle becomes **Z0**; the middle of that face becomes **X0 Y0**. The next steps find the stock's real edges and face, and every program follows them.
            """, image: i.setupImage == nil ? "" : "Image/setup.png",
                              popup: ("Stock clamped?", "Is the stock clamped tight and square to the spindle?")))
        }
        let pr = i.probing
        // The tool in the spindle with its Z set (nil after the edge finder or a flip), and
        // the last one fitted (for the tool change: which collet it had, how long it was).
        var spindle: Tool?
        var fitted: Tool?
        func touchZFile(_ z: Double) -> String {
            let name = "Code/store_z\(abs(z) < 1e-9 ? "" : "_" + ReferenceBores.n(z).replacingOccurrences(of: "-", with: "m").replacingOccurrences(of: ".", with: "_")).nc"
            if abs(z) > 1e-9 {
                files[name] = Data("G10 L20 P1 Z\(ReferenceBores.n(z))\nG4 P0.5\nG54\n".utf8)
            }
            return name
        }
        func installTool(_ n: Int, _ p: Program) {
            if spindle?.id == p.tool.id { return }
            steps += toolChangeSteps("Change to Tool \(n)", tool: p.tool, previous: fitted)
            fitted = p.tool
            let faced = p.touchZ < -1e-6 ? " The face was milled \(Length.mm(-p.touchZ)) mm down by an earlier program: touch off anywhere on the milled face (Coastline stores it as Z\(ReferenceBores.n(p.touchZ)))." : ""
                steps.append(step("Touch Off Tool \(n) on the Face", markdown: """
                Touch off the face by hand with paper for this setup.

                \(paperTouchOff("a solid spot of the stock face (the frame, not over a cut)", extra: faced.isEmpty ? "" : "\n\n" + faced))
                """, popup: ("Paper pinched?", "Is the paper just pinched between the tool and the stock face?"), noStep: "-0"))
                steps.append(step("Record Z0 for Tool \(n)", text: "Click Next to store this height\(abs(p.touchZ) < 1e-9 ? " as Z0" : "") .", gcode: touchZFile(p.touchZ)))
            spindle = p.tool
        }
        /// X0 Y0 after a clamping: the edges, with the edge finder.
        func findEdges(side: Int, first k: Int) {
            if let holding = i.programs[k].workholding {
                steps.append(step("Establish Work Zero · \(holding.title)", markdown: """
                In Machine Control, establish **G54 X0 Y0 at the original stock-face centre and Z0 at the original stock face**, using this fixture's locating datum. Account for material removed in previous setups.

                Do not use an edge or surface that has been machined away as though it were the original blank. Use the fixture's repeatable reference or a measured offset. This step does not move or probe automatically.

                \(holding.fixture.notes)
                """, popup: ("Work zero verified?", "Have you established and verified G54 for \(holding.fixture.name) using its locating reference?")))
                spindle = nil
                return
            }
            let lower = pr.lowerXReachable[min(side, 1)], upper = pr.upperXReachable[min(side, 1)]
            // Side B: turned about the vertical in the same clamps, so it sits where side A
            // did. The machine can bring the tool or finder close; the edges are still found.
            let lastZ = side == 1 && i.customHolding == nil ? i.programs[..<k].last?.tool : nil
                let near = lastZ.map { Approach(centre: .zero, size: size, zShift: EdgeFinding.tool.stickout - $0.stickout) }
                steps += edgeFindSteps(machine: machine, lower: lower, upper: upper, height: size.x, previous: fitted, approach: near,
                                       tag: "s\(side)p\(k)", files: &files)
                spindle = nil
                fitted = EdgeFinding.tool
        }

        findEdges(side: 0, first: 0)
        for (k, p) in i.programs.enumerated() {
            let n = k + 1
            if k > 0, let holding = p.workholding, holding.id != i.programs[k - 1].workholding?.id {
                let before = i.programs[k - 1].side
                let flip = p.side == before ? "Keep the part's current orientation. "
                    : p.side >= 2 ? ""  // its instructions say how to turn it
                    : p.side == 1 && before == 0 ? (i.flipAxis == 1 ? "Roll the stock over about its length for side B. " : "Turn the stock front-to-back about its vertical axis for side B. ")
                    : "Turn the stock so its \(SetupSide.words(p.side)) faces the spindle. "
                steps.append(step("Change Workholding · \(holding.title)", markdown: """
                Stop the spindle and move the tool clear by hand before releasing any fixture. \(flip)

                \(holding.instructions)

                This continues the same partially machined stock. Do not substitute a fresh blank. The next steps establish work zero again; the previous fixture's zero is not reused.
                """, popup: ("New setup secured?", "Is the stock secured in \(holding.fixture.name), with the defined grip patches intact and the tool clear?")))
                spindle = nil
                findEdges(side: p.side, first: k)
            } else if p.workholding == nil && p.side == 1 && (k == 0 || i.programs[k - 1].side == 0) {
                if let custom = i.customHolding {
                    steps.append(step("Flip the Stock", markdown: """
                    Vacuum the chips. \(i.flipAxis == 1 ? "Roll the stock over about its length" : "Turn the stock front-to-back about its vertical axis") and secure it in **\(custom.name)** for side B.

                    \(custom.notes)

                    Check cutter and holder clearance to the fixture again. The next steps find the stock's edges and face afresh; the previous clamping's position is not assumed.
                    """, image: i.flipImage == nil ? "" : "Image/flip.png",
                                      popup: ("Stock secured for side B?", "Is the stock turned front-to-back and secured in your fixture with clearance checked?")))
                } else {
                steps.append(step("Flip the Stock", markdown: """
                Side A is done. Vacuum the chips from the stock, the fixture and the table\(pr.bores != nil ? ", and out of the two reference bores in the frame" : "").

                \(i.flipAxis == 1
                    ? "Release the stock and **roll it over** about its length: the face that was at the back now faces the spindle, and the face that was on the table is now on top. Its ends stay where they were. Secure it again."
                    : "Release the stock and **turn it front-to-back** about its vertical axis: the face that was at the back now faces the spindle, and the end that was on the left is now on the right. Secure it again.")

                The next steps find the stock's edges and face afresh.\(pr.bores != nil ? " Side B's edges give a first zero; the reference bores then set it exactly." : "")
                """, image: i.flipImage == nil ? "" : "Image/flip.png", gcode: "Code/tool_change_position.nc", timeout: 90,
                popup: ("Flipped and secured?", "Is the stock turned front-to-back and secured again?")))
                }
                spindle = nil
                findEdges(side: 1, first: k)
            }
            let cutPath = "Code/T\(n)_cut.nc"
            let airPath = "Code/T\(n)_aircut.nc"
            files[cutPath] = Data(p.gcode.utf8)
            files[airPath] = Data(AirCut.make(from: p.gcode).utf8)
            installTool(n, p)
            if let probe = p.surfaceProbe {
                let probePath = "Code/T\(n)_surface.nc"
                files[probePath] = Data(probe.utf8)
                let count = probe.components(separatedBy: "M111").count - 1
                steps.append(step("Probe the Surface", markdown: """
                The engraving follows the real face, not the CAD: the tool feels it at **\(count) points** over the text. It turns slowly backwards and creeps down at each one until it touches (the stock is insulated in the fixture; the probe wire stays on the fixture).

                The points go into the sender's contour map (M111); the engraving turns the compensation on (M112), so its depth stays the same everywhere, even on a face that isn't quite flat or square.
                """, gcode: probePath, timeout: 240,
                popup: ("Wire on the fixture?", "Is the probe wire plugged in and fixed to the fixture, and the tool clean?")))
            }
            steps.append(step("Air Cut First?", markdown: """
            The first time you run a program, run it **10 mm above the stock with the spindle off**. Watch that every move goes where you expect.
            """, popup: ("Run an air cut?", "Run program \(n) as an air cut first? Choose No to skip straight to cutting."), noStep: "+2"))
            steps.append(step("Air Cut · Program \(n)", text: "The tool moves 10 mm above the work with the spindle off.", gcode: airPath))
            let refNote: String = switch p.reference {
            case .bores?: "\n\nThis program also bores **two reference holes** in the frame (⌀\(ReferenceBores.n(ReferenceBores.diameter)) mm, \(Length.mm(pr.bores?.depthA ?? 0)) mm deep). Side B finds its zero from them: keep them clean."
            case .windows?: "\n\nIt opens the two **reference bores** from this side (⌀\(ReferenceBores.n(ReferenceBores.windowDiameter)) mm windows, \(Length.mm(pr.bores?.windowDepth ?? 0)) mm deep) so they can be found next."
            case nil: ""
            }
            steps.append(step("Cut · Program \(n)", markdown: """
            **\(p.operationNames.joined(separator: " → "))** with \(p.tool.name). About \(Int(p.minutes.rounded())) minutes.\(refNote)

            \(i.material.chips)
            """, gcode: cutPath))
            steps.append(step("Clear the Chips", markdown: """
            Vacuum the chips from the stock, clamps and table\(p.reference == .windows ? ", and out of both reference bores (a chip in a bore throws the probing off)" : ""). Never use compressed air: it drives chips into the machine's bearings.
            """))
            if p.reference == .windows, let plan = pr.bores {
                steps += borePickupSteps(plan, tool: p.tool, electrical: false, files: &files)
                spindle = nil
            }
            for c in i.checkpoints where c.afterProgram == k {
                steps += checkpointSteps(c, measuring: i.measuring)
            }
        }
        let twoSided = i.programs.contains { $0.side == 1 }
        let free: String
        if let t = i.tabs {
            free = "cut the part free. It hangs in the frame on **\(t.count) small tabs** (\(Length.mm(t.width)) mm wide, \(Length.mm(t.height)) mm thick): cut each one close to the part with a jeweller's saw\(i.material.family == .wax || i.material.family == .plastic ? " or flush cutters" : ""), then file and sand the stubs flush"
        } else if twoSided && i.customHolding == nil {
            free = "saw through the thin web to free the part, then file the web marks flush"
        } else {
            free = "deburr the part"
        }
        steps.append(step("Done", markdown: """
        Home the machine, unclamp the stock and \(free).

        **Finishing**
        \(FinishingGuide.steps(for: i.material).map { "- " + $0 }.joined(separator: "\n"))

        Log the result in Coastline's job journal: measured sizes, finish and any chatter. Coastline uses them to tune the next job.
        """, gcode: "Code/home.nc"))
        job.steps = steps
        return job
    }

    /// Edge finding to the stock centre in X and Y, as the maker's cutcodes do it:
    /// store both edges in G55/G56, then M100 puts their midpoint into G54. The edge finder's
    /// radius cancels out in the midpoint. An X edge out of the machine's reach: X0 from the other
    /// edge and the stock's height instead.
    static func edgeFindSteps(machine: MachineProfile, note: String = "", lower: Bool = true, upper: Bool = true,
                              height: Double = 0, previous: Tool? = nil, approach: Approach? = nil, tag: String = "",
                              files: inout [String: Data]) -> [Step] {
        var s: [Step] = []
        let finder = EdgeFinding.tool
        let r = finder.diameter / 2
        if previous.map(EdgeFinding.isEdgeFinder) != true {
            s += toolChangeSteps("Fit the Edge Finder", tool: finder, previous: previous,
                                 note: "The stock was just clamped, so its edges are found again: everything after this works from them. The **edge finder** spins at \(Int(machine.probeSpindleRPM)) RPM while you search. \(note)")
        } else if !note.isEmpty {
            s.append(step("Edge Finder Still In", markdown: "The edge finder is still in the spindle. \(note)"))
        }
        s.append(step("Start the Edge Finder", text: "Click Next to spin the edge finder.", gcode: "Code/edgefinder_spin.nc"))
        /// The machine's move near an edge (when the stock's place is known), then the pair.
        func edge(_ title: String, _ where_: String, _ store: String, axis: Int, side: Double) {
            if let a = approach {
                let file = "Code/near_\(tag)_\(axis == 0 ? "x" : "y")\(side < 0 ? "lo" : "hi").nc"
                files[file] = Data(a.program(axis: axis, side: side, radius: r).utf8)
                s.append(step("Move Near the \(title)", markdown: "Click Next: the machine drives the spinning finder to about 4 mm outside \(where_), 6 mm in front of the face, from where the stock should be. It can't feel the edge: if the stock sits elsewhere, stop and jog instead.",
                              gcode: file, timeout: 60))
            }
            s += edgePair(title, where_, store, nearby: approach != nil)
        }
        if lower && upper {
            edge("Lower Edge (X)", "the **lower** edge of the stock", "Code/store_x_low.nc", axis: 0, side: -1)
            edge("Upper Edge (X)", "the **upper** edge of the stock", "Code/store_x_high.nc", axis: 0, side: 1)
            s.append(step("Centre in X", text: "Click Next to set X0 halfway between the two edges.", gcode: "Code/set_x_centre.nc"))
        } else {
            let useLower = lower
            let name = useLower ? "x_from_lower.nc" : "x_from_upper.nc"
            files["Code/" + name] = Data(ReferenceBores.singleEdgeProgram(axis: "X", toward: useLower ? 1 : -1, edgeAt: (useLower ? -1 : 1) * height / 2,
                                                                         radius: EdgeFinding.tool.diameter / 2, electrical: false).utf8)
            s.append(step("Find the \(useLower ? "Lower" : "Upper") Edge (X)", markdown: """
            The \(useLower ? "upper" : "lower") edge is **out of the machine's reach** in this clamping, so X0 comes from the \(useLower ? "lower" : "upper") edge and the stock's height, **\(Length.mm(height)) mm** (measure it: if it differs, the part shifts by half the difference).

            \(edgeFinding("the **\(useLower ? "lower" : "upper")** edge"))
            """, popup: ("Edge found?", "Has the edge finder just clicked off-centre at the edge, in 0.01 mm steps?"), noStep: "-0"))
            s.append(step("Set X0 from the Edge", text: "Click Next to set X0 half the stock's height from this edge.", gcode: "Code/" + name))
        }
        edge("Left Edge (Y)", "the **left** edge of the stock", "Code/store_y_left.nc", axis: 1, side: -1)
        edge("Right Edge (Y)", "the **right** edge of the stock", "Code/store_y_right.nc", axis: 1, side: 1)
        s.append(step("Centre in Y", text: "Click Next to set Y0 halfway between the two edges.", gcode: "Code/set_y_centre.nc"))
        s.append(step("Stop the Spindle", text: "Click Next to stop the edge finder.", gcode: "Code/spindle_stop.nc"))
        return s
    }

    static func edgeFindSteps(machine: MachineProfile, note: String = "", previous: Tool? = nil) -> [Step] {
        var unused: [String: Data] = [:]
        return edgeFindSteps(machine: machine, note: note, previous: previous, files: &unused)
    }

    /// Side B's exact zero from side A's reference bores (after the windows are open).
    static func borePickupSteps(_ plan: ReferenceBores.Plan, tool: Tool, electrical: Bool, files: inout [String: Data]) -> [Step] {
        var s: [Step] = []
        let b = plan.centresB
        s.append(step("Reference Bores", markdown: """
        Side A bored two ⌀\(ReferenceBores.n(ReferenceBores.diameter)) mm holes in the frame from the same zero as the part, and side B just opened them. Their centres are found now and **X0 Y0 is set from them**: side B then lines up with side A to a few hundredths, whatever the stock's edges are like.

        Bore 1 is at X\(ReferenceBores.n(b[0].x)) Y\(ReferenceBores.n(b[0].y)), bore 2 at X\(ReferenceBores.n(b[1].x)) Y\(ReferenceBores.n(b[1].y)) (side B). Each bore's diameter, their spacing and the line between them are checked: if anything is off (a chip, a wrong flip, the stock seated crooked) the step stops with a message instead of cutting.
        """))
        if electrical {
            for k in 0..<2 {
                let file = "Code/B_bore\(k + 1).nc"
                files[file] = Data(ReferenceBores.boreProgram(plan, bore: k, toolDiameter: tool.diameter, electrical: true).utf8)
                s.append(step("Find Bore \(k + 1)", markdown: """
                Click Next: the tool goes down into bore \(k + 1) (\(ReferenceBores.n(-plan.probeZ)) mm deep) and touches its wall four times, turning slowly backwards.
                """, gcode: file, timeout: 300))
            }
        } else {
            s.append(step("Install the Edge Finder", markdown: """
            The spindle moves to the tool-change position. Take the tool out and fit the **edge finder**: it finds the bores' walls.
            """, gcode: "Code/tool_change_position.nc", timeout: 90))
            for k in 0..<2 {
                let over = "Code/B_over_bore\(k + 1).nc"
                files[over] = Data("G21 G90\nG53 G0 Z-1\nG54 G0 X\(ReferenceBores.n(b[k].x)) Y\(ReferenceBores.n(b[k].y))\nG0 Z3\n".utf8)
                s.append(step("Over Bore \(k + 1)", text: "Click Next to bring the edge finder over bore \(k + 1).", gcode: over, timeout: 120))
                s.append(step("Start the Edge Finder", text: "Click Next to spin the edge finder.", gcode: "Code/edgefinder_spin.nc"))
                s.append(step("Into Bore \(k + 1)", markdown: """
                In **Machine Control**, lower the edge finder into the bore to about **Z\(ReferenceBores.n(plan.probeZ))**, its tip below the wider window, in the bore's own wall.
                """, popup: ("In the bore?", "Is the edge finder's tip down in the narrow bore, not touching?"), noStep: "-0"))
                for axis in ["X", "Y"] {
                    let plus = "Code/B_wall_\(axis)p.nc", minus = "Code/B_wall_\(axis)m.nc"
                    files[plus] = Data(ReferenceBores.storeWall(axis: axis, positive: true).utf8)
                    files[minus] = Data(ReferenceBores.storeWall(axis: axis, positive: false).utf8)
                    for (sign, file) in [("+", plus), ("−", minus)] {
                        s.append(step("Bore \(k + 1): \(sign)\(axis) Wall", markdown: """
                        Step toward the bore's **\(sign)\(axis)** wall (0.1 mm, then 0.01 mm moves) until the edge finder **kicks off-centre**.
                        """, popup: ("Wall found?", "Has the edge finder just kicked at the \(sign)\(axis) wall?"), noStep: "-0"))
                        s.append(step("Record the \(sign)\(axis) Wall", text: "Click Next to store this position.", gcode: file))
                    }
                    let centre = "Code/B_bore\(k + 1)_\(axis).nc"
                    files[centre] = Data((ReferenceBores.storeCentre(bore: k, axis: axis, toolDiameter: EdgeFinding.tool.diameter)
                                          + "G\(k == 0 ? 55 : 56) G0 \(axis)0\n").utf8)
                    s.append(step("Bore \(k + 1): Centre in \(axis)", text: "Click Next to store the centre in \(axis) and move there.", gcode: centre))
                }
                files["Code/B_up.nc"] = Data("G53 G0 Z-1\n".utf8)
                s.append(step("Up Out of Bore \(k + 1)", text: "Click Next to raise the edge finder.", gcode: "Code/B_up.nc"))
            }
            s.append(step("Stop the Spindle", text: "Click Next to stop the edge finder.", gcode: "Code/spindle_stop.nc"))
        }
        files["Code/B_bores_zero.nc"] = Data(ReferenceBores.zeroProgram(plan).utf8)
        s.append(step("Set X0 Y0 from the Bores", markdown: """
        Click Next to check the two centres against each other and set X0 Y0 from them. The tool then stands over bore 1 at the top of its travel.
        """, gcode: "Code/B_bores_zero.nc", timeout: 120))
        return s
    }

    /// Edge finding by hand (manual §4.6.1): 1 → 0.1 → 0.01 mm steps, backing off between.
    static func edgeFinding(_ where_: String, nearby: Bool = false) -> String {
        """
        In **Machine Control**:
        1. \(nearby ? "Jog toward the stock (−Z) about 7.5 mm, so the tip is 1.5 mm below the face beside the edge." : "Bring the spinning edge finder beside \(where_), its tip about 1.5 mm below the face (its side touches, not its end).")
        2. Jog toward the edge in 1 mm steps until it **clicks** and kicks off-centre.
        3. Back off 1 mm, then jog in 0.1 mm steps until it clicks again.
        4. Back off 0.1 mm, then jog in 0.01 mm steps until it just clicks. Stop there.
        """
    }

    private static func edgePair(_ title: String, _ where_: String, _ store: String, nearby: Bool = false) -> [Step] {
        [
            step("Find the \(title)", markdown: edgeFinding(where_, nearby: nearby),
                 popup: ("Edge found?", "Has the edge finder just clicked off-centre at the edge, in 0.01 mm steps?"), noStep: "-0"),
            step("Record the \(title)", text: "Click Next to store this position.", gcode: store),
        ]
    }

    /// Measure, then a yes/no. No goes to a step with advice, which loops back to measuring.
    static func checkpointSteps(_ c: Checkpoint, measuring: [MeasuringTool]) -> [Step] {
        let instrument = measuring.first { [.micrometer, .caliper].contains($0.kind) }?.name ?? "a caliper (add one to your inventory)"
        let low = Length.mm(c.expected - c.tolerance), high = Length.mm(c.expected + c.tolerance)
        return [
            step("Measure · \(c.what)", markdown: """
            With **\(instrument)**, measure \(c.what.lowercased()).

            **Expected** \(Length.mm(c.expected)) mm (between \(low) and \(high) mm).
            """, popup: ("In tolerance?", "Is \(c.what.lowercased()) between \(low) and \(high) mm?"), noStep: "+1", yesStep: "+2"),
            step("Out of Tolerance", markdown: """
            Don't unclamp the stock.

            - **Too big**: the tool may be deflecting or worn. Re-run the finishing program (it removes only what's left), or add a spring pass.
            - **Too small**: check the tool's real diameter and stick-out, and the touch-off.

            Note the measurement for the job journal, then measure again.
            """, goTo: "-1"),
        ]
    }

    // MARK: Step helper

    static func step(_ title: String, text: String = "", markdown: String = "", image: String = "", gcode: String = "",
                     timeout: UInt = 0, popup: (String, String)? = nil, noStep: String = "", yesStep: String = "",
                     goTo: String = "") -> Step {
        var s = Step(manifest: "manifest.yml")
        s.title = clean(title)
        s.prompt = clean(text)
        s.markdown = safeMarkdown(markdown)
        s.imagePath = image
        s.gcodePath = gcode
        s.timeout = timeout
        if let popup {
            s.popupTitle = clean(popup.0)
            s.popupText = clean(popup.1)
        }
        s.popupNoStep = noStep
        s.popupYesStep = yesStep
        s.goTo = goTo
        return s
    }

    /// Scalars can't contain '#' (comment marker in the cutcode format).
    static func clean(_ s: String) -> String { s.replacingOccurrences(of: "#", with: "No.") }

    /// Markdown blocks end at any line that looks like `key: value`, and 3-character lines are
    /// skipped by the sender's parser. Make every line safe without changing what it says.
    public static func safeMarkdown(_ md: String) -> String {
        guard !md.isEmpty else { return "" }
        let keyLike = try! NSRegularExpression(pattern: #"^\s*[A-Za-z0-9_\-]+\s*:"#)
        return md.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            var line = String(raw)
            if keyLike.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { line = "› " + line }
            if line.count == 3 { line += " " }
            return line
        }.joined(separator: "\n")
    }
}

/// The air-cut copy of a program: spindle never starts, and every work-coordinate Z is lifted,
/// so the whole program can be watched safely above the stock.
public enum AirCut {
    public static func make(from gcode: String, lift: Double = 10) -> String {
        var out = ["(AIR CUT: spindle off, all moves \(GRBLPost.fmt(lift)) mm above the work)"]
        for raw in gcode.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            let upper = line.uppercased()
            if upper.hasPrefix("(") { out.append(line); continue }
            if upper.contains("M3") || upper.contains("M4") || upper.range(of: #"^S\d"#, options: .regularExpression) != nil {
                out.append("(spindle start removed: " + line.replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]") + ")")
                continue
            }
            if !upper.contains("G53"), let r = line.range(of: #"Z(-?\d+(\.\d+)?)"#, options: .regularExpression) {
                let v = Double(line[r].dropFirst()) ?? 0
                line.replaceSubrange(r, with: "Z" + GRBLPost.fmt(v + lift))
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

/// A standalone facing program (zig-zag along Y), for stock squaring.
public enum FacingProgram {
    public static func make(width: Double, length: Double, depth: Double, tool: Tool, data: CuttingData,
                            machine: MachineProfile, title: String) -> String {
        GRBLPost.program(header: .init(programName: title, setupName: "Squaring", tool: tool, operationNames: ["Facing"],
                                      stockDescription: "\(Length.mm(width)) × \(Length.mm(length)) mm face"),
                        rpm: data.rpm, paths: [OperationToolpath(operationID: UUID(), moves: moves(width: width, length: length, depth: depth, tool: tool, data: data))],
                        machine: machine)
    }

    /// The facing moves (work frame: X across the face's width, Y along its length).
    /// - yRange: where the tool centre travels along Y (default: past both ends). startHigh:
    ///   enter from its high end (the open end of a shoulder at +Y).
    public static func moves(width: Double, length: Double, depth: Double, tool: Tool, data: CuttingData,
                             yRange: ClosedRange<Double>? = nil, startHigh: Bool = false, safeZ: Double = 3) -> [Move] {
        let r = tool.diameter / 2
        var moves: [Move] = []
        let passes = max(1, Int((depth / max(data.stepdown, 0.05)).rounded(.up)))
        var y0 = yRange?.lowerBound ?? (-length / 2 - r - 1), y1 = yRange?.upperBound ?? (length / 2 + r + 1)
        if startHigh { swap(&y0, &y1) }
        var xs: [Double] = []
        var x = -width / 2 - r + data.stepover * 0.5
        while x - r < width / 2 { xs.append(x); x += data.stepover }
        for p in 1...passes {
            let z = -depth * Double(p) / Double(passes)
            moves.append(Move(.rapid, x: xs[0], y: y0, z: safeZ))
            moves.append(Move(.rapid, x: xs[0], y: y0, z: 1))
            moves.append(Move(.plunge, x: xs[0], y: y0, z: z, feed: data.plungeFeed))
            var forward = true
            for (k, xv) in xs.enumerated() {
                if k > 0 { moves.append(Move(.link, x: xv, y: forward ? y0 : y1, z: z, feed: data.feed)) }
                moves.append(Move(.cut, x: xv, y: forward ? y1 : y0, z: z, feed: data.feed))
                forward.toggle()
            }
            moves.append(Move(.rapid, x: xs.last!, y: forward ? y0 : y1, z: safeZ))
        }
        return moves
    }
}
