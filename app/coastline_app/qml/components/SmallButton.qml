import QtQuick

// A bordered push button at .controlSize(.small), with an optional symbol.
Rectangle {
    id: b
    property string title: ""
    property string symbol: ""
    property string help: ""
    property bool chevron: false
    signal clicked()
    implicitWidth: r.implicitWidth + 16
    implicitHeight: 20
    radius: 5
    color: ma.pressed ? Qt.rgba(1, 1, 1, 0.24) : Qt.rgba(1, 1, 1, 0.14)
    opacity: enabled ? 1 : 0.4
    Row {
        id: r
        anchors.centerIn: parent
        spacing: 5
        Sym { visible: b.symbol !== ""; name: b.symbol; size: 10; anchors.verticalCenter: parent.verticalCenter }
        Text { visible: b.title !== ""; text: b.title; color: Theme.label; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
        Sym { visible: b.chevron; name: "chevron.down"; size: 7; weight: "bold"; anchors.verticalCenter: parent.verticalCenter }
    }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: b.clicked() }
    ToolTipHelp { text: b.help; shown: ma.containsMouse }
}
