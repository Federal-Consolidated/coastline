# Third-party code and libraries

| Component | Where | Licence | Use |
|---|---|---|---|
| FreeCAD `Adaptive.cpp/.hpp` | `engine/native/third_party/freecad_adaptive/` | LGPL-2.1 (`LICENSE_FreeCAD_LGPL.txt`) | Constant-engagement adaptive clearing. Built as a separate dynamic module (`_native`). |
| Clipper 6 (`clipper.cpp/.hpp`, as shipped with FreeCAD) | same folder | Boost Software License | Polygon offsets for Adaptive. |
| Clipper2 2.0.1 | `engine/native/third_party/clipper2/` | Boost Software License (`LICENSE`) | Polygon clipping and offsets. |
| OpenCASCADE, via `cadquery-ocp` | pip | LGPL-2.1 with exception | STEP/IGES import and B-rep. |
| rhino3dm (openNURBS) | pip | MIT | Rhino `.3dm` import. |
| OpenCAMLib | pip | LGPL-2.1 | Drop-cutter and waterline. |
| pyclipper, numpy, trimesh | pip | MIT / BSD | 2D offsets, arrays, mesh utilities. |
| MillCore | `MillCore/` | GPL-3.0 (this project); a Swift port of the original controller software, released under CC0 | `.crproj` model/writer, G-code classifier, GRBL protocol, machine session. |

## Machine and fixture design files

These files were released into the public domain (CC0 1.0 Universal) by the machine's maker and
are included with their geometry unchanged. Their source is recorded outside this repository.

| File | What |
|---|---|
| `resources/machine/machine.step` | Machine mechanical assembly |
| `resources/machine/dimensions.3dm` | Measured work envelope |
| `resources/fixtures/universal_clamp_v96.step` | Universal clamp |
| `resources/fixtures/quick_release_jig_plate.step` | Quick release jig plate, Rev D (metric) |
| `resources/fixtures/clamp_kit.npz` | Clamp kit meshes, built from the maker's clamp kit model |
| `resources/libraries/tools-aluminium.tools`, `tools-steel.tools` | Tool libraries (Fusion `.tools` format) |

No vendor post-processor is included: `GRBLPost` in CoastlineCore is an independent implementation.
