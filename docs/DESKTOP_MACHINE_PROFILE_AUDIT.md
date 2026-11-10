# Desktop machine profile — source audit and resolution record

Date: 2026-11-06  
Status: Revision 2 resolves the portable model's geometry, seating frame, controller adapter and tooling policy through source review and automated CAD tests. Physical homing calibration and Fusion CAM simulation remain unverified. Supplied source files are unchanged. The original audit below is preserved as a record of the issues found; current behavior is described in [Machine profiles](MACHINE_PROFILES.md).

This is the evidence for checkpoint 1 of the [manufacturing workflow proposal](MANUFACTURING_WORKFLOW_PROPOSAL.md). Digital validation does not constitute user acceptance or activate a profile for physical machining.

## Revision 2 resolutions

| Original issue | Concrete change and evidence | Remaining boundary |
| --- | --- | --- |
| Stock orientation | Added a table seating frame separate from the machining WCS. Exact CAD tests seat a 203.2 × 37 × 50.8 mm asymmetric block on the actual table plane; regressions reject the old basis, floating stock and off-table stock. The app renders that specimen attached to the moving table. | This validates the portable Coastline setup. The original Fusion CAM simulation has not been reproduced or corrected in the source document. |
| Controller-to-model calibration | Explicit mappings and parent motion now have regression tests; CAD contact checks constrain selected Y/Z travel boundaries. | Actual homing-switch offsets must be measured on the physical machine. The profile records a concrete measurement procedure rather than claiming measured calibration. |
| Conflicting tool limits | Separate the 8 mm shank capacity, 22.9 mm seating requirement and a conservative 75 mm overall-length policy. Do not use Fusion's authored 7 mm cutter field as a universal shank limit. | These are different dimensions, not interchangeable machine ratings. Tool reach and clearance still depend on each setup. |
| M4/M5 mounting | Store the table's slot envelope independently of the fixture's bolt thread. Exact booleans check both reviewed Bookend M5 nut/key envelopes against the table. | Geometry fit is not a torque or clamping-force rating. |
| Controller/post | Bind the native Coastline GRBL adapter explicitly. Add feed and arc-mode initialization, closed bounded comments, and correct G91.1 classification/preflight. | The source Fusion CPS link remains provenance; Coastline does not execute imported scripts. Existing tool-length compensation is preserved consistently with touch-off. |
| Reference pose versus limits | Start the digital scene at the defined home. Keep the exported q=0 pose available separately with axis sliders disabled. | The CAD origin is not necessarily an operating pose. |
| Simplification and missing covers | Export all invisible components/bodies read-only from the saved Fusion document. The new STEP matches all 52 audited body bounds, including nine cover bodies; hiding the enclosure is display-only. | This is still a simplified source model and does not certify unmodelled hardware or full-motion collision clearance. |
| Spindle range | Retain 1500–8000 RPM as the documented usable range and preserve 1360–8500 as firmware settings evidence. | Reported settings are not the same as usable cutting limits. |
| Manual tool change | Use the native operator-guided tool-change contract; do not infer an automatic changer from generic Fusion preload metadata. | Tool-change duration is not a verified cycle-time promise. |

Detailed reproducible evidence: [geometry checks](MACHINE_PROFILE_GEOMETRY_RESOLUTION.md), [geometry results](machine-profile-geometry-validation.json), and [controller/tooling review](machine-profile-controller-evidence.md). The full export is retained at `resources/machine-profile-sources/desktop-cnc-full.step`, SHA-256 `7035295044ea6c8e84ef12289cb68a4bb3dab5bb70ad5d86477fa82e9f720cc3`.

## Original source audit

## Source package

Folder: `/Users/pd/Project/CNC Model/export/Desktop CNC Machine - share`.

| File | Size, bytes | Observed role |
| --- | ---: | --- |
| `Desktop CNC Machine.mch` | 54,901 | JSON Fusion machine definition. |
| `CNC simplified v31.f3d` | 3,453,681 | Fusion archive with design, machine/CAM and simulation data. |
| `CNC simplified v31.step` | 2,923,711 | STEP AP214 assembly; its declared length unit is centimetres. |
| `README.md` | 4,813 | Layout, controller defaults, component assignments, table dimensions and known limitations. |

