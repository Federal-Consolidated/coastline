# Coastline

Open-source CAM, guided setups and machine control for GRBL desktop mills, as a native Mac app.

Coastline plans a part from CAD to a guided job: orientations, holding, tools, feeds and toolpaths,
with a simulation and safety checks. It then runs the job on the mill itself, step by step. It also
runs proven G-code that already exists (other CAM programs, older `.dd` and `.crproj` job packages)
in the same guided flow.

> [!WARNING]
> **Alpha.** Read every program before you run it, air-cut first, and keep a hand on the E-stop.
> You are responsible for your machine, your tools and your safety. See [docs/FIRST_CUT.md](docs/FIRST_CUT.md).

## What it does

- Imports parts from STEP, IGES or Rhino `.3dm` (exact NURBS via OpenCASCADE).
- Guides **Part → Stock → Setups → Plan → Toolpaths → Review**. Recommends owned blanks and builds a job proposal from owned tools and defined library fixtures; clamp-kit and bed setups remain manual options.
- Holding choices stay selected. **Vise / custom fixture** plans without the built-in clamp kit or its sacrificial frame; set the stock height, face position and setup notes in Workholding. Custom fixture geometry is not modelled, so its jaws and fasteners need a manual clearance check.
- Exact-size blanks and zero face allowance are supported: existing stock faces can stay as supplied. Automatic plans omit facing at zero allowance; 2.5D toolpaths skip exterior walls with no stock to remove and still cut pockets and recesses.
- Keeps an inventory of your stock, tools, fixtures and measuring tools, and plans only with what you own.
- Generates 2.5D and 3D toolpaths (facing, adaptive roughing, contour, pockets, drilling, helical boring, 3D finishing, engraving).
- Feeds and speeds for the machine profile's spindle and frame, across 30+ materials.
- Simulates material removal and checks for collisions with the machine and fixtures.
- **Machine Control:** the actual machine assembly with live position and a compact native control inspector. Connect over USB, home, unlock the eight-direction jog pad (including diagonals), use steps or hold-to-jog, set work zero and G54–G59, go to positions, control the spindle and overrides, feed hold, resume, stop and open the console. Arrow keys also jog; locking cancels current and queued pad/key jogs.
- Save, edit, delete and favorite reusable test and setup programs from **Machine Control → Setup → Test programs → Manage Programs**. Probe contact has a permanent place in the status row; **Guided Mode** returns to the current guided job.
- Switch **mm / in** in Machine Control or Settings. Positions, jogging, work-zero/go-to inputs and shared dimension fields use the selected units; geometry and controller commands stay in millimeters.
- Review work zero in **Setups**. Clamp-kit jobs offer electronic probing or edge finder and paper. Library fixture setups use their defined datum and require manual work-zero verification at each re-clamping.
- From the generated results, **Export Selected Code** saves individual probing, setup, cutting and air-cut files. **Run on Machine** opens the built-in guided runner with stock prep and part setups in order; each program still requires its Run button. Contour-map surface following and reference-bore host macros require exporting to a compatible sender.
- **Projects:** one list for planned projects (made in Coastline from CAD) and G-code projects (guided jobs around G-code that already exists). Import takes a shared `.zip`, a `.coastline` file, an older `.dd` or `.crproj` job, a job folder or G-code files; Export saves a project as one `.zip` to share.

## Stock, tool and material libraries

Use **Import Library…** on Stock, Tools or Materials to preview a `.coastlib` file
or Fusion tool library. Choose how duplicates and quantities are handled before
importing. **Export Library** shares selected entries or a whole category.
Custom materials are editable; built-in materials use **Edit a Copy**.
Jobs retain their selected definitions. **Job Resources → Update from Library**
applies later library edits and clears dependent toolpaths.
See [Resource libraries](docs/RESOURCE_LIBRARIES.md) for the workflow and format.

## Planning with your fixture library

1. **Part:** import the CAD and confirm its designed size. A new part starts a fresh library-based proposal, without the previous part's scale, offsets or clamp prep.
2. **Stock:** choose a blank you have. Recommendations prefer owned blanks with a defined fixture assembly, then lower material volume. Exact-size blanks remain valid without a clamp-kit frame or mandatory face allowance.
3. **Setups:** click a workholding card to preview it around the stock, review its grip, then **Use Workholding**. Orientation, part allowance, work zero and any manual stock prep belong here too. Job placements preserve library defaults. You can also import a closed-solid STEP assembly of a jig and its hardware, without stock or the part; generic models still need their actual mounting and grip/support definition. Geometry cannot infer these physical constraints.
4. **Plan:** **Machinability** marks every problem on the part in the workspace: red can't be machined, amber a missing tool or stock, blue a setup change, grey information needed. Each problem has a numbered pin; click it (or its row) for what is wrong, the measurement and what to do. Then **Build Toolpaths** compares owned tooling, generates the cuts and assigns them to the selected fixtures; review each proposed setup there. No obstructed operation is silently dropped and no tool is treated as purchased.
5. **Toolpaths:** inspect and refine cutting operations, cutting data and the material-removal simulation. Machining alternatives stay in Plan.
6. **Review:** walk through the complete sequence, check results, then export or open **Run on Machine**. The guided sequence stops for fixture changes and manual work-zero verification, including changes on the same side. Changing a fixture definition or CAD file requires regeneration and review.

