import QtQuick

// A small capsule label ("Not owned", "Needs specs").
Rectangle {
    property alias text: label.text
    property color tint: Theme.secondary
    radius: height / 2
    color: Qt.rgba(tint.r, tint.g, tint.b, 0.22)
    implicitHeight: label.implicitHeight + 4
    implicitWidth: label.implicitWidth + 12
    Text {
        id: label
        anchors.centerIn: parent
        color: Theme.text
        font.pixelSize: Theme.smallFont
        font.weight: Font.DemiBold
    }
}
