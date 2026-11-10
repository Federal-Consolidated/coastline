# Stock, tool and material libraries

## Use the library

**Stock** is one library of blocks, bars and blanks. Each item has its material,
dimensions and cutting properties together in the inspector; there is no separate
Materials page or tab. Expand **Material properties** to inspect the selected
material or customize it for that stock. **Apply to Stock** saves the material and its snapshot
together; Cancel leaves the stock unchanged. Customization preserves the original
shared definition, other stock and existing job snapshots.

Choosing a material supplies its cutting data. Coastline calculates feeds and
speeds from that data together with the tool, operation and selected machine.
Stock and Tools retain **Import Library…** and **Export Library** actions and
initially show both owned and catalog entries. Imported material definitions
appear in the stock's material picker and retain their source notes.

Import accepts Coastline `.coastlib` files and Fusion `.tools` / tool-library
`.json` files. A preview shows each item, converted dimensions, resulting quantity
and import action. Import notes retain conversions, inferred Fusion dimensions
and skipped unsupported entries.

- **Keep Mine** is the default: duplicate IDs retain existing entries and edits.
- **Replace Definitions** updates specifications while retaining local ownership,
  condition, usage and stock location. Conflicting built-in materials become
  custom copies, and imported stock references those copies.
- **Import Copies** assigns stable new identities and remaps material dependencies.
  Reimporting an unchanged copy does not add another item.

New stock and tools default to **Not owned**. Select **Use quantities from file**
to retain imported quantities, or use **Mark as Owned** / **I Have It Now** after
import. Installing a vendor catalog does not imply that its tools are in the shop.
The Owned/Not Owned filters use quantities for all entries, including imports.

Catalog updates add missing entries without overwriting measurements, notes or
quantities in existing records, including records that are not yet owned.

## Basic blocks and tool definitions

The basic Bookend stock suggestions are 6061 aluminum **101.6 × 50.8 × 50.8 mm**
and **152.4 × 50.8 × 50.8 mm** (2 × 2-inch square bar, cut to 4 or 6 inches).
These use the same section as the existing 8-inch block, with shorter lengths
that leave more room for the two bases on the reviewed desktop table. Tests seat
both against the actual Bookend contacts and constrain their hardware to the
selected machine's slots. This establishes geometric fit, not a promise that
every part/toolpath is machinable from that blank. Both start with quantity zero.

Three generically named tool definitions preserve the published dimensions from
the requested catalog:

| Tool | Cutting diameter | Flute length | Overall length | Source |
| --- | --- | --- | --- | --- |
| 1/4-inch 3-flute bull nose roughing mill | 6.35 mm; 0.254 mm corner radius | 19.05 mm | 63.5 mm | [Published specification](https://ghostgunner.net/product/1-4-helical-end-mill/) |
| 1/8-inch 4-flute flat end mill | 3.175 mm | 6.35 mm | 50.8 mm | [Published specification](https://ghostgunner.net/product/1-8-end-mill/) |
| #34 carbide drill | 2.794 mm | 28.575 mm | 57.15 mm | [Published specification](https://ghostgunner.net/product/34-drill-bit/) |

These are unowned catalog definitions. Published overall lengths are below the
selected desktop profile's 75 mm limit; shank compatibility and installed reach
still need measurements. Missing values display as **—** and the inspector lists
the specifications still needed. Enter the values and use **Confirm Specifications**
before planning. **Other / proprietary** records a coating that does not match
the standard options; keep its actual coating name in Notes. Published APLUS and
ZPLUS names remain in the tool notes without an invented coating classification.

Incomplete definitions can be saved and exported with their review state intact.
Claiming ownership alone does not make them usable for CAM. Their preview and wear
estimate wait for valid, confirmed specifications. Contradictory listings and
the longer tools that exceed this machine's tool-length limit were not added.

**Export Selected** exports the selected rows and the material definitions their
stock needs. **Export All** includes both owned and catalog entries in that
category; **Export All Stock** also includes installed custom material definitions
that have not yet been assigned to stock. Exported lengths and feeds use
millimetres and millimetres per minute.
Stock CAD paths are references only; this format does not bundle printed-blank
CAD, fixture models or machine profiles.

## Jobs retain their definitions

A job stores its selected stock, material and operation-tool definitions. Editing,
replacing or removing a library item does not change that job's geometry or feeds.
Local quantities, tool condition and usage remain inventory facts; a shared job
does not make missing tools owned.

Use **Workspace → Job Resources → Update from Library** to apply changed
definitions deliberately. This clears generated toolpaths and dependent caches.
Selecting or editing stock in the job's own **Save & Use** flow also applies that
change. Projects and debug sessions persist the snapshots, including jobs that
have not generated toolpaths yet. Generated results record the resource snapshot
they used and are rejected if it no longer matches.

Older inventory files migrate from schema 1 to schema 2 without removing stock,
tools, fixtures, accessories or measuring tools. Inventory writes remain atomic
and keep the previous file as `Inventory.json.bak`. An unreadable existing
inventory cannot be overwritten through import or ordinary editing.

Early development Bookend records that predate the lip/tip measurements now load
without preventing the rest of the inventory from opening. Only the exact audited
CAD file can be rebound to those measurements; its old placement review is cleared.
Unknown incomplete fixtures stay unavailable for planning. Existing stock, tools,
names and ownership are preserved; no replacement stock records are fabricated.

## Portable format

The format is JSON with `schemaVersion: 1`, a library `name`, explicit `units`, and
`stock`, `tools` and `materials` arrays. A valid units declaration is:

```json
{
  "length": "mm",
  "feed": "mm/min",
  "density": "g/cm3",
  "surfaceSpeed": "m/min",
  "specificCuttingForce": "N/mm2"
}
```

Imperial input uses `length: "in"` and `feed: "in/min"`; material units remain
as declared above. Export an existing library to obtain complete record examples.
Unknown units, duplicate IDs within a package, unresolved material references,
conflicting embedded definitions and invalid numeric values reject the import
before changing the inventory. This is data validation, not DFM or proof of a
material/tool combination's machining performance.

The first library checkpoint covers stock, tools and materials. Vetted fixture
behavior, Bookend setup/flip guidance and DFM remain separate review stages.

## Verification

On 2026-11-06 the macOS app and core test runner built successfully. All 63
targeted tests passed: material resources (7), library import/export (11), job
resource snapshots (2), inventory (8), built-in materials (2), journal (4), CAM
(15, including the engine integration), setups (11), and project sharing (3).
Checks include source preservation, legacy migration, unit conversion, duplicate
policies, dependency remapping, conflicting copy identities and job definitions
surviving library changes. Native UI interaction remains for user review.

The combined-library/catalog update passed the debug app build and 54 focused
checks: inventory (8), stock catalog (3), tool catalog (4), Bookend setup (8),
vetted assemblies (7), resource import/export (11), job snapshots (2), material
resources (7) and journal (4). A read-only `InventoryStore.load` probe also checked
the live inventory: 22 stock entries, 56 tools and 7 fixtures; both original owned
6061 blocks retained their IDs and quantity 1, and the Bookend definition was
repaired. The probe left the inventory and its backup byte-for-byte unchanged.

The subsequent single-Stock-view revision passed the debug app build and 51
focused checks, including isolated material customization, stale-target rejection,
saved-job snapshot preservation and material dependency export/import.
