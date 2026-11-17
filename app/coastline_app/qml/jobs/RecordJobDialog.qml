import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import "../components"

// Recording a job after it ran: how it went, what you measured, the stock left, notes and photos.
// Port of RecordJobSheet (Views/JournalViews.swift).
Dialog {
    id: dlg
    property var journal
    readonly property var d: (journal.revision, journal.draftInfo())
    visible: d.part !== undefined
    modal: true
    anchors.centerIn: Overlay.overlay
    width: 500
    height: Math.min(680, Overlay.overlay ? Overlay.overlay.height - 60 : 680)
    title: qsTr("Record %1").arg(d.part || "")
    onRejected: journal.cancelDraft()
    footer: DialogButtonBox {
        Button { text: qsTr("Cancel"); DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
        Button { text: qsTr("Record"); highlighted: true; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
        onAccepted: dlg.journal.commitDraft()
        onRejected: dlg.journal.cancelDraft()
    }
    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        ColumnLayout {
            width: parent.width
            spacing: 10
            Card {
                title: qsTr("How it went")
                FieldRow {
                    label: qsTr("Result")
                    ComboBox {
                        width: parent.width
                        readonly property var opts: dlg.d.outcomes || []
                        model: opts.map(o => o.title)
                        currentIndex: Math.max(0, opts.findIndex(o => o.value === dlg.d.outcome))
                        onActivated: i => dlg.journal.setDraftField("outcome", opts[i].value)
                    }
                }
                FieldRow { label: qsTr("Surface finish"); Slider { width: parent.width; from: 1; to: 5; stepSize: 1; snapMode: Slider.SnapAlways; value: dlg.d.finish || 3; onMoved: dlg.journal.setDraftField("finish", value) } }
                CheckBox { text: qsTr("Chatter or squeal while cutting"); checked: dlg.d.chatter === true; onToggled: dlg.journal.setDraftField("chatter", checked) }
                Repeater {
                    model: dlg.d.chatter ? dlg.d.tools : []
                    delegate: CheckBox { required property var modelData; text: modelData.name; checked: modelData.chatter; leftPadding: 30; onToggled: dlg.journal.setChatterTool(modelData.id, checked) }
                }
            }
            Card {
                visible: (dlg.d.measurements || []).length > 0
                title: qsTr("What you measured")
                Repeater {
                    model: dlg.d.measurements || []
                    delegate: FieldRow {
                        required property var modelData
                        required property int index
                        label: modelData.what + " (" + modelData.expected.toFixed(3) + ")"
                        NumberEdit { optional: true; value: modelData.measured; onCommitted: v => dlg.journal.setDraftMeasured(index, v) }
                    }
                }
            }
            Card {
                visible: (dlg.d.remnant || -1) >= 0
                title: qsTr("Stock")
                CheckBox { text: qsTr("Put the rest back as an offcut"); checked: dlg.d.putBack === true; onToggled: dlg.journal.setDraftField("putBack", checked) }
                FieldRow { visible: dlg.d.putBack === true; label: qsTr("Length left"); NumberEdit { value: dlg.d.remnant; onCommitted: v => dlg.journal.setDraftField("remnant", v) } }
            }
            Card {
                title: qsTr("Notes and photos")
                TextArea { Layout.fillWidth: true; placeholderText: qsTr("Notes"); wrapMode: Text.WordWrap; text: dlg.d.notes || ""; onEditingFinished: dlg.journal.setDraftField("notes", text) }
                Label { visible: (dlg.d.photos || []).length > 0; text: qsTr("%1 photo(s)").arg((dlg.d.photos || []).length); color: Theme.secondary }
                Button { text: qsTr("Add Photos…"); onClicked: photoDialog.open() }
                Label { text: qsTr("Recording adds each tool's cutting time to its wear and takes one piece of the stock out of the inventory."); color: Theme.tertiary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
            }
        }
    }
    FileDialog {
        id: photoDialog
        fileMode: FileDialog.OpenFiles
        nameFilters: [qsTr("Images (*.jpg *.jpeg *.png *.heic)")]
        onAccepted: dlg.journal.addDraftPhotos(selectedFiles.map(u => String(u)))
    }
}
