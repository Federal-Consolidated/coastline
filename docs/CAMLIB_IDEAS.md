# Ideas from camlib (for later)

[camlib](https://github.com/stevecad/camlib) is an MIT-licensed CAM engine in Rust with a Python API.
Reviewed 2026-11-07. Not used as a dependency: it is experimental and unproven on real machines, has no
release or macOS build, needs Python 3.12+ (the engine is on 3.11 for OpenCAMLib), and has no DFM,
workholding or setup planning. Its ideas can be copied (MIT, with notice).

Most useful first:

1. **Leftover check.** After simulation, compare the stock with the part and mark the material still
   there on the part. Shows what the toolpaths actually cannot reach, for more reliable DFM. `DexelSim`
   already does the gouge check against the part; this adds the opposite side.
2. **OK / problem / not sure.** Every check gives one of three results, and the app lists what it did
   not check. Export needs explicit acceptance of any problem or "not sure" result.
3. **V-carve for engraving.** camlib `src/vcarve.rs`: for each outline sample, the largest disk inside
   the region that touches it; the V bit's axis goes to its centre, deep enough for the cone to match the
   disk at the surface; checked between samples. See "Later" in [ENGRAVING_JOB.md](ENGRAVING_JOB.md).
4. **Read the posted G-code back the way GRBL does** (at most 8 digits per number, binary32 positions)
   and compare it with the planned path before export. `GCodeValidator` already checks line length and
   arc error 33.

Smaller:

- Rest machining from the simulated stock (what is actually left), not only from earlier tool sizes.
- A fixed set of frozen test parts with measured results (air cutting, cycle time, leftover, gouge) that
  flags toolpath changes.
- More 3D finishing: scallop, pencil, steep-and-shallow, flat-area.

Not useful: its GRBL post (lines only), feeds and speeds (simpler than ours), fixture checks (simple
extruded shapes; Coastline uses the real fixture meshes).
