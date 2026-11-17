import QtQuick
import QtQuick.Layouts

// A finding or a setup as a row: an icon (or a numbered dot), the title and the summary.
Item {
    id: fr
    property string title: ""
    property string summary: ""
    property string symbol: ""
    property color symbolColor: Theme.label
    property string number: ""
    property color numberColor: Theme.ok
    property bool selected: false
    signal clicked()
    Layout.fillWidth: true
    implicitHeight: col.implicitHeight
    Rectangle { visible: fr.selected; anchors.fill: parent; anchors.margins: -4; radius: 6; color: Qt.rgba(1, 1, 1, 0.08) }
    Item {
        width: 18; height: 18
        Rectangle { visible: fr.number !== ""; anchors.fill: parent; radius: 9; color: fr.numberColor
            Text { anchors.centerIn: parent; text: fr.number; color: "white"; font.pixelSize: 11; font.weight: Font.Bold } }
        Sym { visible: fr.number === ""; anchors.centerIn: parent; name: fr.symbol; size: 12; color: fr.symbolColor }
    }
    Column {
        id: col
        x: 26
        width: parent.width - 26
        spacing: 2
        Text { text: fr.title; color: Theme.label; font.pixelSize: 12; width: parent.width; wrapMode: Text.WordWrap }
        Text { visible: fr.summary !== ""; text: fr.summary; color: Theme.secondaryLabel; font.pixelSize: 10; width: parent.width; wrapMode: Text.WordWrap }
    }
    MouseArea { anchors.fill: parent; enabled: fr.enabled; onClicked: fr.clicked() }
}