The `.mch` declares millimetres and degrees. The STEP declares centimetres. Each importer must honor its own file's units and convert once into Coastline's millimetre coordinates. Neither a missing conversion nor an additional manual 10× scale is acceptable.

The README describes 34 unique parts and 52 bodies. The STEP contains 34 solid definitions and 72 assembly-occurrence relationships; those are different kinds of counts. Follow-up inspection found 43 assembled STEP solids and 52 Fusion body proxies: the nine bodies under Fusion's `Cover` root are absent from the STEP. The remaining counts and checked table/spindle dimensions agree. The portable model therefore omits enclosure/cover geometry.

The active saved `CNC simplified v31` document contained no CAM setups or document machines during the API inspection. Its geometry was read without changing or saving the document. The reported 90° stock-placement issue could not be reproduced from a setup in that document. The evidence is retained in [the Fusion audit](machine-profile-fusion-audit.json) and the draft package.

### Source fingerprints

```text
CNC simplified v31.f3d
248593fa1d679518f2329452b9b2237a479fe9995be0d462069949015341f1ea

CNC simplified v31.step
c485b7053d1d20f89e27e950628d3359c084bf1900547ceb7ba40b3ec9955ce0

Desktop CNC Machine.mch
c7492a394592ee32571aaf2453c39533dd2cb4ecf5c71f4b1db4391a9cb7fc52

README.md
7ee11e8a3e8020a3a4fecce8b8441d5c818237a1cb3a34e6856a35d80698a6c8
```

These SHA-256 hashes identify the files inspected. They establish identity, not manufacturing validity.

## What the supplied definition contains

The JSON has `controller`, `fusion`, `general`, `interactions`, `kinematics`, `machining`, `post`, `post_settings` and `tooling` sections. The main motion tree is under `kinematics.default.parts`:

```text
Machine root
├── base                         static frame
├── X                            table motion
│   └── table                    stock/fixture attachment
└── Y                            carriage motion
    └── Z                        head motion relative to carriage
        └── head                 spindle/tool attachment
```

| Axis | Positive motion vector in CAD world | Definition range, mm | Definition home, mm | Max feed/rapid, mm/min |
| --- | --- | --- | ---: | ---: |
| X | (−1, 0, 0), table downward | −86.5 … 0 | −86.0 | 2540 |
| Y | (0, +1, 0), carriage and head | −172.5 … +69.0 | +68.5 | 3100 |
| Z | (0, 0, +1), head retracts | +1.4 … +79.9 | +79.4 | 3100 |

These positions refer to the model pose. They must not be copied directly into controller-position limits.

The table attach point is `(15.865, −343.0, 79.04)` mm. The head attach point is `(105.43, −176.8, 112.26)` mm, described in the README as the ER11 nut front face on the spindle axis. Both frames specify local x along world +X and local z along world +Z. The tool points toward world −Z; tool length/reference semantics need to match that direction.

Other configured values:

- Milling head; spindle range **1360–8500 RPM**.
- ER11 station; maximum **tool diameter 7 mm** and **tool length 75 mm**.
- Manual tool change: one tool, no changer. `supports_tool_preload` is nevertheless `true`; review its meaning before mapping it into Coastline behavior.
- Tool-change time **15 seconds**, a configured estimate rather than measured evidence.
- Post references in `post.default.path` and `post_settings.default.path`: `system://grbl.cps`.
- `fusion.default.model_urn` points to version 31 in the original Fusion cloud location. It does not point to the neighboring STEP/F3D files.
- Collision pairs compare the base, table chain and spindle chain, with internal same-chain pairs excluded. This records configuration, not a successful collision test.

Native component/model bindings need inspection in Fusion and an explicit portable mapping for Coastline. Display names or the cloud URN alone are insufficient.

## Priority findings to resolve

