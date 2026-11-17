import QtQuick
import QtQuick.Layouts

// Button(title, systemImage:) in a grouped form: a bordered push button with its icon.
Rectangle {
    id: b
    property string title: ""
    property string symbol: ""
    signal clicked()
    implicitWidth: r.implicitWidth + 20
    implicitHeight: 22
    radius: 6
    color: ma.pressed ? Qt.rgba(1, 1, 1, 0.24) : Qt.rgba(1, 1, 1, 0.14)
    opacity: enabled ? 1 : 0.4
    Row {
        id: r
        anchors.centerIn: parent
        spacing: 5
        Sym { name: b.symbol; size: 12; anchors.verticalCenter: parent.verticalCenter }
        Text { text: b.title; color: Theme.label; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
    }
    MouseArea { id: ma; anchors.fill: parent; onClicked: b.clicked() }
}
