import QtQuick
import QtQuick.Controls
import "../components"

// How much of the machine to show, as one attached icon selector, the jog panel and the display
// options; beside it how the stock is drawn. Port of Views/ViewModeBar.swift.
Row {
    id: bar
    property var ws
    readonly property var head: (ws.revision, ws.header())
    spacing: 8

    GlassCapsule {
        height: 36
        padding: 6
        spacing: 2
        GlassSelector {
            anchors.verticalCenter: parent.verticalCenter
            options: [{value: "full", symbol: "cube.fill", help: qsTr("Whole machine")},
                      {value: "open", symbol: "cube", help: qsTr("Without enclosure")},
                      {value: "ghost", symbol: "cube.transparent", help: qsTr("Ghosted (see-through)")},
                      {value: "moving", symbol: "arrow.up.and.down.and.arrow.left.and.right", help: qsTr("Moving parts only")},
                      {value: "hidden", symbol: "eye.slash", help: qsTr("Hidden")}]
            value: bar.ws.machineDisplay
            onPicked: v => bar.ws.machineDisplay = v
        }
        Rectangle { width: 1; height: 20; color: Theme.separator; anchors.verticalCenter: parent.verticalCenter; Item { width: 8 } }
        Item { width: 8; height: 1 }
        Item {
            width: 30; height: 26
            anchors.verticalCenter: parent.verticalCenter
            Rectangle { anchors.fill: parent; radius: height / 2; visible: bar.head.jogOpen; color: Qt.rgba(1, 1, 1, 0.13) }
            Sym { anchors.centerIn: parent; name: "dpad"; size: 14 }
            MouseArea { id: jogMa; anchors.fill: parent; hoverEnabled: true; onClicked: bar.ws.setFlag("jogOpen", !bar.head.jogOpen) }
            ToolTipHelp { text: qsTr("Jog the machine: move X, Y and Z by hand, with or without a bit"); shown: jogMa.containsMouse }
        }
        Item {
            width: 40; height: 26
            anchors.verticalCenter: parent.verticalCenter
            Row {
                anchors.centerIn: parent
                spacing: 3
                Sym { name: "slider.horizontal.3"; size: 14; anchors.verticalCenter: parent.verticalCenter }
                Sym { name: "chevron.down"; size: 8; weight: "bold"; anchors.verticalCenter: parent.verticalCenter }
            }
            MouseArea { id: optMa; anchors.fill: parent; hoverEnabled: true; onClicked: options.popup() }
            ToolTipHelp { text: qsTr("Display options"); shown: optMa.containsMouse }
            Menu {
                id: options
                MenuItem { text: qsTr("Realistic Rendering"); checkable: true; checked: bar.ws.realistic; onTriggered: bar.ws.realistic = checked }
                MenuItem { text: qsTr("Chip Guards (Clear)"); checkable: true; checked: bar.ws.showChipGuards; onTriggered: bar.ws.showChipGuards = checked }
                MenuItem { text: qsTr("Show Only the Work"); checkable: true; checked: bar.ws.isolateWork; onTriggered: bar.ws.isolateWork = checked }
                MenuItem { text: qsTr("Work Area"); checkable: true; checked: bar.ws.showWorkArea; onTriggered: bar.ws.showWorkArea = checked }
                MenuItem { text: qsTr("Perspective"); checkable: true; checked: bar.ws.perspective; onTriggered: bar.ws.perspective = checked }
                MenuItem { text: qsTr("Step Card"); checkable: true; checked: bar.head.showStepCard; onTriggered: bar.ws.setFlag("showStepCard", checked) }
                MenuItem { text: qsTr("Next Cut Face Highlight"); checkable: true; checked: bar.head.showCutFace; onTriggered: bar.ws.setFlag("showCutFace", checked) }
                MenuItem { text: qsTr("Highlight Back Faces"); checkable: true; checked: bar.head.showUndercuts; onTriggered: bar.ws.setFlag("showUndercuts", checked) }
                MenuSeparator {}
                MenuItem { text: qsTr("Sweep the Travel"); enabled: bar.head.machineLoaded; onTriggered: bar.ws.sweepTravelSlot() }
            }
        }
    }

    GlassCapsule {
        height: 36
        padding: 6
        spacing: 2
        Item { width: 4; height: 1 }
        Sym { name: "shippingbox"; size: 11; weight: "semibold"; color: Theme.secondaryLabel; anchors.verticalCenter: parent.verticalCenter }
        Item { width: 4; height: 1 }
        GlassSelector {
            anchors.verticalCenter: parent.verticalCenter
            itemWidth: 30
            symbolSize: 14
            options: [{value: "realistic", symbol: "square.fill", help: qsTr("Stock: Realistic")},
                      {value: "seeThrough", symbol: "square.lefthalf.filled", help: qsTr("Stock: See-through")},
                      {value: "wireframe", symbol: "square.dashed", help: qsTr("Stock: Edges")},
                      {value: "hidden", symbol: "eye.slash", help: qsTr("Stock: Hidden")}]
            value: bar.ws.stockDisplay
            onPicked: v => bar.ws.stockDisplay = v
        }
    }
}
