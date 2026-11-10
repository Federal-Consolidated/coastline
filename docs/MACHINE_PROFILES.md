# Machine profiles

Coastline installs portable machine definitions and uses the selected job profile
for workspace geometry, stock placement, CAM, tool limits, timing and post output.
The bundled desktop CNC profile is revision 2. Browsing a profile is separate from
selecting it for a job; neither action connects to or configures a physical controller.

## Use a machine for a job

Choose **Use for Job** on the Machine page, or select a machine from the workspace
toolbar. The workspace loads the same model, component hierarchy, table surface
and spindle reference used in the profile preview. Generated paths, plan suggestions,
simulation state and clearance caches are cleared when the assignment changes.
Rebuild the job plan with the selected machine's tools and travel limits.

Each project and saved result records its full machine definition, revision and
asset fingerprints. Opening an older project explicitly selects **Legacy Desktop
CNC**; it does not silently adopt revision 2. Missing or changed packages produce
an error before replacing the current job. Shared projects preserve the machine
snapshot; colleagues must install the matching profile package as well.

The last deliberately selected machine is the default for a new workspace. Saved
projects and debug sessions retain their own assignments. Timing calibration is
stored separately for each complete profile snapshot.

## Review the desktop CNC

1. Open **Machine** in the sidebar and select **Desktop CNC · r2**. It starts at
   digital home, with the axis controls available and an asymmetric reference
   block seated on the table.
2. In **Setup**, inspect the **203.2 × 37 × 50.8 mm** reference stock and move the
   digital X/Y/Z axes using the sliders or the small −/+ buttons, which step by
   1 mm. Positions are controller coordinates in millimetres. The stock moves
   with the table.
3. Use **View → Reference Stock** and **View → Enclosure** to control visibility.
   The menu also provides standard camera directions, **Moving Parts Only** and
   **Frames & T-slots**. **Fit Machine** frames the visible geometry.
4. **Reference Pose** shows the CAD model as exported, before axis motion is
   applied. That pose can lie outside operating travel, so the axis controls are
   disabled there. **Show Home** returns to the digital home position.
5. Open **Definition** for machine specifications, mounting interfaces and motion
   details. **In this job** identifies the profile used by the workspace; **Available**
   identifies a profile being browsed. **Use for Job** changes the planning assignment.

| Tab | What to inspect |
| --- | --- |
| Setup | Reference stock and compact axis controls. On this mill, X moves the table and Z rides on the Y carriage. |
| Definition | Identity/revision, spindle and tooling values, reference frames and table mounting interfaces. Expand Assemblies and Axis limits for motion details. |

Engineering checks and evidence are retained in the package and technical
documentation rather than presented as a separate inspector tab.

**Show Home is a visualization action**, not a physical homing command. Axis motion
in this view does not run live collision checks. The existing live-machine settings
and maintenance view remains under **More → Current Machine & Maintenance…**.

## Import a profile

Choose **Import Profile…** and select a folder containing `manifest.json` and all
its declared assets. A Fusion `.mch` by itself is insufficient: Coastline also
needs portable geometry, component bindings and explicit coordinate information.

The importer validates the manifest, asset fingerprints and file paths, then copies
the declared files into `~/Library/Application Support/Coastline/Machine Profiles`.
Importing the same ID/revision with different data is rejected; export a new
revision instead. **More → Reload Profiles** rereads the library, and **Show Profile
Files** reveals the selected package.

The digital format supports three orthogonal linear axes, milling and GRBL.
The current setup planner additionally requires a horizontal spindle, an explicit
seating surface and table T-slots. Its coordinate basis comes from relative
table/head motion, so rotated CAD and renamed components do not change behavior.
Vertical profiles remain inspectable but cannot use this horizontal fixture planner.
Unsupported configurations produce a specific error rather than a desktop fallback.

CAM currently uses the reviewed fixture family: two parallel slots approximately
40 mm apart with matching opening, cavity and lip dimensions and enough slot
length for the reviewed 11 mm mounting nut. A different mounting
interface can be inspected but needs compatible workholding before CAM is generated.
This limit belongs to the current vetted fixture library, not to all machine profiles.

## What the digital checks establish

Revision 2 separates completed digital checks from physical commissioning. The
asymmetric block makes a swapped stock orientation visible and is checked against
the table surface and the table's motion. The enclosure is available as a separate
visibility group. These improvements support digital setup inspection; they do
not certify a collision-free job or reproduce and certify Fusion CAM simulation.

The remaining physical calibration step asks for the actual machine's homed
positions, axis directions and reference measurements. The current
controller-to-model mapping is still inferred from the supplied sources. The
package's commissioning record describes the measurements needed to establish
the physical mapping; moving the digital sliders does not complete that step.

The capability decisions are explicit:

- **Spindle:** cutting programs use **1500–8000 RPM**. The separate **1360–8500 RPM**
  values are firmware reporting parameters, not the usable cutting range.
- **Tooling:** the profile uses an **8 mm shank capacity**, **75 mm overall-length
  planning cap** and **22.9 mm nominal collet seating depth**. Fusion's imported
  7 mm tool-diameter value remains source metadata. Cutting diameter, shank
  diameter, overall length and measured stickout are distinct quantities.
- **Tool changes:** one installed tool and manual guided changes. Fusion's preload
  flag does not enable an automatic changer; its 15-second duration is an estimate.
