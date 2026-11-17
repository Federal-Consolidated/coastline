import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Coastline.Viewport
import "../components"

// A guided job: its steps, tools and options with the 3D preview of a program; or, while it
// runs, the runner. Port of Views/Jobs/JobsPage.swift (JobPane, JobDetail) and JobPreview.swift.
SplitView {
    id: pane
    property var app
    property var jobs: app.jobs
    readonly property var d: (jobs.revision, jobs.detail())
    readonly property var run: (jobs.revision, jobs.runState())
    readonly property var pv: (jobs.revision, jobs.preview())

    Loader {
        SplitView.preferredWidth: 440
        SplitView.minimumWidth: 340
        sourceComponent: pane.run.title !== undefined ? runner : detail
    }

    Item {
        SplitView.fillWidth: true
        Viewport {
            id: preview
            anchors.fill: parent
            scene: pane.jobs.viewScene
            Component.onCompleted: pane.jobs.attachViewport(preview)
            Component.onDestruction: pane.jobs.detachViewport(preview)
        }
        Label {
            visible: pane.pv.id === undefined
            anchors.centerIn: parent
            text: qsTr("Press Show on a program step to see its toolpath here.")
            color: Theme.secondary
        }
        Rectangle {
            visible: pane.pv.id !== undefined
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 12
            width: 340
            radius: 12
            color: Qt.rgba(0.08, 0.08, 0.09, 0.92)
            implicitHeight: card.implicitHeight + 20
            ColumnLayout {
                id: card
                anchors.fill: parent
                anchors.margins: 10
                spacing: 4
                Label { text: pane.pv.title || ""; font.weight: Font.DemiBold; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Label {
                    visible: pane.pv.loaded === true
                    text: qsTr("%1 moves · about %2 min").arg(pane.pv.moves || 0).arg(pane.pv.minutes || 0)
                          + ((pane.pv.machineMoves || 0) > 0 ? qsTr(" · %1 machine-coordinate moves (G53) not drawn").arg(pane.pv.machineMoves) : "")
                    color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont
                }
                Repeater { model: pane.pv.changes || []; delegate: Label { required property var modelData; text: "• " + modelData; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont } }
                Repeater { model: pane.pv.issues || []; delegate: Label { required property var modelData; text: Theme.severitySymbol(modelData.severity) + " " + modelData.message; color: Theme.severityColor(modelData.severity); wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont } }
                Label { visible: pane.pv.checking === true; text: qsTr("Checking the cuts against the part…"); color: Theme.secondary; font.pixelSize: Theme.smallFont }
                Label {
                    visible: pane.pv.cut !== undefined
                    text: pane.pv.cut ? qsTr("Removes %1 cm³").arg(pane.pv.cut.removed)
                          + (pane.pv.cut.gouge > 0 ? qsTr(" · ⛔ gouges the part (%1 mm³, red)").arg(pane.pv.cut.gouge) : qsTr(" · no gouge"))
                          + (pane.pv.cut.rapidHits > 0 ? qsTr(" · ⚠ rapids through the part (%1 mm³, yellow)").arg(pane.pv.cut.rapidHits) : "") : ""
                    color: pane.pv.cut && pane.pv.cut.gouge > 0 ? Theme.danger : Theme.secondary
                    wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont
                }
                RowLayout {
                    CheckBox { text: qsTr("Cuts"); checked: pane.pv.showCuts === true; onToggled: pane.jobs.setShowCuts(checked) }
                    CheckBox { visible: pane.pv.hasMachine === true; text: qsTr("Machine"); checked: pane.pv.showMachine === true; onToggled: pane.jobs.setShowMachine(checked) }
                }
            }
        }
    }

    Component {
        id: detail
        ScrollView {
            id: sv
            contentWidth: availableWidth
            ColumnLayout {
                width: sv.availableWidth - 24
                x: 12
                spacing: 12
                Item { Layout.preferredHeight: 6 }
                Label { text: pane.d.title || ""; font.pixelSize: 19; font.weight: Font.DemiBold; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Label { visible: (pane.d.summary || "") !== ""; text: pane.d.summary || ""; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Repeater { model: pane.d.problems || []; delegate: Label { required property var modelData; text: "⛔  " + modelData; color: Theme.danger; wrapMode: Text.WordWrap; Layout.fillWidth: true } }
                RowLayout {
                    Button { text: qsTr("▶  Start Job"); highlighted: true; enabled: (pane.d.problems || []).length === 0; onClicked: pane.jobs.startRun(false) }
                    Button { text: qsTr("Simulate"); enabled: (pane.d.problems || []).length === 0; onClicked: pane.jobs.startRun(true)
                        ToolTip.visible: hovered; ToolTip.text: qsTr("Run it on the Simulated Mill: nothing moves, the preview draws each program") }
                    Item { Layout.fillWidth: true }
                    Button { text: qsTr("Delete…"); onClicked: confirmDelete.open() }
                }
                Card {
                    visible: (pane.d.requirements || []).length > 0
                    title: qsTr("Before you start")
                    Repeater { model: pane.d.requirements || []; delegate: Label { required property var modelData; text: "• " + modelData; wrapMode: Text.WordWrap; Layout.fillWidth: true } }
                }
                Card {
                    visible: (pane.d.options || []).length > 0
                    title: qsTr("Options")
                    Repeater {
                        model: pane.d.options || []
                        delegate: FieldRow {
                            required property var modelData
                            label: modelData.title
                            ComboBox {
                                width: parent.width
                                model: modelData.choices.map(c => c.title)
                                currentIndex: Math.max(0, modelData.choices.findIndex(c => c.id === modelData.value))
                                onActivated: i => pane.jobs.chooseOption(modelData.id, modelData.choices[i].id)
                            }
                        }
                    }
                }
                Repeater {
                    model: pane.d.setups || []
                    delegate: Card {
                        id: setupCard
                        required property var modelData
                        title: modelData.title
                        Label { visible: modelData.summary !== ""; text: modelData.summary; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                        Repeater {
                            model: setupCard.modelData.steps
                            delegate: ColumnLayout {
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                spacing: 2
                                RowLayout {
                                    Layout.fillWidth: true
                                    Label { text: (index + 1) + ". " + modelData.title; font.weight: Font.DemiBold; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    Button { visible: modelData.program !== ""; text: qsTr("Show"); onClicked: pane.jobs.showProgram(modelData.program) }
                                }
                                Label { visible: modelData.text !== ""; text: modelData.text; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
                                Label { visible: modelData.tool !== ""; text: modelData.tool; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
                                Label { visible: modelData.caution !== ""; text: "⚠  " + modelData.caution; color: Theme.warning; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
                            }
                        }
                    }
                }
                Card {
                    visible: (pane.d.tools || []).length > 0
                    title: qsTr("Tools")
                    Repeater { model: pane.d.tools || []; delegate: ValueRow { required property var modelData; label: modelData.name; value: modelData.detail } }
                }
            }
        }
    }

    Component { id: runner; JobRunner { app: pane.app } }

    Dialog {
        id: confirmDelete
        anchors.centerIn: Overlay.overlay
        modal: true
        title: qsTr("Delete %1?").arg(pane.d.title || qsTr("this job"))
        Label { text: qsTr("Its programs and steps are removed from this computer.") }
        standardButtons: Dialog.Cancel | Dialog.Ok
        onAccepted: pane.jobs.deleteJob(pane.d.folder)
    }
}
