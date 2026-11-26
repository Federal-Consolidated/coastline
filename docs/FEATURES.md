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
  (nest, tuner, deviation map, batching), bit IDs with wear tracking (K10), and sharp snapshots with exact readouts (K12).

Line K is built on top of line C's latest commit, so GitHub's compare view shows exactly what it
adds. Both workflows run side by side there: a job uses the clamp kit unless it is planned from the
fixture library (`Setup.planFromFixtureLibrary`) or held in a custom fixture. How the two branches
trade features is in [SYNC.md](SYNC.md).

Checks on line K: planning core 262 passed, machine core (MillCore) 123 passed, engine 122 passed.
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

### K12. Sharp snapshots, exact readouts and export (phases 1–4 built; STEP, compare and multi-setup planned)
The playback simulation (`Sim/Heightmap.swift`, about 250 000 cells: ~0.09 mm on a 50 × 40 mm
block, ~0.2 mm on a 150 × 80 mm bar) is enough to watch material go but far coarser than an 8 µm
cusp or the deviation map's ±20 µm band. K12 re-simulates at µm level on demand and answers
single points and sections exactly from the toolpath.

- **Sharp snapshot (built).** Playback bar ▸ Sharpen ▸ Whole Stock (10 µm, capped at 30 million
  cells, so ~14–20 µm on a long bar) or Around Measure Point A (5 mm square at 2.5 µm).
  `SharpSim.sharpen` (core, `Sim/SharpSnapshot.swift`):
  - starts from the coarse state the side began from;
  - culls every segment whose lowest tip stays above the coarse final surface around it (plus
    1.5 coarse cells + 20 µm);
  - goes from the lowest segment up, in parallel bands of 32 × 32-cell tiles that remember their
    highest cell, so a segment skips every tile already below it.

  Measured: a 150 × 80 mm bar after 36 min of 2.5D cutting, 30 million cells in 0.9 s; the 3D
  signet pendant at 14 µm in 1.1 s; a 2.5 µm detail square in 0.1 s. Shown in place of the
  playback grid (drawn at up to 2.5 million cells; the readouts and export use all of it) until
  the playhead moves. The deviation map (K7) compares the shown snapshot when there is one.
- **Exact readouts (built).** `SharpSim.envelope`: the lowest point of a cutter (flat, ball,
  bull nose) moving along a sloped segment over a point. The height is convex in the move's
  parameter, so a golden-section search finds it to float precision. With Measure on and the
  simulation shown, a click on the stock gives:
  - the exact material height there;
  - the playback grid's value and how far off it is;
  - how far it is above or into the part (the part's height from the engine's `height_field`).

  Section ▸ Exact Section… gives up to 4000 exact points along the section line (X or Y) with
  the playback grid and the part, and the most material left above the part and the deepest cut
  into it (against the part's height range within ±2 samples, as the deviation map does).
- **Saved in the project, on the timeline (built).** `SharpSnapshotRecord` in the `.coastline`
  file (`ProjectFile.snapshots`): heights as whole µm, row-delta coded, LZFSE (the pendant's
  30 million cells: 380 KB). A snapshot is tied to the toolpath signature of its side
  (`simSignature`); after regenerating it shows as out of date and can't be shown. The newest are
  kept within 200 MB per project. A diamond on the step's timeline segment (filled: whole stock,
  outline: detail, grey: out of date) goes to the snapshot and shows it. The Sharpen menu lists
  this side's snapshots: Show, Export, Delete.
