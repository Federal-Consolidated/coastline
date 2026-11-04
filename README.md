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
- Plans orientations, one- or two-sided jobs, and holding with a clamp kit or flat on the bed.
- Keeps an inventory of your stock, tools, fixtures and measuring tools, and plans only with what you own.
- Generates 2.5D and 3D toolpaths (facing, adaptive roughing, contour, pockets, drilling, helical boring, 3D finishing, engraving).
- Feeds and speeds for the machine profile's spindle and frame, across 30+ materials.
- Simulates material removal and checks for collisions with the machine and fixtures.
- **Machine Control:** the actual machine assembly with live position and a compact native control inspector. Connect over USB, home, unlock the eight-direction jog pad (including diagonals), use steps or hold-to-jog, set work zero and G54–G59, go to positions, control the spindle and overrides, feed hold, resume, stop and open the console. Arrow keys also jog; locking cancels current and queued pad/key jogs.
- **Projects:** one list for planned projects (made in Coastline from CAD) and G-code projects (guided jobs around G-code that already exists). Import takes a shared `.zip`, a `.coastline` file, an older `.dd` or `.crproj` job, a job folder or G-code files; Export saves a project as one `.zip` to share.

## Machines

The machine is a profile (`MachineProfile`): travel, envelope, rates, spindle range, tooling and tool-change
moves. The built-in profile is a generic 3-axis desktop mill with a horizontal spindle; the controller's own
`$$` settings set the live limits when it connects. Profiles for other machines can be added.

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

For local UI iteration, run `python3 scripts/dev-app.py --watch`. It opens Machine Control
with Digital Machine, watches Swift sources and package manifests, then incrementally builds
and relaunches after saves. Failed builds leave the current app open. This is an automatic
relaunch rather than in-process hot reload; simulator position and unsaved in-memory state
reset on relaunch. Physical-machine connections are disabled in this development mode.
Stop the watcher with Ctrl-C. Launch the app normally to use hardware.

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
