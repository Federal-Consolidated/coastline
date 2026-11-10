# 2" mini vise (Amazon B085VSFQ7K)

`assembly.step`: from the user's Fusion machine file (`04 X Table/Fixtures/Vise - 2in Mini Aluminum`), exported and flattened to one solid per part in machine coordinates. Part list and bounds: `evidence.json`. The model's sizes are round numbers: a stand-in until the real vise is measured.

| Solids | Component | Motion |
| --- | --- | --- |
| 0/0, 3/0, 5/0–10/0 | Body, washer, three M4 T-slot nuts and M4 × 12 screws | fixed, upper T-slot (Z 118.764) |
| 1/0, 2/0, 4/0 | Moving jaw, M8 lead screw, knob | screw joint along −Y, 1.25 mm pitch |

Measured: floor X 27.865 (12 mm above the table), fixed jaw face Y −270.4, moving jaw face Y −245.4 at the authored pose, jaws X 27.865–45.865 and Z 88.764–128.764. Jaw range −21.6 (against the end wall: 46.6 mm opening) to 4.5 (knob against the washer: 20.5 mm).

Revision 3 (M4, from Fusion): the nuts, screws and holes are M4. Mounting holes 4.5 mm, tapped holes M4; the counterbores stay 9.5 mm (Fusion would not shrink them). The screw tips end 0.16 mm below the nuts. Libraries that hold revision 1 or 2 are rebound.