- **Mounting:** the machine defines the T-slot geometry; each fixture supplies its
  matching hardware. The bookends' custom M5 nut and key fit both slots in the
  seated CAD check. That check does not establish insertion clearance, holding
  strength or which hardware is installed on the physical machine.
- **Post:** the profile identifies the implemented native adapter
  `coastline.grbl.desktop.v1`. `system://grbl.cps` remains Fusion provenance; Coastline
  does not execute that CPS. The native post explicitly establishes feed-per-minute
  and arc-centre modes while preserving the tool compensation used at touch-off.

See [controller and tooling evidence](machine-profile-controller-evidence.md), the
[original source audit](DESKTOP_MACHINE_PROFILE_AUDIT.md), and the
[phased proposal](MANUFACTURING_WORKFLOW_PROPOSAL.md). Successful import verifies
structure and asset fingerprints; it does not independently prove the author's
validation claims. Machine Control and independently imported G-code jobs retain
their existing commissioned machine and model. **Run on Machine** is not enabled
for newly selected profile jobs yet; physical instance calibration and execution
integration are a separate checkpoint. The workspace can generate, simulate and
export the selected profile's proposed programs for review.

## Package structure and reproduction

The included example is [`resources/machines/desktop-cnc`](../resources/machines/desktop-cnc).
Its `manifest.json` carries a stable ID and revision, runtime limits, a native post
adapter ID, component hierarchy, frames, reference stock, mounting interfaces,
evidence and scoped validation checks. All asset paths are
relative and every declared asset has a SHA-256 fingerprint. STEP occurrence
bindings are index paths tied to the exact model revision; the most specific
matching ancestor owns each shape.

Geometry and frame origins use CAD-world millimetres at model-axis zero. Axis
mapping is explicit: `model position = controllerScale × controller position +
controllerOffset`. Children inherit moving ancestors. For this mill the inferred
offsets are `(0, 69, 79.9)` mm; they are not a generic rule for other machines.
The optional `view` frame supplies a display basis without changing controller
coordinates or the authored machine geometry.

Revision 2 uses the full STEP export at
`resources/machine-profile-sources/desktop-cnc-full.step`: 52 assembled solids in
50 leaf occurrences, including the nine Cover bodies missing from the original
simplified export. Cover geometry is visible on demand; including it does not
certify full-machine collision coverage.

Reproduce the desktop package from that geometry and the unchanged supplied
definition and notes:

```sh
engine/.venv/bin/python scripts/build-desktop-machine-package.py \
  --source '/Users/pd/Project/CNC Model/export/Desktop CNC Machine - share' \
  --output resources/machines/desktop-cnc
```

Append `--check` to verify reproducibility without writing. The generator pins
the reviewed source fingerprints, checks STEP scale/reference dimensions and
component assignments, and reruns the CAD seating/contact audit. `--geometry`
accepts an explicit path; its default is the full STEP above. The package also
includes the source Fusion audit and controller/tooling evidence. A revised CAD
export requires reviewed bindings and a new package revision. The `.f3d` remains
the authoring source; Coastline does not require it or the original Fusion cloud
link to load this digital setup.

The Swift loader is in
[`MachineDefinitionPackage.swift`](../CoastlineCore/Sources/CoastlineCore/Machine/MachineDefinitionPackage.swift);
the engine's manifest path is handled by
[`machine_profile.py`](../engine/coastline_engine/machine_profile.py) and
[`load_profile_machine`](../engine/coastline_engine/machine_model.py).
No package post processor or script is executed during import.

## Revision 2 verification

On 2026-11-06 the macOS app built successfully and 86 focused checks passed:
12 Swift machine-definition checks, one end-to-end Swift/Python profile RPC
check, 17 controller/post/export checks, eight exact CAD regressions, and 48
Python profile/travel/import checks. The package generator reproduced all ten
files, running fresh exact CAD checks against the emitted seating and tool
frames. The independently generated geometry report matches the bundled report
byte for byte.

This verifies the implementation and stated digital checks. Native UI interaction,
Fusion CAM machine simulation and measurements on the installed machine have
not been performed as part of this revision.

## Workspace and CAM integration verification

On 2026-11-06 the app built successfully with machine selection in the workspace
and the Machine page. The focused integration run passed 78 distinct checks:
seven planning-geometry checks, 15 CAM checks, 11 setup checks, 17 fixture checks,
seven generated-job checks, eight pinned-machine reference checks, 12 definition
checks and one full STEP Swift/Python integration check.

The geometry checks cover rotated CAD coordinates, component motion, table
thickness and support bounds, unsupported mounting interfaces and disconnected
coplanar fastener pads. The full STEP check verifies the actual 305 mm stock
support span rather than extending it to the small mounting pads. CAM regressions
exercise selected-machine RPM/feed/travel limits, tool eligibility and purchase
remedies. Persistence regressions reject missing or altered profile packages.

This checkpoint is ready for user review in the workspace. Native UI interaction
and physical machine execution were not exercised by these automated checks.

## Verification scope

Automated checks cover package structure, installation, source fingerprints,
geometry scale, stock seating, component ownership, Swift/Python motion agreement
and the native post's generated-program contract. They are separate from physical
machine calibration, installed-tool measurements, full collision validation and
Fusion CAM simulation. Workspace/CAM selection does not complete those physical
execution checks or change the commissioned Machine Control connection.
