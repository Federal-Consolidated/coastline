import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A segmented control over [{value, title}].
Rectangle {
    id: seg
    property var options: []
    property var value
    property bool small: false
    signal picked(var value)
    color: Qt.rgba(1, 1, 1, 0.07)
    radius: height / 2
    implicitHeight: 24
    implicitWidth: row.implicitWidth + 4
    RowLayout {
        id: row
        anchors.fill: parent
        anchors.margins: 2
        spacing: 2
        Repeater {
            model: seg.options
            delegate: Rectangle {
                required property var modelData
                radius: height / 2
                color: seg.value === modelData.value ? Qt.rgba(1, 1, 1, 0.2) : "transparent"
                Layout.fillHeight: true
                implicitWidth: label.implicitWidth + (seg.small ? 16 : 28)
                Text {
                    id: label
                    anchors.centerIn: parent
                    text: modelData.title
                    color: Theme.label
                    font.pixelSize: seg.small ? 11 : 13
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: seg.picked(modelData.value)
                }
            }
        }
    }
}
