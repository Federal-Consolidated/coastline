# Coastline manufacturing workflow proposal

Date: 2026-11-06  
Status: Checkpoints 1–4 have user acceptance (DFM on 2026-11-07). Checkpoint 5 has started: slice 5.1 (what the plan cuts) awaits review; side setups (5.2) are next. Physical commissioning remains separate. Handoff status updated 2026-11-07.  

## Goal and working agreement

Load a part, choose a machine and available stock, and have Coastline propose a machining sequence using the tools and vetted workholding in the user's library. Explain what is possible, what needs a change, and how to physically set up each operation.

Build and review one piece at a time. Each checkpoint below ends with a working demonstration and the user's acceptance. Fix that piece until it behaves as intended before starting the next. Passing automated checks alone does not advance a checkpoint.

**The first deliverable is a correct machine definition and model in Fusion.** Importing that definition into Coastline follows its acceptance. DFM, new planning behavior and workholding automation follow later.

## Scope decisions

- Support multiple machine models and multiple individual machines over time. The first supported machine is the user's horizontal-spindle desktop CNC.
- Start with vetted workholding, including the Bookends. A fixture is eligible for automatic planning only after its mounting, adjustment, contact and use limits are defined and reviewed.
- Use generic fixture display names. Rename the old **CR-1 Universal Clamp** to **Universal Clamp**; audit other CR-1 fixture labels when the library checkpoint begins. Preserve identities, geometry, saved references and user-customized names.
- Allow users to install/import and edit **stock, cutting tools and materials**. Installing a material or tool does not automatically establish proven cutting parameters for every machine.
- Keep arbitrary custom-fixture teaching and automatic interpretation of imported fixture CAD outside the first release of this workflow. Preserve existing user assets; do not silently delete or reclassify them as vetted.
- Allow unchanged stock faces to coincide with the finished part. Zero allowance is valid when no operation needs to cut that face.
- Keep the actual machine, stock, part and fixtures together in the existing workspace. Setup guidance and corrections should refer to that view.

## What the research changes

