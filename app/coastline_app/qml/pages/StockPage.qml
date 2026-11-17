import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
import "../workspace"

// Stock: blocks, bars, plates and printed blanks. Port of Views/Inventory/StockPage.swift.
PageScaffold {
    id: page
    property var inventory: app.inventory
    property string ownership: "both"
    property string family: ""
    property string sortKey: ""
    property bool ascending: true
    property var allRows: { inventory.revision; return inventory.stockRows(ownership, searchText, sortKey, ascending) }
    property var rows: family === "" ? allRows : allRows.filter(r => r.family === family)
    property string selectedId: table.selection.length === 1 ? table.selection[0] : ""
    readonly property var families: { inventory.revision; const all = inventory.stockRows("both", "", "material", true); const seen = []; const out = []
        for (const r of all) if (r.family !== "" && seen.indexOf(r.family) < 0) { seen.push(r.family); out.push({value: r.family, title: r.familyTitle}) }
        return out }
    title: qsTr("Stock")
    searchPlaceholder: qsTr("Search stock")
    inspector: stockInspector

    inspectorJoin: [
        ToolbarIcon { symbol: "square.and.arrow.down"; help: qsTr("Preview a Coastline library or Fusion tool library before importing"); onClicked: library.importLibrary() }
    ]
    inspectorItems: [
        GlassCapsule {
            ToolbarIcon { id: exportButton; symbol: "square.and.arrow.up"; chevron: true; help: qsTr("Export Library"); onClicked: library.exportMenu(exportButton) }
        },
        GlassCapsule {
            ToolbarIcon { symbol: "plus"; help: qsTr("Add Stock"); onClicked: page.add("block") }
            ToolbarIcon {
                id: addMore
                symbol: "chevron.down"; symbolSize: 10; implicitWidth: 26
                onClicked: addMenu.popup(addMore, 0, addMore.height + 6)
                Menu {
                    id: addMenu
                    MenuItem { text: qsTr("Block"); onTriggered: page.add("block") }
                    MenuItem { text: qsTr("Round bar"); onTriggered: page.add("roundBar") }
                    MenuItem { text: qsTr("Plate / sheet"); onTriggered: page.add("plate") }
                    MenuItem { text: qsTr("Printed blank"); onTriggered: page.add("printedBlank") }
                }
            }
        },
        GlassCapsule {
            ToolbarIcon { symbol: "trash"; enabled: table.selection.length > 0; help: qsTr("Delete the selected stock (⌫)"); onClicked: deleteDialog.open() }
        }
    ]

    function add(shape) {
        table.selection = [page.inventory.addStock(shape)]
        family = ""; ownership = "owned"; searchText = ""
        page.app.showInspector = true
    }

    LibraryButton { id: library; app: page.app; scope: "stock"; selection: table.selection }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 10; Layout.bottomMargin: 10
            spacing: 16
            Rectangle {
                visible: page.families.length > 0
                implicitWidth: famPicker.implicitWidth + 24
                implicitHeight: 24
                radius: 12
                color: Qt.rgba(1, 1, 1, 0.08)
                border.color: Theme.glassStroke
                PopupPicker {
                    id: famPicker
                    anchors.fill: parent
                    anchors.leftMargin: 12; anchors.rightMargin: 6
                    implicitWidth: 150
                    value: page.family
                    options: [{title: qsTr("All Families"), value: ""}].concat(page.families)
                    onPicked: v => page.family = v
                }
            }
            Item { Layout.fillWidth: true }
            Segmented {
                options: [{value: "owned", title: qsTr("Owned")}, {value: "notOwned", title: qsTr("Not Owned")}, {value: "both", title: qsTr("Both")}]
                value: page.ownership
                onPicked: v => page.ownership = v
            }
        }
        DataTable {
            id: table
            Layout.fillWidth: true
            Layout.fillHeight: true
            rows: page.rows
            sortKey: page.sortKey
            ascending: page.ascending
            onSortRequested: (key, asc) => { page.sortKey = key; page.ascending = asc }
            columns: [
                {title: "", role: "issueMark", width: 26, sort: "", cell: issueCell},
                {title: qsTr("Material"), role: "material", width: 0, sort: "material", cell: materialCell},
                {title: qsTr("Shape"), role: "shape", width: 110, sort: "shape", cell: shapeCell},
                {title: qsTr("Size"), role: "name", width: 150, sort: "volume", digits: true},
                {title: qsTr("Weight"), role: "weight", width: 60, sort: "", color: r => Theme.secondaryLabel, digits: true},
                {title: qsTr("Finish"), role: "finish", width: 110, sort: "finish", color: r => Theme.secondaryLabel},
                {title: qsTr("Location"), role: "location", width: 90, sort: "location", color: r => Theme.secondaryLabel},
                {title: qsTr("Qty"), role: "quantity", width: 40, sort: "quantity", digits: true}
            ]
            onContextMenuRequested: (ids, x, y) => { menu.ids = ids; menu.popup() }
        }
    }
    ContentUnavailable {
        visible: page.allRows.length === 0 && page.searchText === ""
        anchors.centerIn: parent
        title: qsTr("No Stock")
        symbol: "shippingbox"
        description: qsTr("Add the blocks, bars and printed blanks you have.")
    }

    Component {
        id: issueCell
        Item {
            implicitHeight: 16
            Sym {
                anchors.centerIn: parent
                size: 12
                name: row.issue === "error" ? "xmark.octagon.fill" : row.issue === "warning" ? "exclamationmark.triangle.fill" : "checkmark.circle"
                color: row.issue === "error" ? Theme.danger : row.issue === "warning" ? Theme.warning : Theme.tertiaryLabel
            }
        }
    }
    Component {
        id: materialCell
        Item {
            id: mc
            width: parent ? parent.width : 0
            implicitHeight: Math.max(16, col.implicitHeight)
            Rectangle { id: sw; width: 14; height: 14; radius: 4; color: row.swatch; border.color: Qt.rgba(1, 1, 1, 0.2); anchors.verticalCenter: parent.verticalCenter }
            Column {
                id: col
                x: 22
                width: mc.width - 22
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                Item {
                    width: parent.width
                    height: mt.implicitHeight
                    Text { id: mt; text: row.material; color: Theme.label; font.pixelSize: 13; elide: Text.ElideRight
                        width: Math.min(implicitWidth, parent.width - (row.notOwned ? nob.width + 6 : 0)) }
                    Rectangle {
                        id: nob
                        visible: row.notOwned
                        x: mt.width + 6
                        anchors.verticalCenter: mt.verticalCenter
                        width: nt.implicitWidth + 10; height: nt.implicitHeight + 2; radius: height / 2
                        color: Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.25)
                        Text { id: nt; anchors.centerIn: parent; text: qsTr("Not owned"); color: Theme.label; font.pixelSize: 10; font.weight: Font.DemiBold }
                    }
                }
                Text { visible: row.caption !== ""; text: row.caption; color: Theme.secondaryLabel; font.pixelSize: 10; elide: Text.ElideRight; width: parent.width }
            }
        }
    }
    Component {
        id: shapeCell
        Row {
            spacing: 6
            width: parent ? parent.width : 0
            Sym { name: row.shapeSymbol; size: 12; anchors.verticalCenter: parent.verticalCenter }
            Text { text: row.shape; color: Theme.label; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
        }
    }

    Menu {
        id: menu
        property var ids: []
        MenuItem { text: qsTr("Mark as Owned"); onTriggered: page.inventory.markStockOwned(menu.ids) }
        MenuItem { text: qsTr("Duplicate"); onTriggered: table.selection = page.inventory.duplicate("stock", menu.ids) }
        MenuSeparator {}
        MenuItem { text: qsTr("Delete…"); onTriggered: deleteDialog.open() }
    }
    Dialog {
        id: deleteDialog
        title: table.selection.length === 1 ? qsTr("Delete this stock?") : qsTr("Delete %1 stock items?").arg(table.selection.length)
        standardButtons: Dialog.Cancel | Dialog.Ok
        anchors.centerIn: parent
        modal: true
        Label { text: qsTr("This can't be undone.") }
        onAccepted: { page.inventory.remove("stock", table.selection); table.selection = [] }
    }

    Component {
        id: stockInspector
        Item {
            id: insp
            property var stock: { page.inventory.revision; return page.selectedId === "" ? ({}) : page.inventory.item("stock", page.selectedId) }
            function set(key, value) { page.inventory.setField("stock", page.selectedId, key, value) }
            readonly property var mat: (page.app.inventoryExtras.revision, page.selectedId === "" ? ({}) : page.app.inventoryExtras.material(page.selectedId))
            function mm(v) { const s = Number(v || 0).toFixed(2); return s.replace(/0+$/, "").replace(/\.$/, "") }
            ContentUnavailable { visible: page.selectedId === ""; anchors.centerIn: parent; title: qsTr("No Stock Selected"); symbol: "shippingbox"; description: "" }
            Panel {
                visible: page.selectedId !== ""
                anchors.fill: parent
                ws: page.app.workspace
                app: page.app
                // The preview and the name, on the panel itself.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    spacing: 8
                    PreviewCard {
                        app: page.app
                        kind: "stock"
                        itemId: page.selectedId
                        drawing: Component { StockDrawing { envelope: insp.stock._envelope || [50, 50, 20]; shape: insp.stock.shape || "block"; swatch: insp.stock._swatch || "#888" } }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: insp.stock._materialName || ""; color: Theme.label; font.pixelSize: 13; font.weight: Font.Bold; Layout.fillWidth: true; elide: Text.ElideRight }
                        Badge { visible: (insp.stock._difficulty || "") !== ""; text: insp.stock._difficulty || ""
                            tint: [Theme.secondaryLabel, Theme.label, Theme.warning, Theme.danger][insp.stock._difficultyKey || 0] }
                    }
                    Text { text: qsTr("Drag to orbit · Pinch to zoom · Double-click to fit"); color: Theme.secondaryLabel; font.pixelSize: 10; Layout.leftMargin: 10; Layout.bottomMargin: 4 }
                }
                Card {
                    title: qsTr("Material & shape")
                    FieldRow { label: qsTr("Material"); ChoiceEdit { choices: page.inventory.materialChoices(); value: insp.stock.materialID; onCommitted: v => page.inventory.setStockMaterial(page.selectedId, v) } }
                    FieldRow { label: qsTr("Shape"); ChoiceEdit { choices: page.inventory.choices("StockShape"); value: insp.stock.shape; onCommitted: v => insp.set("shape", v) } }
                    FieldRow { label: qsTr("Faces"); ChoiceEdit { choices: page.inventory.choices("StockFinish"); value: insp.stock.finish; onCommitted: v => insp.set("finish", v) } }
                    FieldRow {
                        visible: insp.stock.shape !== "printedBlank"
                        label: qsTr("Extruded along")
                        ChoiceEdit {
                            choices: [{value: -1, title: qsTr("Not known (longest side)")}, {value: 0, title: "X · " + insp.mm(insp.stock.sizeX) + " mm"},
                                      {value: 1, title: "Y · " + insp.mm(insp.stock.sizeY) + " mm"}].concat(insp.stock.shape === "roundBar" ? [] : [{value: 2, title: "Z · " + insp.mm(insp.stock.sizeZ) + " mm"}])
                            value: insp.stock.extrusionAxis === undefined || insp.stock.extrusionAxis === null ? -1 : insp.stock.extrusionAxis
                            onCommitted: v => insp.set("extrusionAxis", v < 0 ? null : v)
                        }
                    }
                }
                Card {
                    visible: (insp.mat.summary || []).length > 0
                    Disclosure {
                        title: qsTr("Material properties")
                        Repeater { model: insp.mat.summary || []; delegate: ValueRow { required property var modelData; label: modelData[0]; value: modelData[1] } }
                        Repeater { model: insp.mat.notesList || []; delegate: ValueRow { required property var modelData; label: modelData[0]; value: modelData[1] } }
                        LinkButton { symbol: "slider.horizontal.3"; title: insp.mat.builtIn ? qsTr("Customize Material…") : qsTr("Edit Properties…"); onClicked: materialDialog.begin(page.selectedId) }
                    }
                }
                Card {
                    title: qsTr("Size")
                    NumberRow { label: insp.stock.shape === "roundBar" ? qsTr("Diameter") : qsTr("X (length)"); value: insp.stock.sizeX || 0; onCommitted: v => insp.set("sizeX", v) }
                    NumberRow { label: insp.stock.shape === "roundBar" ? qsTr("Length") : qsTr("Y (width)"); value: insp.stock.sizeY || 0; onCommitted: v => insp.set("sizeY", v) }
                    NumberRow { visible: insp.stock.shape !== "roundBar"; label: qsTr("Z (height)"); value: insp.stock.sizeZ || 0; onCommitted: v => insp.set("sizeZ", v) }
                    ValueRow { visible: (insp.stock._weight || "") !== ""; label: qsTr("Weight"); value: insp.stock._weight || "" }
                }
                Card {
                    title: qsTr("Ownership")
                    StepperRow { label: qsTr("Quantity"); value: insp.stock.quantity || 0; onCommitted: v => insp.set("quantity", v) }
                    NumberRow { label: qsTr("Price each"); optional: true; value: insp.stock.unitCost === undefined ? null : insp.stock.unitCost; unit: ""; decimals: 2; onCommitted: v => insp.set("unitCost", v) }
                    FieldRow { label: qsTr("Supplier"); TextEdit { value: insp.stock.supplier || ""; onCommitted: t => insp.set("supplier", t) } }
                    FieldRow { label: qsTr("Location"); TextEdit { value: insp.stock.location || ""; placeholderText: qsTr("e.g. Drawer 2"); onCommitted: t => insp.set("location", t) } }
                    SwitchRow { label: qsTr("Offcut from an earlier job"); checked: insp.stock.isRemnant === true; onToggled: on => insp.set("isRemnant", on) }
                    FieldRow { label: qsTr("Notes"); TextEdit { value: insp.stock.notes || ""; onCommitted: t => insp.set("notes", t) } }
                }
                Checks { issues: insp.stock._issues || [] }
                Item { Layout.preferredHeight: 16 }
            }
        }
    }

    Component.onCompleted: if (rows.length > 0) table.selection = [rows[0].id]
    MaterialDialog { id: materialDialog; app: page.app }
}
