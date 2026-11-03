# Engraving job (idea)

**Status:** idea, not built. Written 2026-11-01.

A generic guided job that engraves text on a part that is already held in the machine: in any
jig, vise or clamp. The operator sets the zero on the part, so Coastline needs no list of jigs or
parts. The text becomes a program with the toolpath generation Coastline already has.

Older web engraving generators for jig-held parts work the other way: one form per jig, with
each jig's engraving area and zero kept on their server, toolpaths made on the server and the file
sent by email. A generic job avoids that list, works offline and works for any part.

## What the operator does

| Setup | Step | Kind | What happens |
|---|---|---|---|
| Prepare | Clear the machine | instruction | Nothing in the work area. |
| | Home and go to the tool position | run (move) | `home.nc`: the machine profile's `toolChangeMoves`. |
| | Fit the engraver | toolChange | The engraver chosen in the sheet. |
| Zero | Mount the part | mount | Clamp the part so the face to engrave faces the spindle. Connect the probe wire to the part. |
| | Jog over the text centre | instruction | In Machine Control, jog the tool tip 2–5 mm above the centre of where the text goes. Close Machine Control. |
| | Find the zero | run (probe) | `zero.nc`: X0 Y0 here, then creeps down until it touches the face: Z0. |
| | Map the face (optional) | run (probe) | `surface.nc`: up to 9 points on the cut path (`SurfaceProbe.program`). |
| Engrave | Engrave | run (cut) | `engrave.nc`. The runner offers an air cut first. |
| | Go to the tool position | run (move) | Take the engraver out. |
| | Finish | instruction | Vacuum the chips. Never use compressed air on the machine. |

## What exists already

| Piece | Where |
|---|---|
| Text to glyph outlines in the work frame (X up, Y along; any Mac font; height, position, turn, depth) | `CoastlineCore/Plan/Engraving.swift` |
| Engraving toolpath: outlines dropped on the part, cut at depth in passes | `engine/coastline_engine/cam/surface3d.py` `engrave()` |
| Toolpaths from the engine | `EngineCAM.generate(partID:transform:stockMin:stockMax:operations:)` |
| G-code | `GRBLPost.program(header:rpm:paths:machine:)` |
| Surface map and compensation (M111–M114) | `CoastlineCore/Export/SurfaceProbe.swift`: `points`, `program`, `follow` |
| Generic guided job around G-code (home, tool card, mount, zero, run with air cut) | `ProgramJob.fromGCode` in `Program/ProgramJobFromGCode.swift` |
| Projects page Import (a job folder, G-code, a `.dd`, a shared zip) | `Coastline/Model/JobsModel.swift` |
| Paper touch-off text for parts that don't conduct | `Export/GuidedJob.swift` |
| Probe feed and spindle speed | `MachineProfile.probeFeed` (20), `probeSpindleRPM` (1500) |

## What is new

1. **`ProgramJob.engraving(_:into:)`**: the builder. The same shape as `fromGCode`, with the steps above.
   It makes the engraving program itself instead of taking files.
2. **A flat plate for the engine.** `generate` needs an imported part. A new engine call (`plate`)
   makes a box with its top at Z0, a few mm larger than the text, and registers it like an
   imported part. The engraving drops onto a flat face, which the surface map then corrects.
3. **`zero.nc`**: sets the zero where the operator jogged (below).
4. **An "Engrave Text…" action** on the Projects page, next to Import. A sheet with the inputs below
   and a 2D preview of the outlines. Create writes the job folder and opens it.

### Inputs

| Input | Notes |
|---|---|
| Text | One line for now (see Later). |
| Font | Any font on the Mac, as in `EngravingFields`. |
| Letter height | Cap height, mm. `Engraving` default: 4. |
| Depth | Below the face, mm. `Engraving` default: 0.15. |
| Turn | Degrees. 0: reads along +Y, top toward +X. |
| Tool | From the tool inventory: engravers first, then chamfer, ball and flat mills ≤ 3.2 mm (the filter `MachiningInspector` already uses). |
| Material | For feeds and speeds (`FeedsEngine`). |
| Find Z | Probe (bare, conductive metal) or paper. Paper turns the surface map off. |
| Map the face | On or off. Probe only. |

### `zero.nc`

Work coordinates G54. The tool tip is 2–5 mm above the face when it starts; −Z goes toward the part.

```gcode
(Set the work zero: X0 Y0 here, Z0 on the face)
G21
G90
G10 L20 P1 X0 Y0     (X0 Y0 at the current position)
M4 S1500             (turn backward for probing)
G4 P2
G91
G38.2 Z-8 F20        (creep toward the face; alarm if nothing within 8 mm)
G90
G10 L20 P1 Z0        (Z0 on the face)
G91 G0 Z2            (back off)
G90
M5
```

`S` and `F` come from the machine profile. With paper, this step is an instruction instead:
jog to the face with paper, then Set Work Zero, as in the existing touch-off text.

### Building the engraving program

1. `Engraving.polylines()` with the text centred on (0, 0).
2. `plate` sized to the outlines plus 3 mm, top at Z0.
3. `EngineCAM.generate` with one `.engrave` operation.
4. `GRBLPost.program` with the tool's RPM.
5. With the surface map on: `SurfaceProbe.points` from the cut positions, `SurfaceProbe.program(points:face: 0)`
   for `surface.nc`, and `SurfaceProbe.follow(gcode, face: 0)` for `engrave.nc`.

## Safety

- `G38.2` stops with an alarm if it touches nothing, so a wrong start height cannot drive the tool in.
- The engrave program is a cut, so the runner offers an air cut first.
- The mount step tells the operator to connect the probe wire and check that the machine sees no contact before the probe.
- **Open:** the travel check. The program is relative to a zero set at run time, so Coastline cannot
  check the reach when it builds the job. The runner could check the program's extents against the
  travel after `zero.nc` (it knows the work offset then).

## Limits

- The position is as good as the operator's eye: about ±0.2–0.3 mm. Good enough for most engraving.
- Electrical probing needs bare, conductive metal and a part insulated from the machine.
- The surface map is for faces that are almost flat. On a curved face, use the part's own STEP and
  its placement instead of the plate, with the map off.
- Trace only: the tool follows the outline at one depth.

## Later

- More lines, alignment, and line, letter and word spacing in `Engraving`.
- V-carve: depth from the V angle for sharp corners (Clipper2 offsets in the engine).
- SVG logos as outlines, and a fill for flat tools.
- A grid surface map over the whole text area, not only on the cut path.
- Add an engraving to an existing jig job: run after that job's probe and use its work offset (for example G55), so the position comes from the jig, not the eye.

## Files to touch

- `CoastlineCore/Sources/CoastlineCore/Program/ProgramJobEngraving.swift` (new): the builder.
- `engine/coastline_engine/server.py`: the `plate` call. `CoastlineCore/Engine/EngineCAM.swift`: its Swift side.
- `Coastline/Sources/Coastline/Model/JobsModel.swift`, `Views/Jobs/JobsPage.swift`: the action and the sheet.
- `CoastlineCore/Sources/CoastlineSelfTest/`: a test that builds a job and checks `problems(in:)` is empty and that the program stays within the text area at the right depth.
