import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// A tool change in playback: the machine goes to the change position, you fit the tool,
// "Tool Changed" brings it back. Port of Views/ToolChangeCard.swift.
FloatCard {
    id: card
    property var ws
    readonly property var d: (ws.revision, ws.toolChangeCard())
    visible: d.phase !== undefined
    Label { text: qsTr("Tool change"); font.weight: Font.DemiBold; font.pixelSize: 15 }
    Label {
        text: d.phase === "moving" ? qsTr("Going to the tool-change position…")
            : d.phase === "returning" ? qsTr("Back to the next cut…")
            : qsTr("Take out the %1 and fit the %2, %3 mm sticking out of the collet nut.").arg(d.from || qsTr("tool")).arg(d.to).arg(d.stickout)
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
    }
    Label { visible: (card.d.note || "") !== ""; text: card.d.note || ""; color: Theme.warning; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
    RowLayout {
        Layout.fillWidth: true
        Button { text: qsTr("Skip"); onClicked: card.ws.cancelToolChange() }
        Item { Layout.fillWidth: true }
        Button { text: qsTr("Tool Changed"); highlighted: true; enabled: card.d.phase === "waiting"; onClicked: card.ws.confirmToolChange() }
    }
}
