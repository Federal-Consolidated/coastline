import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// The Paths stage: the operations, their tools and cutting data, the result, and generating.
// Port of MachiningInspector, OperationRow and GenerateBar (Views/MachiningInspector.swift).
Item {
    id: root
    property var ws
    property var app
    readonly property var ops: (ws.revision, ws.operationRows())
    readonly property var gen: (ws.revision, ws.generation())

    ContentUnavailable {
        visible: !root.gen.ready
        anchors.centerIn: parent
        title: qsTr("Set Up First")
        symbol: "cube.transparent"
        description: qsTr("Load a part and choose stock, then build the job in Plan.")
    }

    Panel {
        visible: root.gen.ready
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: bar.top
        ws: root.ws
        app: root.app

        Card {
            visible: root.gen.toolsToBuy.length > 0
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Sym { Layout.alignment: Qt.AlignTop; name: "cart.badge.plus"; size: 13; color: Theme.accent }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 3
                    Text { text: root.gen.toolsToBuy.length === 1 ? qsTr("This job needs a tool you don't have yet") : qsTr("This job needs %1 tools you don't have yet").arg(root.gen.toolsToBuy.length)
                        color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Text { text: root.gen.toolsToBuy.join(", ") + qsTr(". They're on your Shopping List; the toolpaths and the simulation already use them.")
                        color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Text { text: qsTr("Open the Shopping List"); color: Theme.systemBlue; font.pixelSize: 10
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.app.page = "shopping" } }
                }
            }
        }

        Card {
            ValueRow { label: qsTr("Job plan"); value: root.gen.chosen }
            LinkButton { symbol: "sparkles"; title: qsTr("Change Job Plan…"); onClicked: root.ws.enterStage("planning") }
            Text { text: qsTr("Inspect and refine the cuts here. Workholding and work zero are in Setups; export and running are in Review.")
                color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }

        Card {
            visible: root.ops.length > 0
            title: qsTr("Operations")
            Repeater {
                model: root.ops
                delegate: OperationRow { ws: root.ws }
            }
            Item {
                Layout.fillWidth: true
                implicitHeight: 18
                Row {
                    id: addRow
                    spacing: 5
                    opacity: addMa.pressed ? 0.6 : 1
                    Sym { name: "plus"; size: 12; color: Theme.secondaryLabel; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: qsTr("Add Operation"); color: Theme.secondaryLabel; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                    Sym { name: "chevron.down"; size: 8; weight: "bold"; color: Theme.secondaryLabel; anchors.verticalCenter: parent.verticalCenter }
                }
                MouseArea { id: addMa; anchors.fill: addRow; onClicked: addMenu.popup(addRow, 0, addRow.height + 4) }
                Menu {
                    id: addMenu
                    Repeater {
                        model: root.ws.addableOperations()
                        delegate: MenuItem { required property var modelData; text: modelData.title; onTriggered: root.ws.addOperation(modelData.kind) }
                    }
                }
            }
        }

        ResultsCard { visible: root.gen.hasPrograms; ws: root.ws; app: root.app; delivery: false }
        Item { Layout.preferredHeight: 12 }
    }

    // GenerateBar: Generate and its progress stay put at the bottom.
    Rectangle {
        id: bar
        visible: root.gen.ready
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: visible ? gb.implicitHeight + 24 : 0
        color: Theme.toolbarBackground
        Rectangle { width: parent.width; height: 1; color: Theme.separator }
        ColumnLayout {
            id: gb
            x: 16; y: 12
            width: parent.width - 32
            spacing: 6
            RowLayout {
                visible: root.gen.generating
                Layout.fillWidth: true
                spacing: 10
                ProgressBar { value: root.gen.progress; Layout.fillWidth: true }
                SmallButton { title: qsTr("Cancel"); help: qsTr("Stops now; the operations already done stay and are reused next time (⌘.)"); onClicked: root.ws.cancelGeneration() }
            }
            Text { visible: root.gen.generating; text: root.gen.status; color: Theme.secondaryLabel; font.pixelSize: 10; elide: Text.ElideMiddle; Layout.fillWidth: true }
            RowLayout {
                visible: !root.gen.generating
                Layout.fillWidth: true
                Layout.preferredHeight: 18
                spacing: 6
                Sym { name: "clock"; size: 12; color: Theme.secondaryLabel }
                Text { text: qsTr("Expected"); color: Theme.secondaryLabel; font.pixelSize: 12; Layout.fillWidth: true }
                Text { visible: root.gen.expected !== ""; text: "≈ " + root.gen.expected; color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold }
                Text { visible: root.gen.delta !== ""; text: root.gen.delta; color: root.gen.faster ? Theme.ok : Theme.warning; font.pixelSize: 12 }
                Text { visible: root.gen.expected === ""; text: qsTr("after a plan"); color: Theme.secondaryLabel; font.pixelSize: 12 }
            }
            GlassButton {
                visible: !root.gen.generating
                Layout.fillWidth: true
                title: root.gen.title
                prominent: true
                enabled: root.gen.blocker === ""
                help: qsTr("Operations generate in the background, several at once; each chapter's toolpaths show (and simulate) as soon as they're ready. Unchanged operations are reused. (⌘G)")
                onClicked: root.ws.generate()
            }
            IconText { visible: !root.gen.generating && root.gen.blocker !== ""; symbol: "arrow.turn.left.up"; text: root.gen.blocker; color: Theme.secondaryLabel; wrap: true; Layout.fillWidth: true }
        }
    }
}
