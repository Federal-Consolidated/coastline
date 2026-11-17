import QtQuick

// ContentUnavailableView: a large symbol, a title and a description, centred.
Column {
    id: cu
    property string title: ""
    property string symbol: ""
    property string description: ""
    spacing: 0
    width: parent ? parent.width - 70 : 280
    Sym { name: cu.symbol; size: 40; color: Theme.secondaryLabel; anchors.horizontalCenter: parent.horizontalCenter }
    Item { width: 1; height: 14 }
    Text { text: cu.title; color: Theme.label; font.pixelSize: 26; font.weight: Font.Bold; anchors.horizontalCenter: parent.horizontalCenter }
    Item { width: 1; height: 8 }
    Text { text: cu.description; color: Theme.secondaryLabel; font.pixelSize: 13; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; width: parent.width }
}
