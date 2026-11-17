import QtQuick
import QtQuick.Layouts

// Label(text, systemImage:) at caption size.
RowLayout {
    id: it
    property string symbol: ""
    property string text: ""
    property color color: Theme.label
    property real fontSize: 10
    property bool wrap: false
    spacing: 4
    Sym { name: it.symbol; size: it.fontSize; color: it.color; Layout.alignment: Qt.AlignTop; Layout.topMargin: 1 }
    Text { text: it.text; color: it.color; font.pixelSize: it.fontSize; wrapMode: it.wrap ? Text.WordWrap : Text.NoWrap; Layout.fillWidth: it.wrap }
}
