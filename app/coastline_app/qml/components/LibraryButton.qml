import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

// Import and export of stock or tool libraries (JSON resource libraries): the dialogs and the
// export menu; the toolbar buttons call importLibrary() and exportMenu(at).
// Port of Views/Inventory/ResourceLibraryActions.swift.
Item {
    id: btn
    function importLibrary() { openDialog.open() }
    function exportMenu(at) { menu.popup(at, 0, at.height + 6) }
    property var app
    property string scope: "stock"     // "stock" or "tools"
    property var selection: []
    property var extras: app.inventoryExtras
    property var preview: ({})
    property string policy: "keepExisting"
    Menu {
        id: menu
        MenuItem { text: qsTr("Export Selected…"); enabled: btn.selection.length > 0; onTriggered: { saveDialog.all = false; saveDialog.open() } }
        MenuItem { text: btn.scope === "stock" ? qsTr("Export All Stock…") : qsTr("Export All Tools…"); onTriggered: { saveDialog.all = true; saveDialog.open() } }
    }
    FileDialog {
        id: openDialog
        nameFilters: [qsTr("Libraries (*.json)")]
        onAccepted: { btn.file = String(selectedFile); btn.preview = btn.extras.previewImport(btn.file, btn.policy); importDialog.open() }
    }
    property string file: ""
    FileDialog {
        id: saveDialog
        property bool all: true
        fileMode: FileDialog.SaveFile
        defaultSuffix: "json"
        nameFilters: [qsTr("Libraries (*.json)")]
        currentFile: btn.scope === "stock" ? "Stock.json" : "Tools.json"
        onAccepted: btn.extras.exportLibrary(String(selectedFile), btn.scope, all ? [] : btn.selection)
    }
    Dialog {
        id: importDialog
        title: qsTr("Import %1").arg(btn.preview.name || qsTr("library"))
        modal: true
        anchors.centerIn: Overlay.overlay
        width: 520
        standardButtons: Dialog.Cancel | Dialog.Ok
        onAccepted: { var e = btn.extras.applyImport(); if (e !== "") btn.extras.lastError = e }
        ColumnLayout {
            anchors.fill: parent
            spacing: 8
            Label { visible: (btn.preview.error || "") !== ""; text: btn.preview.error || ""; color: Theme.danger; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            FieldRow {
                label: qsTr("Existing entries")
                ChoiceEdit {
                    choices: [{value: "keepExisting", title: qsTr("Keep mine")}, {value: "replaceExisting", title: qsTr("Replace mine")}, {value: "addAsCopy", title: qsTr("Add as copies")}]
                    value: btn.policy
                    onCommitted: v => { btn.policy = v; btn.preview = btn.extras.previewImport(btn.file, v) }
                }
            }
            Label { visible: (btn.preview.error || "") === ""; text: qsTr("%1 added · %2 replaced · %3 kept · %4 copies").arg(btn.preview.added || 0).arg(btn.preview.replaced || 0).arg(btn.preview.kept || 0).arg(btn.preview.copied || 0); color: Theme.secondary }
            ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(300, contentHeight)
                clip: true
                model: btn.preview.rows || []
                delegate: Label { required property var modelData; width: ListView.view.width; text: modelData.action + " · " + modelData.name + "  " + modelData.detail; elide: Text.ElideRight; color: Theme.text }
            }
            Repeater { model: btn.preview.warnings || []; delegate: Label { required property var modelData; text: "⚠  " + modelData; color: Theme.warning; wrapMode: Text.WordWrap; Layout.fillWidth: true } }
        }
    }
}
