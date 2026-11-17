import QtQuick
import QtQuick.Layouts

// Toggle(label, isOn:) in a grouped form: the label on the left, a small switch on the right.
Item {
    id: sw
    property string label: ""
    property bool checked: false
    signal toggled(bool on)
    Layout.fillWidth: true
    implicitHeight: 22
    opacity: enabled ? 1 : 0.45
    Text { text: sw.label; color: Theme.label; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 50; elide: Text.ElideRight }
    Rectangle {
        id: track
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 32; height: 18; radius: 9
        color: sw.checked ? Theme.accent : Qt.rgba(1, 1, 1, 0.16)
        Behavior on color { ColorAnimation { duration: 150 } }
        Rectangle {
            width: 16; height: 16; radius: 8
            y: 1
            x: sw.checked ? parent.width - width - 1 : 1
            color: "white"
            Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
        }
    }
    MouseArea { anchors.fill: parent; onClicked: sw.toggled(!sw.checked) }
}
