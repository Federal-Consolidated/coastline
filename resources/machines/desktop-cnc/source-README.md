# Desktop CNC Machine — simplified model and CAM machine profile

Vendor: Federal Consolidated. Date: 2026-11-06.

## Files

| File | What it is | How to use it |
|---|---|---|
| `CNC simplified v31.step` | Simplified machine model, STEP AP214 assembly (34 unique parts, 52 bodies). STEP length unit is cm; all CAD tools convert it. | Open in any CAD tool or 3D viewer. |
| `CNC simplified v31.f3d` | The same model as a Fusion archive, with the component structure. | Fusion: File > Upload / Open. |
| `Desktop CNC Machine.mch` | Fusion CAM machine definition (kinematics, limits, feeds, spindle, post `grbl.cps`). | Fusion Manufacture: Manage > Machine Library > Import. Then link the model (see "Machine model link"). |

## Machine layout

The machine has a **horizontal spindle**. All coordinates are model (world) coordinates in mm.

- **+X is up.** The X axis moves the **table** up and down. The table top faces +X.
- **Y** is along the table length. The Y axis moves the **carriage and the spindle**.
- **Z is the spindle axis.** The spindle is at the back (+Z), and the tool points **−Z** toward the front.
- **Front** (operator side, acrylic window) is −Z.
- The model pose (as saved) is the zero of all three axes in the machine definition.

## Kinematics in the machine definition

```
Base (static)        01 Fixed Frame and Drives + Cover
X  -> Table          04 X Table
Y  -> Z -> Spindle   Y: 02 Y Carriage and Z Guides
                     Z: Z Head Body, Upper Spindle Clamp, Lower Spindle Clamp, Spindle Motor and Belt Drive
                     Spindle: Spindle Cartridge
```

| Axis | Moves | Direction of +axis (world) | Range from model pose (mm) | Home (mm) | Max rate (mm/min) |
|---|---|---|---|---|---|
| X | Table | table moves −X (down); tool moves +X relative to the part | −86.5 … 0 | −86.0 (table up, X switches) | 2540 |
| Y | Carriage + spindle | +Y | −172.5 … +69.0 | +68.5 (Y switch, +Y end) | 3100 |
| Z | Spindle head | +Z (retract) | +1.4 … +79.9 | +79.4 (Z switch, retracted) | 3100 |

Attach points (world mm, model pose):
- Spindle (tool): ER11 nut front face on the spindle axis, (105.43, −176.80, 112.26). Tool axis +Z points from the tool tip into the spindle.
- Table: (15.865, −343.0, 79.04) = table top, −Y datum, −Z datum. Axes x = +X, z = +Z.

Collision checks: base, table side (X + table + stock + fixture) and spindle side (Y + Z + head + tool) are checked against each other. Parts on the same moving chain are not checked against each other.

## Controller values (GRBL 1.1-based firmware, machine defaults)

| Setting | Value |
|---|---|
| Steps/mm X, Y, Z | 400 |
| Max rate X / Y / Z | 2540 / 3100 / 3100 mm/min |
| Acceleration X / Y / Z | 500 mm/s² (not stored in the .mch; it has no field for it) |
| Soft-limit travel X / Y / Z | 86.5 / 241.5 / 78.5 mm (mechanical approx. 88 / 242.9 / 80 mm) |
| Homing | Z first, then X and Y. X homes in −X (table up); Y and Z home in + direction. Pull-off 0.5 mm. |
| Machine position after homing | X −86.0, Y −0.5, Z −0.5 |
| Spindle | BLDC, belt drive, 1360 … 8500 rpm |
| Tool holder | ER11 collet, tool ≤ 7 mm diameter, ≤ 75 mm long, manual tool change (1 tool) |
| Coolant | None |
| Post processor | Fusion library `grbl.cps` |

## Table

- X Unibody top face at x = 15.865 mm, raised top 305 × 75 mm (Y −389.42 … −84.42, Z 54.91 … 129.84).
- Two T-slots along Y, centres at z = 78.759 and z = 118.764 (40 mm apart). Neck 6.13 mm wide, lips 2.0 mm thick (aluminium), cavity 12.0 × 3.0 mm. T-nut entry at the −Y end. Keep M5 screw torque near 2 N·m to protect the lips.

## Simplification

Removed from the full model: all fasteners, washers, nuts, rings, spacers and standoffs; bearings and ballscrew nuts; electronics inside the enclosure (controller boards, power supply, fan, cables); belts, pulleys, couplings; limit switches and targets. The model has no Fusion joints: the machine definition controls all axis motion.

## Known limitations

1. **Part placement in Fusion machine simulation is not verified.** In tests, Fusion placed the stock rotated 90° (long side along Z) on this horizontal-spindle machine, and changing the table attach frame changed only the position. Toolpaths and posting do not depend on this. Check the placement before you use the machine simulation for collision results.
2. The Y range uses the measured hard stops (spindle-axis Y −350.1 … −107.8 mm in world coordinates).
3. X = 0 is assumed to be the lowest table position. Check against the real machine.
4. Machine model link: the .mch links the Fusion file "CNC simplified" v31 in the original team hub. In another hub, open Machine Library > Edit > Machine Model, link your uploaded copy of the .f3d, and assign the components as in "Kinematics" above.