This first version selects among the assembled fixture states you define and assigns complete generated operations/depth slices. It does not invent jaw positions, split arbitrary toolpaths, or prove clamping force, rigidity or that the part remains connected. Stock and fixture occupancy are sampled; locating cavities are credited conservatively from horizontal flat-end-mill cuts. Review the proposed physical setups before machining.

In **Setups**, click a fixture card. The existing workspace shows the assembly around the actual part and stock. The reviewed **Bookends** automatically fit their contact faces and locating lip to the blank, with mounting hardware in the job machine's measured T-slots. Their side screw controls stay visible; optional base movements are under **Adjust placement**. Releasing the screw keeps the bases mounted. **Use Workholding** saves the job's assembly and returns to Setups with its preview visible. Grip and cutting-load suitability still require review. The header identifies the actual job machine and lets older jobs apply a measured machine profile in place. See [Workholding assemblies](docs/WORKHOLDING_ASSEMBLIES.md).

Other imported models retain general piece editing under **Adjust placement**: select a piece, drag its arrows, use quarter-turn rings, or click a handle to type a distance. Nearby solids are editing groups, not proven mechanical connections. **Fit to Stock Ends** aligns bounding faces; it does not infer gripping faces or joints. **Mark on Stock** marks contacts in the scene. **Cancel** discards the fixture draft. The Quick Release model has its embedded reference table removed in a separate copy, but its source is an exploded view and remains display-only until an assembled definition is supplied.

Placement shows the real X-table and spindle with the enclosure hidden. **Fit Setup** includes that machine context. **Snap to stock** is on by default: nearby stock edges catch the selected model's flat faces, with an edge highlight and a label. Axis-handle drags snap only along that axis; free drags can align corners. Hold **Option** for fine movement without snapping, or use **Snap Selected Piece** for keyboard-accessible alignment. Snapping aligns geometry; the job planner still checks clearance and grip material.

## Machines

The **Machine** page installs and reviews versioned machine packages with their actual STEP model,
axis hierarchy, coordinate mappings, mounting interfaces and source evidence. **Desktop CNC · r2** opens
at digital home with a **203.2 × 37 × 50.8 mm** reference block on the table. **Setup** contains the
stock and axis controls; **Definition** contains the machine specifications. **View** toggles reference
stock and enclosure. Engineering checks and evidence remain in the package and technical documentation.

The profile uses the native Coastline GRBL adapter, a 1500–8000 RPM usable spindle range, an 8 mm shank
capacity and a 75 mm overall-tool-length planning cap; imported Fusion post and capability values remain
documented provenance. See [Machine profiles](docs/MACHINE_PROFILES.md) and [controller/tooling evidence](docs/machine-profile-controller-evidence.md).
Choose **Use for Job** or the workspace machine picker to use that model, table, spindle, motion and
capability limits for setup, CAM, simulation and posting. Projects pin the exact profile and asset hashes;
changing the machine clears generated paths and plan suggestions. Older projects keep their explicit
legacy machine assignment. Machine Control remains on its existing commissioned machine until physical
instance calibration is implemented. Digital checks do not certify full collision clearance or Fusion CAM simulation.

## Requirements

- macOS 26 or later on Apple Silicon
- Swift 6 (Xcode or the Command Line Tools)
- [uv](https://docs.astral.sh/uv/) for the Python geometry engine

## Build and run

```bash
cd engine && uv sync && native/build.sh   # the geometry engine
scripts/selftest.sh                        # CoastlineCore and engine tests
(cd MillCore && swift build --product MillCoreSelfTest && .build/debug/MillCoreSelfTest)
scripts/build-app.sh                       # build the app
Coastline/.build/debug/Coastline           # start it
```

Set `BUNDLE_ID` when you package a branded build (`scripts/make-app.sh`). Check a job folder before you
ship it with `COASTLINE_JOB=/path/to/job` and the self-tests.

For local iteration, double-click **scripts/Coastline Debug.command**, or run
`python3 scripts/dev-app.py --watch`. Keep that one debug session running: Swift, Metal,
engine Python and resource edits trigger a build and automatic relaunch. Failed builds leave
the current app open; the compiler log is **build/dev/build.log**. Starting the launcher a
second time does not create another watcher.

Debug relaunches restore the part, unsaved project setup/operations, completed toolpaths,
workflow step, page, playback position and camera from **build/dev/session.json**, separately
from project files. In-progress generation and Digital Machine position reset. This is an
automatic relaunch, not in-process SwiftUI hot reload. Use `--page control` to open Machine
Control explicitly; otherwise the previous page resumes. Physical-machine connections are
disabled in debug mode. Stop the watcher with Ctrl-C and launch normally to use hardware.

## Viewport navigation

| Input | Action |
|---|---|
| Drag | Orbit |
| Two-finger scroll | Pan |
| Pinch | Zoom |
| Option-drag or right-drag | Pan |
| Double-click | Frame everything |

## Layout

| Folder | What |
|---|---|
| `Coastline/` | The SwiftUI app |
| `CoastlineCore/` | Planning, feeds, post-processor, safety checks, guided-job export, program jobs |
| `Viewport/` | Metal 3D viewport |
| `MillCore/` | Machine session (serial, GRBL protocol, homing, jogging, program runs), `.crproj` reader and writer |
| `engine/` | Python and C++ geometry engine: CAD import, toolpaths, simulation |
| `resources/` | Example projects, samples, machine and fixture models |

## License

GPL-3.0. See [LICENSE](LICENSE) and [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md) for bundled code and files.
