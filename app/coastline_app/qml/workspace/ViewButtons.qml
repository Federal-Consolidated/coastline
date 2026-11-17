import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// Standard views and Fit (the Swift app's view cube and control bar views).
Rectangle {
    id: bar
    property var ws
    radius: height / 2
    color: Qt.rgba(0.08, 0.08, 0.09, 0.9)
    implicitWidth: row.implicitWidth + 12
    implicitHeight: row.implicitHeight + 8
    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 0
        Repeater {
            model: bar.ws.standardViews()
            delegate: ToolButton {
                required property var modelData
                text: modelData.title
                onClicked: bar.ws.setView(modelData.id)
            }
        }
        ToolButton { text: qsTr("Fit"); onClicked: bar.ws.fit(); ToolTip.visible: hovered; ToolTip.text: qsTr("Frame the part and stock") }
    }
}
