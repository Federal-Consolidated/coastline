import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The shared layout of the simpler inventory pages: a table of one list, an Add menu by kind,
// Delete, and an inspector for the selected item (the page supplies its fields).
PageScaffold {
    id: page
    property var inventory: app.inventory
    property string listName: ""
    property string kindEnum: ""          // e.g. "FixtureKind": the Add menu offers each kind
    property string noun: qsTr("item")
    property string addTitle: qsTr("Add")
    property string note: ""              // a GlassCard above the table
    property string noteSymbol: ""
    property string emptyTitle: ""
    property string emptySymbol: ""
    property var columns: []
    property Component itemInspector: null    // gets `item` (JSON) and `set(key, value)` through `page`
    property var extraAddItems: []        // [{title, symbol, action}] before the kinds
    property string search: ""
    property var rows: { inventory.revision; return inventory.simpleRows(listName, search) }
    property string selectedId: table.selection.length === 1 ? table.selection[0] : ""
    property alias table: table
    property var item: { inventory.revision; return selectedId === "" ? ({}) : inventory.item(listName, selectedId) }
    function set(key, value) { inventory.setField(listName, selectedId, key, value) }
    inspector: Component {
        Item {
            ContentUnavailable { visible: page.selectedId === ""; anchors.centerIn: parent; title: qsTr("No %1 Selected").arg(page.noun.charAt(0).toUpperCase() + page.noun.slice(1)); symbol: page.emptySymbol; description: "" }
            ScrollView {
                id: insp
                visible: page.selectedId !== ""
                anchors.fill: parent
                clip: true
                contentWidth: availableWidth
                Loader { x: 10; width: insp.availableWidth - 20; sourceComponent: page.itemInspector }
            }
        }
    }

    inspectorItems: [
        GlassCapsule {
            ToolbarIcon {
                id: addButton
                symbol: "plus"
                chevron: true
                help: page.addTitle
                onClicked: addMenu.popup(addButton, 0, addButton.height + 6)
                Menu {
                    id: addMenu
                    Repeater {
                        model: page.extraAddItems
                        MenuItem { required property var modelData; text: modelData.title; onTriggered: modelData.action() }
                    }
                    MenuSeparator { visible: page.extraAddItems.length > 0 }
                    Repeater {
                        model: page.kindEnum === "" ? [] : page.inventory.choices(page.kindEnum)
                        MenuItem {
                            required property var modelData
                            text: modelData.title
                            onTriggered: { table.selection = [page.inventory.addKind(page.listName, modelData.value)]; page.app.showInspector = true }
                        }
                    }
                }
            }
            ToolbarIcon { symbol: "trash"; enabled: table.selection.length > 0; help: qsTr("Delete the selected %1s (⌫)").arg(page.noun); onClicked: deleteDialog.open() }
        }
    ]

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Rectangle {
            visible: page.note !== ""
            Layout.fillWidth: true
            Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 10; Layout.bottomMargin: 10
            radius: 18
            color: Theme.glass
            border.color: Theme.glassStroke
            implicitHeight: noteRow.implicitHeight + 28
            RowLayout {
                id: noteRow
                x: 14; y: 14
                width: parent.width - 28
                spacing: 8
                Sym { visible: page.noteSymbol !== ""; name: page.noteSymbol; size: 12; color: Theme.secondaryLabel; Layout.alignment: Qt.AlignTop; Layout.topMargin: 1 }
                Text { text: page.note; color: Theme.secondaryLabel; wrapMode: Text.WordWrap; font.pixelSize: 12; Layout.fillWidth: true }
            }
        }
        DataTable {
            id: table
            Layout.fillWidth: true
            Layout.fillHeight: true
            rows: page.rows
            columns: page.columns
            onContextMenuRequested: (ids, x, y) => menu.popup()
        }
    }
    ContentUnavailable {
        visible: page.rows.length === 0 && page.emptyTitle !== ""
        anchors.centerIn: parent
        title: page.emptyTitle
        symbol: page.emptySymbol
        description: ""
    }
    Component {
        id: nameCell
        Row {
            spacing: 6
            width: parent ? parent.width : 0
            Item { width: 18; height: 16; anchors.verticalCenter: parent.verticalCenter
                Sym { anchors.centerIn: parent; name: row.symbol || ""; size: 12; color: Theme.accent } }
            Text { text: row.name; color: Theme.label; font.pixelSize: 13; elide: Text.ElideRight; width: parent.width - 24; anchors.verticalCenter: parent.verticalCenter }
        }
    }
    property alias nameCell: nameCell
    Menu {
        id: menu
        MenuItem { text: qsTr("Duplicate"); onTriggered: table.selection = page.inventory.duplicate(page.listName, table.selection) }
        MenuSeparator {}
        MenuItem { text: qsTr("Delete…"); onTriggered: deleteDialog.open() }
    }
    Dialog {
        id: deleteDialog
        title: table.selection.length === 1 ? qsTr("Delete this %1?").arg(page.noun) : qsTr("Delete %1 %2s?").arg(table.selection.length).arg(page.noun)
        standardButtons: Dialog.Cancel | Dialog.Ok
        anchors.centerIn: parent
        modal: true
        Text { text: qsTr("This can't be undone."); color: Theme.secondaryLabel; font.pixelSize: 12 }
        onAccepted: { page.inventory.remove(page.listName, table.selection); table.selection = [] }
    }
    Component.onCompleted: if (rows.length > 0) table.selection = [rows[0].id]
}
