# Porting checklist: Swift app → Qt app

Each Swift file and where its Python port lives. Tick when ported **and** its tests are ported.

## MillCore → `coastline_app/mill/`

| Swift | Python | Status |
|---|---|---|
| GRBL/MillError.swift | mill/errors.py | done |
| GRBL/RealTimeStatus.swift | mill/geometry.py, mill/status.py | done |
| GCode/GCodeLine.swift | mill/gcode.py | done |
| GRBL/ConnectionState.swift | mill/state.py | done |
| GRBL/GRBLProtocol.swift | mill/protocol.py | done |
| GRBL/SerialConnection.swift | mill/serial_connection.py | done |
| GRBL/MillConnection.swift | mill/connection.py | done |
| GRBL/CustomMCodes.swift | mill/connection.py (M100–M114), mill/contour.py | done |
| Serial/*.swift (termios, IOKit) | mill/transport.py (pyserial; Windows COM ports and macOS) | done |
| Mock/MockGRBL.swift | mill/mock.py | done |
| Session/SessionTypes.swift | mill/session_types.py | done |
| Session/MillSession.swift | mill/session.py | done |
| Session/GoTo.swift, JobPrograms.swift, TestPrograms.swift, TestProgramLibrary.swift | mill/programs.py | done |
| Tests: GCode, GRBL, Session, SessionCore, ProgramLibrary, ManualControl | tests/mill/ | done (78 tests) |
| Firmware/* (STK500 flasher), Mill/* (MillingManager, MillConnector, ManualMode, Jogging, SpindleLoadMonitor) | — | not ported: the app does not use them |
| Settings/AppSettings.swift (legacy cncmill.conf keys) | — | not ported: the app does not use these keys |
| Project/Project.swift (Step, Job) | mill/project.py | done |

## CoastlineCore → `coastline_app/core/`

Conventions:
- `core/codable.py` writes JSON exactly as Swift's Codable/JSONEncoder do (camelCase keys with
  Swift's acronyms, nil omitted, `[lower, upper]` ranges, Swift number format, sorted keys).
  The real Inventory.json round-trips byte for byte, and fixture layout IDs (SHA-256 of the
  definition JSON) match the Swift values.
- Built-in catalogs (materials, tool and stock suggestions, standard machine profile, flat
  clamping kit) were exported from the Swift catalogs into `coastline_app/data/*.json`
  (2026-11-16, with a throw-away Swift harness in /tmp). The JSON is now the source of truth.
- UUIDs are uppercase strings (`core/ids.py`). simd math is numpy: `M[:, k]` is column k.
- Swift `max(by:)`/`min(by:)` keep the first of equal elements; so do Python's max/min.

| Swift | Python | Status |
|---|---|---|
| Machine/MachineProfile.swift | core/machine/profile.py, core/geometry.py | done |
| Materials/* | core/materials.py (+ data/materials.json) | done |
| Units/DisplayUnits.swift, `Length` | core/units.py | done |
| Inventory/Tool.swift, InventoryItems.swift | core/inventory/items.py | done |
| Inventory/Inventory.swift (+ CatalogUpdates, FixtureSetup, StockMaterials) | core/inventory/inventory.py, core/storage.py | done |
| Inventory/InventoryChecks.swift, ResourceLibraryValidation | core/inventory/checks.py | done |
| Inventory/ToolCatalog.swift, StockCatalog.swift | core/inventory/catalogs.py (+ data/*.json) | done |
| Inventory/ResourceLibraryPackage.swift | core/inventory/resource_library.py | done |
| Inventory/ToolLibraryImport.swift | core/inventory/tool_library_import.py | done |
| Inventory/VettedFixtureLibrary.swift | core/inventory/vetted_fixtures.py | done |
| Inventory/JobResourceSnapshot.swift | core/inventory/snapshot.py | done |
| Plan/Setup.swift, SetupSide.swift, StockOrientation.swift | core/plan/setup.py, setup_side.py, stock_orientation.py | done |
| Plan/FixtureAssemblyDefinition.swift | core/plan/fixture_assembly.py | done |
| Plan/BookendSetup.swift, FixtureMechanism.swift | core/plan/fixture_mechanism.py | done |
| Plan/LibraryWorkholding.swift (types) | core/plan/workholding_profile.py | done |
| Plan/LibraryWorkholding.swift (planner, StockRemoval) | core/plan/library_workholding.py | pending |
| Plan/LibraryFixtureGeometry.swift, FixtureEdgeSnap.swift | core/plan/library_fixture_geometry.py, fixture_edge_snap.py | done |
| Machine/Maintenance.swift | | pending |
| everything else in CoastlineCore | | pending |

## App model (Coastline/Model) → `coastline_app/model/`

QObjects with Qt properties (`model/bindable.py: prop()`), passed to QML as `app` (`AppRoot`).
Lists go to QML as arrays of dicts from slots that depend on a `revision` counter.

| Swift | Python | Status |
|---|---|---|
| AppSettings.swift | model/settings.py (QSettings) | done |
| InventoryModel.swift | model/inventory_model.py | done |
| JournalModel.swift | model/journal_model.py (+ JournalUI: the record-a-job form) | done |
| MillControl.swift (+ GoToRequest helpers) | model/mill_control.py | done, tested on the simulated mill |
| ContentView.swift (navigation) | model/app_root.py, qml/Main.qml | done |
| AppModel and its extensions (workspace) | model/workspace/ (one mixin per Swift file; workspace.py composes them) | done: part → stock → analysis → plans → generation → posting → save/open/undo checked end to end (pendant sample, 9 programs pass) |
| DevelopmentSession.swift | | not ported (Mac dev-loop only) |
| projectThumbnail (Finder icon) | | not ported (Mac only) |
| JobsModel.swift | model/jobs_model.py (JobsUI: the Projects page) | done |
| MachineProfilePreview.swift | model/machine_preview.py | done |
| ControlMachineView's scene | model/control_machine.py | done |
| GeneratedPrograms, ProjectDocument, SavedResults | model/workspace/guided_export.py, project_document.py | done |
| InventoryPreviewModels.swift | | pending |

## Screens (Coastline/Views) → `coastline_app/qml/`

| Swift | QML | Status |
|---|---|---|
| ContentView (sidebar, mill toolbar, mill sheets) | Main.qml, components/MillDialogs.qml | done |
| Inventory: Tools, Stock, Fixtures, Measuring, Accessories, Shopping | pages/*.qml | done (no 3D previews, fixture planning profile, materials editor, library import/export yet) |
| Control: ControlPage, ControlInspector, ManualControls, MillConsole, TestProgramLibrary, JogKeys, ControlMachineView | pages/ControlPage.qml, components/MillDialogs.qml, JogButton.qml | done |
| WorkspaceView, StageViews, SetupInspector, JobPlanningGuide, PlanOptionsView, MachinabilitySection, MachiningInspector, LibraryWorkholdingSection, FixturePlacementInspector, PlaybackBar, JobStrip, StepCard, ToolChangeCard, ViewModeBar, JogPanel, FindingsOverlay (pins), SelectedCodeExportSheet | pages/WorkspacePage.qml, workspace/*.qml (model side: model/workspace/ui.py) | done |
| ProjectsPage, Jobs (JobsPage, JobPreview, JobRunner), JournalViews | pages/ProjectsPage.qml, jobs/*.qml | done |
| MachineProfilesPage (+ maintenance) | pages/MachinePage.qml | done |
| SettingsView | components/SettingsDialog.qml | done |
| ViewCube | viewport/view_cube.py (QQuickPaintedItem) | done |
| SceneLabelsOverlay | — | not ported |

The look is a 1:1 copy of the Mac app, checked page by page against screenshots of it. The
macOS kit lives in `qml/components/`: PageScaffold (52-pt toolbar in the title bar, inspector
column, toolbar search), Sidebar, GlassCapsule/GlassButton/ToolbarIcon, Card (grouped Form
section), ValueRow/FieldRow/NumberRow/StepperRow/SwitchRow/PopupPicker/ChoiceEdit (LabeledContent
and pickers), Disclosure, DataTable (Table with stripes), FilterChips, Segmented, Badge,
ContentUnavailable, PreviewCard, StockDrawing/ToolDrawing. Symbols: `ui/symbols.py` draws SF
Symbols through AppKit on macOS (image://sf); Windows needs open-licence look-alikes in
`ui/symbols/<name>.svg` (not made yet). `ui/window_chrome.py` makes the Mac title bar transparent.
Fixture thumbnails: `ui/thumbnails.py` (QPainter, image://thumb).

To compare: run the Mac app with `COASTLINE_SCRIPT="...; wsnap <png>; quit"` on a copy of the data
and grab the Qt window at the same size (1171 × 829 pt).

`tests/test_app_smoke.py` loads every page in a headless window and fails on any QML warning.

## Viewport → `coastline_app/viewport/`

At parity with the Metal renderer except shadows: meshes with materials (realistic PBR or flat),
translucent and on-top meshes, unlit handles, motion groups, section plane with hatched cut faces,
x-ray toolpaths through the stock (stencil), thick dashed lines, playback count, picking (C++ BVH),
machine-axes → display transform, standard views, eased camera moves, pivot orbit, snapshots.
`scripts/render_check.py` renders a test scene on the real GPU to a PNG. Pending: shadow map,
view cube, labels overlay. Cutter meshes: viewport/cutter.py; heightmap stock mesh: viewport/grid.py; handles: viewport/mesh_builder.py.

## Packaging

`scripts/package.py` packages the app for the system it runs on: one bundled interpreter (uv's
relocatable CPython 3.11) for the app and the engine, laid out like the repository
(`paths.PACKAGED`). macOS: `build/qt/Coastline Qt.app` (named apart from the Swift app);
Windows: `build/qt/Coastline` and, with Inno Setup 6, `Coastline-Setup.exe` (installer/coastline.iss:
per user, Start-menu and desktop shortcuts, `.coastline` files open in it).
`engine/native/build.py` builds the engine's C++ kernels with MSVC or clang.
`.github/workflows/qt-app.yml` builds and tests on Windows and macOS when started by hand and
uploads both as artifacts (no release; the DMG release workflow is untouched).
Checked here: the packaged Mac app imports a part and loads the machine with a clean environment.
Not yet run: the Windows build (needs the workflow, or a Windows PC).

## Known gaps
- Inventory 3D previews show tools, stock and fixture models; measuring tools and accessories have
  none (the Mac app shows representative models). No 3D scene labels.
- Windows symbol fallbacks (`ui/symbols/*.svg`) are still to be drawn: without them icons are blank
  on Windows.
- The package is about 1 GB unpacked (OpenCASCADE, VTK libraries it links, Qt).
- Saved `.coastline` files from the Mac app store toolpaths LZFSE-compressed. This app writes them
  uncompressed (the Mac app reads those) and reads LZFSE only when the `liblzfse` module is
  installed; otherwise it asks to regenerate.
