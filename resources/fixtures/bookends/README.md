# Bookend assembly

Revision 2 (M4). `assembly.step` comes from the user's Fusion machine file (`CNC`, `04 X Table/Fixtures/Bookends`), exported and flattened to one solid per part in machine coordinates. Part list and bounds: `evidence.json`. SHA-256 `cc141eb5ee58f00fb420ab2272d84bb448de1758a691a8f1dcd6947a87dca9e3`. Libraries that hold revision 1 (the M5 original, SHA `341115f7…`) are rebound to it; their fit is redone.

| Solids | Component | Motion |
| --- | --- | --- |
| 0/0, 2/0–5/0, 11/0, 12/0 | Fixed bookend, two M4 × 25 screws and washers, two M4 T-slot nuts | slides along the slots |
| 1/0, 6/0–9/0, 13/0, 14/0 | Clamping bookend, the same hardware | slides along the slots |
| 10/0 | M4 × 25 side screw | screw joint along −Y, 0.7 mm pitch, 0–15 mm |

What changed in Fusion: the T-slot nuts are the Fairway M4 nut (`../hardware/`), running in under each base (fixed: +Y, clamp: −Y; nut Y −352.5…−336.63 and −142.17…−126.3). The mounting holes are 4.5 mm (were 5.5). The side screw hole is tapped M4 × 0.7 (cosmetic thread) and the side screw is an M4 × 25 socket-head screw; its flat tip is 1.5 mm in radius. Screws and washers: ISO 4762 / ISO 7089 sizes, modelled in Fusion, not vendor models. The mounting screw tip ends 0.06 mm below the nut, in the slot space under it.

The audit script `scripts/audit-vetted-workholding.py` and the sections below describe revision 1.

## Revision 1 (M5)

`assembly.step` is a byte-for-byte copy of the user's installed **Workholding-Bookends** assembly. Its SHA-256 is `341115f76ac3ede6f85058c05886872df52cf926588ceb9a20dee3b28acaf78b`. The original installed file and the Fusion/CAD sources are unchanged.

`definition.json` binds the exact STEP occurrence paths to three components. `evidence.json` records their zero-based solid indices in the same `STEPControl_Reader` / `TopExp_Explorer(TopAbs_SOLID)` order used by the engine.

| Component | Solids | Behavior |
| --- | --- | --- |
| Fixed bookend | 0, 2, 3, 4, 5, 6, 12 | Body, two T-slot nuts, two mounting screws and washers move together along the slots. |
| Clamping bookend | 1, 7, 8, 9, 10, 13, 14 | Body, two T-slot nuts, two mounting screws and washers move together along the slots. |
| Pressure screw | 11 | Inherits clamping-bookend placement, then rotates and translates independently. |

All 15 solids are physical components. No table or T-slot reference stand-in occurs in this assembly. The four 11 × 11.6 × 2.8 mm T-slot nuts are the custom M5 mounting hardware defined in `wh_build2.py`, not table geometry. The bodies' 6 × 1.8 mm alignment keys are integral geometry and remain attached to their bookends.

## Pressure screw

The STEP identifies McMaster-Carr **91290A252**, M5 × 0.8, 25 mm socket-head screw with modeled external threads. The threaded-hole authoring operation in `wh_build2.py` specifies M5 × 0.8 internal class 6H with cosmetic internal threads.

At the exported pose:

- Screw axis: `(0, −1, 0)` toward the stock, through world X `25.3651363565511`, Z `104.443594125127` mm.
- Tip plane: Y `−139.8`; underhead plane: Y `−114.8`; rear of head: Y `−109.8` mm.
- Clamp's inner and outer planes: Y `−135.8` and `−125.8` mm; its wall is 10 mm thick.
- The screw projects **4 mm** beyond the inner face. This is `pressure-extension = 4`, the reference value.
- The geometric preview interval is **0…15 mm** extension: 25 mm shaft minus 10 mm wall. Zero places the tip flush with the inner face; 15 brings the underside of the head to the outer face.

The extension interval describes shaft overlap and the modeled head stop. It does not establish a minimum thread engagement, a tightening torque, clamp force or machining-load suitability. Stock contact stops tightening at the material surface. Cosmetic internal threads mean an exact Boolean overlap between a screw thread and its mating hole is expected; it must not be mistaken for stock penetration.

The base slide joints have broad `−1000…1000` mm mathematical bounds, referenced to this exported pose. Those are not a usable machine envelope. The setup solver must constrain the nut footprints to the selected machine's actual slots, as well as checking stock contact and other placement constraints.

## Source evidence

- Installed source: `~/Library/Application Support/Coastline/Fixture Models/54703CA3-5954-462C-903F-464F61F003ED.step`.
- Standalone clamp: `/Users/pd/Project/CNC Model/cad/workholding/b1.step`.
- Standalone fixed stop: `/Users/pd/Project/CNC Model/cad/workholding/b2.step`.
- Authoring source: `/Users/pd/Project/CNC Model/scripts/wh_build2.py`. The older `wh_build.py` is a different design with feet and longer bar nuts.

The standalone body exports agree with the corresponding assembly bodies in world bounds and volume. This is an identity check, not proof of identical topology. The bundled assembly itself is preserved byte-for-byte.

Reproduce the read-only CAD audit from the repository root:

```sh
engine/.venv/bin/python scripts/audit-vetted-workholding.py \
  --clamp-body '/Users/pd/Project/CNC Model/cad/workholding/b1.step' \
  --fixed-body '/Users/pd/Project/CNC Model/cad/workholding/b2.step'
```

Omit the optional body arguments when those local CAD sources are unavailable. The audit reads the bundled assembly and the other bundled fixture STEPs; it writes only its JSON evidence file and never opens Fusion or changes the originals.
