import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// A guided job running on the machine, one step at a time: requirements, steps by hand,
// tool changes, measuring, and programs run (or air cut) through Machine Control.
// Port of Views/Jobs/JobRunner.swift.
ScrollView {
    id: view
    property var app
    property var jobs: app.jobs
    property var mill: app.mill
    property bool clear: false
    property var ticked: ({})
    readonly property var r: (jobs.revision, mill.state, jobs.runState())
    readonly property var st: r.step || null
    contentWidth: availableWidth
    onStChanged: { clear = false }

    ColumnLayout {
        width: view.availableWidth - 24
        x: 12
        spacing: 12
        Item { Layout.preferredHeight: 6 }
        RowLayout {
            Layout.fillWidth: true
            Label { text: view.r.title || ""; font.pixelSize: 18; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.WordWrap }
            Chip { visible: view.r.simulated === true; text: qsTr("Simulation") }
        }
        Label { visible: view.r.simulated === true; text: qsTr("On the Simulated Mill: nothing moves; the preview draws each program as it runs."); color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }

        // The steps.
        Flow {
            Layout.fillWidth: true
            spacing: 4
            Repeater {
                model: view.r.steps || []
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: 26; height: 26; radius: 13
                    color: modelData.current ? Theme.accent : modelData.done ? "#4a4a4e" : Theme.card
                    Label { anchors.centerIn: parent; text: modelData.done ? "✓" : String(index + 1); font.pixelSize: 11 }
                    ToolTip.visible: ma.containsMouse
                    ToolTip.text: modelData.setup + " · " + modelData.title
                    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true }
                }
            }
        }

        // Requirements, before the first step.
        Card {
            visible: view.r.index === -1
            title: qsTr("Before you start")
            Label { text: qsTr("On the machine, each of these must be true. Tick each one; the job starts when all are."); color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Repeater {
                model: view.r.requirements || []
                delegate: CheckBox { required property var modelData; required property int index; text: modelData; checked: view.ticked[index] === true
                    onToggled: { var t = Object.assign({}, view.ticked); t[index] = checked; view.ticked = t } }
            }
            RowLayout {
                Button { text: qsTr("End Job"); onClicked: view.jobs.endRun() }
                Item { Layout.fillWidth: true }
                Button { text: qsTr("▶  Start"); highlighted: true
                    enabled: (view.r.requirements || []).every((x, i) => view.ticked[i] === true)
                    onClicked: view.jobs.nextStep() }
            }
        }

        // Finished.
        Card {
            visible: view.r.finished === true
            title: qsTr("Done")
            Label { text: qsTr("%1 is done. Vacuum the chips; never use compressed air on the machine.").arg(view.r.title || ""); wrapMode: Text.WordWrap; Layout.fillWidth: true }
            RowLayout {
                Button { text: qsTr("Back"); onClicked: view.jobs.backStep() }
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Close the Job"); highlighted: true; onClicked: view.jobs.endRun() }
            }
        }

        // The current step.
        Card {
            visible: view.st !== null
            title: view.st ? view.st.setup + " · " + qsTr("step %1 of %2").arg(view.r.index + 1).arg(view.r.count) : ""
            Label { text: view.st ? view.st.title : ""; font.pixelSize: 16; font.weight: Font.DemiBold; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Label { visible: view.st && view.st.text !== ""; text: view.st ? view.st.text : ""; textFormat: Text.MarkdownText; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Repeater {
                model: view.st ? view.st.items : []
                delegate: Label { required property var modelData; required property int index; text: (index + 1) + ".  " + modelData; textFormat: Text.MarkdownText; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            }
            Label { visible: view.st && view.st.tool !== null; text: view.st && view.st.tool ? qsTr("%1 in the %2 collet. %3").arg(view.st.tool.name).arg(view.st.tool.collet).arg(view.st.tool.fitting) : ""; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Label {
                visible: view.st && view.st.check !== null
                text: view.st && view.st.check ? qsTr("%1: %2 mm ± %3. If out of tolerance, keep the stock clamped, correct the problem and measure again.").arg(view.st.check.what).arg(view.st.check.expected.toFixed(3)).arg(view.st.check.tolerance.toFixed(3)) : ""
                wrapMode: Text.WordWrap; Layout.fillWidth: true
            }

            // A step by hand.
            ColumnLayout {
                visible: view.st && view.st.program === null
                Layout.fillWidth: true
                CheckBox { id: confirmed; visible: view.st && view.st.caution !== ""; text: view.st ? view.st.caution : "" }
                RowLayout {
                    Button { text: qsTr("Back"); onClicked: view.jobs.backStep() }
                    Item { Layout.fillWidth: true }
                    Button { text: qsTr("✓  Done"); highlighted: true; enabled: !(view.st && view.st.caution !== "") || confirmed.checked; onClicked: { confirmed.checked = false; view.jobs.nextStep() } }
                }
            }

            // A program.
            ColumnLayout {
                visible: view.st && view.st.program !== null
                Layout.fillWidth: true
                readonly property var m: view.st && view.r.step ? (view.r.step.mill || {}) : {}
                readonly property var status: m.status || null
                readonly property bool running: status !== null && status.outcome === "running"
                readonly property bool done: view.st ? view.st.done : false
                Label {
                    visible: view.r.simulated === true && parent.m.open === true && parent.m.simulated !== true
                    text: qsTr("⚠  A machine is connected. Disconnect it to simulate."); color: Theme.warning
                }
                RowLayout {
                    visible: parent.m.open !== true
                    Label { text: view.r.simulated ? qsTr("The Simulated Mill is not running.") : qsTr("Connect to the machine to run this step."); color: view.r.simulated ? Theme.secondary : Theme.warning; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    Button { text: view.r.simulated ? qsTr("Start the Simulated Mill") : qsTr("Connect"); onClicked: view.r.simulated ? view.mill.connectSimulator() : view.mill.connect() }
                }
                ProgressBar { visible: parent.status !== null; value: parent.status ? parent.status.fraction : 0; Layout.fillWidth: true }
                Label {
                    visible: parent.status !== null
                    text: !parent.status ? "" : parent.status.outcome === "running" ? (parent.status.airCut ? qsTr("Air cut running…") : qsTr("Running…"))
                        : parent.status.outcome === "completed" ? (parent.status.airCut ? qsTr("Air cut done. Check the moves, then Cut.") : view.r.simulated ? qsTr("Done on the Simulated Mill.") : qsTr("Done."))
                        : parent.status.outcome === "failed" ? qsTr("Stopped: %1").arg(parent.status.failure) : qsTr("Stopped.")
                    color: !parent.status ? Theme.text : parent.status.outcome === "failed" ? Theme.danger : parent.status.outcome === "stopped" ? Theme.warning : Theme.text
                }
                Label { visible: parent.status !== null; text: parent.status ? qsTr("line %1 of %2").arg(parent.status.done).arg(parent.status.total) : ""; color: Theme.secondary; font.pixelSize: Theme.smallFont }
                ProgressBar { visible: (view.r.animation || -1) >= 0; value: view.r.animation; Layout.fillWidth: true }
                RowLayout {
                    visible: parent.running
                    Button { text: qsTr("Feed Hold"); onClicked: view.mill.feedHold() }
                    Button { text: qsTr("Resume"); onClicked: view.mill.resume() }
                    Button { text: qsTr("Stop"); palette.button: "#5a1a16"; onClicked: view.mill.stop() }
                }
                CheckBox {
                    visible: !parent.running && !parent.done && view.r.simulated !== true
                    text: qsTr("The machine is clear, the chip cover is on, and I can reach the E-stop.")
                    checked: view.clear
                    onToggled: view.clear = checked
                }
                Label { visible: !parent.running && !parent.done && (parent.m.gate || "") !== ""; text: parent.m.gate || ""; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
                Label { visible: !parent.running && (parent.m.message || "") !== "" && !(parent.status && parent.status.outcome === "completed"); text: "⚠  " + (parent.m.message || ""); color: Theme.warning; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
                RowLayout {
                    visible: !parent.running
                    Button { text: qsTr("Back"); onClicked: view.jobs.backStep() }
                    Item { Layout.fillWidth: true }
                    Button { visible: parent.parent.done; text: qsTr("Run Again"); onClicked: { view.clear = false; view.jobs.retryStep() } }
                    Button { visible: parent.parent.done; text: qsTr("Next ›"); highlighted: true; onClicked: view.jobs.nextStep() }
                    Button {
                        visible: !parent.parent.done && view.r.simulated !== true && view.st && view.st.program && view.st.program.airCut
                        text: qsTr("Air Cut")
                        enabled: view.clear && (parent.parent.m.gate || "") === ""
                        onClicked: { view.clear = false; view.jobs.runCurrent(true) }
                        ToolTip.visible: hovered; ToolTip.text: qsTr("The whole program 10 mm above the work with the spindle off")
                    }
                    Button {
                        visible: !parent.parent.done
                        text: view.r.simulated ? qsTr("Simulate") : view.st && view.st.program && view.st.program.purpose === "cut" ? qsTr("Cut") : qsTr("Run")
                        highlighted: true
                        enabled: (view.r.simulated || view.clear) && (parent.parent.m.gate || "") === "" && (!view.r.simulated || parent.parent.m.simulated === true)
                        onClicked: { view.clear = false; view.jobs.runCurrent(false) }
                    }
                }
            }
        }
        Button { text: qsTr("End Job"); flat: true; onClicked: view.jobs.endRun() }
    }
}
