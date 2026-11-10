# Desktop machine geometry, seating and mounting evidence

This records the geometry fixes and their limits. The reproducible checks use
OpenCascade on the STEP solids; they do not drive Fusion or the machine.

## Complete geometry recovered

The original `CNC simplified v31.step` contains 43 assembled solids in 41 leaf
occurrences. The native Fusion source contains 52 body proxies, including nine
under `Cover`. Those bodies were hidden, rather than absent from the design.

The complete export is
`resources/machine-profile-sources/desktop-cnc-full.step`, SHA-256
`7035295044ea6c8e84ef12289cb68a4bb3dab5bb70ad5d86477fa82e9f720cc3`.
It contains 52 assembled solids in 50 leaf occurrences. All 41 original leaf
occurrences preserve their names, paths, world bounds within 0.000001 mm and
volumes within 0.00001 mm³. Every one of the 52 STEP solids matches a body proxy
from `docs/machine-profile-fusion-audit.json` by world bounds within 0.001 mm.
Bounds and volume agreement are identity checks, not a proof of identical topology.

The original four component branches keep their paths. `0/4`, named `Cover`, is a
separate static component. It contains the back plate, enclosure, two handles,
two X top chip guards, Y side and top guards, and front cover. No geometry was
transplanted from the unrelated legacy STEP or positioned by a bounding-box guess.

Recovering these nine bodies does not reverse intentional simplification of the
native model. For example, the full export still lacks the bearing/nut hardware
used in the earlier X hard-stop audit and the electronics/power-supply covers
used in two earlier Y contact checks.

## Stock seating and machining coordinates are different frames

The table's broad support plane is **world X = 15.86513635655 mm**. Its raised
support footprint is world Y **−389.422758…−84.422758 mm**, world Z
**54.913594…129.843594 mm**. These are analytical plane measurements from the CAD
table, not the extent of the full table assembly with chip guards.

The seating frame at the Bookend datum corner is:

| Value | World millimetres / direction |
| --- | --- |
| Origin | `(15.865, −343, 79.04)` |
| Local X, stock length | `(0, 1, 0)` |
| Local Y, stock width | `(0, 0, 1)` |
| Local Z, stock thickness away from table | `(1, 0, 0)` |

The existing machining WCS remains world X/Y/Z aligned. The spindle tool axis is
world Z; it is horizontal and perpendicular to the table normal. Making stock
thickness follow machining WCS Z turns the stock onto the wrong plane.
The tool frame is checked against the largest analytical cylindrical surface of
the spindle tube and the collet-nut nose plane. Its rounded source origin agrees
within 0.01 mm; positive tool Z points from the nose into the spindle.

The source authoring history makes this distinction explicit:

- `/Users/pd/Project/CNC Model/scripts/mch_update_simplified.py` used the seating
  basis X=`(0,1,0)`, Z=`(1,0,0)` at the table centre.
- `mch_desktop_cnc.py` subsequently changed `table.attach_frame` to machine-axis
  X=`(1,0,0)`, Z=`(0,0,1)` at the stock datum corner. Its comment calls this
  “machine axes at the datum corner.”

Coastline therefore needs an explicit `table-surface` seating frame as well as
the machining WCS. This resolves Coastline's orientation without pretending to
have reproduced a historical Fusion setup; the audited Fusion document had no
CAM setups.

The regression block is deliberately asymmetric: local **203.2 × 37 × 50.8 mm**.
Its world bounds must be `(15.865, −343, 79.04)` to
`(66.665, −139.8, 116.04)`. All four bottom corners lie on the measured table
plane within 0.001 mm and the footprint lies within the raised support envelope.
The test rejects the old machine-axis seating basis, a floating block, and a
block extending beyond the table. This is a seating check, not a workholding
grip or cutting-force assessment; the footprint can span the T-slot openings.

## Mounting is a geometric interface, not one screw size

The two T-slot centre lines are world Z **78.7585941251** and
**118.7635941251 mm**. Each has a 6.13 mm opening, a 12 mm wide × 3 mm high nut
cavity, and a 2 mm lip. A standard M4 T-nut and a custom M5 T-nut are different
fixture hardware choices that can use the same table interface.

The current Bookend authoring source is
`/Users/pd/Project/CNC Model/scripts/wh_build2.py`, not the earlier `wh_build.py`:

- Each upright uses two M5 × 25 screws and washers, one per slot.
- The custom nut envelope is 11 × 11.6 × 2.8 mm, with 0.4 mm chamfers.
- The source requests `M5x0.8`, ISO metric, internal class `6H` thread metadata.
- The alignment key is 6 mm wide × 1.8 mm deep; bolt clearance diameter is 5.5 mm.

The audit places conservative, unchamfered nut and key envelopes into both
actual CAD T-slots. Exact solid intersections are zero. Point classification
checks that the nearby neck and cavity positions are void while points just
outside the specified widths are table material. Thus the result is based on
the modeled slot, not merely comparison of advertised dimensions.

This establishes seated geometric fit. It does not establish an insertion path,
actual installed thread size, tightening torque, thread strength, or whether the
user's manufactured nuts follow this CAD revision. Those belong to the fixture
definition and setup review, not a generic “M4 only” machine restriction.

## Controller position mapping is only partly evidenced by CAD

The declared digital mapping is `q = (MPosX, MPosY + 69, MPosZ + 79.9)`. Table
motion is world `−X`; the Y carriage moves world `+Y`; the spindle inherits Y
and moves world `+Z`. The exported shape is the authored reference `q=0`, which
need not be an allowed controller operating position.

Selected exact-solid checks corroborate parts of this mapping:

| Contact pair and model position | Result |
| --- | --- |
| Z body / YZ body, qZ = −0.01 | 4.084 mm³ overlap, beyond lower CAD stop |
| Same, qZ = 1.4 | Clear by 1.4 mm |
| Same, qZ = 79.9 | Clear by 0.1 mm |
| Same, qZ = 80.01 | 3.313 mm³ overlap, beyond upper CAD stop |
| Lower spindle mount / X top guard, qY = 69, qZ = 1.4 | Clear by 0.804976 mm |
| Same, qY = 69.84, qZ = 1.4 | 0.004724 mm³ overlap |

An earlier source audit,
`/Users/pd/Project/CNC Model/cad/machine/primary_stop_measurements.json`, brackets
X table travel at 0…87.959 mm and Z travel at 0…80 mm. It expressly covers
selected contact pairs, not a complete travel envelope. Its Y carriage pose
differs from v31 by approximately +54.096719 mm; those historical Y contact
numbers cannot be copied into v31 unchanged. The new direct Y check avoids
that reference-pose ambiguity for the recovered upper contact pair.

These checks do **not** measure homing-switch trip points, pull-off distance,
machine-position readback, or installed firmware settings. The physical
controller-to-model calibration remains unmeasured. The older renderer's
`MODEL_POSE` was also an estimate from collision ranges and is not independent
calibration evidence. No complete three-axis collision guarantee follows from
the selected pairs above.

## Reproduce

From the repository root:

```sh
engine/.venv/bin/python scripts/audit-desktop-machine-geometry.py \
  --manifest resources/machines/desktop-cnc/manifest.json \
  --output docs/machine-profile-geometry-validation.json
engine/.venv/bin/python -m pytest -q scripts/tests/test_desktop_machine_geometry.py
```

The JSON report records the actual input hash, native body agreement, support
plane, asymmetric block bounds, both mounting fits, and contact-check results.
