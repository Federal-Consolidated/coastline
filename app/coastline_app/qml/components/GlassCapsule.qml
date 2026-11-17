import QtQuick

// A Liquid Glass capsule holding toolbar items or floating controls (glassEffect in .capsule).
Rectangle {
    id: cap
    default property alias content: row.data
    property alias spacing: row.spacing
    property real padding: 4
    radius: height / 2
    color: Theme.glass
    border.color: Theme.glassStroke
    border.width: 1
    implicitHeight: 34
    implicitWidth: row.implicitWidth + padding * 2
    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        x: cap.padding
        spacing: 0
    }
}
