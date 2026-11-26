# Feature catalog

Every feature in this repository, what it does, where it lives and how to test it. It is written
so that a person, or a coding assistant working on the other branch, can find one feature
and carry it over without reading the whole code base.

Coastline has two lines of work in this repository, each on its own branch:

- **Line C (control), branch `main`:** releases v0.2 – v0.10. Native machine control, the fixture
  library planner, machine profiles, side setups, resource libraries, the toolpath cache and more.
- **Line K (clamp kit), branch `xioaniumi`:** everything in line C, plus the original CR-1
  workflow that v0.6 ("Remove the clamp kit, other job formats and side features") took out: the
  clamp kit and bed holding, stock prep, guided `.crproj` export, examples and the side tools
  (nest, tuner, deviation map, batching), and bit IDs with wear tracking (K10).

Line K is built on top of line C's latest commit, so GitHub's compare view shows exactly what it
adds. Both workflows run side by side there: a job uses the clamp kit unless it is planned from the
fixture library (`Setup.planFromFixtureLibrary`) or held in a custom fixture. How the two branches
trade features is in [SYNC.md](SYNC.md).

Checks on line K: planning core 258 passed, machine core (MillCore) 123 passed, engine 113 passed.
The app builds and generates the Motor Mount example (shoulders + clamp kit) with every program
passing the safety check.

---

## How to port a feature

1. **Find it below.** Each entry lists its files, entry points, tests and what it depends on.
2. **Copy the files** marked *own files*. They are self-contained or only use types listed under
   *depends on*.
3. **Apply the hooks.** *Hooks* are the few places in shared files that call into the feature.
   Search for the names given; they are stable.
4. **Run its tests:** `scripts/selftest.sh <Filter>` runs the Swift self-tests whose suite matches
   the filter (for example `scripts/selftest.sh Fixture`). `cd MillCore && swift run MillCoreSelfTest`
   for the machine core, `cd engine && uv run python -m pytest -q` for the engine.
5. **Check the app** with script mode, no screen needed:
   `COASTLINE_INVENTORY=/tmp/inv.json COASTLINE_SCRIPT="example motor_mount; generate; quit" Coastline/.build/debug/Coastline`
   (always point `COASTLINE_INVENTORY` at a scratch file).

Rules that hold for every feature: every G-code program passes `GCodeValidator` against the
machine profile; never weaken a limit to make a test pass; engine units are millimetres.

### Taking line K's clamp kit into line C

