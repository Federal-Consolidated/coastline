import QtQuick
import QtQuick.Layouts

// A selectable row of a macOS List (inset): rounded selection, a hairline under it.
Item {
    id: lr
    property bool selected: false
    property bool separator: true
    default property alias content: holder.data
    signal clicked()
    signal doubleClicked()
    signal contextMenu(real x, real y)
    Layout.fillWidth: true
    implicitHeight: holder.childrenRect.height + 10
    Rectangle { anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6; radius: 6; color: lr.selected ? Theme.accent : "transparent" }
    Item { id: holder; x: 14; y: 5; width: parent.width - 28; height: childrenRect.height }
    Rectangle { visible: lr.separator && !lr.selected; x: 14; width: parent.width - 28; height: 1; anchors.bottom: parent.bottom; color: Theme.separator }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: m => { if (m.button === Qt.RightButton) lr.contextMenu(m.x, m.y); else lr.clicked() }
        onDoubleClicked: lr.doubleClicked()
    }
}
