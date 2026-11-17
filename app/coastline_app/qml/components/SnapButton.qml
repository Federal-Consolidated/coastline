import QtQuick

// A .bordered, .small button with its icon and title at caption size.
Rectangle {
    id: b
    property string title: ""
    property string symbol: ""
    signal clicked()
    implicitWidth: r.implicitWidth + 14
    implicitHeight: 20
    radius: 5
    color: ma.pressed ? Qt.rgba(1, 1, 1, 0.24) : Qt.rgba(1, 1, 1, 0.12)
    opacity: enabled ? 1 : 0.4
    Row {
        id: r
        anchors.centerIn: parent
        spacing: 4
        Sym { name: b.symbol; size: 10; anchors.verticalCenter: parent.verticalCenter }
        Text { text: b.title; color: Theme.label; font.pixelSize: 10; anchors.verticalCenter: parent.verticalCenter }
    }
    MouseArea { id: ma; anchors.fill: parent; onClicked: b.clicked() }
}