It is one commit on top of line C's v0.10: `Bring back the clamp kit workflow next to the fixture
library`. `git cherry-pick <that commit>` onto `main` applies it as it is. To take only part of it,
use the K entries below and these notes on how it joins line C's code:

| File | How the clamp kit joins in |
|---|---|
| `CoastlineCore/.../Plan/Setup.swift` | Both property sets and every `CodingKeys` case. `usesClampKit` is `!planFromFixtureLibrary && !onBed && holding != .custom`, so library jobs never pick up the kit. |
| `CoastlineCore/.../Plan/StockOrientation.swift` | Line C's plain fit check is unchanged; the kit's `options(stock:part:twoSided:topAllowance:softJaw:toolDiameter:requiresClampFrame:preferredAxes:)` is an extension, and `Option` gains `prepHeight`, `softJawOff`, `viaShoulders` (all defaulted). |
| `CoastlineCore/.../Export/GuidedJob.swift` | `Input` keeps `flipAxis` and adds `millDown` and `bed`. "Flip the Stock": roll-over wording when `flipAxis == 1`, else the clamp-kit steps. |
| `Coastline/.../Model/AppModel.swift` | The welcome and start sheets next to the in-process snapshots. `machineOrigin(stickout:)` uses the kit or bed placement when the job isn't library-planned or custom; `kitMachineOrigin` calls it. `kitWorkXRange` guards on `setup.usesClampKit`. |
| `Coastline/.../Model/BackgroundGeneration.swift` | Batching, grip-zone clipping and the kit's X-travel clamp first; then line C's reach, end-piece and fixture lift-overs. `static let outOfReach` is back. |
| `Coastline/.../Model/Machining.swift` | `strips` = shoulder strips (not on the bed) + the kit's keep-out (not when library-planned); `keepOut` = the library keep-out + `strips`. The stock-model air check runs before the kit's set-back pass. Program fixtures fall back to `clampField` only outside the library. `outOfReach` warnings become errors. |
| `Coastline/.../Model/Playback.swift` | The stock-model start first; the shoulders' open cells as the `else`. |
| `Coastline/.../Model/StageTransition.swift` | `ViewKey` (side + prep stage), with `show(side:)` as a shortcut. Between setups line C's quaternion turn; to and from the prep clampings the prep's own turn. |
| `Coastline/.../Model/JobStepGuide.swift` | `instructions(for:)` returns `kitInstructions(for:)` (in `Tour.swift`) for kit and bed jobs and for prep steps. |
| `Coastline/.../Model/EngravingPreview.swift` | The outline repeats per batched copy (`copyOffsets`, just 0 without batching) and hides while the mill-down shows. |
| `Coastline/.../Model/Stages.swift` | `JobStage` raw values are kept; the Setups stage is `.clampKit = 3` (line C's `.setups`), `holding = 1` and `prep = 2` are its detail views. |

---|---|
| `CoastlineCore/.../Plan/Setup.swift` | Keep both property sets and every `CodingKeys` case. `usesClampKit` is `!planFromFixtureLibrary && !onBed && holding != .custom`, so library jobs never pick up the kit. |
| `CoastlineCore/.../Export/GuidedJob.swift` | `Input` keeps `flipAxis`, `millDown` and `bed`. The "Flip the Stock" text: roll-over wording when `flipAxis == 1`, else the clamp-kit steps. |
| `Coastline/.../Model/AppModel.swift` | Keep the in-process snapshots *and* the welcome/start sheets. `machineOrigin(stickout:)` uses the clamp kit or bed placement when the job isn't library-planned or custom; `kitMachineOrigin` calls it. Keep both layout blocks (stand-in vise and in-process stock, and the clamp-kit layout). `kitWorkXRange` guards on `setup.usesClampKit`. |
| `Coastline/.../Model/BackgroundGeneration.swift` | Batching, grip-zone clipping and the kit's X-travel clamp first; then the reach, end-piece and fixture lift-overs. Restore `static let outOfReach`. |
| `Coastline/.../Model/Machining.swift` | `strips` = shoulder strips (not on the bed) + the kit's keep-out (not when library-planned); `keepOut` = the library keep-out + `strips`. Keep `bridged`. The stock-model air check runs before the kit's set-back pass. Program fixtures fall back to `clampField` only outside the library. Reference bores use the kit's X reach. Promote `outOfReach` warnings to errors. |
| `Coastline/.../Model/Playback.swift` | The stock-model start first; the shoulders' open cells as the `else`. |
| `Coastline/.../Model/StageTransition.swift` | `ViewKey` (side + prep stage) with `show(side:)` as a shortcut. Between setups the quaternion turn; to and from the prep clampings the prep's own turn. |
| `docs/MANUFACTURING_WORKFLOW_PROPOSAL.md` | Keep line C's text. |

Also restore `Model/MachineTable.swift` (v0.6 added it and line C uses it as `tableGeometry`), keep
`Plan/PartAnalysis.swift` under that name, and keep the `JobStage` raw values (the Setups stage is
`.clampKit = 3`; line C calls it `.setups`).

---

## Line K: clamp kit and the original CR-1 workflow

### K1. Clamp kit holding
The CR-1 universal clamp, measured from its Rhino model: C-shaped body bolted into both T-slots,
stock on the lower jaw or the U spacer, parallels behind it, soft jaw on top. One or two clamps,
slid along the slots, editable in the workspace.
- **Own files:** `CoastlineCore/.../Plan/UniversalClamp.swift`, `Plan/GripZones.swift`,
  `Coastline/.../Model/KitEditor.swift`, `Model/FixtureCheck.swift`,
  `engine/coastline_engine/fixture_kit.py`, `resources/fixtures/clamp_kit.npz`.
- **Hooks:** `Setup.usesClampKit`, `clampKitLayout`, `clampKitField`, `kitWorkXRange`,
  `GenerationRun.strips` / `kitXRange`, `GripZones.clip` in `BackgroundGeneration.swift`.
- **Tests:** `scripts/selftest.sh Fixture` (`universalClampsSlideAlongTheSlotsAndMustGrip`,
  `clampingStockIsNeverCut`).

### K2. Holding paths: bed, prep, shoulders
Five ways to hold the stock (`Setup.Workholding`): clamp kit as is, flat on the bed only, prep on
the bed then the kit, shoulders then the kit, custom fixture. Each is assessed for the part and
stock, with the reason (`holdingAssessment`).
- **Own files:** `CoastlineCore/.../Plan/FlatPrep.swift`, `Plan/PrepGeometry.swift`,
  `Coastline/.../Model/Prep.swift`, `Model/PrepVisual.swift`, `Model/Shoulders.swift`,
  `Model/BedEditor.swift`, `Model/CClampMesh.swift`.
- **Hooks:** `JobStage.holding` / `.prep`, `Setup.onBed`, `shoulders`, `downsizeHeight`,
  `prepOverrides`, `ViewKey` in `StageTransition.swift`, `Input.millDown` / `Input.bed` in the guided job.
- **Tests:** `scripts/selftest.sh Fixture`, `scripts/selftest.sh PrepGeometry`.

### K3. Guided `.crproj` export for CRWrite
The job as a CRWrite project: squaring, mount, edge finding, touch-off, tool changes, air cuts,
checkpoints. Written with MillCore's `ProjectWriter` and read back by its parser.
- **Own files:** `MillCore/Sources/MillCore/Project/` (`ProjectWriter`, `ProjectArchive`,
  `YAMLSubset`), `MillCore/Sources/MillCore/Guided/GuidedNavigator.swift`.
- **Tests:** MillCore self-tests `Writer`, `YAMLSubset`, `Project`, `Guided`.

### K4. Other job formats and sharing
Import `.dd` / `.crproj` packages and plain G-code as guided jobs, and share a project as one `.zip`.
Includes the `jobtool` command line.
- **Own files:** `CoastlineCore/.../Program/PackageImport.swift`, `Program/ProgramJobFromGCode.swift`,
  `Program/GCodeConvert.swift`, `Program/ProjectShare.swift`, `CoastlineCore/Sources/jobtool/`,
  `Coastline/.../Model/ProjectImport.swift`.
- **Tests:** `scripts/selftest.sh Share`.

### K5. Printable nest
A 3D-printable soft nest for the part's underside, as an STL (File ▸ Print a Nest…).
- **Own files:** `engine/coastline_engine/cam/nest.py`, `Coastline/.../Model/Nest.swift`,
  `Views/NestSheet.swift`. Engine RPC `nest`. Script command `nest`.

### K6. Quality ↔ time tuner and cost model
Presets Draft / Standard / Fine / Mirror; cusp height and pace; tool wear and job cost.
- **Own files:** `Coastline/.../Model/TunerModel.swift`, `Views/TunerSection.swift`
  (core: `Plan/Tuning.swift`, shared). Script command `tuner <preset>`.
- **Tests:** `scripts/selftest.sh Tuner`.

### K7. Deviation map
The simulated part against the CAD height field: green within ±20 µm, blue left, red gouge.
- **Own files:** `Coastline/.../Model/Deviation.swift`. Engine RPC `height_field`. Script command `deviation`.

### K8. Batching
Several copies of the part along the bar, each with its own roughing band and a web between.
- **Own files:** `Coastline/.../Model/Batching.swift`. **Hooks:** `Setup.copies`, `copyOffsets` in
  `BackgroundGeneration.swift`. Script command `copies n`.

### K9. Examples, first cut, welcome and tour
Four example parts with saved projects, the first-cut checklist (Projects ▸ First Cut on the CR-1),
the welcome sheet, the start sheet and the app tour.
- **Own files:** `resources/examples/`, `Coastline/.../Model/Examples.swift`, `Model/Tour.swift`,
  `Views/FirstCutView.swift`, `Views/WelcomeView.swift`, `Views/StartView.swift`,
  `Views/FlowSteps.swift`, `scripts/support/make_examples.py`, `scripts/make-example-projects.sh`,
  `scripts/regression.sh`. Script commands `example <id>`, `coupon pom`, `welcome`, `start`.

### K10. Consumables: bit IDs, wear forecast and wear-aware planning
Every physical bit gets an ID and its own wear; the job shows each bit's wear before and after,
recommends which bit to load, explains what wear does to the part, cuts gentler with a worn bit,
can plan the whole job to save tools, and corrects its life estimates from what the user reports.

- **Bit IDs.** `ToolUnit` (`Tool.units`, `Tool.loadedUnitID`): one per bit of a tool entry, labelled
  T-001, T-002 … (`Inventory.nextUnitNumber`). `Consumables.normalize` runs on every inventory
  load and change: it adds units when the quantity rises, removes unused ones (then retires the most
  worn) when it falls, and moves usage recorded before K10 onto the first bit. Tools ▸ inspector ▸
  Bits: wear per bit, Use This Bit, Worn Out / Broken: Retire, Print Label(s). The Tools search finds
  a bit by its ID (a handheld scanner reading the label's QR code types it there).
- **Wear per bit.** Stored as `load`, the share of the *estimated* life used:
  `minutes / ToolWear.life(tool, material, pace, toolSaver)` per recorded program, from the job's
  material, the tuner's pace and Save tools (`JournalEntry.pace`, `.toolSaver`,
  `ProgramRun.unitID`). Shown wear is `load / learned factor`. `Tool.cuttingMinutes` still adds up,
  and `ToolLife` (Wear column, Shopping List) now reads the bit in use and counts fresh spares.
- **Forecast.** `Consumables.forecast`: per program (one tool load) the bit, wear before → after,
  stage and advice. A program that finishes moves to the freshest bit when its bit would pass
  `WearPolicy.swapAt` (85 %); one that only roughs keeps a worn bit until it would pass 100 %
  ("rough with the old, finish with the new"). With no spare it says so. Machining ▸ Bits
  (`BitForecastSection`), follows the tuner before regenerating; the record sheet pre-fills each
  program's bit (changeable); the tool-change card names the box label.
- **What wear does.** `WearStage` (Sharp < 10 % < Worn in < 60 % < Dulling < 85 % < Near its end
  < 100 % < Worn out) with plain-language effects per tool size and material family (rubbing and
  heat, built-up edge in aluminium, melting in plastics, work hardening in stainless and titanium,
  deflection and oversize walls, rougher finish, chatter, small bits snapping).
- **Worn-bit mode.** `Operation.bitWear` (set while generating: the program's bit from the
  forecast, else the bit in use). From 60 % `WearAwareFeeds.applyWorn` lowers the spindle (down to
  80 % when worn out) with the feeds, so the chip per tooth is kept, takes lighter roughing and
  contour steps, and turns on the spring pass for contours. Operations Coastline adds itself (prep,
  reference bores and windows, side setups, side B backing) get the same through
  `AppModel.wearFeeds`.
- **Save tools.** `Tuning.toolSaver` / `Operation.toolSaver`: spindle 85 % with the chip load kept
  (Taylor: about 1.9× the life) and deep roughing, so wear spreads along the flutes. A switch in
  Machining ▸ Bits with its time and tool-cost change against the current settings; the tuner's
  time, cost and per-tool life follow it.
- **Learning.** `ToolLifeLearning` (`Inventory.lifeLearning`), per tool kind and tool material,
  0.3 … 3: retiring a bit as worn out at x % of its estimate pulls the life towards x (first report
  half weight, later ones less); a rough finish or chatter on a bit past 50 % shortens it 5 %; a
  fine, clean finish past 90 % lengthens it 3 %. A broken bit teaches nothing.
- **Labels.** A4 PDF, 3 × 11 labels of 50 × 22 mm: QR code with the ID, the ID large, the tool,
  diameter, flutes and tool material (`BitLabels`, opened in Preview to print).
- **Not yet.** A bit is chosen per program (one tool load), not per operation inside a program;
  the life model is Taylor on cutting time, not engagement or chip load per operation.
- **Own files:** `CoastlineCore/.../Inventory/Consumables.swift`, `Coastline/.../Model/WearModel.swift`,
  `Views/BitWearViews.swift`. **Touches** `Tool`, `Inventory`, `Operation.cuttingData`, `Tuning`,
  `CostModel`, `JobJournal`/`ToolLife`, `JobResourceSnapshot.planningInventory` and the library import
  (they carry the bits), `InventoryModel`, `Machining` (generation), `TunerModel`, `ToolsPage`,
  `JournalViews`, `ToolChangeCard`. Script commands `bits [tuned]`, `savetools [off]`,
  `wearbit T-001 0.8`, `showbit T-001`, `bitlabels path.pdf`.
- **Tests:** `scripts/selftest.sh Consumables`.

### K11. Tool Check: test cuts on a test block (planned, not built)
A plan, not code yet. It builds on K10 (bit IDs, `ToolUnit.load`, `ToolLifeLearning`), the
journal's measurements and photos, the clamp kit, and the guided job / built-in runner.

**Why.** K10's wear is an estimate from cutting time. A short test cut measures each bit, so the
estimate can be corrected per bit and the life model learns from measurements, not only from
"marked worn" reports.

**Phase 1. The test block**
- A stock item flagged as a test block (`StockItem.testBlock`), e.g. 6061, 50 × 50 × 15 mm, held
  in the clamp kit.
- Its face is a grid of test cells sized to the largest tool tested. Coastline remembers the used
  cells (`TestBlock.usedCells`); when the face is full it plans a facing pass and starts a new
  grid, and tracks the block's thickness until it is too thin for the kit.

**Phase 2. The test pattern (per bit, about 2–3 minutes)**
- **Slot:** one full-width slot, 0.5 D deep, 3 D long. Its width is the bit's cutting diameter.
- **Boss:** a 10 × 10 mm square boss, roughed with 0.2 mm left, then one finishing pass at the
  standard finishing feeds. A dull edge is pushed away from the wall, so the boss comes out
  oversize: the most sensitive sign on a desktop mill.
- **Floor patch:** a small floor-finished area for the finish and burrs.
- Ball mills: a small 3D patch at a set cusp instead of the boss. Drills: one hole, checked with
  a pin gauge.
- Feeds come from the feeds engine, never worn-bit mode or Save tools, so every test of a bit is
  cut the same way. Every program passes `Safety`; the first test of the block is an air cut.
- "Check the bits for this job" makes one program set for every bit the job uses, with the tool
  changes, as a guided job.

**Phase 3. Recording and reading the result**
- A Tool Check sheet per bit: slot width, boss X and Y (several readings, averaged), finish 1–5,
  burrs yes/no, squeal yes/no, an optional close-up photo of the cutting edge.
- Each bit's first test is its baseline (`ToolUnit.baseline`). Later tests are compared with it,
  which cancels the machine's own deflection and the caliper's bias: boss growth, slot shrinkage,
  finish drop and new burrs.
- From those, a measured wear estimate with a confidence based on the measuring tool's resolution
  (`MeasuringTool.resolution`: a micrometer counts more than calipers).
- The bit's `load` is corrected towards it, and `ToolLifeLearning` gets an observation weighted
  by that confidence (more than a journal hint).
- A plain verdict: good for finishing / roughing only / retire, with the reasons ("the boss grew
  0.03 mm since new and the floor shows burrs").

**Phase 4. When it is offered**
- Tools ▸ a bit ▸ Test Cut.
- Machining ▸ Bits: "Check the bits for this job" before an important job.
- Suggested when the forecast puts a bit in Dulling or later, or when the bit has cut a lot since
  its last test.

**Phase 5. Measuring by probing (later, optional)**
- The CR-1 can probe conductive stock electrically (M4 S1500, insulated clamp kit). With that
  working, the bit, spinning slowly in reverse, probes a precision dowel pin from both sides: the
  span minus the pin is the bit's real cutting diameter, with no calipers.
- It needs electrical probing verified on the machine first.

**Limits to keep in view**
- Calipers read to about 0.02 mm, and a bit loses only a few hundredths of diameter over its life.
  The slot alone is a weak signal; the boss growth together with finish and burrs is the stronger
  one. A micrometer helps a lot.
- Each test costs a few minutes and well under 1 % of a bit's life.

**Where it would live**
- Core: `Inventory/ToolCheck.swift` (new: test block grid, pattern, reading the results),
  `Inventory/Consumables.swift` (baseline, measured wear, weighted learning), `InventoryItems`
  (`StockItem.testBlock`).
- Engine: the slot, boss and floor patch from the existing 2.5D operations; no new engine code.
- App: the Tool Check sheet, Test Cut in Tools ▸ Bits, the button in Machining ▸ Bits, the
  guided job for a check run.
- Tests to add: cell grid and refacing, pattern safety, baseline comparison, the wear estimate and
  its confidence, learning weights.

### K12. Sharp snapshots, exact readouts and export (planned, not built)
A plan, not code yet. It builds on the playback simulation (`Sim/Heightmap.swift`, about 250 000
cells: ~0.09 mm on a 50 × 40 mm block, ~0.22 mm on a 150 × 80 mm bar), the multi-setup model
(`Sim/StockModel.swift`, `Sim/DexelSim.swift`, 0.2–0.5 mm), the deviation map (K7), the saved
results (`Model/SavedResults.swift`) and the engine's 2.5D regions and OCCT.

**Why.** Finishing cusps are around 8 µm and the deviation map's green band is ±20 µm, both far
below the simulation's cell size. Checking a state closely needs either a much finer simulation
or exact answers from the toolpath itself.

**Phase 1. Sharp snapshot**
- With playback paused, "Sharpen" re-simulates up to the playhead at 10–20 µm in the background
  (progress, cancel) and shows the result until playback moves on.
- Whole part, the visible area, or a box the user drags; a small box can go to a few µm.
- Kept fast by culling: the coarse simulation already knows the final surface, so every move
  whose tool envelope stays above it (plus a margin) is skipped. Most roughing moves are cut away
  later, so most of the work disappears. Tiled and multithreaded; Metal compute if CPU is not
  enough.
- The deviation map (K7) runs on the sharp version when there is one, so its ±20 µm colours mean
  what they say.

**Phase 2. Exact readouts**
- Exact probe: the Measure tool gives the remaining material height and the distance to the part
  at the clicked point, evaluated from the moves themselves (the lowest tool envelope over that
  point), not from a grid.
- Exact section: a line drawn across the part gives the material profile along it, with cusp
  heights, step heights between levels and the gap to the CAD, in µm.
- Cheap (only the moves near the point or line), so no waiting.

**Phase 3. Snapshots saved in the project, on the timeline**
- Each snapshot is stored in the `.coastline` file with its region, resolution, playhead time,
  name and note, as heights in whole µm relative to the coarse simulation, LZFSE-compressed like
  the saved moves.
- It is tied to the toolpath signature it was made from. After regenerating or changing the
  operations it shows as out of date (greyed), with "Sharpen Again", and is never shown as true.
- A limit on snapshot space per project (setting); the oldest are dropped first. Snapshots are a
  cache: dropping one loses nothing that can't be made again.
- On the timeline: a marker at each snapshot's moment (different marks for whole-part and region
  snapshots, greyed when out of date). Click jumps the playhead there and shows the sharp state at
  once; hover shows name, resolution and date. A list beside the timeline renames, notes, exports
  and deletes.

**Phase 4. Export**
- Mesh: STL, 3MF, OBJ and Rhino `.3dm` (rhino3dm is already in the engine) of a snapshot as a
  closed solid, in part or machine coordinates. For checking in Rhino or Fusion, or designing a
  soft jaw or nest around a half-machined part.
- STEP: where every cut so far is 2.5D (facing, pockets, contours, holes), the engine builds the
  stock minus the exact cleared regions per level as a real OCCT solid, with true planes and
  cylinders. After 3D finishing an exact solid is not practical (subtracting the swept volume of
  tens of thousands of moves is slow and fragile): those areas go in as a fine mesh next to the
  exact 2.5D faces, and the app says so.

**Phase 5. Compare and automatic snapshots**
- Compare two snapshots: only what changed between them, coloured by depth (what program 3
  removed, whether rest finishing really cleared a corner).
- Optional automatic snapshots after each program or setup, made in the background, so the
  timeline always has sharp checkpoints at the important moments.

**Phase 6. Multi-setup jobs**
- The same for side B, side setups and prep, from the multi-setup model at fine resolution.

**Where it would live**
- Core: `Sim/SharpSnapshot.swift` (new: tiled fine heightmap with culling, exact point and line
  evaluation, quantized storage), `Sim/Heightmap.swift` (shared cutter envelope).
- Engine: an RPC that builds the 2.5D STEP from the cleared regions; mesh and `.3dm` writers
  (`cam/nest.py` already writes STL).
- App: Sharpen in the playback bar, the snapshot markers and list on the timeline, the exact probe
  in Measure, the section tool, Export in the snapshot list; `SavedResults` stores snapshots.
- Tests to add: culling gives the same surface as the full fine run, exact probe against an
  analytic cut (flat, ball, bull), the out-of-date check after regenerating, the storage round
  trip, a 2.5D STEP that OCCT reads back as a valid solid.

---

## Line C: control, fixture library and machine profiles

### C1. Machine Control
Connect over USB, home, jog (eight directions, steps or hold, arrow keys), work zero and G54–G59,
go to, spindle and overrides, feed hold, resume, stop, console. A digital machine to practise on.
Connecting retries a freshly plugged board after 1, 2 and 5 s; the console lists ports found and
removed with their USB IDs (boards 2341:0043, 2341:003E, CH340 1A86:7523; a missing serial number is allowed).
- **Own files:** `MillCore/Sources/MillCore/Session/` (`MillSession`, `GoTo`, `SessionTypes`,
  `JobPrograms`), `MillCore/Sources/MillCore/Mock/MockGRBL.swift`, `MillCore/Sources/MillCore/GRBL/GRBLText.swift`,
  `Coastline/.../Model/MillControl.swift`, `Coastline/.../Views/Control/`.
- **Depends on:** MillCore (the renamed, extended CRCore: serial, GRBL protocol, firmware).
- **Tests:** MillCore self-tests `Session`, `SessionCore`, `ManualControl`, `GRBL`. CLI: `MillCore/Sources/millcheck`.

### C2. Test program library
Save, edit, delete and favourite reusable test and setup programs (Machine Control ▸ Setup ▸ Test programs).
- **Own files:** `MillCore/.../Session/TestProgramLibrary.swift`, `Session/TestPrograms.swift`,
  `Coastline/.../Views/Control/TestProgramLibrary.swift`. **Tests:** MillCore `ProgramLibrary`.

### C3. Native guided runner and G-code jobs
"Run on Machine" runs the generated job step by step in Coastline itself. G-code and NC files open
straight into Machine Control.
The runner also runs the reference-bore macros M102 (offset arithmetic) and M106 (offset check).
- **Own files:** `CoastlineCore/.../Export/GeneratedJob.swift`, `Program/ProgramJob.swift`,
  `Program/GCodeReader.swift`, `Coastline/.../Views/Jobs/` (`JobsPage`, `JobRunner`, `JobPreview`),
  `Model/JobsModel.swift`, `Model/JobStepGuide.swift`, `Model/GeneratedPrograms.swift`.
- **Tests:** `scripts/selftest.sh GeneratedJob`, `scripts/selftest.sh Program`.

### C4. Fixture library planning
Includes the universal clamp pair as a library assembly (`resources/fixtures/universal-clamps/`; not yet
plannable, see its `planningLimitation`). It sits beside the clamp kit (K1), which keeps its own model and planner.
Fixtures as STEP assemblies with mechanisms, grip patches and a datum. The planner picks owned
fixtures per setup, checks reach and clearance, and assigns every cut to a setup.
- **Own files:** `CoastlineCore/.../Plan/FixtureAssemblyDefinition.swift`, `FixtureMechanism.swift`,
  `FixtureEdgeSnap.swift`, `FixtureFieldBox.swift`, `LibraryFixtureGeometry.swift`,
  `LibraryWorkholding.swift`, `JobLibraryGuide.swift`, `BookendSetup.swift`,
  `Inventory/VettedFixtureLibrary.swift`, `Inventory/InventoryFixtureSetup.swift`,
  `Coastline/.../Model/LibraryWorkholding.swift`, `FixtureWorkspacePlacement.swift`,
  `VettedFixtures.swift`, `Views/LibraryWorkholdingSection.swift`, `Views/FixturePlacementInspector.swift`,
  `Views/Inventory/FixturePlanningSection.swift`, `resources/fixtures/{bookends,c-clamps,quick-release,vise,hardware}/`.
- **Hooks:** `Setup.planFromFixtureLibrary`, `fixtureAssemblies`, `selectedFixtureIDs`,
  `libraryWorkholdingPlan`, `fixtureKeepOut(candidates:)`.
- **Tests:** `scripts/selftest.sh LibraryWorkholding`, `FixtureAssembly`, `FixtureMechanism`,
  `FixtureSnap`, `VettedFixtureAssembly`, `BookendSetup`. Docs: [WORKHOLDING_ASSEMBLIES.md](WORKHOLDING_ASSEMBLIES.md).

### C5. Side setups, end pieces and the stand-in vise
Up to six setups (A, B, upper, lower, both ends). End pieces stay on through the long-face setups
and are faced off at the end. A setup nothing owned can hold gets "a vise that opens to N mm" on
the Shopping List, drawn as a see-through stand-in.
- **Own files:** `CoastlineCore/.../Plan/SetupSide.swift`, `Plan/SideCuts.swift`,
  `Plan/StockOrientation.swift`, `Coastline/.../Model/SideSetups.swift`.
- **Hooks:** `Setup.flipAxis`, `endPieces`, `SidePlan.keepY`, `StandInVise`.
- **Tests:** `scripts/selftest.sh SetupSide`.

### C6. Stock model between setups
A tri-dexel model of the stock (0.5 mm): every pass is swept in, in machine order. Finishing passes
lift over air an earlier cut already cleared. The workspace shows each setup's stock as it starts.
- **Own files:** `CoastlineCore/.../Sim/StockModel.swift`, `Sim/DexelSim.swift`.
- **Hooks:** `inProcessSnapshots`, `layoutInProcessStock`, `inProcessStart` in `Playback.swift`.
- **Tests:** `scripts/selftest.sh Dexel`.

### C7. Machine reach per setup
Each setup knows what the tool tip can reach from where its fixture puts the stock. Out-of-reach
cuts are left to other setups, with a note.
- **Own files:** `Coastline/.../Model/Reach.swift`. **Hooks:** `SetupReach`, `outOfReachStrips`, `sp.reachX`.

### C8. Toolpath disk cache
Every toolpath kept on disk, keyed by everything it depends on (part, operation, setup, machine,
engine code). 1.5 GB limit. `COASTLINE_NO_CACHE=1` turns it off.
- **Own files:** `Coastline/.../Model/ToolpathCache.swift`.

### C9. Machinability (DFM) and plan coverage
Every problem on the part, marked in the workspace with numbered pins: red can't be machined, amber
missing tool or stock, blue a setup change, grey information needed. Coverage shows which faces each
setup cuts.
- **Own files:** `CoastlineCore/.../Plan/DFM.swift`, `Plan/NamedFeatures.swift`, `Plan/PlanCoverage.swift`,
  `Plan/PartAnalysis.swift`, `Coastline/.../Views/MachinabilitySection.swift`, `Views/FindingsOverlay.swift`,
  `Views/JobPlanningGuide.swift`, `resources/samples/dfm_coupon.step`.
- **Tests:** `scripts/selftest.sh DFM`, `Feasibility`.

### C10. Machine profiles
Versioned machine packages: STEP model, axis hierarchy, coordinate mappings, mounting interfaces,
source evidence. Pick the machine per job.
- **Own files:** `CoastlineCore/.../Machine/MachineDefinition.swift`, `MachineDefinitionPackage.swift`,
  `MachinePlanningGeometry.swift`, `PlanningMachineReference.swift`, `Coastline/.../Model/MachineProfileLibrary.swift`,
  `MachineProfilePreview.swift`, `PlanningMachine.swift`, `MachineTable.swift`,
  `Views/MachineProfilesPage.swift`, `Views/Components/PlanningMachinePicker.swift`, `resources/machines/`.
- **Tests:** `scripts/selftest.sh MachineDefinition`, `MachinePlanningGeometry`, `PlanningMachineReference`.
  Docs: [MACHINE_PROFILES.md](MACHINE_PROFILES.md).

### C11. Resource libraries
Import and export stock, tools and materials (`.coastlib`, Fusion tool libraries), with duplicate
handling. Jobs keep a snapshot of the resources they use.
- **Own files:** `CoastlineCore/.../Inventory/ResourceLibraryPackage.swift`, `JobResourceSnapshot.swift`,
  `InventoryCatalogUpdates.swift`, `InventoryStockMaterials.swift`, `Coastline/.../Model/JobResources.swift`,
  `Views/Inventory/ResourceLibraryActions.swift`.
- **Tests:** `scripts/selftest.sh ResourceLibrary`, `JobResourceSnapshot`, `MaterialResource`,
  `StockCatalog`, `ToolCatalog`. Docs: [RESOURCE_LIBRARIES.md](RESOURCE_LIBRARIES.md).

### C12. Units
mm / in everywhere the user types or reads a length; geometry and G-code stay in millimetres.
- **Own files:** `CoastlineCore/.../Units/DisplayUnits.swift`, `Coastline/.../Views/Components/Units.swift`.
- **Tests:** `scripts/selftest.sh Units`.

### C13. Export selected code and the steady plan choice
Save single probing, setup, cutting or air-cut files from the results (`Views/SelectedCodeExportSheet.swift`).
The planner ranks plans with a 10 % tolerance so identical runs pick the same plan
(`StrategyEngine.pick`, test `pickHoldsThePlanSteadyWhenTheTimeModelDrifts`).

### C14. Release workflow
`.github/workflows/release.yml` builds the engine and the app on every push to `main`, runs the
self-tests and publishes a disk image as a GitHub release.

### C15. Qt app (Windows and macOS)
A cross-platform port of the Swift app in `app/` (PySide6, QML screens, QRhi viewport, same engine).
Only on `main`; status per file in `app/PORTING.md`. Not on `xioaniumi` yet.
