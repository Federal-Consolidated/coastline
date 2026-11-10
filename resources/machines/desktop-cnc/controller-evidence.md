# Desktop machine controller and tooling evidence

Reviewed 2026-11-06. This records the evidence used to resolve imported profile fields and the limits of that evidence. It does not certify an individual physical machine.

## Sources

- The user's Fusion export: `/Users/pd/Project/CNC Model/export/Desktop CNC Machine - share`. Imported values and provenance are recorded in `resources/machines/desktop-cnc/manifest.json`.
- Manufacturer [GRBL firmware, pinned revision `ee8afc8`](https://github.com/CoastRunnerCNC/coastrunner_cr1_firmware_328p/tree/ee8afc8dbf89c155db33b70405cc452832d7a0a8). Relevant files are `grblCR/defaults.h`, `config.h`, `gcode.c`, `protocol.c` and `serial.c`.
- Manufacturer [operator manual, version 0.9, November 1, 2024](https://coastrunner.net/wp-content/uploads/2024/11/Coast-Runner-Operator-Manual-LATEST.pdf). The host returned HTTP 403 for the complete PDF on this review; the cited sections were available in the search index. The section-specific evidence below is explicit about what was recovered.
- Existing local implementations: `MachineProfile.swift`, `GRBLPost.swift`, `GCodeValidator.swift`, `MillCore` and their self-tests. These are implementation evidence, not substitutes for manufacturer specifications.

## Resolved interpretations

### Spindle speed

Firmware defaults report `$31 = 1360` and `$30 = 8500`. These are controller parameters. The manual §5.2.3.2, p. 59 gives the usable range as 1500–8000 RPM: lower commands do not turn the spindle and higher commands saturate. Keep both fields with distinct meanings; use 1500–8000 for generated cutting programs. The post clamps requested RPM to this usable range.

### Collet, diameter and length

The manual §2.1, p. 14 identifies ER11 and an 8 mm tool acceptance diameter. §4.5, p. 41 describes seating the tool to the back of the collet, approximately 0.9 inch deep. Those support the existing 8 mm shank capacity and 22.9 mm nominal seating depth.

The imported Fusion machine sets a 7 mm maximum tool diameter and 75 mm maximum tool length. Preserve these as imported planning limits. Do not relabel 7 mm as a verified physical cutting-diameter limit or infer exposed stickout from the 75 mm value. Shank diameter, cutting diameter, overall length, exposed stickout and insertion depth are separate quantities. A conservative 75 mm overall-length planning cap can coexist with the hardware's 8 mm shank capacity without claiming that the two diameter fields measure the same thing.

The legacy 76.2 mm overall-length limit cites manual §4.2, but that section in version 0.9 is Homing; this review did not recover a current manufacturer statement for 76.2 mm. Prefer the supplied 75 mm profile cap until the exact limit is established. The existing manual also describes a roughly 16 mm spindle interior separately from the 0.9-inch collet seating description; neither is a measured installed tool stickout. Require the actual tool assembly dimensions for reach and collision calculations.

### Manual tool changes and preload

The Fusion export describes one tool and no tool changer. Its `supports_tool_preload` flag does not create a physical changer. Coastline emits one program per installed tool and uses separate guided tool-change steps; it does not emit `M6` or a preload command. Treat preload as inapplicable for this adapter. The imported 15-second change time is an estimate, not a verified duration or safety dwell.

### Controller and post selection

`system://grbl.cps` is a Fusion post reference, not the implementation Coastline executes. This application uses the native Swift `GRBLPost`, identified by `coastline.grbl.desktop.v1`; it neither executes nor bundles that CPS. Store the Fusion reference as provenance and select the Coastline adapter explicitly. A generic GRBL identity alone is insufficient to authorize a different machine: retract location, machine coordinate signs, usable spindle range and tool-change motion remain profile-specific.

The pinned firmware parser supports G90/G91, G17–G19, G20/G21, G93/G94, G40, G43.1/G49, G54–G59 and incremental I/J arc centres. Coastline's emitted subset has been checked against that parser. G91.1 is accepted and specifies the already-supported incremental arc-centre convention. G49 must be on a block without axis motion.

## Controller contract fixes

The post previously left feed mode inherited from earlier controller activity. It now emits `G94 G40 G91.1` before the first move, alongside its existing explicit absolute, millimetre, XY-plane and G54 setup. The validator accepts these modes and rejects G93 inverse-time programs instead of treating G93 as a harmless unfamiliar word.

Tool-length compensation is preserved. Existing G10 L20 touch-off may have established G54 while that compensation was active; cancelling it only when cutting starts would shift the work coordinates. Any future explicit compensation policy must apply consistently before touch-off and during cutting, not only in the post header.

Generated comments now reserve the closing parenthesis, fit the 79-byte line budget, remain on one ASCII line, and remove the firmware's realtime characters. A long or multiline program/tool label cannot truncate its comment boundary or inject a command/realtime control byte. The firmware handles realtime input before interpreting comments, so parentheses alone are not sufficient protection.

The guided-job preflight also recognizes G91.1. The line classifier now distinguishes that arc-centre mode from G91 so it cannot incorrectly change the sender's XYZ distance mode.

Existing post behavior remains: machine-Z retract at -1 mm, controlled spindle ramp, expanded drilling moves, G0/G1/G2/G3 motion, one program per tool, no M6, and an M5 finish. Regression coverage checks the reset block, both usable-RPM boundaries, comment boundaries, line length and the rejected inverse-time mode. These checks validate generated text and its local interpretation; no controller command was sent during this review.

## What source review cannot establish

- Whether this physical controller still has its factory settings, firmware or homing offsets.
- The installed tool's measured length, stickout, engagement and current G54/tool touch-off.
- Whether a changed table, spindle, fixture or fastener clears the selected retract/tool-change route.

These are commissioning or setup inputs. They should be concrete measurement/connection checks, not permanent generic warnings that prevent digital inspection and planning with the resolved profile values.

## Verification

Focused self-tests cover three post cases, the CAM validator regression, seven generated-job export/preflight cases, the MillCore job-program check and decimal G-code classification. Compiler warnings about existing unmutated variables and unavailable user-level SwiftPM caches are unrelated to these checks.
