import QtQuick
import QtCore
import QtQuick.Layouts
import "../components"

// The step on screen, as an instruction card over the 3D view: the chapter, the step, what to
// do at the machine, and Previous / Next. An accordion: the header always shows; its button
// folds the instructions away (remembered). Port of Views/StepCard.swift.
Rectangle {
    id: card
    property var ws
    readonly property var d: (ws.revision, ws.stepCard())
    Settings { id: prefs; property bool stepCardCollapsed: false }
    readonly property bool collapsed: prefs.stepCardCollapsed
    visible: d.id !== undefined
    width: 340
    implicitHeight: col.implicitHeight + 28
    height: implicitHeight
    radius: 16
    color: Theme.glass
    border.color: Theme.glassStroke
    clip: true
    Behavior on height { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }

    ColumnLayout {
        id: col
        x: 14; y: 14
        width: parent.width - 28
        spacing: 8
        Item {
            Layout.fillWidth: true
            implicitHeight: head.implicitHeight
            ColumnLayout {
                id: head
                width: parent.width
                spacing: 6
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Text { text: qsTr("Chapter %1 · %2").arg(card.d.chapterNumber || 0).arg(card.d.chapter || ""); color: Theme.secondaryLabel; font.pixelSize: 10; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                    Text { text: qsTr("Step %1 of %2").arg(card.d.number || 0).arg(card.d.count || 0); color: Theme.secondaryLabel; font.pixelSize: 10 }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Sym { name: card.d.symbol || ""; size: 13 }
                    Text { text: card.d.title || ""; color: Theme.label; font.pixelSize: 13; font.weight: Font.Bold; elide: Text.ElideRight; Layout.fillWidth: true }
                    Rectangle {
                        width: 24; height: 24; radius: 12
                        color: Qt.rgba(1, 1, 1, 0.12)
                        border.color: Theme.glassStroke
                        Sym { anchors.centerIn: parent; name: "chevron.down"; size: 11; weight: "bold"; rotation: card.collapsed ? 0 : 180
                            Behavior on rotation { NumberAnimation { duration: 280 } } }
                    }
                }
            }
            MouseArea { id: hm; anchors.fill: parent; hoverEnabled: true; onClicked: prefs.stepCardCollapsed = !prefs.stepCardCollapsed }
            ToolTipHelp { text: card.collapsed ? qsTr("Show the step's instructions") : qsTr("Fold the instructions away"); shown: hm.containsMouse }
        }
        ColumnLayout {
            visible: !card.collapsed
            Layout.fillWidth: true
            spacing: 8
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 5
                Repeater {
                    model: card.d.instructions || []
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 6
                        Rectangle { width: 4; height: 4; radius: 2; color: Theme.secondaryLabel; Layout.alignment: Qt.AlignTop; Layout.topMargin: 6 }
                        Text { text: modelData; textFormat: Text.MarkdownText; color: Theme.label; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    }
                }
            }
            Row {
                spacing: 8
                Rectangle {
                    width: 26; height: 20; radius: 5
                    color: Qt.rgba(1, 1, 1, 0.14)
                    opacity: (card.d.prev || "") !== "" ? 1 : 0.4
                    Sym { anchors.centerIn: parent; name: "chevron.left"; size: 10 }
                    MouseArea { id: pm; anchors.fill: parent; enabled: (card.d.prev || "") !== ""; hoverEnabled: true; onClicked: card.ws.goToStep(card.d.prev) }
                    ToolTipHelp { text: qsTr("Previous step (⌘[)"); shown: pm.containsMouse }
                }
                Rectangle {
                    width: nr.implicitWidth + 16; height: 20; radius: 5
                    color: Qt.rgba(1, 1, 1, 0.14)
                    opacity: (card.d.next || "") !== "" ? 1 : 0.4
                    Row { id: nr; anchors.centerIn: parent; spacing: 4
                        Sym { name: "chevron.right"; size: 10; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: qsTr("Next Step"); color: Theme.label; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter } }
                    MouseArea { id: nm; anchors.fill: parent; enabled: (card.d.next || "") !== ""; hoverEnabled: true; onClicked: card.ws.goToStep(card.d.next) }
                    ToolTipHelp { text: qsTr("Next step (⌘])"); shown: nm.containsMouse }
                }
            }
        }
    }
}
