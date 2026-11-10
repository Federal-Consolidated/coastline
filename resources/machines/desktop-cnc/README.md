# Desktop CNC — digital machine package, revision 2

This package supports digital machine inspection, nested axis motion and stock
placement on the X table. The checks in `manifest.json` record what was proved and
how. Physical controller calibration is separate and remains pending. Digital
status does not activate the profile for machine control or certify a machining
job, holding force, tool reach or a collision-free travel envelope.

## What changed

The read-only complete STEP export includes all 52 authored solids in 50 leaf
occurrences. The nine Cover solids, previously missing, are present and bound to
a separate stationary enclosure component. Hiding that enclosure in a preview is
only a display choice: it remains part of the machine definition. The simplified
source still excludes some bearings, fasteners, switches and other hardware.

The `table-surface` frame describes the actual support plane: local X follows
world Y along the slots, local Y follows world Z across them, and local Z is world
X away from the surface. It is distinct from the original `table` machining-axis
frame. The asymmetric reference block is 203.2 × 37 × 50.8 mm in that seating
frame. Its footprint and bottom plane are checked against analytic STEP faces.
This fixes Coastline's seating-frame ambiguity without claiming a historical
Fusion simulation fault was reproduced. The original `.mch` remains unchanged.

T-slot geometry is a machine interface; the fixture owns its nut and fastener
choice. The custom Bookend M5 nut/key envelopes fit both actual CAD slots. This
seated-fit check does not establish insertion clearance, torque, thread strength
or the installed hardware's dimensions.

Tool dimensions now have distinct meanings. ER11 accepts an 8 mm shank; the
conservative overall-length planning cap is the supplied 75 mm, replacing the
legacy unsubstantiated 76.2 mm value. Nominal collet seating is 22.9 mm. The source
7 mm tool-diameter limit remains in the original Fusion metadata; it is not a
proved cutting-diameter hardware limit. Actual tool stickout is a setup input.
The usable spindle range is 1500–8000 RPM; 1360–8500 are firmware parameters.
The 150 W cutting-power value remains an estimate, not a measured rating.

Coastline uses `coastline.grbl.desktop.v1`, its native Swift GRBL adapter. The
original `system://grbl.cps` reference is provenance only. Native post/preflight
tests check explicit feed/arc modes, bounded ASCII comments, usable RPM and
manual tool changes. Tool-length compensation is preserved consistently with
existing touch-off. No controller command was sent for these checks.

## Commissioning still required

The supplied home mapping is q=(Mx, My+69, Mz+79.9), with controller home
(-86,-0.5,-0.5). Digital checks validate its algebra, nested motion and selected
CAD contact boundaries. Actual switch trip, pull-off, settings and table/spindle
datum measurements are needed to establish that mapping on the installed machine.
The reference CAD pose q=0 is an authoring position; the preview starts at the
defined digital home, inside the configured operating ranges.

## Evidence and reproduction

- `machine.step`: complete source geometry, unchanged; centimetres in STEP,
  converted to millimetres by OpenCascade.
- `source.mch` and `source-README.md`: unchanged original exports/notes. Some
  original warnings describe the earlier incomplete package; the checks and
  resolution evidence here record the actual fixes.
- `geometry-index.json`: source-bound occurrence paths and dimensional audit.
- `fusion-audit.json`: read-only saved-model inspection, including all 52 bodies.
- `geometry-validation.json`: reproduced analytic seating, mounting, body-bounds
  and selected contact checks, generated against this package's actual frames.
- `geometry-resolution.md` and `controller-evidence.md`: engineering decisions,
  exact source references, test scope and limitations.

From the repository root, run `engine/.venv/bin/python
scripts/build-desktop-machine-package.py --source '/path/to/Desktop CNC Machine -
share' --output resources/machines/desktop-cnc` as one shell command. Add `--check`
to compare without writing. `--geometry` defaults to the pinned complete export
in `resources/machine-profile-sources`; source hashes and occurrence names are
checked before packaging. Exact CAD tests run during every generation/check.
Changed source exports require a reviewed mapping and a new package revision.

The `view` frame changes viewport presentation only. Its world-Y right and
world-X up axes display this horizontal-spindle machine upright without changing
controller coordinates, machining frames or toolpaths.