| Finding | Evidence and implication | Required resolution |
| --- | --- | --- |
| **Stock rotated 90° in Fusion simulation** | Supplied README reports the stock's long side along Z and says changing the table attach frame changed position only. | Reproduce with an asymmetric reference part. Check setup orientation, WCS, attachment frames and machine-model mapping; demonstrate the corrected placement before accepting simulation. |
| **Different axis origins** | `.mch` home is `(−86, 68.5, 79.4)`; README controller home is `(−86, −0.5, −0.5)`. | Define and validate the controller-to-model mapping, including signs, before any position or limit is reused. |
| **Assumed X reference pose** | README says X=0 at the lowest table position is assumed. | Identify whether this is CAD convention or a measured physical pose, then record the calibration evidence. |
| **Z reference pose outside operating range** | Model-pose qZ=0 is below the definition's minimum qZ=1.4. | Explain the reference pose separately from allowed operating poses; do not initialize digital motion at an invalid pose unnoticed. |
| **Y hard stops need reconciliation** | README quotes world spindle positions −350.1 … −107.8 mm, while definition ranges use model-pose coordinates. | Check the reference location, hard stops and chosen margins in a common frame. |
| **Reported versus usable spindle range** | `.mch`: 1360–8500; current app: 1500–8000, with a comment explicitly distinguishing usable speed from reported firmware limits. | Preserve both meanings and sources. Establish the usable range; do not overwrite it with controller metadata. |
| **Different tooling limits/semantics** | `.mch`: tool diameter 7 mm, length 75 mm. App: shank diameter 8 mm, length 76.2 mm, collet seating depth 22.9 mm. | Define cutting diameter, shank diameter, overall length, gauge reference and stick-out separately; confirm actual constraints. |
| **M4/M5 mounting descriptions** | Supplied README references M5 screws; the current app names an M4 T-slot nut. | Verify the installed hardware and permitted slot/nut geometry. Do not silently choose either description or adopt the README's torque suggestion as a vetted rating. |
| **Post is a library link** | `system://grbl.cps` is not a bundled, revision-pinned implementation. Existing app has custom startup, spindle-ramp, probing and tool-change behavior. | Review the intended controller dialect and emitted behavior before choosing a post/adapter. A GRBL label alone does not prove equivalence. |
| **Simplification omits hardware** | README says fasteners, bearings, switches/targets, belts, electronics and other parts were removed. | Determine which omitted geometry affects motion clearance and which exclusions are acceptable. Document collision coverage. |

### Candidate coordinate mapping — hypothesis only

Let `q` be the axis position in the supplied machine definition and `M` be GRBL machine position. If the README's home values refer to the same physical pose and the described directions are correct, they imply:

```text
qX = MX
qY = MY + 69.0 mm
qZ = MZ + 79.9 mm
```

At the stated controller home `M = (−86, −0.5, −0.5)`, this produces the definition home `q = (−86, 68.5, 79.4)`.

This is an inferred axis-coordinate mapping, not a complete world transform or measured calibration. X's moving group then uses its negative world-X direction; Z inherits the Y carriage transformation. The `.mch` `zero_position_offset` entries are all zero, so the controller mapping is not established by those entries.

Under this hypothesis, the definition's ranges map to controller ranges X −86.5…0, Y −241.5…0 and Z −78.5…0. The current app intentionally uses smaller/asymmetric windows around some endpoints. Keep definition travel, homing pull-off, usable controller limits and mechanical stops separate; investigate endpoint policy rather than treating the range difference as a unit error.

## Information that needs structured supplemental fields

These values are documented in the supplied README but are not fully represented by the `.mch`:

| Area | Source claims to validate and represent |
| --- | --- |
| Controller configuration | Steps/mm 400 per axis; acceleration 500 mm/s² per axis; GRBL-based firmware. |
| Homing | Z first, then X/Y; X homes negative, Y/Z positive; 0.5 mm pull-off; resulting machine coordinates. |
| Table seating surface | World X=15.865 mm, normal +X; raised surface approximately 305 × 75 mm. |
| Mounting interface | Two Y-directed T-slots at world Z=78.759 and 118.764 mm, about 40.005 mm apart; −Y nut entry. |
| Slot geometry | Opening 6.13 mm, lips 2.0 mm, cavity 12 × 3 mm. These are source claims pending measurement checks. |
| Calibration and evidence | Whether a value is defined by CAD, copied from controller defaults, measured, estimated or unresolved; source revision and validation date. |

The table is a machine mounting interface. The Bookends remain separate vetted fixtures that reference that interface. Neither the part nor the current stock should be baked into the reusable machine model.

