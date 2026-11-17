import QtQuick

// A borderless Menu label (.menuStyle(.borderlessButton)): symbol, title, chevron.
Item {
    id: m
    property string title: ""
    property string symbol: ""
    property string help: ""
    signal clicked()
    implicitWidth: r.implicitWidth + 8
    implicitHeight: 20
    opacity: enabled ? 1 : 0.4
    Row {
        id: r
        anchors.centerIn: parent
        spacing: 4
        Sym { visible: m.symbol !== ""; name: m.symbol; size: 10; color: Theme.secondaryLabel; anchors.verticalCenter: parent.verticalCenter }
        Text { text: m.title; color: Theme.secondaryLabel; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
        Sym { name: "chevron.down"; size: 7; weight: "bold"; color: Theme.secondaryLabel; anchors.verticalCenter: parent.verticalCenter }
    }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: m.clicked() }
    ToolTipHelp { text: m.help; shown: ma.containsMouse }
}
