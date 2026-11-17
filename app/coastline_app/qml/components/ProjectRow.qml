import QtQuick

// A project's row: its icon, the title and a caption.
Row {
    id: r
    property string title: ""
    property string detail: ""
    property string symbol: "doc"
    property bool selected: false
    spacing: 10
    width: parent ? parent.width : 300
    Item { width: 32; height: 32
        Sym { anchors.centerIn: parent; name: r.symbol; size: 24; color: r.selected ? "white" : Theme.label } }
    Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        width: r.width - 42
        Text { text: r.title; color: r.selected ? "white" : Theme.label; font.pixelSize: 13; font.weight: Font.Bold; elide: Text.ElideRight; width: parent.width }
        Text { visible: r.detail !== ""; text: r.detail; color: r.selected ? Qt.rgba(1, 1, 1, 0.8) : Theme.secondaryLabel; font.pixelSize: 10; elide: Text.ElideRight; width: parent.width }
    }
}
