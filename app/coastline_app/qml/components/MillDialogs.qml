import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

// The machine's confirmation sheets, available from every page: Home, Spindle start, Run a
// program, Go To, the console and the saved test programs. Port of the sheets in ContentView,
// ControlPage, ManualControls, MillConsole and TestProgramLibrary (Swift).
Item {
    id: dialogs
    required property var mill
    anchors.fill: parent

    // ---- Home
    Dialog {
        id: homeDialog
        modal: true
        anchors.centerIn: parent
        width: 440
        title: qsTr("Home the machine?")
        visible: dialogs.mill.showHomeConfirm
        onClosed: dialogs.mill.showHomeConfirm = false
        ColumnLayout {
            width: parent.width
            spacing: 12
            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap
                text: qsTr("All three axes move to their limit switches: Z first, then X and Y. It takes up to 10 seconds, and the machine does not answer while it homes.") }
            CheckBox { id: homeClear; Layout.fillWidth: true
                text: qsTr("The table and the spindle path are clear, the tool does not touch anything, and I can reach the E-stop.")
                contentItem: Label { leftPadding: homeClear.indicator.width + 6; text: homeClear.text; wrapMode: Text.WordWrap } }
            RowLayout {
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Cancel"); onClicked: homeDialog.close() }
                Button { text: qsTr("Home"); highlighted: true; enabled: homeClear.checked; onClicked: { dialogs.mill.home(); homeDialog.close() } }
            }
        }
        onOpened: homeClear.checked = false
    }

    // ---- Spindle
    Dialog {
        id: spindleDialog
        modal: true
        anchors.centerIn: parent
        width: 440
        title: qsTr("Start the spindle at %1 RPM?").arg(Math.round(dialogs.mill.spindleRPM))
        visible: dialogs.mill.showSpindleConfirm
        onClosed: dialogs.mill.showSpindleConfirm = false
        ColumnLayout {
            width: parent.width
            spacing: 12
            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: qsTr("M3: forward, the cutting direction. The spindle runs until you press Stop.") }
            CheckBox { id: spindleClear; Layout.fillWidth: true
                text: qsTr("The tool is tight in the collet, nothing touches it, and I can reach the E-stop.")
                contentItem: Label { leftPadding: spindleClear.indicator.width + 6; text: spindleClear.text; wrapMode: Text.WordWrap } }
            RowLayout {
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Cancel"); onClicked: spindleDialog.close() }
                Button { text: qsTr("Start"); highlighted: true; enabled: spindleClear.checked; onClicked: { dialogs.mill.spindleOn(); spindleDialog.close() } }
            }
        }
        onOpened: spindleClear.checked = false
    }

    // ---- Run a program
    Dialog {
        id: runDialog
        modal: true
        anchors.centerIn: parent
        width: 520
        property var program: dialogs.mill.programToConfirm
        property var check: { dialogs.mill.state; program; return dialogs.mill.checkConfirm() }
        title: qsTr("Run %1?").arg(program.title || "")
        visible: (program.id || "") !== ""
        onRejected: dialogs.mill.cancelConfirm()
        ColumnLayout {
            width: parent.width
            spacing: 10
            Label { visible: (runDialog.program.detail || "") !== ""; text: runDialog.program.detail || ""; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Label { text: runDialog.program.motion ? qsTr("Spindle-off motion check") : qsTr("Setup program: may probe, change work offsets and run the spindle"); color: Theme.secondary; font.pixelSize: Theme.smallFont }
            ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: 180
                TextArea { readOnly: true; text: runDialog.program.preview || ""; font.family: "Menlo"; font.pixelSize: Theme.smallFont; selectByMouse: true }
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: runDialog.check.ok ? (runDialog.program.motion ? qsTr("Code and machine travel checked") : qsTr("Setup code checked; work moves use controller soft limits")) : (runDialog.check.why || "")
                color: runDialog.check.ok ? Theme.secondary : Theme.warning
            }
            Label { visible: dialogs.mill.message !== ""; text: dialogs.mill.message; color: Theme.warning; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Label { text: qsTr("Feed Hold pauses it, Stop ends it. The red E-stop is always the first stop."); color: Theme.secondary; font.pixelSize: Theme.smallFont; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            CheckBox { id: runClear; Layout.fillWidth: true
                text: qsTr("The machine is clear, the tool does not touch anything, and I can reach the E-stop.")
                contentItem: Label { leftPadding: runClear.indicator.width + 6; text: runClear.text; wrapMode: Text.WordWrap } }
            RowLayout {
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Cancel"); onClicked: { dialogs.mill.cancelConfirm(); runDialog.close() } }
                Button { text: qsTr("Run"); highlighted: true; enabled: runClear.checked && runDialog.check.ok === true; onClicked: dialogs.mill.runConfirmed() }
            }
        }
        onOpened: runClear.checked = false
    }

    // ---- Go to
    Dialog {
        id: goDialog
        modal: true
        anchors.centerIn: parent
        width: 480
        property var request: dialogs.mill.goTo
        property var plan: { request; dialogs.mill.state; return dialogs.mill.goToPlan() }
        title: request.title || ""
        visible: (request.title || "") !== ""
        onRejected: dialogs.mill.cancelGoTo()
        ColumnLayout {
            width: parent.width
            spacing: 10
            Segmented {
                visible: !goDialog.request.fixed
                options: [{value: "work", title: qsTr("Work (G%1)").arg(dialogs.mill.state.activeWCS)}, {value: "machine", title: qsTr("Machine")}]
                value: goDialog.request.frame
                onPicked: v => dialogs.mill.setGoToField("frame", v)
            }
            Repeater {
                model: goDialog.request.fixed ? [] : [{key: "x", title: qsTr("X  table")}, {key: "y", title: qsTr("Y  gantry")}, {key: "z", title: qsTr("Z  spindle")}]
                delegate: FieldRow {
                    required property var modelData
                    label: modelData.title
                    NumberEdit { value: goDialog.request[modelData.key]; optional: true; onCommitted: v => dialogs.mill.setGoToField(modelData.key, v) }
                }
            }
            CheckBox {
                visible: !goDialog.request.fixed
                text: qsTr("Spindle out first, then X and Y, then Z")
                checked: goDialog.request.retractFirst === true
                onToggled: dialogs.mill.setGoToField("retractFirst", checked)
            }
            Label { visible: !goDialog.request.fixed; text: qsTr("Blank: that axis does not move."); color: Theme.secondary; font.pixelSize: Theme.smallFont }
            Rectangle {
                Layout.fillWidth: true
                color: Theme.card
                radius: 8
                implicitHeight: planCol.implicitHeight + 16
                ColumnLayout {
                    id: planCol
                    anchors.fill: parent
                    anchors.margins: 8
                    Repeater {
                        model: goDialog.plan.ok ? goDialog.plan.steps : []
                        Label { required property var modelData; required property int index; text: (index + 1) + ". " + modelData }
                    }
                    Label { visible: goDialog.plan.ok === true; text: qsTr("G-code (mm): ") + (goDialog.plan.code || ""); color: Theme.secondary; font.family: "Menlo"; font.pixelSize: Theme.smallFont; wrapMode: Text.WrapAnywhere; Layout.fillWidth: true }
                    Label { visible: goDialog.plan.ok === false; text: goDialog.plan.why || ""; color: Theme.danger; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                }
            }
            Label { text: qsTr("Rapid moves (G0). Feed Hold pauses them, Stop ends them. The red E-stop is always the first stop."); color: Theme.secondary; font.pixelSize: Theme.smallFont; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Label {
                visible: text !== ""
                color: Theme.warning
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                text: !dialogs.mill.allowJog ? qsTr("Unlock jogging first.") : (dialogs.mill.state.gates && dialogs.mill.state.gates.run) || dialogs.mill.message
            }
            RowLayout {
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Cancel"); onClicked: { dialogs.mill.cancelGoTo(); goDialog.close() } }
                Button { text: qsTr("Go"); highlighted: true
                    enabled: dialogs.mill.allowJog && dialogs.mill.state.gates && dialogs.mill.state.gates.run === "" && goDialog.plan.ok === true
                    onClicked: dialogs.mill.go() }
            }
        }
    }

    // ---- Console
    Dialog {
        id: consoleDialog
        modal: true
        anchors.centerIn: parent
        width: Math.min(760, dialogs.width - 80)
        height: Math.min(520, dialogs.height - 80)
        title: qsTr("Console")
        visible: dialogs.mill.showConsole
        onClosed: dialogs.mill.showConsole = false
        onOpened: dialogs.mill.endHold()
        ColumnLayout {
            anchors.fill: parent
            ListView {
                id: consoleList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: dialogs.mill.console
                onCountChanged: positionViewAtEnd()
                ScrollBar.vertical: ScrollBar {}
                delegate: Text {
                    required property var modelData
                    width: consoleList.width
                    text: (modelData.kind === "sent" ? "› " : modelData.kind === "realtime" ? "⚡ " : "") + modelData.text
                    color: modelData.kind === "error" ? Theme.danger : modelData.kind === "sent" ? Theme.text : modelData.kind === "note" ? Theme.secondary : "#c8c8c8"
                    font.family: "Menlo"
                    font.pixelSize: Theme.smallFont + 1
                    wrapMode: Text.WrapAnywhere
                }
            }
            RowLayout {
                TextField {
                    id: consoleInput
                    Layout.fillWidth: true
                    placeholderText: qsTr("G-code or $ command")
                    font.family: "Menlo"
                    onAccepted: if (text !== "" && dialogs.mill.send(text)) text = ""
                }
                Button { text: qsTr("Send"); onClicked: if (consoleInput.text !== "" && dialogs.mill.send(consoleInput.text)) consoleInput.text = "" }
                Button { text: qsTr("Clear"); onClicked: dialogs.mill.clearConsole() }
                Button { text: qsTr("Done"); onClicked: consoleDialog.close() }
            }
            Label { visible: dialogs.mill.message !== ""; text: dialogs.mill.message; color: Theme.warning }
        }
    }

    // ---- Saved test programs
    Dialog {
        id: libraryDialog
        modal: true
        anchors.centerIn: parent
        width: 660
        height: 500
        title: qsTr("Test Programs")
        visible: dialogs.mill.showProgramLibrary
        onClosed: dialogs.mill.showProgramLibrary = false
        ColumnLayout {
            anchors.fill: parent
            spacing: 10
            Label { text: qsTr("Save your most used motion checks and setup programs. Favorites appear first in the menu."); color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: dialogs.mill.programs
                delegate: RowLayout {
                    required property var modelData
                    width: ListView.view.width
                    spacing: 10
                    Button { text: modelData.favorite ? "★" : "☆"; flat: true; onClicked: dialogs.mill.favoriteProgram(modelData.id) }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Label { text: modelData.title; font.weight: Font.Medium }
                        Label { text: modelData.detail; color: Theme.secondary; font.pixelSize: Theme.smallFont; elide: Text.ElideRight; Layout.fillWidth: true }
                    }
                    Button { text: qsTr("Edit…"); onClicked: editor.edit(modelData) }
                    Button { text: qsTr("Delete"); onClicked: dialogs.mill.removeProgram(modelData.id) }
                }
                Label { anchors.centerIn: parent; visible: parent.count === 0; text: qsTr("No saved programs. Add a program or restore the built-ins below."); color: Theme.secondary }
            }
            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.secondary; font.pixelSize: Theme.smallFont
                text: qsTr("Motion checks allow spindle-off linear moves and dwells, checked against travel. Setup programs also support probing, work offsets, homing and spindle commands through the guided runner's code checks. All programs use millimeters.") }
            RowLayout {
                Button { text: qsTr("Add Program…"); onClicked: editor.edit({id: "", title: "", detail: "", code: "G21\nG90\nM5\n", kind: "motionCheck"}) }
                Button { text: qsTr("Add Built-ins"); onClicked: dialogs.mill.addBuiltIns() }
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Done"); onClicked: libraryDialog.close() }
            }
        }
    }
    Dialog {
        id: editor
        modal: true
        anchors.centerIn: parent
        width: 600
        height: 520
        property string programId: ""
        property string error: ""
        title: programId === "" ? qsTr("New Test Program") : qsTr("Edit Test Program")
        function edit(p) {
            programId = p.id; nameField.text = p.title; detailField.text = p.detail; codeField.text = p.code
            kindPick.value = p.kind; error = ""; open()
        }
        ColumnLayout {
            anchors.fill: parent
            spacing: 8
            TextField { id: nameField; placeholderText: qsTr("Name"); Layout.fillWidth: true }
            TextField { id: detailField; placeholderText: qsTr("Description"); Layout.fillWidth: true }
            Segmented { id: kindPick; options: [{value: "motionCheck", title: qsTr("Motion Check")}, {value: "setup", title: qsTr("Setup Program")}]; onPicked: v => value = v }
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                TextArea { id: codeField; font.family: "Menlo"; font.pixelSize: Theme.smallFont + 1; selectByMouse: true }
            }
            Label { visible: editor.error !== ""; text: editor.error; color: Theme.warning }
            RowLayout {
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Cancel"); onClicked: editor.close() }
                Button {
                    text: qsTr("Save")
                    highlighted: true
                    onClicked: {
                        editor.error = dialogs.mill.saveProgram(editor.programId, nameField.text, detailField.text, codeField.text, kindPick.value)
                        if (editor.error === "") editor.close()
                    }
                }
            }
        }
    }
}
