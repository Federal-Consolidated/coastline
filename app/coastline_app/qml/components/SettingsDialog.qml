import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Settings: appearance, units, machining defaults and the inventory file.
// Port of Views/SettingsView.swift.
Dialog {
    id: dlg
    property var app
    property var settings: app.settings
    title: qsTr("Settings")
    modal: true
    anchors.centerIn: Overlay.overlay
    width: 480
    standardButtons: Dialog.Close
    ColumnLayout {
        anchors.fill: parent
        spacing: 10
        Card {
            title: qsTr("General")
            FieldRow { label: qsTr("Accent"); Segmented { options: [{value: "graphite", title: qsTr("Graphite")}, {value: "charcoal", title: qsTr("Charcoal")}, {value: "steel", title: qsTr("Steel")}]; value: dlg.settings.accent; onPicked: v => dlg.settings.accent = v } }
            FieldRow { label: qsTr("Units"); Segmented { options: [{value: "metric", title: "mm"}, {value: "imperial", title: qsTr("inch")}]; value: dlg.settings.units; onPicked: v => dlg.settings.units = v } }
        }
        Card {
            title: qsTr("Machining")
            CheckBox { text: qsTr("Reference bores on two-sided parts"); checked: dlg.settings.referenceBores; onToggled: dlg.settings.referenceBores = checked }
            FieldRow {
                label: qsTr("Engines at once")
                ComboBox {
                    width: parent.width
                    readonly property var values: [0, 1, 2, 3, 4, 6, 8]
                    model: [qsTr("Automatic"), "1", "2", "3", "4", "6", "8"]
                    currentIndex: Math.max(0, values.indexOf(dlg.settings.engines))
                    onActivated: i => dlg.settings.engines = values[i]
                }
            }
        }
        Card {
            title: qsTr("Inventory")
            Label { text: qsTr("Your tools, stock, fixtures and accessories are saved on this computer."); color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Button { text: qsTr("Reset to Starter Inventory…"); onClicked: confirmReset.open() }
        }
    }
    Dialog {
        id: confirmReset
        anchors.centerIn: Overlay.overlay
        modal: true
        title: qsTr("Replace your inventory with the starter inventory?")
        Label { text: qsTr("Your own tools, stock and fixtures are replaced. This can't be undone."); wrapMode: Text.WordWrap }
        standardButtons: Dialog.Cancel | Dialog.Ok
        onAccepted: dlg.app.inventory.resetToStarter()
    }
}
