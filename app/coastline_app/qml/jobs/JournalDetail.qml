import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// A recorded job (Projects ▸ Job Journal). Port of JournalDetail (Views/JournalViews.swift).
ScrollView {
    id: view
    property var app
    property string entryId: ""
    readonly property var e: (app.journal.revision, app.journal.entryDetail(entryId))
    contentWidth: availableWidth
    ColumnLayout {
        width: view.availableWidth - 32
        x: 16
        spacing: 12
        Item { Layout.preferredHeight: 8 }
        Label { text: view.e.part || ""; font.pixelSize: 20; font.weight: Font.DemiBold }
        Label { text: (view.e.date || "") + " · " + (view.e.outcome || "") + " · " + (view.e.material || "") + " " + (view.e.stock || ""); color: Theme.secondary }
        Card {
            title: qsTr("Programs")
            Repeater {
                model: view.e.programs || []
                delegate: ValueRow { required property var modelData; label: modelData.title; value: modelData.tool + " · " + modelData.minutes + " min" }
            }
        }
        Card {
            visible: (view.e.measurements || []).length > 0
            title: qsTr("Measured")
            Repeater {
                model: view.e.measurements || []
                delegate: ValueRow {
                    required property var modelData
                    label: modelData.what
                    value: (modelData.measured === null || modelData.measured === undefined ? "–" : modelData.measured.toFixed(3)) + " mm (" + modelData.expected.toFixed(3) + " ± " + modelData.tolerance.toFixed(3) + ")"
                    valueColor: modelData.ok === false ? Theme.danger : Theme.text
                }
            }
        }
        Card { visible: (view.e.notes || "") !== ""; title: qsTr("Notes"); Label { text: view.e.notes || ""; wrapMode: Text.WordWrap; Layout.fillWidth: true } }
        Card {
            visible: (view.e.photos || []).length > 0
            title: qsTr("Photos")
            Flow {
                Layout.fillWidth: true
                spacing: 8
                Repeater { model: view.e.photos || []; delegate: Image { required property var modelData; source: "file:///" + modelData.replace(/^\//, ""); width: 160; height: 120; fillMode: Image.PreserveAspectFit } }
            }
        }
        RowLayout {
            Button { visible: (view.e.project || "") !== ""; text: qsTr("Open the Project"); onClicked: { view.app.workspace.openProject(view.e.project); view.app.page = "workspace" } }
            Item { Layout.fillWidth: true }
            Button { text: qsTr("Delete…"); onClicked: confirm.open() }
        }
    }
    Dialog {
        id: confirm
        anchors.centerIn: Overlay.overlay
        modal: true
        title: qsTr("Delete the journal entry for %1?").arg(view.e.part || qsTr("this job"))
        Label { text: qsTr("Its measurements and notes go with it. This can't be undone.") }
        standardButtons: Dialog.Cancel | Dialog.Ok
        onAccepted: view.app.journal.remove(view.entryId)
    }
}