## Coastline integration audit before implementation

The initial code audit found the following foundation and gaps. The subsequent package/preview work adds an independent inspection path; active planning and control still use the legacy machine. The explicit home-vector issue below has now been corrected and regression tested.

| Area | Current state | Change after Fusion acceptance |
| --- | --- | --- |
| Profile | [`MachineProfile.swift`](../CoastlineCore/Sources/CoastlineCore/Machine/MachineProfile.swift) stores motion, spindle, tooling, controller and probe values; provenance is in comments. | Add stable identity/revision, explicit frames/hierarchy and structured evidence status. |
| Selection | [`AppModel.swift`](../Coastline/Sources/Coastline/Model/AppModel.swift) owns immutable `MachineProfile.standard`. | Select a machine definition and physical/digital instance explicitly. |
| Geometry | AppModel and [`ControlMachineView.swift`](../Coastline/Sources/Coastline/Views/Control/ControlMachineView.swift) load the fixed `resources/machine/machine.step`. | Resolve model assets from the selected profile revision. |
| Kinematics | [`machine_model.py`](../engine/coastline_engine/machine_model.py) groups assemblies by names and contains desktop-specific spindle, table, slot and pose constants. | Import explicit component roles, parent relationships and reference frames. |
| Calibration | The current model pose is estimated from CAD motion/travel; [first-cut notes](FIRST_CUT.md) still request real table/spindle measurements. | Preserve that uncertainty; never re-label it as measured calibration during migration. |
| Home | `MachineProfile.toolChangeWaypoints` starts from envelope upper bounds rather than an explicit home vector. | Represent home separately and check all consumers, especially this machine's X home. |
| Projects | [`ProjectDocument.swift`](../Coastline/Sources/Coastline/Model/ProjectDocument.swift) does not persist a machine ID/revision. | Pin the planning machine and relevant configuration, including explicit legacy migration. |
| Consumers | Most planning/post APIs accept a profile, but operation cutting data, adaptive parameters and some library checks still use `.standard`. | Pass the selected profile consistently and test a contrasting profile. |
| Control | Live GRBL settings supply controller limits separately. | Compare reported settings with the selected definition and calibrated instance; do not silently overwrite either. |

Existing travel `(86.5, 241.5, 78.5)` mm, physical-envelope estimates `(89, 242, 79)` mm and usable machine-coordinate windows describe different things. They should not become one generic machine “size.”

## Library findings to carry into the later checkpoint

- The repository's starter inventory already uses **Universal Clamp** and **Quick Release Jig Plate**. The old **CR-1 Universal Clamp** survives in the user's saved inventory. A targeted migration should match the legacy built-in name/kind/model and retain its ID and fixture definition; do not globally replace CR1 strings used for legacy file compatibility.
- Existing Bookends are saved as **Workholding-Bookends**. Preserve that asset and its identity while defining the vetted assembly behavior.
- Stock/tools already have editable persisted inventory, and Fusion tool-library import exists. Materials currently come from compiled `MaterialLibrary.all`; installable material definitions require later implementation.

These are recorded requirements, not changes made by this audit.

## First Fusion review session

1. Work from the supplied definition and source model, preserving the original exports. Verify the component assignments and cloud/local model relationship.
2. Inspect the axis hierarchy, frame directions and attachment points; compare each positive motion and parent motion against the physical machine layout.
3. Use an asymmetric blank/reference part to isolate the reported 90° placement problem. Validate seating, long direction, tool approach and WCS together.
4. Compare the digital home and range endpoints in both coordinate systems. Record any unresolved physical measurement separately.
5. Review spindle/tool semantics, mounting hardware, controller/post requirements and relevant collision exclusions.
6. Export the reviewed definition/model pair and a short validation record. Present the behavior to the user for acceptance before coding its Coastline importer.

Fusion defines machine geometry and kinematics as linked assets, and supports explicit collision-pair exclusions. An excluded pair is not checked, so a simulation result must be interpreted with its configured coverage. [Autodesk: machine definitions and models](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINES.htm), [kinematics editing](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINE-EDIT-KINEMATICS.htm), [collision-pair configuration](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINE-MANAGE-COLLISION-CHECKS.htm).
