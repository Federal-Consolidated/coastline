# C-clamp pair

`assembly.step`: two McMaster 5027A13 3" C-clamps from the user's Fusion machine file (`04 X Table/Fixtures/C-Clamps`), copied to a scratch document, exported and flattened to one solid per part in machine coordinates. Part list and bounds: `evidence.json`.

| Solids | Component | Motion |
| --- | --- | --- |
| 1/0 | Clamp A frame | slides along the table edge (Y) |
| 0/0, 2/0, 3/0 | Clamp A pad, screw, handle | screw joint along −X, 2.54 mm pitch (assumed) |
| 5/0 | Clamp B frame | slides along Y |
| 4/0, 6/0, 7/0 | Clamp B pad, screw, handle | screw joint along −X |

Measured: anvil face under the table at X 1.265, arm underside at X 91.68, pad face X 66.665 at the authored pose (on a 50.8 mm bar), pad ⌀22.2 centred Z 104.444 (25.4 mm behind the table edge). Screw range −10.79 (pad against the arm: 76.2 mm opening) to 50.8 (pad on the table).