- **Export (built).** A snapshot as a closed, watertight mesh (top, four walls, bottom fan) in
  work coordinates (mm, origin at the stock face centre, Z down from the face). Snapshot menu ▸
  Export:
  - **Rhino `.3dm`** (engine, rhino3dm): units mm, layer "Coastline snapshot", the snapshot's
    name. Up to ~3 million triangles.
  - **STEP** (engine, OpenCASCADE, `mesh_export.write_step`): the mesh is welded, built as one
    shell with shared edges, made a solid (`ShapeFix_Solid`), and coplanar faces are merged
    (`ShapeUpgrade_UnifySameDomain`). Flat floors, faces and walls become single faces; curved
    areas stay faceted. Up to ~400 000 triangles, so a whole-stock snapshot goes out coarser
    (the motor mount: 206 µm, 7 610 faces, a closed solid, 22 MB, about 1.5 min); a detail
    snapshot keeps its resolution.
  - **Clean CAD, NURBS (.step)** (engine, `clean_cad.py`, RPC `export_clean`): a B-rep solid, not
    a mesh. From the snapshot's heights (at most ~1.2 million cells):
    - the flat levels the cuts left are found;
    - micron cusps, specks under 1 mm² and levels closer than 0.05 mm are cleaned away;
    - each level's outline is traced, and fitted with lines and least-squares arcs (a whole
      circle becomes one circle);
    - the outlines are cut out of the stock block as prisms, one cut at a time, each checked;
    - sloped 3D areas get a light cubic B-spline surface (about 40 × 40 points, extended past
      the area's edge), and the area's footprint is split by it — only where one fits: an area
      that rises less than 0.3 mm, or that the surface misses by more than 8 % of its rise (a
      half-bored spiral ramp), becomes one flat step at the level nearest its middle instead;
    - each level's outline loses anything thinner than about four cells (no hairline grooves),
      and holes are cut out of simple prisms rather than built as faces with holes (those were
      invalid where outlines ran close, which left whole pockets uncut).

    Tested from the app: the signet pendant gives 158 faces (62 planes, 88 cylinders, 8 NURBS), a
    valid solid, in 5 s; the motor mount mid-way through boring its holes (23 raw depths) gives
    226 faces, valid, in 6.2 s. Coplanar faces are merged with their edges when OCCT manages,
    else faces only; engine errors reach the app with their own message.
    Rhino, Fusion and other CAD programs open it as a NURBS polysurface.
  - **With the exact part** (`build_with_part`): when the part is an exact B-rep (STEP, IGES,
    `.3dm`), the clean export is the part itself joined with the material still on it. Cells the
    cut has reached (within 0.05 mm of the part's top) are lowered to its underside, so only the
    leftover stock is reconstructed; the union shows the user's own faces, edges and fillets.
    - The part's top and underside heights come from an OpenCAMLib drop on it (and on it turned
      over), placed by the setup's transform.
    - The leftover's outlines take the part's exact circles and wall lines where they run within
      0.04 mm of them (corners where the snapped neighbours meet), and a whole circle starts at the
      part circle's seam. Without that, the fitted wall lay a few microns from the CAD wall and
      left rings of sliver faces round holes and bores, and seams that didn't meet (an invalid
      `.3dm` edge).
    - Same-surface faces are merged with tight tolerances (1e-4), repaired if that leaves a face
      invalid, else kept as fused.
    - Motor mount, end of the main setup: 164 faces (90 planes, 73 cylinders, the cone), a valid
      solid and a valid Rhino polysurface (trims within 0.5 µm), 99 % of the surface within 2 µm
      of the simulation, 0.7 s. The fine lines left on its top face are real: islands 0.1 mm
      proud of the finished top that the simulated toolpaths leave between the bore and the holes.
  - **Clean CAD, NURBS (.3dm)** (engine, `clean_3dm.py` and the openNURBS module `_opennurbs`):
    the same solid as one joined Rhino polysurface.
    - The shape is converted to NURBS throughout. Each face gives its B-spline surface; each edge,
      numbered once so neighbouring faces share it, gives its 3D curve and vertices; each trim
      gives its 2D curve, oriented along its loop. openNURBS (`native/src/opennurbs_module.cpp`)
      builds the `ON_Brep`, sets trim flags and tolerances, checks it with `IsValid`, and writes
      it in mm on a "Coastline snapshot" layer with the snapshot's name.
    - Files hold no path: openNURBS writes through a file handle the module opens itself
      (`ONX_Model::Write(filename)` would store the full path, with the user's folders). The mesh
      `.3dm` goes through the same writer when `_opennurbs` is built (rhino3dm's `Write` stores
      the path too; without openNURBS it writes in a neutral temporary folder and moves the file).
    - Rhino's rules handled: zero-length edges as singular trims, trim ends snapped to meet exactly, a single closed edge on one
      vertex, single-edge loops the wire walker skips. A hole outline that is closed on the
      surface but open in 3D (a flaw of a fitted patch) is left out and counted in the result.
    - Tested from the app and read back by rhino3dm: the signet pendant, 158 faces, a closed
      valid solid, 5.8 s; the motor mount mid-bore, 226 faces, valid, two such outlines left
      out, 8.2 s.
    - **Building it:** openNURBS (McNeel's Rhino file toolkit) isn't in the repo.
      `engine/native/get_opennurbs.sh` fetches a pinned 8.x commit into
      `native/third_party/opennurbs` (git-ignored), and `engine/native/build_opennurbs.sh`
      compiles it, caching its objects in `engine/build/opennurbs` (about 17 s the first time),
      into `coastline_engine/_opennurbs*.so` (also git-ignored). Without it the menu item explains
      what to run. Bull-nose fillets along wall feet are left out (as steps); `COASTLINE_CLEAN_DUMP=path`
    saves the heights the engine received, for work on `clean_cad` offline.
  - **3MF** (zip, mm) up to ~3 million triangles.
  - **STL** and **OBJ** (Swift) up to ~3 million triangles.
- **Still planned.**
  - Clean CAD straight from the toolpaths (the engine's cleared regions) instead of the
    simulated heights, for exact walls and fillets.
  - Comparing two snapshots.
  - Automatic snapshots after each program or setup.
  - Multi-setup jobs at fine resolution: side B shows its cuts, but starts from the coarse model
    of side A, and the back surface stays coarse.
- **Own files:** `CoastlineCore/.../Sim/SharpSnapshot.swift`, `Coastline/.../Model/SharpModel.swift`,
  `Views/SharpViews.swift`. **Touches** `Heightmap` (explicit grids, `sample`), `AppModel`
  (state, the measure click), `Playback` (hiding the snapshot when the playhead moves),
  `Deviation`, `ProjectDocument`, `PlaybackBar` (Sharpen, timeline marks), `WorkspaceView`
  (measure readout, Exact Section). Script commands `sharpen [x y size]`, `snapshots`,
  `showsnap`, `hidesnap`, `exactprobe x y`, `exactsection x|y offset`, `exportsnap path`,
  `measured`, `exportclean path`. Engine: `coastline_engine/mesh_export.py` (RPC `export_mesh`) and
  `coastline_engine/clean_cad.py` (RPC `export_clean`, `format` step or 3dm), `clean_3dm.py`,
  `native/src/opennurbs_module.cpp`, `native/get_opennurbs.sh`, `native/build_opennurbs.sh`.
- **Tests:** `scripts/selftest.sh SharpSnapshot`, `engine/tests/test_clean_cad.py` (planes and arcs
  for a pocket and step, one NURBS surface for a dish, valid solids within 1 % of the volume, a
  circle fitted as one circle; the exact part with its leftover: a plate in its slot with the hole
  drilled on into the bar comes out valid, no face under 0.02 mm wide, a valid `.3dm`), `engine/tests/test_clean_3dm.py` (a box with a pocket and the dish as
  closed, valid Rhino polysurfaces; skipped without openNURBS) and `engine/tests/test_mesh_export.py` (3MF and
  `.3dm` read back with units and counts; a STEP block merges its flat faces into a closed, valid
  solid):
  - ball cusps at their analytic height;
  - a culled and a full run agree cell for cell;
  - the exact envelope against brute force on a ramp with a bull nose;
  - storage to the µm;
  - watertight export.

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
