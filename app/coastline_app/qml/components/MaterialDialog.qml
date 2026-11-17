import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "."

// Customising one stock item's material: its own definition, never editing the shared one.
// Port of MaterialEditor (Views/Library/MaterialsPage.swift).
Dialog {
    id: dlg
    property var app
    property string stockId: ""
    property var m: ({})
    property var draft: ({})
    title: m.builtIn ? qsTr("Customize Material") : qsTr("Edit Material Properties")
    modal: true
    anchors.centerIn: Overlay.overlay
    width: 480
    height: Math.min(700, Overlay.overlay ? Overlay.overlay.height - 60 : 700)
    standardButtons: Dialog.Cancel | Dialog.Apply
    function begin(id) { stockId = id; m = app.inventoryExtras.material(id); draft = Object.assign({}, m); error.text = ""; open() }
    function set(k, v) { var d = Object.assign({}, draft); d[k] = v; draft = d }
    onApplied: { var e = app.inventoryExtras.customizeMaterial(stockId, draft); if (e === "") close(); else error.text = e }
    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        ColumnLayout {
            width: parent.width
            spacing: 10
            Label { text: qsTr("Applies to this stock item."); color: Theme.secondary }
            Label { id: error; visible: text !== ""; color: Theme.danger; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Card {
                title: qsTr("Material")
                FieldRow { label: qsTr("Name"); TextEdit { value: dlg.draft.name || ""; onCommitted: t => dlg.set("name", t) } }
                FieldRow { label: qsTr("Grade"); TextEdit { value: dlg.draft.grade || ""; onCommitted: t => dlg.set("grade", t) } }
                FieldRow { label: qsTr("Hardness"); TextEdit { value: dlg.draft.hardness || ""; onCommitted: t => dlg.set("hardness", t) } }
                FieldRow { label: qsTr("Density"); NumberEdit { value: dlg.draft.density; unit: "g/cm³"; onCommitted: v => dlg.set("density", v) } }
            }
            Card {
                title: qsTr("Cutting data")
                FieldRow { label: qsTr("Min. surface speed"); NumberEdit { value: dlg.draft.speedMin; unit: "m/min"; onCommitted: v => dlg.set("speedMin", v) } }
                FieldRow { label: qsTr("Max. surface speed"); NumberEdit { value: dlg.draft.speedMax; unit: "m/min"; onCommitted: v => dlg.set("speedMax", v) } }
                FieldRow { label: qsTr("Chip load factor"); NumberEdit { value: dlg.draft.chip_load_factor; unit: "×"; onCommitted: v => dlg.set("chip_load_factor", v) } }
                FieldRow { label: qsTr("Max. stepover"); NumberEdit { value: dlg.draft.adaptive_stepover_max; unit: "× ⌀"; onCommitted: v => dlg.set("adaptive_stepover_max", v) } }
                FieldRow { label: qsTr("Max. adaptive depth"); NumberEdit { value: dlg.draft.adaptive_depth_max; unit: "× ⌀"; onCommitted: v => dlg.set("adaptive_depth_max", v) } }
                FieldRow { label: qsTr("Max. slot depth"); NumberEdit { value: dlg.draft.slot_depth_max; unit: "× ⌀"; onCommitted: v => dlg.set("slot_depth_max", v) } }
                FieldRow { label: qsTr("Cutting force"); NumberEdit { value: dlg.draft.specific_cutting_force; unit: "N/mm²"; onCommitted: v => dlg.set("specific_cutting_force", v) } }
                FieldRow { label: qsTr("Tool wear factor"); NumberEdit { value: dlg.draft.tool_wear_factor; unit: "×"; onCommitted: v => dlg.set("tool_wear_factor", v) } }
            }
            Card {
                title: qsTr("Source and notes")
                FieldRow { label: qsTr("Source"); TextEdit { value: dlg.draft.source || ""; onCommitted: t => dlg.set("source", t) } }
                FieldRow { label: qsTr("Lubricant"); TextEdit { value: dlg.draft.lubricant || ""; onCommitted: t => dlg.set("lubricant", t) } }
                FieldRow { label: qsTr("Chips"); TextEdit { value: dlg.draft.chips || ""; onCommitted: t => dlg.set("chips", t) } }
                FieldRow { label: qsTr("Tooling"); TextEdit { value: dlg.draft.tooling || ""; onCommitted: t => dlg.set("tooling", t) } }
                FieldRow { label: qsTr("Notes"); TextEdit { value: dlg.draft.notes || ""; onCommitted: t => dlg.set("notes", t) } }
            }
        }
    }
}
