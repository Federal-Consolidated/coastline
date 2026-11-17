import QtQuick

// One attached icon selector (like Finder's view switcher): the chosen one on an accent capsule.
Row {
    id: sel
    property var options: []      // [{value, symbol, help}]
    property var value
    property real itemWidth: 34
    property real symbolSize: 15
    signal picked(var value)
    spacing: 2
    Repeater {
        model: sel.options
        delegate: Item {
            id: cell
            required property var modelData
            readonly property bool on: sel.value === modelData.value
            width: sel.itemWidth
            height: 26
            anchors.verticalCenter: parent ? parent.verticalCenter : undefined
            Rectangle { anchors.fill: parent; radius: height / 2; color: cell.on ? Theme.accent : "transparent"
                Behavior on color { ColorAnimation { duration: 180 } } }
            Sym { anchors.centerIn: parent; name: cell.modelData.symbol; size: sel.symbolSize; color: cell.on ? "white" : Theme.secondaryLabel }
            MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: sel.picked(cell.modelData.value) }
            ToolTipHelp { text: cell.modelData.help || ""; shown: ma.containsMouse }
        }
    }
}
