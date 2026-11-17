import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// Floating glass controls: views, section, measuring. Port of WorkspaceView.controlBar.
Row {
    id: bar
    property var ws
    readonly property var head: (ws.revision, ws.header())
    spacing: 10

    GlassCapsule {
        height: 35
        padding: 6
        Repeater {
            model: [{v: "tool", t: qsTr("Tool"), h: qsTr("Look down the spindle at the face being cut")},
                    {v: "toolIso", t: qsTr("Tool Iso"), h: qsTr("Tool Iso view")},
                    {v: "front", t: qsTr("Front"), h: qsTr("Front view")},
                    {v: "top", t: qsTr("Top"), h: qsTr("Top view")},
                    {v: "iso", t: qsTr("Iso"), h: qsTr("Iso view")}]
            delegate: Item {
                required property var modelData
                width: lbl.implicitWidth + 18
                height: 35
                Text { id: lbl; anchors.centerIn: parent; text: modelData.t; color: Theme.label; font.pixelSize: 13 }
                MouseArea { id: vm; anchors.fill: parent; hoverEnabled: true; onClicked: bar.ws.setView(modelData.v) }
                ToolTipHelp { text: modelData.h; shown: vm.containsMouse }
            }
        }
        Item {
            width: 32
            height: 35
            Sym { anchors.centerIn: parent; name: "arrow.up.left.and.arrow.down.right"; size: 13 }
            MouseArea { id: fm; anchors.fill: parent; hoverEnabled: true; onClicked: bar.head.placing ? bar.ws.focusPlacementContext() : bar.ws.focusWork() }
            ToolTipHelp { text: bar.head.placing ? qsTr("Frame the fixture, stock, X-table and spindle") : qsTr("Frame the part and stock"); shown: fm.containsMouse }
        }
    }

    GlassButton {
        id: sectionButton
        title: qsTr("Section")
        symbol: "square.split.diagonal"
        on: bar.ws.sectionOn
        onClicked: { bar.ws.sectionOn = !bar.ws.sectionOn; if (bar.ws.sectionOn) sectionPopup.open(); else sectionPopup.close() }
        Popup {
            id: sectionPopup
            y: -implicitHeight - 10
            x: (parent.width - width) / 2
            width: 312
            padding: 16
            background: Rectangle { color: Qt.rgba(0.16, 0.16, 0.17, 0.97); radius: 12; border.color: Theme.glassStroke }
            ColumnLayout {
                width: 280
                spacing: 12
                Text { text: qsTr("Section"); color: Theme.label; font.pixelSize: Theme.headline; font.weight: Font.Bold }
                Segmented {
                    Layout.fillWidth: true
                    options: [{value: "x", title: qsTr("X (vertical)")}, {value: "y", title: "Y"}, {value: "z", title: qsTr("Z (depth)")}]
                    value: bar.ws.sectionAxis
                    onPicked: v => bar.ws.sectionAxis = v
                }
                RowLayout {
                    Slider { from: -60; to: 60; value: bar.ws.sectionOffset; onMoved: bar.ws.sectionOffset = value; Layout.fillWidth: true }
                    Text { text: bar.ws.sectionOffset.toFixed(1) + " mm"; color: Theme.label; font.pixelSize: 13; Layout.preferredWidth: 64; horizontalAlignment: Text.AlignRight }
                }
                Text { text: qsTr("The cut face is drawn hatched, like a drawing's cross-section."); color: Theme.secondaryLabel; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: 10 }
            }
        }
    }

    GlassButton {
        title: qsTr("Measure")
        symbol: "ruler"
        on: bar.ws.measuring
        enabled: bar.head.hasPart && !bar.head.placing
        help: qsTr("Measure faces and distances (M)")
        onClicked: bar.ws.measuring = !bar.ws.measuring
    }
}