ToolDance presents DFM, automatic machining proposals and guided workholding as a connected experience. Its public demonstrations are useful workflow references, but they do not establish that arbitrary imported fixtures can be understood or secured automatically. Coastline should use an editable machining proposal, then resolve and verify the physical setups before treating the job as ready to run. [ToolDance](https://tooldance.ai/), [official workholding demonstration](https://cdn.shopify.com/videos/c/o/v/b8e39463f98b43b09837b6d7c645ae66.mp4).

Fabworks illustrates a useful DFM principle: findings come from manufacturing rules and measured geometry, and the explanation tells the user what to change. Its sheet-metal rules are not milling rules. Digital Metal documents feature-linked measurements and configurable rule packs; that is a useful pattern for explainable findings, not evidence that a generic report proves a setup on this mill. [Fabworks](https://www.fabworks.com/blog/ai-dfm-check-mcp), [Digital Metal](https://www.digitalmetal.io/resources/api/dfm).

Fusion distinguishes the machine definition from the linked CAD model. Its kinematics describe component relationships and motion; the CAD provides geometry for visualization and simulation. Coastline needs both, plus the controller calibration and mounting information specific to our workflow. [Autodesk: manufacturing machines](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINES.htm), [machine kinematics](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINE-KINEMATICS.htm).

These references inform the proposal. No external CAM or DFM service, or replacement CAM engine, is selected by this document.

## Intended user flow

1. **Part and resources:** import the part; select the machine, material and owned blank. Keep the part at its designed size unless the user deliberately changes it.
2. **Analyse:** identify relevant features, tool access and resource limitations. Show findings on the model and distinguish a missing resource from an inaccessible feature or an unresolved setup.
3. **Propose a job:** suggest orientations, operations, owned tools and candidate vetted workholding together. Explain why each setup is needed.
4. **Resolve setups:** show how stock mounts to the table and how each fixture contacts it. Let the user change a candidate, placement or sequence. Recalculate affected operations and findings.
5. **Verify:** review the ordered operations against the machine, tool assembly, fixtures and stock remaining at each stage. Identify unsupported checks explicitly.
6. **Set up and run:** guide mounting, homing, tool changes, work zero, cutting, inspection and stock flips in their actual order.

Steps 3 and 4 form an iteration loop. An early toolpath is a proposal; workholding and tool-access changes can alter it. A stock flip creates a new setup with its own placement and datum, and carries forward the material removed in the preceding setup.

## Checkpoint 1 — build and validate the desktop machine in Fusion

### Starting assets

Source folder: `/Users/pd/Project/CNC Model/export/Desktop CNC Machine - share`.

| File | Role |
| --- | --- |
| `Desktop CNC Machine.mch` | Existing Fusion machine definition: axes, limits, spindle, attachment frames and linked-model reference. |
| `CNC simplified v31.f3d` | Editable Fusion machine model. |
| `CNC simplified v31.step` | Portable machine geometry for Coastline. |
| `README.md` | Source notes, controller defaults and known limitations. |

This is an existing definition to reconcile and validate. The initial findings and unresolved values are recorded in [Desktop machine profile audit](DESKTOP_MACHINE_PROFILE_AUDIT.md).

### What we will establish

- Correct component hierarchy: a fixed frame; an X-driven table; a Y-driven carriage carrying the Z-driven head and spindle.
- Explicit physical directions. For this model, world +X is up, the table travels along X, the carriage along Y, and the tool points toward world −Z.
- Separate names and transforms for CAD world coordinates, model-pose axis positions, controller machine positions, table mounting coordinates and setup work coordinates.
- Axis home positions, controller travel limits and mechanical limits with their sources. These are different concepts and must not be substituted for one another.
- Correct table and spindle attachment frames, including the tool-length reference plane and direction.
- Table seating surface and both T-slots: usable extents, slot direction, spacing and entry/keep-out regions. Hardware compatibility remains explicit rather than inferred from a fixture's appearance.
- Spindle and tool limits, tool-change behavior, probing and controller/post requirements. Mark uncertain values instead of assigning plausible defaults.
- Collision geometry and deliberately included/excluded component pairs. Review omissions in the simplified model before relying on a collision result.

### Demonstration and acceptance

- [ ] Open the supplied definition and linked model in Fusion; all intended components are assigned to their moving groups.
- [ ] Move each axis independently in simulation. X moves the table correctly; Y carries the Z head; Z moves the spindle head relative to Y.
- [ ] Show home and travel extremes with consistent signs and origins. Record how these correspond to controller positions.
- [ ] Place a clearly asymmetric reference blank/part on the table. Its long direction, seating face and tool approach are correct; resolve the documented 90° placement problem.
- [ ] Show the spindle reference, table surface and two T-slots in the same coordinate system. Confirm scale using known dimensions.
- [ ] Record conflicting spindle/tool/hardware values and resolve those required for the next step. Estimated values remain visibly estimated.
- [ ] Export a reproducible definition/model pair that does not require the original author's cloud link to work in Coastline.
- [x] User reviews and accepts the digital model and its behavior before Coastline integration begins (2026-11-06, Coastline preview).

Start with digital validation. Physical calibration and any machine movement are separate, explicit work with the operator; they are not implied by inspecting these files. Record whether each result has been checked in CAD, in simulation or on hardware.

## Checkpoint 2 — use that machine profile in Coastline

### Profile design

Use three related records so the first mill does not become a hard-coded definition of every machine:

| Record | Responsibility |
| --- | --- |
| **Machine definition** | Stable ID and revision; process capabilities; kinematic tree; axis and spindle limits; model assets; mounting interfaces; compatible controller/post adapters. |
| **Machine instance** | A particular physical machine: selected definition revision, connection, measured calibration, observed controller settings and installed configuration. |
| **Job machine reference** | The definition revision and relevant configuration used to plan and verify that job. Later library edits do not silently change an existing job. |

Fusion owns the authored model and machine kinematics. A proposed Coastline package adds the data not carried by the supplied `.mch`: provenance, controller-to-model mapping, calibration status, mounting interfaces and explicit capability support. Package format and import schema are implementation decisions at this checkpoint, not frozen by this proposal.

Keep source `.mch` and portable geometry together with a versioned manifest. The `.f3d` remains the authoring source; it must not be required to run Coastline. Use package-relative assets and explicit units. Display names and original cloud locations are not stable identifiers.

The selected profile must feed the workspace, digital machine, planning, limits, simulation and posting. Avoid separate copies of the same machine values. Live controller settings can expose a mismatch or narrow allowed motion; they must not silently overwrite the authored machine or enlarge its verified limits.

Represent motion relationships and capabilities explicitly so another machine can be added without editing the first machine's coordinate assumptions. The initial supported behavior is three-axis milling. Future rotary machines, different controllers or other processes need their own supported planning/control behavior; accepting an asset does not imply support for running it.

### Small implementation slices

Review each slice before proceeding to the next:

1. **Install and inspect:** load the accepted package, validate its schema/assets and show identity, revision and unresolved fields.
2. **Display and move digitally:** use the imported hierarchy, transforms and geometry in the existing workspace and digital machine.
3. **Use consistently:** pass the selected profile through planning, simulation, posting and control; persist it with projects and development sessions.

### Demonstration and acceptance

- [ ] Installing the desktop profile produces the correct model, scale, axes, spindle and table without machine-specific code branches.
- [ ] Home, positive jogs and representative positions match the accepted Fusion reference in the digital machine.
- [ ] Existing projects reopen with an explicit legacy machine assignment; no hidden swap to a different profile or loss of setup data.
- [ ] Changing a machine or relevant revision marks dependent planning/verification results stale and requires review.
- [ ] A contrasting test profile, such as a simple vertical three-axis mill, proves that axis directions, hierarchy, spindle direction and table definition are data-driven. It is a software test fixture, not another physically certified machine.
- [ ] Unsupported kinematics/controllers, missing geometry and conflicting critical settings produce specific errors instead of a fallback to the desktop mill.
- [x] User accepts selection, display and digital behavior before library/DFM work begins (2026-11-06: “looks great”; authorized starting libraries). Physical operation requires the corresponding hardware validation record.

## Checkpoint 3 — usable libraries and vetted workholding

### Stock, tools and materials

Provide install/import, inspect, edit and export flows. Preview imported records and units; handle duplicate IDs/revisions explicitly and preserve user edits. Jobs reference the records they used.

- **Stock:** shape, dimensions, quantity and material reference; show the actual blank and any deliberately chosen machining allowance.
- **Tools:** cutting geometry, flute length, shank, holder and stick-out needed for compatibility and reach. Distinguish a tool definition from a particular assembled tool.
- **Materials:** grade and machining properties with sources. Cutting data is associated with the material, tool, strategy and machine; untested combinations remain untested.

### Vetted fixtures

Start with the Bookends and the other fixtures explicitly reviewed for this machine. Name-only inventory entries are not sufficient for automatic selection. Each vetted definition needs mounting compatibility, supported adjustment, contact/locating faces, usable stock range, access limits and a documented setup sequence.

The Bookends sequence must match the user's actual practice:

1. Place stock on the table.
2. Slide the fixed-stop and clamping bookends along the T-slots into contact, then secure their bases.
3. Tighten the pressure screw to seat the material against the locating surfaces.
4. For a subsequent orientation, release the pressure screw and flip the material while keeping the bases mounted, when that setup permits it.
5. Re-seat and secure the stock, then perform the required datum verification for the new setup.

Mounting constrains the fixture to the table/slots. Stock contact constrains its adjustment. Auto-orient and snapping should solve those relationships within permitted travel; a visually close bounding-box placement is insufficient. Bookend bodies and their hardware remain rigid groups; the supported adjustment is represented explicitly.

### Demonstration and acceptance

- [x] Stock, tool and material library slice accepted on 2026-11-06: “everything looks fine”; user authorized beginning interactive workholding.
- [ ] Show fixture models and generic names with descriptions/details available without dominating the list.
- [ ] Migrate exact legacy built-in CR-1 fixture labels while preserving custom names and saved jobs.
- [ ] Place the Bookends on the actual slots, adjust them to an allowed blank and show real contact; explain incompatible placement or stock sizes.
- [ ] Demonstrate the user's slide/tighten/flip sequence without moving the mounted bases unnecessarily.
- [ ] An imported but unvetted fixture is preserved and clearly distinguished from a planner-supported fixture.
- [x] Latest fixture-selection/placement UX accepted by the user: “works good, whats next in our flow now” (recorded for the 2026-11-07 handoff). This covers the direct card-to-workspace flow and machine-selection recovery, not every unchecked demonstration above.
- [ ] User accepts the library and fixture behavior before DFM work begins.

## Checkpoint 4 — DFM grounded in the selected resources

Build three distinct layers: geometry/features and measurements; feasibility against the selected machine/tools/material/stock; and later verification of the proposed operation/setup sequence.

Every finding should identify the affected feature or faces, the measured condition, the relevant resource/rule and an actionable next step. Separate **missing information**, **missing resource**, **setup change needed** and **not achievable with the supported process**. A generic warning should not be presented as a proved machining failure.

### Demonstration and acceptance

- [ ] An exact-size blank is accepted where its original faces can remain untouched.
- [ ] A narrow/deep feature points to the affected geometry and explains which owned tool can or cannot reach it, including shank/holder clearance.
- [ ] A feature requiring another orientation is proposed for setup review rather than assumed machinable by simply flipping the part.
- [ ] Changing a tool, machine or stock updates the relevant finding.
- [ ] Unknown material/rigidity/cutting data remains visible; geometry alone does not prove clamping force or cutting stability.
- [x] User accepts the findings and remedies before automatic job planning changes begin (2026-11-07: “this is good for now. lets start on 5 and 6”). The unchecked demonstrations above remain open.

## Checkpoint 5 — machining proposals and iterative setups

Propose operations, tools, orientations and vetted workholding as a connected plan. Show which surfaces are machined in each setup, why the setup exists and what holds/locates the stock. Offer only supported choices and explain missing resources without silently dropping cuts.

### Demonstration and acceptance

- [ ] One agreed reference part, such as a stepped and pocketed test coupon, produces a reviewable proposal using installed resources.
- [ ] Changing a fixture or permitted placement updates the dependent access checks and machining operations.
- [ ] A multi-setup example preserves the mounted Bookend bases, carries remaining stock forward and shows the new part orientation and work zero.
- [ ] Machining does not remove material required for the current holding arrangement without a supported transition.
- [ ] Unresolved access or holding remains unresolved in the proposal; the UI does not report completion because some operations generated successfully.
- [ ] User accepts the proposed sequence and editing behavior before guided execution changes begin.

## Checkpoint 6 — verification and guided execution

Verify the ordered job against the accepted machine, tools, fixtures and evolving stock. Guide the physical actions in that order, with the actual machine visible. Keep homing and setup readiness discoverable, and reserve stable UI space for status so warnings do not move controls around.

### Demonstration and acceptance

- [ ] Digital playback and guided instructions agree about current stock, fixture position, tool, setup and work zero.
- [ ] Tool/holder/machine/fixture clearance and axis-limit checks use the same accepted profile revision; coverage limitations are stated precisely.
- [ ] Tool changes and flips pause for the appropriate physical action and datum verification.
- [ ] A reviewed air-cut and test coupon establish the physical behavior for this machine before a production job is treated as proven.
- [ ] User accepts the complete workflow before extending to new fixture families or machine capabilities.

## Current next step and progress

**Next (2026-11-07): user review of checkpoint 5.1, then 5.2 setups from the sides.** The paragraphs below record the earlier steps in order.

**Toolpath speed (2026-11-09), awaiting user review.** The user's Inner Core job (2" bar, 30 operations) showed nothing for minutes. Measured on its first roughing request (1/4" tool, four levels): 100 s before.
- The part's outline from above (`PartGeometry.shadow`) unioned every slice from the top again at each level (~9 s a level, holding the interpreter so levels couldn't run in parallel): now built up once going down and kept; 8× faster, the same outline (< 0.001 mm²).
- The roughing solver's accuracy: half the stock left for finishing, at most 0.1 mm (was 0.05).
- The air past the stock is told to the solver as already clear (`cleared_paths`, keep-out rules kept). It swept that air at cutting feed: 16.6 of 86.7 m of path with the tool wholly outside the bar. Now 61 m and 53 k moves (was 120 k); every material point checked is still cut.
- Result: that request 100 s → 27 s; the engine tests 2:45 → 1:33.
- "Use This Plan" starts building at once (a build of an older plan is stopped first).
- Three engines stay: three roughing requests at once took 73 s, one alone 50 s (a request has few levels and the slowest sets its time).
- Tried and dropped: limiting the solver's lead moves to a box around them (same paths, 6× slower, cause not found); trimming the band at the stock edge (shorter path, slower solving).
- Not done: simple passes for open areas. On this part there are none: the band around the part has the frame on its outer side, so it is a channel the solver must work. A faster solver for channels is the remaining big gain.
- Follow-up (2026-11-10): the upper and lower side setups' small-tool roughing (1/8" after 1/4") failed with `map::at: key not found`. Cause: in the solver's rest-roughing step (`Adaptive.cpp` 5e), a vertex of the input path can come back twice from the intersection, and the second copy was then looked up as a new point. Fixed in the vendored solver: duplicates are removed, clip vertices are tagged so the input edge is known. Both requests now finish.
- Side cavity roughing skips pieces narrower than `min_pocket` (as top-side roughing does), so the rest roughing's "what the larger tool skipped" matches what that tool cut.
- A region with straight walls is the same at every level. It is now solved once and reused at each level (regions within 0.01 mm match; their round ends come from different facets each level). Threads skip regions another thread is solving. The arc fit of a reused result is also reused. Applies to side cavities and top-side pockets.
- The toolpath writer's duplicate-point check used `np.allclose` for every point (a third of a long pass's time): written out, same rule.
- Result on the Inner Core side small-tool roughing: 341 s → 36 s (192 solves → 9). Engine tests 112 passed (one new test for the reuse).

