import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// A message over the 3D view, with an optional action.
Rectangle {
    id: banner
    property string text: ""
    property string action: ""
    property color tint: Theme.secondary
    signal triggered()
    Layout.fillWidth: true
    radius: 12
    color: Qt.rgba(tint.r * 0.25 + 0.08, tint.g * 0.25 + 0.08, tint.b * 0.25 + 0.08, 0.92)
    implicitHeight: row.implicitHeight + 18
    RowLayout {
        id: row
        anchors.fill: parent
        anchors.margins: 9
        spacing: 8
        TextArea {
            Layout.fillWidth: true
            text: banner.text
            readOnly: true
            selectByMouse: true
            wrapMode: Text.WordWrap
            color: Theme.text
            font.pixelSize: Theme.fontSize
            background: null
            padding: 0
        }
        Button { visible: banner.action !== ""; text: banner.action; onClicked: banner.triggered(); flat: banner.action === "✕" }
    }
}
