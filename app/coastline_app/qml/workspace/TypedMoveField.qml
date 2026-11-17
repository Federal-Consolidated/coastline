import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// The little field a clicked gumball arrow or ring opens: type a distance or an angle.
Rectangle {
    id: field
    property var ws
    readonly property var d: (ws.revision, ws.gumballPromptInfo())
    visible: d.title !== undefined
    x: (d.x || 0) + 14
    y: (d.y || 0) - 18
    radius: height / 2
    color: Qt.rgba(0.1, 0.1, 0.11, 0.95)
    implicitWidth: row.implicitWidth + 20
    implicitHeight: row.implicitHeight + 12
    onVisibleChanged: if (visible) { input.text = ""; input.forceActiveFocus() }
    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Label { text: field.d.title || ""; color: Theme.secondary; font.pixelSize: Theme.smallFont }
        TextField {
            id: input
            implicitWidth: 70
            horizontalAlignment: Text.AlignRight
            onAccepted: { var v = Number(text.replace(",", ".")); if (!isNaN(v)) field.ws.applyTypedMove(v) }
            Keys.onEscapePressed: field.ws.closeTypedMove()
        }
        Label { text: field.d.unit || ""; color: Theme.secondary }
        ToolButton { text: "✕"; onClicked: field.ws.closeTypedMove() }
    }
}