**Bloat removal (2026-11-10), awaiting user review.** The user asked for the app to hold only what the fixture-library flow needs (STEP → stock → setups and workholding → toolpaths → review → run → journal). A local checkpoint commit was made first. Removed, with the user's choice for each:
- Side features: the printable nest (engine `cam/nest.py`, Nest sheet), the feed tuner and cost model, the simulated-vs-CAD deviation readout and its `height_field` engine call, the first-cut checklist, the app tour, the example parts (`resources/examples`) and the welcome/start sheets. The old text-only `Feasibility` check (only its drill-size list was still used; it is now `DFM.standardSizes`). Dead controls and functions the heuristic found.
- Other job formats: `.dd`/`.crproj` package import, job-from-your-own-G-code, shared `.zip` import/export, the guided `.crproj` export for the maker's sender, the `jobtool` command line, and MillCore's `.crproj` reader/writer (`ProjectWriter`, `ProjectArchive`, `YAMLSubset`) with the sender's `GuidedNavigator`. Kept: "Run on Machine…" (the native runner: `GuidedJobBuilder` → `GeneratedJob.writeNative` → `ProgramJob` → `JobRunner`), with MillCore's `Job`/`Step` model it builds. MillCore no longer depends on ZIPFoundation.
- The clamp-kit workholding system: the hand-modelled kit (`UniversalClamp`, `fixture_kit.py`, `clamp_kit.npz`), its holding modes (clamp kit, bed only, prep-then-kit, shoulders), stock squaring (`FlatPrep`, `Prep`, `PrepVisual`), the bed and kit editors, grip zones, batching (copies), the kit's electrical probing (`clampKitProbing`), the mill-down and squaring jobs in the guided job, and the kit's clearance field. `Setup` keeps only the fixture-library and custom-fixture fields (older files with kit fields still open). The stages are Part → Stock → Setups → Plan → Toolpaths → Review. `StockOrientation` is a plain fit check. The table geometry comes from `MachineTable` (machine model or profile).
- Size: app 26.8k → 21.6k lines of Swift, core 15.6k → 13.5k, MillCore library 7.7k → 6.7k, engine 6.3k → 5.8k Python, tests 5.8k → 5.0k. Python stays: the CAD kernel (OpenCASCADE), the roughing solver, OpenCamLib and the feature recogniser are C++/Rust with Python bindings and no Swift ones.
- Checks: engine 111 passed; core 213 passed; MillCore 90 passed; the app builds and launches. The whole Inner Core job (2" bar, Bookends) generates all 34 toolpaths with none failing (about 5 min), then the library workholding check rejects Bookends for every cut: with the bar on the table (Bookends height 0) the tool tip reaches only to 3.6 mm above the bar's bottom edge (machine X −86 limit; the stock centre sits at X −64.2), and side A's outline roughing goes 8 mm below the bar; the side setups cut 48.8 mm deep where a 28.6 mm stick-out reaches 44.8 mm (Z −78.5 limit). The travel check's stick-out sign was fixed on 2026-11-09 (the spindle sits higher by the stick-out). Open: the plan must keep each setup's cuts within reach (leave the bar's bottom edge to the lower-side setup, or raise the stock on parallels), or say so plainly.
- Not done: docs for removed features (FIRST_CUT.md, parts of WORKHOLDING_ASSEMBLIES.md) still describe them.

**Earlier next step: the first resource-aware DFM slice (checkpoint 4).** The user accepted the latest fixture-selection/placement flow with “works good, whats next in our flow now”. The next proposed slice is stock fit with valid zero allowance, tool access/reach findings tied to the affected geometry, and concise remedies in the existing workspace. Audit the existing analysis and feasibility code before designing that slice. DFM implementation has not begun in this handoff; complete and review one slice before advancing to iterative job planning. Unchecked demonstrations above remain open; this acceptance does not establish physical calibration, a complete multi-setup flip demonstration or an unperformed Fusion CAM simulation.

**DFM audit (2026-11-07, no code changed).** Existing pieces: bounding-box stock containment that accepts zero allowance (`SetupChecks`), owned stock that fits in any orientation, exact hole and floor detection along the tool axis, part-level corner/concave/back-face/thin-wall measurements, plan-level flute-reach comparison in `StrategyEngine`, and shank, collet-nut and fixture clearance checks that run only on generated toolpaths. Gaps: `Feasibility.assess` returns unstructured text, appears only in the legacy clamp-kit inspector, compares whole-part depth with flute length, counts holes as inside corners, suggests scaling the part and claims the planner flips the part for any back-facing face. Tools excluded for a missing collet, unconfirmed specifications or the machine length limit are dropped silently. The cached `features` result is not invalidated after reorientation. Proposed first slice, awaiting review: structured findings from the existing analysis calls (stock faces kept as supplied; per-feature tool reach including shank and collet-nut clearance; line-of-sight access from the current side, the opposite side and other axis directions), shown in Plan and highlighted in the workspace, then reviewed on a generated reference coupon with known answers.

**DFM slice 1 implemented (2026-11-07), awaiting user review.** Plan has a compact **Machinability** section (also in the legacy clamp-kit inspector). One row per finding, grouped as can't be machined, missing tool or stock, needs info, setup change and OK (collapsed). Clicking a row highlights its faces in the workspace and frames them; remedies are explicit (use owned stock, show tool, add collet, review setups; a needed stick-out is stated, never applied). Findings recalculate when the part orientation, stock, tools or machine change.
- Stock fit: part vs stock per side; faces on a zero-allowance stock face are listed as kept as supplied. No scaling suggestions remain.
- Tool reach per floor, hole and outside profile, using owned tools only: cutter vs opening, shank wider than the cutter, flute length vs wall (shank rub), collet-nut clearance as a required stick-out (overall length minus 10 mm grip), the machine's shank and length limits and missing collets. Owned tools the planner cannot use are listed with the reason.
- Access: line of sight from the six axis directions for every face. Faces needing the back side or another position are setup changes for review; faces with no straight path are not supported. The old "the planner flips the part" claim is gone.
- Engine: `analyse(access: true)` returns per-face access, regions, floors, holes, holder depth and highlight triangles; holes no longer count as inside corners or concave curves. The cached `features` result is keyed by part and orientation.
- Reference part: `resources/samples/dfm_coupon.step` (from `scripts/make-dfm-coupon.py`), 203.2 × 50.8 × 50.8 mm, seven features with known answers.
- Tests: engine 102 passed; Swift DFM 13, DFMEngine 4 (real engine RPC on the coupon with the user's tools and the r2 profile), Feasibility 9, Guided 7, Setup 24, Engine 16, CAM 16, LibraryWorkholding 21, BookendSetup 8, MachineDefinition 12, MachinePlanningGeometry 8, all passed; app debug build passed. Analysis with access on the user's `inner core` part: 3.9 s (2.6 s before).
- Limits: only the six axis directions are tested (angled access reads as "none"); reach uses the finished part only, not remaining stock or fixtures; the ER-11 nut size is a Coastline constant; cutting force, rigidity and clamping are not checked. On-screen layout has not been reviewed yet.

**DFM slice 1 revised after user review (2026-11-07).** User feedback: the list alone was "useless"; problems must be shown on the part with clear explanations (Fabworks/ToolDance style), workholding belongs in Setups, and Plan is where the problem check and toolpaths live. Implemented:
- Step order is now Part → Stock → **Setups** (workholding, orientation, placement, work zero) → **Plan** (Machinability and toolpaths, then the proposed setups to review) → Toolpaths → Review. **Use Workholding** returns to Setups.
- In Plan every problem's faces are coloured on the part at once (red can't be machined, amber missing tool or stock, blue setup change, grey needs info), with a numbered pin per place and a legend that can hide them. Clicking a pin or row opens a card beside the pin: title, measurement, what is wrong, what to do, ways forward and details. The selected problem is also drawn over everything, so back and inside faces show where they are.
- Findings have separate measurement and fix lines. The same finding in several places is merged into one numbered item with a pin per place. A thin-wall reading below 0.1 mm (the measuring limit) is no longer shown.
- Checks: core DFM 9 and DFMEngine 4, Feasibility 9, Guided 7 and Setup 24 tests passed; app debug build passed. On-screen behaviour has not been reviewed by the user yet.

**DFM accuracy fixes (2026-11-07), after the user said the result on `inner core` "seems wrong".** A headless run on that part (Desktop CNC r2, 203.2 × 50.8 × 50.8 block, both sides) showed one "No straight path" region of 95 faces over most of the part: regions joined every touching hidden face and took the worst access, so the thread's blocked crests turned the windows and bore round them red. Fixed:
- Engine regions join faces only with the same access and, for side access, the same nearest open side; faces no single side sees form their own groups. Each region now reports the sides a tool must come from (front first; with both sides machined, the back next; every other sample from its nearest side), with the share and depth from each, measured on the surface.
- A blocked region that is a bore round one main axis (coaxial cylinders of more than one radius, or helical faces) is a **thread**: its diameters, length and the open end it is cut from. The finding checks owned thread mills and names the setup; the pitch is not read.
- Side and back regions are now reach-checked like floors and holes (opening from the region's cross-section, wall depth and collet-nut stick-out from that side), so a long bore reached only from an end is "Too deep" when no tool the machine holds reaches it. Pieces of one bore seen through several windows are one item, judged at the deepest piece.
- With both sides machined, the outside profile is cut to the split from each side (deeper half + 0.3 mm), not the whole depth.
- Floors are named by how much of their edge has a wall (engine `enclosed`): pocket or slot when closed, open slot/pocket, or step. The top of `inner core` was called a slot; it is a step.
- Result on `inner core`: 16 findings instead of 7 misleading ones. Can't be machined: the ⌀10 bore along the part (123 mm from the left end, 5 places). Missing tool: an 18 mm thread at the right end (no thread mill), the end-face holes and deeper pockets (owned end mills reach but shanks rub). Setup changes: windows on both long sides and the walls between them.
- Tests: Swift 236 passed, 2 skipped (DFM 14, including new side-reach, thread, grouped-bore, floor-name and two-sided-profile cases; DFMEngine 4); engine 104 passed (new: hidden groove beside a bore, thread by shape, floor wall share). App debug build passed.
- Limits: depth is the deepest sample from that side, and the opening is the region's narrower cross-section (approximate for odd shapes); the cover is per sample, not a minimum set of setups; thread detection needs the thread modelled; side-setup holding is not checked.

**Tools to buy and feature names (2026-11-07).** User direction: "on the missing tooling, id like for coastline to suggest the tools so in the end the ones im missing can be bought and added to my library. not having a tool shouldnt stop me, as long as it fits the machine"; quiddity accepted "if it helps".
- A missing-tool finding names one tool to buy: a library tool to buy (Coastline's catalogue or one added earlier) that reaches cleanly, else a tool Coastline specifies for that cut: the largest common cutter through the opening, on a shank the user has a collet for, flutes or a reduced neck to the depth, and a common overall length that holds the stick-out with the 10 mm grip within the machine's limit. Threads get a single-profile thread mill. The card's **Add to buy** adds it to the library with quantity 0 (a Coastline suggestion), so the existing plans "with tools to buy" can use it and it shows on the job's shopping list; once added, the card says **Buy**. Only cuts no tool that fits the machine can reach (for example the `inner core` bore, 123 mm from the end) stay "can't be machined".
- Feature names: quiddity 0.4.9 (Apache-2.0, pinned in the engine) names holes, slots, pockets and chamfers with sizes. Its face numbers equal the engine's (checked: 34/34 on the coupon, 108/108 on `inner core`). The app runs it once per file on a separate engine process in the background and caches the result in `~/Library/Caches/Coastline/Features`; it takes 0.3 s on the coupon and about 50 s on `inner core`, so findings first show without names. A side or back region takes a name only when the feature is mostly inside it and covers at least a third of its faces, as "Slot 16.89 x 31 mm: cut from the upper side". The check itself does not depend on it. quiddity refuses the `inner core` thread; Coastline's own thread detection names it.
- Tests: Swift 238 passed, 2 skipped (DFM 16: specified tools within the machine's limits and collets, add then buy, thread mill, naming rules; DFMEngine 5 including quiddity on the coupon through the engine); engine 107 passed (recognition: coupon names, unreadable file, labels). App debug build passed.
- Limits: a specified tool is a size to look for, not a catalogue part; reduced-neck and long tools may not exist at every size; slender ones carry a warning. Planning with tools to buy is the existing behaviour; it has not been reviewed on screen for these added tools.

**Checkpoint 5 started (2026-11-07).** User: “this is good for now. lets start on 5 and 6”. Audit of the existing planning: **Build Toolpaths** already compares plans (StrategyEngine), generates both sides (A from the front, B turned over), assigns cuts to library fixtures with stock carried across the flip, checks fixture clearance and grip patches, and hands the steps to the guided runner. Gaps against the checkpoint list: the plan only machines the front and the back, so features the part check sends to a side (windows, end holes, the thread on `inner core`) were silently left out while Plan and Toolpaths still read “done”; the one-click proposal used owned tools only, against the user's “not having a tool shouldnt stop me”; and nothing stopped running a job that uses a tool still to buy. Proposed order: 5.1 coverage (below), 5.2 setups from the sides (orientation per setup, cuts limited to the features that need it, stock carried forward, Bookends re-seated), then checkpoint 6 (leftover-material check on the simulated stock, one verification list with what is not checked, guided run gates).

**Checkpoint 5.1: what the plan cuts (2026-11-07), awaiting user review.**
- Each part-check finding now records the sides its cut comes from. Plan has a **What the plan cuts** section after a plan is built: one row per side (A from the front, B from the back) listing the features it cuts; clicking a row lights those faces green on the part. Features no setup in the plan cuts are listed under it with the reason: can't be machined, needs a setup from a named side (the back: turn on Machine both sides), or needs a tool the plan doesn't use. Clicking one selects its finding on the part.
- Plan and Toolpaths show “needs attention” with the count while any feature is not in the plan; a plan with some generated toolpaths no longer reads as complete.
- **Build Toolpaths** may now choose a plan with tools to buy (fits the machine and your collets); the proposal says how many. **Use This Plan** is enabled for those plans. Export, Export Selected Code and Run on Machine stop with the tool names until each is marked as owned in Tools.
- On `inner core` (both sides): side A cuts the top step; 15 features are listed as not in the plan, most needing a setup from the upper, lower, left or right side.
- Tests: Swift 239 passed, 2 skipped (DFM 17, new: coverage on the coupon with one side, a tool to buy in the plan, and both sides). App debug build passed.
- Limits: coverage comes from the part check (line of sight and reach), not from the simulated stock; a feature counts as cut with a tool to buy only when the plan uses that exact tool. Side setups are not planned yet (5.2).

**Checkpoint 5.2/5.3: the part turned and cut from every side (2026-11-09), awaiting user review.** User: “it needs to be able to turn the part for me and cut all sides, for real auto setup it needs to be able to do this and plan a whole job for me. it basically needs as little input from me as possible”.

- Turns: the part check's proposed sides (`PlanCoverage.propose`, all six considered) become setups. Upper/lower side and the ends (`SetupSide` 2…5) are side A's setup turned a quarter about Y or X with the part kept where it is in the stock (`Setup.forSide`; exact quarter-turn rotations, part placement checked against side A's frame in `SetupSideTests`). The back stays side B.
- What a side setup cuts (`SideCuts`): only the features the part check sends to that side, inside a window around their faces (one roughing radius + 1 mm); roughing only that side's own cavities (`side_cavity`: what lies inside the part's outline seen from that side but isn't part just under its face, so pockets, holes and steps open to the edge), leaving nothing on their walls. (2026-11-09: the first version roughed the strip of stock around the whole outline at every level, about 30 s per level, and hung the app's build for 15+ minutes; now 2–3 s, `test_roughing_from_a_side_clears_its_step_and_leaves_the_rest`.) floors, drilling, boring and threads with the plan's own tools, holes and floors outside the window skipped by the engine (`window`). No facing, contour or 3D finishing from a side, so the other setups' grip faces stay whole.
- Order at the machine: the side setups first, on the whole block, then side A and side B. Programs, the job strip and the guided job follow it ("Turn: upper side to the spindle", "Turn: front to the spindle").
- Workholding: automatic workholding fits each fixture to the stock as it lies in every setup (`prepareLibraryFixtures(turned:)`); the planner takes per cut only the fixtures fitted that way round. Removed material is carried through the whole job on three dexel grids (columns along side A's X, Y and Z), so a hole from a side counts against a later setup's grip patches (`aCutFromTheUpperSideCountsAgainstTheNextSetupsGrip`). A turned setup gets no credit for cleared air: its fixture must stay out of the block.
- Limits: only with automatic library workholding (not the clamp kit, stock prep, shoulders or copies); a side setup needs an owned fixture that fits the turned block (the vise 20.5–46.6 mm, C-clamps, Bookends), otherwise the plan reports which cut has no workholding. The preview simulation shows each turned setup on a fresh block, not the stock left by the others. Not yet run in the app on a real part.

**Direction for checkpoint 5 (user, 2026-11-07).** “this app will allow a user, with little cam knowledge, to load in their step model. have a libray assortment of tools and workholding, and be able to 0-100 a plan to get it cammed in the machine, just as easy as 3d printing is”. Coastline should turn the stock as needed (for example 90° onto a side), choose and place workholding from the library for each setup and make the setups itself. Revised order: **5.2** automatic turns (the fewest that reach every feature, each checked to fit the machine: part length toward the spindle, tool length, travel), CAM per setup for only what it needs, stock carried forward; **5.3** automatic workholding per setup from the library, placed on the stock left at that point, grip and clearance checked, another turn or fixture tried on failure; **5.4** one action from part to reviewed job. The user is asked only for real choices (buy a tool, accept an open feature).

Review notes (2026-11-07, `inner core`): the ⌀10 bore along the part is reached from both ends in the check (56.5 mm from the right, its deepest place 123 mm from the left); the machine takes tools up to 75 mm long (about 65 mm past the collet), so turning the part does not make it reachable. The part check names end setups (“left/right side toward the spindle”) without checking that a 203 mm part fits the machine that way: fixed in 5.2. Only the Bookends have a complete assembled definition for automatic holding; the Universal Clamp has no assembly, Quick Release needs an assembled model, the C-clamps have no model.

**Checkpoint 5.2, first part: all six sides (2026-11-07), awaiting user review.** User: “the material i chose has 6 sides, so it always needs to take into account all sides to a part”.
- Plan's **Setups** section (after Machinability) proposes the fewest setups that cut the most features, every one of the six sides considered; each setup is “Setup N: <side> toward the spindle” with what it cuts, and clicking it lights those faces. **Other sides** (collapsed) lists every unused side with the reason: doesn't fit the machine (with the depth and the table's), nothing needs it, or its features can't be made from there.
- Machine room: on this horizontal mill the stock lies on the table with its face at the front edge, so the depth toward the spindle must fit the table (74.9 mm on the Desktop CNC r2, from the machine model's seating surface). The part check now marks cuts from a side that doesn't fit as can't be machined, with the depths, instead of “add a setup with that side toward the spindle”. A proposed back setup turns on Machine both sides unless the user chose.
- On `inner core`: setups from the front, back, upper and lower sides; the ends don't fit (203.2 mm deep, table 74.9 mm), so the end holes, the thread and the bore are can't be machined on this machine. The upper and lower setups show “Coastline can't make toolpaths from this side yet”: their 6 features are counted as not in the toolpaths.
- Tests: Swift 240 passed, 2 skipped (new: six sides with room on the coupon). App debug build passed.
- Limits: only the table depth is checked (not height, travel or collisions of the turned stock); the blank's size is used for every setup, not the stock left by earlier setups. Next (5.2, second part): toolpaths for the side setups, limited to their features, with the stock carried forward.

**`inner core` review (2026-11-07).** User: “what if we milled one long side halfway, then flipped it to the other long side to cut the other half”. Measured from the STEP: a 51 × 51 mm bar, 170.8 mm long (in 203.2 mm stock), six baffles with ⌀10 holes along its length (11.5 mm long, 20 mm apart, from 40 to 151 mm), chambers opening to the upper and lower long sides, a modelled 1/2" thread stub at one end, a ⌀20 counterbore and four ⌀5.12 holes at the other.
- Splitting the depth between opposite long sides suits the chambers and the outside: each half is cut from its own side and they meet in the middle (the part check's “cut from 2 sides”). That is the plan for the upper and lower setups (5.2, second part).
- It does not make the round baffle holes: from a long side the tool is across the hole's axis, so it would cut a 10 mm slot through each baffle. They need a tool along the bar, from an end: that turn doesn't fit the 74.9 mm table, and the deepest holes are 83 mm (from one end) and 76.5 mm (from the other) in, past the reach of a 75 mm tool.
- **Engine fix, found on this part:** OCCT's mesher left the thread's helical B-spline flanks with triangles across whole turns (up to 3.7 mm off the surface), which put material across the bore at the threaded end. The part check then measured every baffle hole from the far end (123 mm instead of 83), and toolpaths, which use the same mesh, would have treated that end of the bore as solid. Import now checks free-form faces for triangles more than 0.05 mm off their surface and meshes such untrimmed faces again as a UV grid within the deflection (`cad_import._off_surface`, `_grid`). The thread's crests then read as seen from the end while its flanks stay blocked, so a blocked free-form region is joined with the regions it touches within its length and width when together they make a thread.
- Tests: engine 108 passed (new: a 20-turn thread flank found off its surface and meshed again); Swift 240 passed, 2 skipped. `inner core` import: 1.2 s, 24,771 triangles (36,908 before), no triangle across the bore.
- Limit: a trimmed free-form face that meshes badly is kept as meshed (only untrimmed faces are meshed again).

**Fit check from the machine model (2026-11-08).** User: “yes fix the fit check, thats how most things on this machine are cut since the table is so small” (stock hanging past the table). The first rule (stock no deeper than the 74.9 mm table) was too strict.
- `MachinePlanningGeometry.roomBehindTable` measures how far stock may hang past the table's far edge (away from the spindle) before it meets any other machine part, each component swept over its motion relative to the table across the whole travel (triangle bounds, 1 mm clearance). On the Desktop CNC r2: 57 mm with the enclosure (its panel stops any size of stock), unlimited without it.
- `SetupRoom` now holds the table depth and, per side, the room behind it with and without the enclosure: a turn fits, fits only with the enclosure open (stated on the setup row and in the finding's details), or doesn't fit (the part check marks those cuts can't be machined, with the depths). The app measures it per machine, stock size and travel centre, cached.
- On `inner core` all six sides are now proposed: front, back, upper and lower sides, and both ends with the enclosure open (203.2 mm deep, 128.3 mm past the table). The ends carry the thread, the ⌀5.12 holes and the outer bore pieces. The two middle baffle holes (76.5 and 83 mm from the nearer end) stay can't be machined: no tool reaches.
- Tool reach along the spindle: the spindle moves 78.5 mm in Z, and a tool must start clear of the stock face, so no hole along the spindle can be deeper than about 76 mm (2 mm clearance) on this machine, whatever the tool's length. 83 mm is past it; 76.5 mm would need about an 80 mm stick-out (12.6× a 1/4" tool) and a tool longer than the 75 mm profile limit.
- Tests: Swift 240 passed, 2 skipped (DFM: fit, enclosure-open and no-fit cases, setup notes; Engine: the real machine's room behind the table with and without the enclosure). App debug build passed.
- Limits: the stock is taken as centred at the travel centre and seated at the table's spindle-side edge; only the enclosure is optional; cutting forces on a long overhang are not judged.

**Workholding set up from the Fusion model, and chosen automatically (2026-11-08).** User: “workholding, im still having to manually select … lets go through them and do proper setups for all”, then “only put in 1,2, and the quick release jig. the others are WIP” (the C-clamps, the 2" vise and the Quick Release Jig Plate; the grid plate and blank carrier are still being designed).
- Source: the user's Fusion machine file (`CNC v4`/`v5`, `04 X Table/Fixtures`), placed on the X table. Each fixture was copied into a scratch Fusion document (hidden parts don't export), exported to STEP and flattened to one solid per part in machine coordinates (`resources/fixtures/{c-clamps,vise}/assembly.step`, `quick-release/assembly.step`; part list and bounds in each `evidence.json`). The user's document was not changed.
- **C-clamps (pair):** frame slides along the table edge; screw, pad and handle advance on a screw joint (2.54 mm pitch assumed: it only turns the handle in the preview). Measured: pad ⌀22.2 at 25.4 mm behind the stock face; opening 76.2 mm from the anvil, so stock up to 61.6 mm tall; needs stock ≥ 36.5 mm deep and ≥ 55.4 mm long for two clamps. Fit: stock on the table, face at the table edge, a clamp 20 mm in from each end, both pads tightened onto the top. Contacts: each pad and the table under it.
- **2" vise:** body bolted to the upper T-slot (three M4 nuts); the jaw, lead screw and knob move together (M8, 1.25 mm). The model holds 20.5–46.6 mm: closed further, its knob meets the washer; the sizes are round numbers, so it is a stand-in until the real vise is measured. Fit: stock on the vise floor (12 mm above the table) against the fixed jaw, two-thirds of its depth in the jaws, the rest past them toward the spindle; the nuts must stay in the slot.
- **Quick Release Jig Plate:** the assembled model replaces the exploded one (planning no longer blocked by it). It holds nests on its shoulder pins, not stock, so it isn't chosen automatically until a nest exists. Seen in the model: the four screws to the table reach about 0.2 mm into the nut space and no T-slot nuts are modelled.
- **Automatic choice:** with no fixture placed by hand, Coastline fits every owned fixture with a reviewed mechanism (bookends, C-clamps, vise) to the job's stock (`FixtureMechanism.automatic`) and the planner picks one for each cut. Setups lists each fixture with “Fits this stock” or why not; clicking one still places it by hand, and **Choose Automatically** returns. Grip of an automatic fit counts as reviewed (its contacts come from the mechanism); each setup is still reviewed before export. Vise and C-clamps allow roughing; the bookends keep the library setting.
- Library: the 3" C-clamp entry (quantity 2, no model) gets the reviewed pair, the exploded jig plate gets the assembled model (`VettedFixtureLibrary.migrate`), and a 2" mini vise entry was added to this user's library.
- Tests: Swift 245 passed, 2 skipped (new: models match their definitions and bind by checksum; C-clamp and vise fits, ranges and refusals; automatic fits pass the planner's eligibility and repeat exactly; library migration). Engine 108 passed; the three models load through the engine's assembly loader. App debug build passed.
- Fixes after the user's first look: the fixture list refreshes when the machine finishes loading; jobs saved with the old built-in machine (“Legacy Desktop CNC”, no measured T-slots) now open on the installed Desktop CNC profile instead (user: “there is no LEGACY”).
- T-slot nuts: the user's are Fairway JPPNM04016 (M4); no McMaster equivalent fits (5278N51, checked through the McMaster API: its 2.55 mm boss would stand 0.5 mm proud of the 2 mm lip). Modelled from the listed size and a photo (`resources/fixtures/hardware/`, estimates marked) and put in the vise (revision 2; libraries holding revision 1 are rebound).
- All fixture hardware is M4 (2026-11-09), changed in the user's Fusion machine file first: the M4 nut, M4 screws (ISO sizes) and washers in the Bookends, vise and Grid Plate; 4.5 mm mounting holes; M4 tapped holes (Bookends side screw, vise, Grid Plate grid). Bookends revision 2 and vise revision 3 are exported from that file; libraries are rebound on load and the fits are redone. Not changed: the machine's own M5 screws, the Quick Release jig plate (M5 tapped grid and shoulder bolts), the Grid Plate countersinks and the vise counterbores (still M5 size).
- Limits: fixtures stay in their modelled orientation (no turning a clamp or vise); the C-clamps don't check the machine below the table beyond the planner's collision check; the clamp pitch and vise sizes are not measured.

The accepted fixture flow opens a card directly in the workspace, fits Bookends to measured slots and stock contacts, exposes the side screw, and collapses optional placement controls. **Use Workholding** saves a job-specific fixture snapshot and returns to Plan with the fixture visible. Explicit fixture selections constrain planner candidates without changing library defaults. An older job's legacy machine assignment can be replaced through an inline explicit action; merely browsing another machine never changes a saved job's assignment.

The selected profile now supplies workspace geometry, table dimensions, relative motion, CAM limits, tool selection, timing and post output. Projects pin the full profile snapshot and asset fingerprints; old projects retain an explicit legacy assignment. Changing a machine invalidates dependent results. Physical control remains isolated. Engineering validation stays in package records and documentation rather than a user-facing Validation tab. See [Machine profiles](MACHINE_PROFILES.md).

The first library slice adds portable stock/tool/material import previews and export, editable custom materials, explicit duplicate and quantity choices, and saved-job resource snapshots. Stock and material are now one user-facing library: material and cutting properties live with the stock, without a separate Materials page or tab. See [Resource libraries](RESOURCE_LIBRARIES.md).

The workholding slice binds exact reviewed CAD to explicit components and joints. Bookend bases carry their mounting hardware along the actual slots; the side screw advances and rotates independently. Seating uses the stock contact faces and locating lip. Jobs retain their fixture state, and display and clearance checks share those transforms. A copied Quick Release asset removes its reference X table, but remains display-only because the source is an exploded view. See [Workholding assemblies](WORKHOLDING_ASSEMBLIES.md). CAD contact and a digital lock do not establish physical clamping force or cutting suitability.

Latest fixture-flow verification: app debug build passed; 63 focused Core tests passed with no failures or skips (LibraryWorkholding 21, MachinePlanningGeometry 8, Setup 11, BookendSetup 8, VettedFixtureAssembly 7, PlanningMachineReference 8). This is the last recorded result, not a substitute for testing subsequent changes. No native-app automation was used for this slice.

| Checkpoint | Status |
| --- | --- |
| 1. Machine definition/model | Digital model and motion accepted through Coastline on 2026-11-06. Fusion CAM setup simulation and physical calibration remain unverified. |
| 2. Coastline machine integration | Planning selection, workspace geometry/motion, CAM propagation and project pinning accepted on 2026-11-06. Live control migration remains separate. |
| 3a. Stock, tools and materials | Import/export, material editing and resource snapshots accepted on 2026-11-06. |
| 3b. Vetted fixtures | Latest selection/placement UX accepted by the user; unchecked detailed demonstrations remain open. Bookend joints, slot mounting, contact seating and job snapshots implemented. 2026-11-08: C-clamp pair and 2\" vise fitted from the user's Fusion model, assembled Quick Release model; automatic fixture choice. Awaiting review. |
| 4. DFM | Slice 1 implemented, then revised on 2026-11-07 after user feedback: problems marked on the part with pins and cards; Setups now before Plan; region grouping, side reach, threads and floor names corrected the same day; tools to buy specified to fit the machine; quiddity feature names. Accepted by the user on 2026-11-07 (“this is good for now”); limits in the entries above remain. |
| 5. Iterative job planning | Started 2026-11-07. 5.1 (what the plan cuts, plans with tools to buy, run gate on unowned tools) implemented, awaiting review. 2026-11-09: setups from the other four sides with toolpaths (5.2) and automatic workholding per setup (5.3) implemented, not yet tried in the app; awaiting review. Next: 5.4 one action from part to job. |
| 6. Verification and guided execution | Proposed. |

Record acceptance date, demonstrated behavior and remaining limitations here as each checkpoint is completed. Do not use this roadmap as permission to implement later phases ahead of the user's review.
