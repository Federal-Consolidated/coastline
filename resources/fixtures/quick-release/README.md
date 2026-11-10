# Quick release jig plate: fixture geometry

The source `../quick_release_jig_plate.step` includes the machine's **X Unibody - RevD v1** table as its first occurrence. This is a 385 × 74.93 × 14.605 mm reference table, not hardware that belongs to the jig plate.

`fixture.step` excludes only that exact, fingerprinted occurrence (`0/0`, flat solid index 0). All 34 remaining solids are retained with their assembly names and placements, including bolts, washers, plates, insulators and unnamed components. No other component is discarded based on a generic name or inferred role. The original source file is unchanged.

The source STEP header names it **Jig Plate Rev D - Metric Exploded View.step**. Removing the reference table does not assemble the exploded hardware or establish a mounted pose. This is cleaned display/reference geometry, not a newly qualified machining setup.

`definition.json` keeps the retained geometry in one physical component, conservatively including its hardware. Independent adjustment and assembled placement have not been defined. `evidence.json` records the source/output hashes, removed body, retained-body mapping, bounds and volume checks.

Reproduce the export from the repository root:

```sh
engine/.venv/bin/python scripts/export-reviewed-fixtures.py
```

The exporter accepts only source SHA-256 `06df20ac25bc5ab5268f1cc4cf124da6e7e32c7f25f91cd8525b316a0bdc83c1`. It writes this cleaned bundle and its evidence; it does not edit the source STEP or use Fusion. STEP export metadata may change the output file hash on regeneration, so the generated definition and evidence must travel with the generated STEP.

## Assembled model (2026-11-08)

`assembly.step` (with `assembly-definition.json`, part list in `assembly-evidence.json`) is the assembled jig plate from the user's Fusion machine file, exported the same way as the C-clamps and vise. It replaces the exploded `fixture.step` in the library. It has no stock mechanism: it holds nests on its shoulder pins, so planning waits for a nest model. In the model, the four M4 screws to the table end about 0.2 mm into the nut space and no T-slot nuts are modelled.
