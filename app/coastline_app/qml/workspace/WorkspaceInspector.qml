import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// The job's six stages across the top, the stage's "why", and its panel.
// Port of WorkspaceInspector, StageBar and StageHeader (Views/SetupInspector.swift, StageViews.swift).
Rectangle {
    id: insp
    property var ws
    property var app
    color: Theme.panelBackground
    readonly property var stages: (ws.revision, ws.stages())
    readonly property var header: (ws.revision, ws.stageHeader())
    readonly property var head: (ws.revision, ws.header())

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            active: insp.head.placing
            visible: active
            sourceComponent: FixturePlacementPanel { ws: insp.ws }
        }

        // Stage bar (StageBar).
        Row {
            visible: !insp.head.placing
            Layout.fillWidth: true
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            Layout.topMargin: 5
            spacing: 2
            Repeater {
                model: insp.stages
                delegate: Item {
                    id: cell
                    required property var modelData
                    readonly property bool faint: modelData.state === "later" || modelData.state === "notNeeded"
                    width: (insp.width - 20 - 10) / 6
                    height: 46
                    enabled: modelData.enabled
                    Rectangle {
                        id: dot
                        width: 24; height: 24; radius: 12
                        x: (parent.width - width) / 2
                        y: 2
                        color: {
                            const s = cell.modelData.state, cur = cell.modelData.current
                            if (s === "done") return Qt.rgba(0.36, 0.36, 0.36, 1)
                            if (s === "attention") return Qt.rgba(0.62, 0.48, 0, 1)
                            if (s === "todo") return Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, cur ? 1 : 0.75)
                            if (s === "blocked") return Qt.rgba(0.75, 0.16, 0.14, 1)
                            if (s === "later" && cur) return Theme.accent
                            return Qt.rgba(0.55, 0.55, 0.55, 0.18)
                        }
                        Sym {
                            anchors.centerIn: parent
                            size: 10
                            weight: "bold"
                            color: cell.faint ? Theme.secondaryLabel : "white"
                            name: ({done: "checkmark", attention: "exclamationmark", todo: "arrow.right", blocked: "xmark", notNeeded: "minus"})[cell.modelData.state]
                                  || cell.modelData.symbol
                        }
                    }
                    Rectangle {
                        anchors.centerIn: dot
                        width: 28; height: 28; radius: 14
                        color: "transparent"
                        border.width: 1.5
                        border.color: Qt.rgba(1, 1, 1, 0.6)
                        visible: cell.modelData.current
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: dot.y + 24 + 3 + 2
                        text: cell.modelData.short
                        color: cell.modelData.state === "later" ? Theme.secondaryLabel : Theme.label
                        font.pixelSize: 10
                        font.weight: cell.modelData.current ? Font.DemiBold : Font.Medium
                    }
                    MouseArea { id: sm; anchors.fill: parent; hoverEnabled: true; onClicked: insp.ws.enterStage(cell.modelData.id) }
                    ToolTipHelp { text: cell.modelData.title + ": " + cell.modelData.why; shown: sm.containsMouse }
                }
            }
        }

        // The stage's "why" (StageHeader).
        RowLayout {
            visible: !insp.head.placing
            Layout.fillWidth: true
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            Layout.topMargin: 8
            Layout.bottomMargin: 8
            spacing: 8
            Rectangle {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 0
                width: 18; height: 18; radius: 9
                color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.25)
                Text { anchors.centerIn: parent; text: insp.header.number; color: Theme.label; font.pixelSize: 10; font.weight: Font.Bold }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text { text: insp.header.title; color: Theme.label; font.pixelSize: Theme.headline; font.weight: Font.Bold }
                Text { text: insp.header.why; color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            }
            Rectangle {
                id: nextButton
                visible: insp.header.next !== ""
                Layout.alignment: Qt.AlignTop
                enabled: insp.header.canNext
                implicitWidth: nextRow.implicitWidth + 16
                implicitHeight: 18
                radius: 5
                color: nm.pressed ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(1, 1, 1, 0.12)
                opacity: enabled ? 1 : 0.45
                Row {
                    id: nextRow
                    anchors.centerIn: parent
                    spacing: 4
                    Sym { name: "chevron.right"; size: 9; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: qsTr("Next"); color: Theme.label; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
                }
                MouseArea { id: nm; anchors.fill: parent; hoverEnabled: true; onClicked: insp.ws.enterStage(insp.header.next) }
                ToolTipHelp { text: qsTr("Go to %1").arg(insp.header.nextTitle); shown: nm.containsMouse }
            }
        }
        Rectangle { visible: !insp.head.placing; color: Theme.separator; Layout.fillWidth: true; Layout.preferredHeight: 1 }

        Loader {
            id: stagePanel
            ContentUnavailable {
                visible: !insp.head.hasPart && !insp.head.hasStock && (insp.head.stage === "partStock" || insp.head.stage === "stock")
                anchors.centerIn: parent
                title: qsTr("No Part")
                symbol: "cube.transparent"
                description: qsTr("Import a part, then choose stock from your inventory.")
            }
            visible: !insp.head.placing
            Layout.fillWidth: true
            Layout.fillHeight: true
            sourceComponent: {
                switch (insp.ws.revision, insp.head.stage) {
                case "partStock": return partPanel
                case "stock": return stockPanel
                case "planning": return planPanel
                case "setups": return setupsPanel
                case "machining": return machiningPanel
                default: return reviewPanel
                }
            }
        }
    }

    Component { id: partPanel; PartStockPanel { ws: insp.ws; app: insp.app; scope: "part" } }
    Component { id: stockPanel; PartStockPanel { ws: insp.ws; app: insp.app; scope: "stock" } }
    Component { id: planPanel; PlanPanel { ws: insp.ws; app: insp.app } }
    Component { id: setupsPanel; SetupsPanel { ws: insp.ws; app: insp.app } }
    Component { id: machiningPanel; MachiningPanel { ws: insp.ws; app: insp.app } }
    Component { id: reviewPanel; ReviewPanel { ws: insp.ws; app: insp.app } }
}
