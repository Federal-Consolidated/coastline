import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// The tool library: what you own, catalog entries to buy, or both. Port of Views/Inventory/ToolsPage.swift.
PageScaffold {
    id: page
    property var inventory: app.inventory
    property string filter: "all"
    property string ownership: "both"
    property string sortKey: "diameter"
    property bool ascending: true
    property var rows: { inventory.revision; return inventory.toolRows(filter, ownership, searchText, sortKey, ascending) }
    property string selectedId: table.selection.length === 1 ? table.selection[0] : ""
    title: qsTr("Tools")
    searchPlaceholder: qsTr("Search tools, vendors, part numbers")
    inspector: Component {
        ToolInspector { inventory: page.inventory; app: page.app; toolId: page.selectedId }
    }

    function show(id) {
        filter = "all"; ownership = "both"; searchText = ""
        table.selection = [id]
        page.app.showInspector = true
    }
    function addTool() {
        var id = page.inventory.add("tools")
        filter = "all"; ownership = "owned"; searchText = ""
        table.selection = [id]
        page.app.showInspector = true
    }

    inspectorJoin: [
        ToolbarIcon { symbol: "square.and.arrow.down"; help: qsTr("Preview a Coastline library or Fusion tool library before importing"); onClicked: library.importLibrary() }
    ]
    inspectorItems: [
        GlassCapsule {
            ToolbarIcon { id: exportButton; symbol: "square.and.arrow.up"; chevron: true; help: qsTr("Export Library"); onClicked: library.exportMenu(exportButton) }
        },
        GlassCapsule {
            ToolbarIcon { symbol: "plus"; help: qsTr("Add Tool"); onClicked: page.addTool() }
            ToolbarIcon { symbol: "trash"; enabled: table.selection.length > 0; help: qsTr("Delete the selected tools (⌫)"); onClicked: deleteDialog.open() }
        }
    ]

    LibraryButton { id: library; app: page.app; scope: "tools"; selection: table.selection }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 10; Layout.bottomMargin: 10
            spacing: 8
            FilterChips {
                options: [{value: "all", title: qsTr("All")}, {value: "endMills", title: qsTr("End mills")},
                          {value: "ball", title: qsTr("Ball & bull")}, {value: "holes", title: qsTr("Drills")},
                          {value: "chamfer", title: qsTr("Chamfer & engrave")}, {value: "attention", title: qsTr("Needs attention")}]
                value: page.filter
                onPicked: v => page.filter = v
            }
            Item { Layout.fillWidth: true }
            Segmented {
                options: [{value: "owned", title: qsTr("Owned")}, {value: "notOwned", title: qsTr("Not Owned")}, {value: "both", title: qsTr("Both")}]
                value: page.ownership
                onPicked: v => page.ownership = v
            }
            Text { text: qsTr("%1 of %2").arg(page.rows.length).arg(page.inventory.counts().toolsTotal); color: Theme.secondaryLabel; font.pixelSize: 12 }
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
                {title: qsTr("Tool"), role: "name", width: 0, minWidth: 260, sort: "name", cell: toolCell},
                {title: "⌀", role: "diameterText", width: 120, sort: "diameter"},
                {title: qsTr("Flutes"), role: "flutesText", width: 56, sort: "flutes"},
                {title: qsTr("Stick-out"), role: "stickoutText", width: 84, sort: "stickout"},
                {title: qsTr("Coating"), role: "coating", width: 84, sort: "", color: r => Theme.secondaryLabel},
                {title: qsTr("Qty"), role: "quantity", width: 40, sort: "quantity"},
                {title: qsTr("Wear"), role: "wearMark", width: 70, sort: "wear", cell: wearCell}
            ]
            onContextMenuRequested: (ids, x, y) => { menu.ids = ids; menu.popup() }
        }
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
        id: toolCell
        Item {
            id: tc
            width: parent ? parent.width : 0
            implicitHeight: Math.max(16, col.implicitHeight)
            Item { width: 18; height: 18; anchors.verticalCenter: parent.verticalCenter
                Sym { anchors.centerIn: parent; name: row.symbol; size: 12; color: Theme.accent } }
            Column {
                id: col
                x: 26
                width: tc.width - 26
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                Item {
                    width: parent.width
                    height: nm.implicitHeight
                    Text { id: nm; text: row.name; color: Theme.label; font.pixelSize: 13; elide: Text.ElideRight
                        width: Math.min(implicitWidth, parent.width - badges.width - 6) }
                    Row {
                        id: badges
                        x: nm.width + 6
                        anchors.verticalCenter: nm.verticalCenter
                        spacing: 4
                        Rectangle { visible: row.needsSpecs; width: ns.implicitWidth + 10; height: ns.implicitHeight + 2; radius: height / 2; color: Qt.rgba(1, 1, 1, 0.1)
                            Text { id: ns; anchors.centerIn: parent; text: qsTr("Needs specs"); color: Theme.label; font.pixelSize: 10; font.weight: Font.Medium } }
                        Rectangle { visible: row.notOwned; width: no.implicitWidth + 10; height: no.implicitHeight + 2; radius: height / 2
                            color: Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.25)
                            Text { id: no; anchors.centerIn: parent; text: qsTr("Not owned"); color: Theme.label; font.pixelSize: 10; font.weight: Font.DemiBold } }
                    }
                }
                Text { text: row.subtitle; color: Theme.secondaryLabel; font.pixelSize: 10; elide: Text.ElideRight; width: parent.width }
            }
        }
    }
    Component {
        id: wearCell
        Item {
            implicitHeight: 16
            Text { visible: row.wear < 0; text: "—"; color: Theme.secondaryLabel; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
            Row {
                visible: row.wear >= 0
                spacing: 4
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    width: 40; height: 5; radius: 2.5; color: Qt.rgba(1, 1, 1, 0.15)
                    anchors.verticalCenter: parent.verticalCenter
                    Rectangle { width: Math.max(5, parent.width * row.wear); height: parent.height; radius: 2.5
                        color: row.wearState === "worn" ? Theme.danger : row.wearState === "soon" ? Theme.warning : Theme.ok }
                }
                Sym { visible: row.wearState === "worn" || row.wearState === "soon"; name: "exclamationmark.triangle.fill"; size: 10
                    color: row.wearState === "worn" ? Theme.danger : Theme.warning; anchors.verticalCenter: parent.verticalCenter }
            }
            MouseArea { id: wm; anchors.fill: parent; hoverEnabled: true }
            ToolTipHelp { text: row.wearText; shown: wm.containsMouse }
        }
    }

    Menu {
        id: menu
        property var ids: []
        MenuItem { text: qsTr("Mark as Owned"); onTriggered: page.inventory.markToolsOwned(menu.ids) }
        MenuItem { text: qsTr("Duplicate"); onTriggered: table.selection = page.inventory.duplicate("tools", menu.ids) }
        MenuSeparator {}
        MenuItem { text: qsTr("Delete…"); onTriggered: deleteDialog.open() }
    }

    Dialog {
        id: deleteDialog
        title: table.selection.length === 1 ? qsTr("Delete this tool?") : qsTr("Delete %1 tools?").arg(table.selection.length)
        standardButtons: Dialog.Cancel | Dialog.Ok
        anchors.centerIn: parent
        modal: true
        Label { text: qsTr("This can't be undone.") }
        onAccepted: { page.inventory.remove("tools", table.selection); table.selection = [] }
    }


    Component.onCompleted: {
        if (page.app.toolToShow !== "") { show(page.app.toolToShow); page.app.toolToShow = "" }
        else if (rows.length > 0) table.selection = [rows[0].id]
    }
}
