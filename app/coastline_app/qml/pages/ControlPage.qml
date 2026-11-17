import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Coastline.Viewport
import "../components"

// Machine Control: the machine's state and messages, a running program's progress, and the
// controls in the inspector (position, jog, go to, test programs, spindle, overrides,
// diagnostics). Arrow keys jog while jogging is unlocked. Port of Views/Control/ControlPage.swift
// and ControlInspector.swift.
PageScaffold {
    id: page
    property var mill: app.mill
    property var s: mill.state
    property string frame: "work"
    title: qsTr("Machine Control")
    subtitle: page.s.stateWord || ""
    inspectorWidth: 320
    focus: true
    readonly property var cm: (page.app.controlMachine.revision, page.app.controlMachine.info())
    readonly property bool canSetup: page.s.gates !== undefined && page.s.gates.setup === ""

    function kindColor(k) { return k === "ok" ? Theme.ok : k === "danger" ? Theme.danger : k === "warning" ? Theme.warning : k === "active" ? Theme.accent : Theme.secondaryLabel }

    // Jog keys: ↑ ↓ the table (X− up, X+ down), ← → the gantry (Y), Page Up / Page Down or ⇧↑ ⇧↓ the spindle (Z+ out, Z− in).
    function keyJog(event) {
        var shift = event.modifiers & Qt.ShiftModifier
        if (event.key === Qt.Key_Up && !shift) return [-1, 0, 0]
        if (event.key === Qt.Key_Down && !shift) return [1, 0, 0]
        if (event.key === Qt.Key_Left) return [0, -1, 0]
        if (event.key === Qt.Key_Right) return [0, 1, 0]
        if (event.key === Qt.Key_PageUp || (event.key === Qt.Key_Up && shift)) return [0, 0, 1]
        if (event.key === Qt.Key_PageDown || (event.key === Qt.Key_Down && shift)) return [0, 0, -1]
        return null
    }
    Keys.onPressed: event => {
        var v = keyJog(event)
        if (!v || !mill.allowJog || (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) return
        event.accepted = true
        if (event.isAutoRepeat) return
        if (mill.jogHold) mill.startHold(v[0], v[1], v[2]); else mill.jog(v[0], v[1], v[2])
    }
    Keys.onReleased: event => {
        if (keyJog(event) && !event.isAutoRepeat) { event.accepted = true; mill.endHold() }
    }
    Component.onDestruction: { mill.endHold(); mill.allowJog = false }

    function stateSymbol(w) {
        return w === "Idle" ? "checkmark.circle.fill" : (w === "Alarm" || w === "No reply") ? "xmark.octagon.fill"
             : (w === "Hold" || w === "Door") ? "pause.circle.fill" : ["Run", "Jog", "Home", "Homing"].indexOf(w) >= 0 ? "arrow.triangle.2.circlepath" : "circle.dashed"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        // The status bar.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 36
            color: Theme.panelBackground
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12; anchors.rightMargin: 12
                spacing: 10
                SmallButton { title: qsTr("Guided Mode"); symbol: "list.bullet.clipboard"; help: qsTr("Open projects and guided jobs"); onClicked: page.app.workspace.openGuidedMode() }
                SmallButton { title: qsTr("Workspace"); symbol: "cube.transparent"; help: qsTr("Return to the part setup and toolpaths"); onClicked: page.app.page = "workspace" }
                Rectangle { implicitWidth: 1; implicitHeight: 18; color: Theme.separator }
                Text { text: page.app.controlMachineName; color: Theme.label; font.pixelSize: 12; font.weight: Font.Medium; elide: Text.ElideRight; Layout.maximumWidth: 160 }
                Row { visible: page.s.simulated === true; spacing: 4
                    Sym { name: "desktopcomputer"; size: 10; color: Theme.secondaryLabel; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: qsTr("Simulated"); color: Theme.secondaryLabel; font.pixelSize: 10 } }
                Badge { text: page.s.stateWord || ""; tint: page.kindColor(page.s.stateKind); symbol: page.stateSymbol(page.s.stateWord || "") }
                Text { visible: page.s.homed === true; text: qsTr("Homed"); color: Theme.secondaryLabel; font.pixelSize: 10 }
                Item { Layout.fillWidth: true }
                SmallButton { visible: page.s.open === true; title: qsTr("Disconnect"); symbol: "cable.connector.slash"; onClicked: page.mill.disconnect() }
                SmallButton { visible: page.s.open !== true; title: qsTr("Connect"); symbol: "cable.connector"; onClicked: page.mill.connect() }
                SmallButton { visible: page.s.open !== true; title: qsTr("Digital Machine"); symbol: "desktopcomputer"
                    help: qsTr("Open a simulated controller to practice homing, jogging and work offsets without hardware"); onClicked: page.mill.connectSimulator() }
                SmallButton { symbol: "terminal"; implicitWidth: 26; help: qsTr("Open the machine console"); onClicked: page.mill.showConsole = true }
            }
        }
        // The notice row.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 48
            color: Theme.panelBackground
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12; anchors.rightMargin: 12
                spacing: 10
                Row {
                    Layout.preferredWidth: 125
                    spacing: 5
                    Sym { name: "scope"; size: 10; color: page.s.probeTripped ? Theme.warning : Theme.secondaryLabel; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: page.s.probe || ""; color: page.s.probeTripped ? Theme.warning : Theme.secondaryLabel; font.pixelSize: 10 }
                    MouseArea { id: probeHover; width: 120; height: 16; hoverEnabled: true }
                    ToolTipHelp { text: qsTr("The probe input reports contact, not whether the cable is plugged in."); shown: probeHover.containsMouse }
                }
                Text {
                    Layout.fillWidth: true
                    text: (page.s.notice || "") === "" ? qsTr("Machine status and setup messages appear here.") : page.s.notice
                    color: (page.s.notice || "") === "" ? Theme.secondaryLabel : Theme.warning
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
                SmallButton { title: page.s.homing ? qsTr("Homing…") : qsTr("Home"); symbol: "house"; enabled: page.mill.canHome
                    help: page.s.simulated ? qsTr("Home the digital machine") : qsTr("Home the machine before jogging or setting work zero"); onClicked: page.mill.requestHome() }
                SmallButton { visible: page.s.needsReset === true; title: qsTr("Reset"); symbol: "arrow.counterclockwise"; onClicked: page.mill.softReset() }
            }
        }
        // A program's progress.
        Rectangle {
            id: prog
            visible: page.s.program !== null && page.s.program !== undefined
            Layout.fillWidth: true
            implicitHeight: 58
            color: Theme.panelBackground
            property var p: page.s.program || ({})
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
            ColumnLayout {
                anchors.fill: parent
                anchors.leftMargin: 12; anchors.rightMargin: 12; anchors.topMargin: 4; anchors.bottomMargin: 4
                spacing: 4
                RowLayout {
                    Text { text: prog.p.name || ""; color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold; Layout.fillWidth: true }
                    Text { text: prog.p.outcome || ""; font.pixelSize: 10
                        color: prog.p.kind === "failed" ? Theme.danger : prog.p.kind === "stopped" ? Theme.warning : prog.p.kind === "completed" ? Theme.ok : Theme.accent }
                }
                ProgressBar { Layout.fillWidth: true; value: prog.p.fraction || 0 }
                Text { text: qsTr("Line %1 of %2 · %3 s").arg(prog.p.done || 0).arg(prog.p.total || 0).arg(prog.p.seconds || 0); color: Theme.secondaryLabel; font.pixelSize: 10 }
            }
        }
        // The machine: header, the assembly following the reported position, the footer.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 36
            color: Theme.panelBackground
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12; anchors.rightMargin: 12
                spacing: 10
                Text { text: qsTr("Machine"); color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold }
                Item { Layout.fillWidth: true }
                Rectangle {
                    implicitWidth: dispPicker.implicitWidth + 24
                    implicitHeight: 20
                    radius: 5
                    color: Qt.rgba(1, 1, 1, 0.12)
                    PopupPicker {
                        id: dispPicker
                        anchors.fill: parent
                        anchors.leftMargin: 8; anchors.rightMargin: 4
                        implicitWidth: 110
                        value: page.cm.display
                        options: page.cm.displays.map(o => ({title: o.title, value: o.value}))
                        onPicked: v => page.app.controlMachine.setDisplay(v)
                    }
                }
                MenuLabel {
                    id: cvMenu
                    title: qsTr("View"); symbol: "cube"
                    onClicked: cviews.popup(cvMenu, 0, cvMenu.height + 4)
                    Menu {
                        id: cviews
                        MenuItem { text: qsTr("Isometric"); onTriggered: page.app.controlMachine.setView("iso") }
                        MenuItem { text: qsTr("Front"); onTriggered: page.app.controlMachine.setView("front") }
                        MenuItem { text: qsTr("Tool"); onTriggered: page.app.controlMachine.setView("tool") }
                        MenuItem { text: qsTr("Top"); onTriggered: page.app.controlMachine.setView("top") }
                        MenuItem { text: qsTr("Right"); onTriggered: page.app.controlMachine.setView("right") }
                        MenuSeparator {}
                        MenuItem { text: qsTr("Frame Machine"); onTriggered: page.app.controlMachine.frame() }
                    }
                }
                SmallButton { symbol: "viewfinder"; implicitWidth: 28; help: qsTr("Frame Machine"); onClicked: page.app.controlMachine.frame() }
            }
        }
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Rectangle { anchors.fill: parent; color: Theme.windowBackground }
            Viewport {
                id: machineView
                anchors.fill: parent
                scene: page.app.controlMachine.viewScene
                realistic: page.app.workspace.realistic
                Component.onCompleted: page.app.controlMachine.attachViewport(machineView)
                Component.onDestruction: page.app.controlMachine.detachViewport(machineView)
            }
            BusyIndicator { anchors.centerIn: parent; running: page.cm.loading; visible: running }
            ContentUnavailable {
                visible: page.cm.problem !== ""
                anchors.centerIn: parent
                width: parent.width * 0.6
                title: qsTr("Machine View Unavailable")
                symbol: "cube"
                description: page.cm.problem
            }
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 28
            color: Theme.panelBackground
            Rectangle { width: parent.width; height: 1; color: Theme.separator }
            Text { x: 12; anchors.verticalCenter: parent.verticalCenter; text: page.cm.source; color: Theme.secondaryLabel; font.pixelSize: 10
                MouseArea { id: hov; anchors.fill: parent; hoverEnabled: true }
                ToolTipHelp { text: page.cm.help; shown: hov.containsMouse } }
            Text { anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                text: qsTr("X · Table   Y · Gantry   Z · Spindle"); color: Theme.secondaryLabel; font.pixelSize: 10 }
        }
    }

    inspector: Component {
        ScrollView {
            id: insp
            clip: true
            contentWidth: availableWidth
            ColumnLayout {
                width: insp.availableWidth
                spacing: 0
                // Position
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.margins: 16
                    spacing: 10
                    RowLayout {
                        Text { text: qsTr("Position"); color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold; Layout.fillWidth: true }
                        Segmented { small: true; implicitHeight: 20; options: [{value: "metric", title: "mm"}, {value: "imperial", title: "in"}]
                            value: page.app.settings.units; onPicked: v => page.app.settings.units = v }
                    }
                    RowLayout {
                        spacing: 8
                        Segmented { small: true; implicitHeight: 20; Layout.fillWidth: true
                            options: [{value: "work", title: qsTr("Work")}, {value: "machine", title: qsTr("Machine")}]; value: page.frame; onPicked: v => page.frame = v }
                        Rectangle {
                            implicitWidth: 72; implicitHeight: 20; radius: 5; color: Qt.rgba(1, 1, 1, 0.12)
                            enabled: page.canSetup
                            opacity: enabled ? 1 : 0.45
                            PopupPicker {
                                anchors.fill: parent
                                anchors.leftMargin: 6; anchors.rightMargin: 4
                                value: page.s.activeWCS || 54
                                options: [54, 55, 56, 57, 58, 59].map(n => ({title: "G" + n, value: n}))
                                onPicked: v => page.mill.selectWCS(v)
                            }
                        }
                    }
                    Repeater {
                        model: ["X", "Y", "Z"]
                        delegate: RowLayout {
                            required property string modelData
                            required property int index
                            Layout.fillWidth: true
                            spacing: 8
                            Text { text: modelData; color: Theme.secondaryLabel; font.pixelSize: 12; Layout.preferredWidth: 14 }
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 26
                                radius: 5
                                color: Qt.rgba(1, 1, 1, 0.06)
                                Text { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                                    text: page.s.open ? ((page.frame === "work" ? page.s.work : page.s.machine) || ["—", "—", "—"])[index] : "—"
                                    color: Theme.label; font.family: "Menlo"; font.pixelSize: 13 }
                            }
                            SmallButton { visible: page.frame === "work"; title: qsTr("Zero"); enabled: page.canSetup
                                help: qsTr("Make the current work %1 zero in G%2").arg(modelData).arg(page.s.activeWCS || 54); onClicked: page.mill.zero(modelData) }
                        }
                    }
                    RowLayout {
                        visible: page.frame === "work"
                        Text { text: qsTr("Set coordinates…"); color: page.canSetup ? Theme.systemBlue : Theme.tertiaryLabel; font.pixelSize: 12
                            MouseArea { anchors.fill: parent; enabled: page.canSetup; onClicked: setWork.open() } }
                        Item { Layout.fillWidth: true }
                        Item { visible: page.mill.offsetUndo !== ""; width: 16; height: 16
                            Sym { anchors.centerIn: parent; name: "arrow.uturn.backward"; size: 11 }
                            MouseArea { id: um; anchors.fill: parent; hoverEnabled: true; onClicked: page.mill.undoOffset() }
                            ToolTipHelp { text: qsTr("Undo %1").arg(page.mill.offsetUndo); shown: um.containsMouse } }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.separator }
                // Jog
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.margins: 16
                    spacing: 12
                    RowLayout {
                        Text { text: qsTr("Jog"); color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold; Layout.fillWidth: true }
                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: page.mill.allowJog ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18) : "transparent"
                            enabled: page.s.homed === true || page.mill.allowJog
                            opacity: enabled ? 1 : 0.4
                            Sym { anchors.centerIn: parent; name: page.mill.allowJog ? "lock.open" : "lock"; size: 12 }
                            MouseArea { id: lm; anchors.fill: parent; hoverEnabled: true; onClicked: { page.mill.allowJog = !page.mill.allowJog; page.forceActiveFocus() } }
                            ToolTipHelp { text: page.mill.allowJog ? qsTr("Lock jogging and stop the current jog") : qsTr("Unlock jogging"); shown: lm.containsMouse }
                        }
                    }
                    RowLayout {
                        enabled: page.mill.allowJog && (page.s.gates !== undefined && (page.s.gates.jog === "" || page.mill.holding))
                        spacing: 12
                        Rectangle {
                            implicitWidth: pad.implicitWidth + 12
                            implicitHeight: pad.implicitHeight + 12
                            radius: 8
                            color: Qt.rgba(1, 1, 1, 0.06)
                            GridLayout {
                                id: pad
                                anchors.centerIn: parent
                                columns: 3
                                rowSpacing: 4
                                columnSpacing: 4
                                Repeater {
                                    model: [[-1, -1], [-1, 0], [-1, 1], [0, -1], [0, 0], [0, 1], [1, -1], [1, 0], [1, 1]]
                                    delegate: Item {
                                        required property var modelData
                                        implicitWidth: 40
                                        implicitHeight: 30
                                        JogButton {
                                            anchors.fill: parent
                                            visible: !(modelData[0] === 0 && modelData[1] === 0)
                                            mill: page.mill
                                            jx: modelData[0]; jy: modelData[1]; jz: 0
                                            symbol: ["arrow.up.left", "arrow.up", "arrow.up.right", "arrow.left", "", "arrow.right", "arrow.down.left", "arrow.down", "arrow.down.right"][(modelData[0] + 1) * 3 + modelData[1] + 1]
                                        }
                                    }
                                }
                            }
                        }
                        Item { Layout.fillWidth: true }
                        Rectangle { implicitWidth: 1; implicitHeight: 104; color: Theme.separator }
                        ColumnLayout {
                            Layout.preferredWidth: 72
                            spacing: 8
                            Text { text: qsTr("Spindle"); color: Theme.secondaryLabel; font.pixelSize: 10; Layout.alignment: Qt.AlignHCenter }
                            JogButton { mill: page.mill; jz: -1; text: qsTr("In"); Layout.fillWidth: true; implicitHeight: 28 }
                            JogButton { mill: page.mill; jz: 1; text: qsTr("Out"); Layout.fillWidth: true; implicitHeight: 28 }
                        }
                    }
                    RowLayout {
                        spacing: 8
                        Text { text: qsTr("Mode"); color: Theme.secondaryLabel; font.pixelSize: 12; Layout.preferredWidth: 38 }
                        Segmented { small: true; implicitHeight: 20; options: [{value: false, title: qsTr("Step")}, {value: true, title: qsTr("Hold")}]
                            value: page.mill.jogHold; onPicked: v => { page.mill.endHold(); page.mill.jogHold = v } }
                    }
                    RowLayout {
                        spacing: 8
                        Text { text: qsTr("Step\n(%1)").arg(page.s.unit || "mm"); color: Theme.secondaryLabel; font.pixelSize: 10; Layout.preferredWidth: 48 }
                        Segmented { small: true; implicitHeight: 20; enabled: !page.mill.jogHold; opacity: enabled ? 1 : 0.45
                            options: page.mill.jogSteps().map(c => ({value: c.value, title: c.title})); value: page.mill.jogStep; onPicked: v => page.mill.jogStep = v }
                    }
                    RowLayout {
                        spacing: 8
                        Text { text: qsTr("Feed"); color: Theme.secondaryLabel; font.pixelSize: 12; Layout.preferredWidth: 38 }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            implicitWidth: feedPicker.implicitWidth + 24; implicitHeight: 20; radius: 5; color: Qt.rgba(1, 1, 1, 0.12)
                            PopupPicker { id: feedPicker; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 4; implicitWidth: 90
                                value: page.mill.jogFeed; options: page.mill.jogFeeds().map(c => ({value: c.value, title: c.title})); onPicked: v => page.mill.jogFeed = v }
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.separator }
                // Setup
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.margins: 16
                    spacing: 10
                    Text { text: qsTr("Setup"); color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold }
                    SmallButton {
                        id: goButton
                        Layout.alignment: Qt.AlignHCenter
                        title: qsTr("Go To"); symbol: "location"; chevron: true
                        enabled: page.mill.allowJog && page.s.gates !== undefined && page.s.gates.run === ""
                        onClicked: goMenu.popup(goButton, 0, goButton.height + 4)
                        Menu {
                            id: goMenu
                            MenuItem { text: qsTr("Work Zero (X Y)"); onTriggered: page.mill.requestGoTo("workZero") }
                            MenuItem { text: qsTr("Home Position"); enabled: page.s.homeTarget === true; onTriggered: page.mill.requestGoTo("home") }
                            MenuItem { text: qsTr("Tool-Change Position"); onTriggered: page.mill.requestGoTo("toolChange") }
                            MenuSeparator {}
                            MenuItem { text: qsTr("Position…"); onTriggered: page.mill.requestGoTo("position") }
                        }
                    }
                    SmallButton {
                        id: progButton
                        title: qsTr("Test programs…"); chevron: true
                        onClicked: programMenu.popup(progButton, 0, progButton.height + 4)
                        Menu {
                            id: programMenu
                            Repeater {
                                model: page.mill.programs
                                MenuItem { required property var modelData; text: (modelData.favorite ? "★ " : "") + modelData.title; onTriggered: page.mill.confirmProgram(modelData.id) }
                            }
                            MenuSeparator {}
                            MenuItem { text: qsTr("Open G-code File…"); onTriggered: openProgram.open() }
                            MenuItem { text: qsTr("Manage Programs…"); onTriggered: page.mill.showProgramLibrary = true }
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.separator }
                Disclosure {
                    Layout.margins: 16
                    title: qsTr("Spindle")
                    fontSize: 12
                    bold: true
                    ValueRow { label: qsTr("State"); value: page.s.spindle || "—" }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: qsTr("Speed"); color: Theme.secondaryLabel; font.pixelSize: 12; Layout.fillWidth: true }
                        NumberEdit { width: 110; value: page.mill.spindleRPM; unit: "RPM"; decimals: 0; onCommitted: v => page.mill.spindleRPM = v }
                    }
                    Row {
                        spacing: 8
                        SmallButton { title: qsTr("Start…"); symbol: "play.fill"; enabled: page.canSetup; onClicked: page.mill.showSpindleConfirm = true }
                        SmallButton { title: qsTr("Stop"); symbol: "stop.fill"; enabled: page.s.gates !== undefined && page.s.gates.console === ""; onClicked: page.mill.spindleOff() }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.separator }
                Disclosure {
                    Layout.margins: 16
                    title: qsTr("Overrides")
                    fontSize: 12
                    bold: true
                    enabled: page.s.open === true
                    Repeater {
                        model: [{title: qsTr("Feed"), key: "feed", minus: "FEED_MINUS_10", plus: "FEED_PLUS_10", reset: "FEED_RESET"},
                                {title: qsTr("Spindle"), key: "spindle", minus: "SPINDLE_MINUS_10", plus: "SPINDLE_PLUS_10", reset: "SPINDLE_RESET"}]
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 6
                            Text { text: modelData.title; color: Theme.secondaryLabel; font.pixelSize: 12; Layout.fillWidth: true }
                            SmallButton { title: "−10"; onClicked: page.mill.override(modelData.minus) }
                            Text { text: (page.s.overrides ? page.s.overrides[modelData.key] : 100) + "%"; color: Theme.label; font.pixelSize: 12; Layout.preferredWidth: 48; horizontalAlignment: Text.AlignHCenter
                                MouseArea { anchors.fill: parent; onClicked: page.mill.override(modelData.reset) } }
                            SmallButton { title: "+10"; onClicked: page.mill.override(modelData.plus) }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: qsTr("Rapid"); color: Theme.secondaryLabel; font.pixelSize: 12; Layout.fillWidth: true }
                        Segmented {
                            small: true; implicitHeight: 20
                            options: [{value: 25, title: "25%"}, {value: 50, title: "50%"}, {value: 100, title: "100%"}]
                            value: page.s.overrides ? page.s.overrides.rapid : 100
                            onPicked: v => page.mill.override(v === 25 ? "RAPID_25" : v === 50 ? "RAPID_50" : "RAPID_100")
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.separator }
                Disclosure {
                    Layout.margins: 16
                    title: qsTr("Diagnostics")
                    fontSize: 12
                    bold: true
                    FieldRow {
                        label: qsTr("Port")
                        ChoiceEdit {
                            enabled: page.s.open !== true
                            choices: {
                                var c = [{value: "auto", title: qsTr("Automatic")}]
                                for (var i = 0; i < page.mill.ports.length; i++) c.push({value: page.mill.ports[i].path, title: page.mill.ports[i].label})
                                var p = page.mill.portChoice
                                if (p !== "auto" && p !== "sim" && !page.mill.ports.some(x => x.path === p)) c.push({value: p, title: p + qsTr(" (not plugged in)")})
                                c.push({value: "sim", title: qsTr("Simulated Mill")})
                                return c
                            }
                            value: page.mill.portChoice
                            onCommitted: v => page.mill.portChoice = v
                        }
                    }
                    SwitchRow { label: qsTr("Connect automatically"); checked: page.mill.autoConnect; onToggled: on => page.mill.autoConnect = on }
                    Row {
                        spacing: 8
                        SmallButton { visible: page.s.open !== true; title: qsTr("Refresh ports"); symbol: "arrow.clockwise"; onClicked: page.mill.refreshPorts() }
                        SmallButton { title: qsTr("Console…"); symbol: "terminal"; onClicked: page.mill.showConsole = true }
                    }
                    Text { visible: (page.s.firmware || "") !== ""; text: page.s.firmware || ""; color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WrapAnywhere; Layout.fillWidth: true }
                    ValueRow { visible: (page.s.buffer || "") !== ""; label: qsTr("Buffer"); value: page.s.buffer || "" }
                    ValueRow { visible: (page.s.limits || "") !== ""; label: qsTr("Limit switches"); value: page.s.limits || "" }
                    ValueRow { visible: (page.s.reportedFeed || "") !== ""; label: qsTr("Reported feed"); value: page.s.reportedFeed || "" }
                    ValueRow { visible: (page.s.reportedSpindle || "") !== ""; label: qsTr("Reported spindle"); value: page.s.reportedSpindle || "" }
                    Text { visible: (page.s.parserState || "") !== ""; text: page.s.parserState || ""; font.family: "Menlo"; font.pixelSize: 10; color: Theme.secondaryLabel; wrapMode: Text.WrapAnywhere; Layout.fillWidth: true }
                    Disclosure {
                        visible: (page.s.offsets || []).length > 0
                        title: qsTr("Work offsets")
                        fontSize: 11
                        Repeater { model: page.s.offsets || []; Text { required property var modelData; text: modelData.text; font.family: "Menlo"; font.pixelSize: 10; color: Theme.label } }
                    }
                }
                Item { implicitHeight: 16 }
            }
        }
    }

    Dialog {
        id: setWork
        modal: true
        anchors.centerIn: parent
        width: 320
        title: qsTr("This position in G%1 is").arg(page.s.activeWCS || 54)
        property var vx: null
        property var vy: null
        property var vz: null
        onOpened: { vx = null; vy = null; vz = null }
        ColumnLayout {
            width: parent.width
            FieldRow { label: "X"; NumberEdit { value: setWork.vx; optional: true; onCommitted: v => setWork.vx = v } }
            FieldRow { label: "Y"; NumberEdit { value: setWork.vy; optional: true; onCommitted: v => setWork.vy = v } }
            FieldRow { label: "Z"; NumberEdit { value: setWork.vz; optional: true; onCommitted: v => setWork.vz = v } }
            Text { text: qsTr("Blank: that axis keeps its offset."); color: Theme.secondaryLabel; font.pixelSize: 10 }
            RowLayout {
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Cancel"); onClicked: setWork.close() }
                Button { text: qsTr("Set"); highlighted: true; enabled: setWork.vx !== null || setWork.vy !== null || setWork.vz !== null
                    onClicked: { page.mill.setWork(setWork.vx, setWork.vy, setWork.vz); setWork.close() } }
            }
        }
    }
    FileDialog {
        id: openProgram
        title: qsTr("Choose a G-code or NC program in millimeters")
        nameFilters: [qsTr("G-code (*.nc *.gcode *.ngc *.tap *.cnc *.txt)")]
        onAccepted: page.mill.openProgramFile(page.app.localPath(selectedFile))
    }
}
