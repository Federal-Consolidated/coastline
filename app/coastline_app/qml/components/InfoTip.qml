import QtQuick

// A small ⓘ that shows its text on hover (InfoTip).
Item {
    id: tip
    property string text: ""
    implicitWidth: 13
    implicitHeight: 13
    Sym { anchors.centerIn: parent; name: "info.circle"; size: 11; color: Theme.secondaryLabel }
    MouseArea { id: ma; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true }
    ToolTipHelp { text: tip.text; shown: ma.containsMouse; delay: 200 }
}
