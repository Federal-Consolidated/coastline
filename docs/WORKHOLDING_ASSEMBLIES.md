# Workholding assemblies

Checkpoint 3b starts with the reviewed Bookends model. Its mechanical definition identifies real CAD components, their mounting relationships and permitted motion. An imported STEP file does not acquire mechanical behavior from its name or from proximity between solids.

## Review in Coastline

1. In **Setups**, click the Bookends card. The existing workspace previews them around the selected stock, on the job's machine. Accessories such as loose nuts and risers are kept out of this primary fixture list.
2. The Bookends automatically fit the blank's end faces and locating lip, using the machine's measured T-slots. Both digital base positions are locked after fitting. This preserves the arrangement while adjusting the screw; it does not assert that physical hardware is tightened.
3. **Side screw** controls are immediately visible. The slider and minus/plus buttons retract or advance it; each button step is a quarter turn. **Release** retracts it, and **Tighten to Stock** advances as far as contact or its available stroke permits. The contact/gap readout shows whether it reached the stock.
4. Optional changes live under **Adjust placement**. Unlock a base to slide it along the slots, then relock it; its bolts, washers and T-slot nuts move with it. **Refit to Stock** restores the fitted arrangement and clears grip review.
5. Review roughing suitability and the grip/cutting load, then press **Use Workholding**. This returns to Setups with the fixture visible. The job keeps its assembly and joint positions without changing library defaults. CAM considers the fixtures explicitly selected for this job; remove a selection through its card's context menu. Older jobs without an explicit selection list retain their previous automatic candidate behavior.

The placement header shows the actual job machine and stock. Browsing a machine profile does not change an older job's saved assignment. If that job still uses a legacy definition without measured slots, an inline **Use [machine] for This Job** action applies the inspected profile and refits the Bookends. The machine picker also works during placement. Failed loads preserve the previous machine; changing machines requires a fresh grip review.

Releasing the pressure screw leaves the base locks and mounting positions intact. A later stock flip can therefore retain the bases, as in the user's physical workflow. Re-seat the stock, advance the screw and verify the datum for the new setup. This slice does not simulate hand-operated stock removal, torque, thread elasticity or clamping force.

## Bookend components and motion

The source assembly contains 15 physical solids: two bodies, four mounting screws, four washers, four T-slot nuts and one side pressure screw. The T-slot nuts are actual mounting hardware and are retained.

| Component | Motion | Attached hardware |
| --- | --- | --- |
| Fixed base | Slides along the table slots | Two mounting screws, washers and T-slot nuts |
| Clamp base | Slides along the table slots | Two mounting screws, washers and T-slot nuts |
| Side pressure screw | Advances and rotates about its own axis; follows the clamp base | Independent screw child component |

The screw uses the modeled M4×0.7 pitch and a 0–15 mm geometric stroke; the authored pose has 4 mm extension. Advancing stops at stock contact, even if more stroke remains. Base travel is constrained by the selected machine's common slot endpoints and the complete nut footprints. Placement rejects mismatched slot spacing, unsupported orientation, stock penetration and a stock end face too small for the pressure tip. Stock depth is located against the actual rear lip, rather than centered on the screw axis.

Both bases must be locked and both end contacts seated before the grip review can be accepted for planning. These are digital setup conditions; the separate grip/load review remains necessary. Screw threads and mating bores are simplified CAD surfaces, not a contact-force model.

## Source cleanup

Original source files are unchanged. Reviewed copies and evidence live under `resources/fixtures`.

- [Bookends](../resources/fixtures/bookends/README.md): exact original assembly, with explicit entity-to-component assignments and a mechanical definition. No physical hardware removed.
- [Quick Release Jig Plate](../resources/fixtures/quick-release/README.md): the first copy was an exploded view. Since 2026-11-08 `quick-release/assembly.step` is the assembled model from the user's Fusion machine file (34 solids, one component). It holds nests on its pins, so it is not chosen automatically until a nest is modelled.
- C-clamps (`c-clamps/`) and the 2" vise (`vise/`): exported from the user's Fusion machine file, one solid per part in machine coordinates. Their definitions carry a `clampPair` or `vise` section that fits them to any stock that fits (`FixtureMechanism.swift`).
- Universal Clamp: the available STEP is a single body; no independent screw or jaw is invented.
- The single 3" C-clamp file (`c_clamp.step`) is superseded by the reviewed pair.

Exact source fingerprints identify the known assets; user names and fixture IDs are preserved. The exact legacy built-in name `CR-1 Universal Clamp` becomes `Universal Clamp`. Custom names are unchanged. Rebinding the reviewed assets clears old free-piece transforms and grip approval because their former placement does not establish the new mechanical state.

## Implementation and verification

`FixtureAssemblyDefinition` records source SHA-256, exact STEP entity paths, parent components and joints. `FixtureAssemblyState` records joint positions and base locks. Engine import verifies the fingerprint and complete closed-solid assignments; unassigned or stale geometry is rejected. Generic imports keep their existing editing behavior.

The workspace, occupancy sampling and cutter/holder clearance checks use the same physical component transforms. Fixture render and collision caches include the complete saved assembly state. Projects pin fixture snapshots when selected, and generated setups preserve them across stock orientation changes. Selected geometry remains visible before CAM exists and is restored with the job; preview restoration validates the source and placement without claiming CAM clearance. Current library ownership still controls availability. Reference-only models are rejected as planning candidates even if a user has checked the general grip-review setting.

Headless tests cover component identity, parent/child screw motion, joint endpoints, stock contact and slot limits, release with locked bases, asymmetric stock, invalid states, legacy decoding and saved-job round trips. Source export checks compare retained solid counts, bounds and sampled geometry. App compilation is checked separately; this task does not use native-app automation.

## Automatic choice (2026-11-08)

With no fixture placed by hand, Coastline fits every owned fixture with a reviewed mechanism to the stock and the planner picks one for each cut. Setups shows each with “Fits this stock” or the reason it doesn't (too tall, too short for two clamps, outside the vise opening, nuts past the slot end). Clicking a fixture places it by hand as before; **Choose Automatically** goes back.

| Fixture | Moves | Holds |
| --- | --- | --- |
| C-clamps (pair) | each frame along the table edge; each screw with its pad and handle | stock on the table up to 61.6 mm tall, at least 36.5 mm deep and 55.4 mm long; pads 20 mm in from the ends |
| 2" vise | jaw, lead screw and knob together | 20.5–46.6 mm between the jaws (model sizes are placeholders), two-thirds of the depth gripped |
