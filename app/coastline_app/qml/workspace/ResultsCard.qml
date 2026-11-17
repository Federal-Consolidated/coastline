import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import "../components"

// The generated programs with their checks, and what to do with them: run on the machine,
// export the G-code or selected files. Port of ResultsSection and ProgramRow.
Card {
    id: card
    property var ws
    property var app
    property bool delivery: true
    title: qsTr("Result")
    info: qsTr("Every program is checked independently against the machine's limits before it can be exported. Always air-cut a new program first (spindle off, Z raised).")
    readonly property var r: (ws.revision, ws.results())
    readonly property bool ready: card.r.passed && card.r.programs.length > 0 && card.r.reviewed && !card.r.waitsForWorkholding
    ValueRow { label: qsTr("Machining time"); value: "≈ " + card.r.total }
    IconText { visible: card.r.backing !== ""; symbol: "lightbulb"; text: card.r.backing; color: Theme.warning; fontSize: 12; wrap: true; Layout.fillWidth: true }
    IconText { visible: card.r.travelIssue !== ""; symbol: "xmark.octagon.fill"; text: card.r.travelIssue + qsTr(". Move the stock on the table, use a shorter stick-out, or turn the part.")
        color: Theme.danger; fontSize: 12; wrap: true; Layout.fillWidth: true }
    ValueRow { label: qsTr("Tool changes"); value: String(card.r.toolChanges) }
    Repeater {
        model: card.r.programs
        delegate: ColumnLayout {
            id: prog
            required property var modelData
            property bool openSet: false
            property bool openValue: false
            readonly property bool open: openSet ? openValue : !modelData.passed
            Layout.fillWidth: true
            spacing: 4
            Item {
                Layout.fillWidth: true
                implicitHeight: 24
                MouseArea { anchors.fill: parent; onClicked: { prog.openValue = !prog.open; prog.openSet = true } }
                Row {
                    spacing: 6
                    anchors.verticalCenter: parent.verticalCenter
                    Sym { name: "chevron.right"; size: 10; weight: "bold"; rotation: prog.open ? 90 : 0; anchors.verticalCenter: parent.verticalCenter }
                    Sym { name: prog.modelData.passed ? "checkmark.shield.fill" : "xmark.shield.fill"; size: 13; color: prog.modelData.passed ? Theme.ok : Theme.danger; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: prog.modelData.label; color: Theme.label; font.pixelSize: 13; elide: Text.ElideRight; width: Math.min(implicitWidth, card.width - 150); anchors.verticalCenter: parent.verticalCenter }
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    Rectangle {
                        visible: prog.modelData.notes > 0
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(16, nt.implicitWidth + 10); height: 14; radius: 7
                        color: Qt.rgba((prog.modelData.passed ? Theme.warning : Theme.danger).r, (prog.modelData.passed ? Theme.warning : Theme.danger).g, (prog.modelData.passed ? Theme.warning : Theme.danger).b, 0.25)
                        Text { id: nt; anchors.centerIn: parent; text: prog.modelData.notes; color: Theme.label; font.pixelSize: 9; font.weight: Font.DemiBold }
                    }
                    Text { text: prog.modelData.minutes; color: Theme.secondaryLabel; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                }
            }
            ColumnLayout {
                visible: prog.open
                Layout.fillWidth: true
                Layout.leftMargin: 16
                spacing: 4
                Text { text: prog.modelData.opsLine; color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Repeater {
                    model: prog.modelData.issues
                    delegate: IconText { required property var modelData; Layout.fillWidth: true; wrap: true; text: modelData.message
                        symbol: modelData.severity === "error" ? "xmark.octagon.fill" : modelData.severity === "warning" ? "exclamationmark.triangle.fill" : "info.circle"
                        color: modelData.severity === "error" ? Theme.danger : modelData.severity === "warning" ? Theme.warning : Theme.secondaryLabel }
                }
                Repeater {
                    model: prog.modelData.warnings
                    delegate: IconText { required property var modelData; Layout.fillWidth: true; wrap: true; symbol: "exclamationmark.triangle"; text: modelData; color: Theme.warning }
                }
                IconText { visible: prog.modelData.stickout !== ""; Layout.fillWidth: true; wrap: true; symbol: "ruler"; text: prog.modelData.stickout; color: Theme.secondaryLabel }
            }
        }
    }
    GlassButton {
        visible: card.delivery
        title: qsTr("Run on Machine…")
        symbol: "play.fill"
        prominent: true
        large: false
        enabled: card.ready && !card.r.jobRunning
        help: qsTr("Open the guided runner for setup, probing, air cuts and cuts. Each program starts only when you press Run.")
        onClicked: card.ws.runOnMachine()
    }
    ColumnLayout {
        visible: card.delivery && card.r.waitsForWorkholding
        spacing: 2
        Text { text: qsTr("Running waits for the workholding to buy: it holds a setup. See the Shopping List."); color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        Text { text: qsTr("Open the Shopping List"); color: Theme.systemBlue; font.pixelSize: 10
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: card.app.page = "shopping" } }
    }
    LinkButton { visible: card.delivery && card.r.jobRunning; symbol: "list.bullet.clipboard"; title: qsTr("Return to Guided Mode"); onClicked: card.ws.openGuidedMode() }
    GlassButton {
        visible: card.delivery
        title: qsTr("Export G-code Only…")
        symbol: "square.and.arrow.up"
        large: false
        enabled: card.r.passed && card.r.programs.length > 0
        onClicked: folderDialog.open()
    }
    LinkButton {
        visible: card.delivery
        symbol: "checklist"
        title: qsTr("Export Selected Code…")
        enabled: card.ready
        onClicked: { card.ws.codeFiles(); selectDialog.open() }
    }
    IconText {
        visible: card.r.failedCount > 0
        symbol: "xmark.shield"
        text: card.r.failedCount === 1 ? qsTr("Fix the program that failed the safety check to export.") : qsTr("Fix the %1 programs that failed the safety check to export.").arg(card.r.failedCount)
        color: Theme.secondaryLabel
        wrap: true
        Layout.fillWidth: true
    }
    FolderDialog {
        id: folderDialog
        title: qsTr("Export the programs to")
        onAccepted: card.ws.exportPrograms(String(selectedFolder))
    }
    Dialog {
        id: selectDialog
        title: qsTr("Export Selected Code")
        modal: true
        anchors.centerIn: Overlay.overlay
        width: 460
        standardButtons: Dialog.Cancel | Dialog.Ok
        property var files: (card.ws.revision, selectDialog.visible ? card.ws.codeFiles() : [])
        property var picked: ({})
        ColumnLayout {
            anchors.fill: parent
            Label { visible: selectDialog.files.length === 0; text: qsTr("Preparing the files…"); color: Theme.secondary }
            Repeater {
                model: selectDialog.files
                delegate: CheckBox {
                    required property var modelData
                    text: modelData.title
                    checked: true
                    Component.onCompleted: selectDialog.picked[modelData.id] = true
                    onToggled: selectDialog.picked[modelData.id] = checked
                }
            }
        }
        onAccepted: selectFolder.open()
        FolderDialog {
            id: selectFolder
            title: qsTr("Export to")
            onAccepted: card.ws.exportSelectedCode(Object.keys(selectDialog.picked).filter(k => selectDialog.picked[k]), String(selectedFolder))
        }
    }
}
