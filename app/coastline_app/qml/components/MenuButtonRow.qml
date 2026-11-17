import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A Menu as a form row: an icon and a title, the chevron on the right; a click opens it.
Item {
    id: mb
    property string symbol: ""
    property string title: ""
    property string help: ""
    default property alias items: menu.contentData
    Layout.fillWidth: true
    implicitHeight: Math.max(22, t.implicitHeight)
    Row {
        id: r
        spacing: 6
        anchors.verticalCenter: parent.verticalCenter
        Sym { name: mb.symbol; size: 13; anchors.verticalCenter: parent.verticalCenter }
        Text { id: t; text: mb.title; color: Theme.label; font.pixelSize: 13; elide: Text.ElideRight; width: Math.min(implicitWidth, mb.width - 50); anchors.verticalCenter: parent.verticalCenter }
    }
    Rectangle {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 16; height: 16; radius: 8
        color: Qt.rgba(1, 1, 1, 0.14)
        Sym { anchors.centerIn: parent; name: "chevron.down"; size: 8; weight: "bold" }
    }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: menu.popup(mb, 0, mb.height + 4) }
    ToolTipHelp { text: mb.help; shown: ma.containsMouse }
    Menu { id: menu }
}
