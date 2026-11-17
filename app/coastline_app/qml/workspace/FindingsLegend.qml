import QtQuick
import "../components"

// What the colours on the part mean, with counts; the eye hides or shows them.
Rectangle {
    id: legend
    property var ws
    readonly property var d: (ws.revision, ws.findingsLegend())
    visible: d.shown === true
    width: row.implicitWidth + 24
    height: 26
    radius: height / 2
    color: Theme.glass
    border.color: Theme.glassStroke
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 10
        Row {
            visible: legend.d.problems === 0
            spacing: 5
            Sym { name: "checkmark.circle.fill"; size: 10; color: Theme.ok; anchors.verticalCenter: parent.verticalCenter }
            Text { text: qsTr("No problems found"); color: Theme.ok; font.pixelSize: 10; font.weight: Font.DemiBold }
        }
        Repeater {
            model: legend.d.problems > 0 && legend.d.overlay ? legend.d.counts : []
            delegate: Row {
                required property var modelData
                spacing: 4
                Rectangle { width: 9; height: 9; radius: 4.5; color: modelData.color; anchors.verticalCenter: parent.verticalCenter }
                Text { text: modelData.text; color: Theme.label; font.pixelSize: 10 }
            }
        }
        Text {
            visible: legend.d.problems > 0 && !legend.d.overlay
            text: legend.d.problems === 1 ? qsTr("1 problem hidden") : qsTr("%1 problems hidden").arg(legend.d.problems)
            color: Theme.label; font.pixelSize: 10
        }
        Item {
            visible: legend.d.problems > 0
            width: eye.width; height: eye.height
            anchors.verticalCenter: parent.verticalCenter
            Sym { id: eye; name: legend.d.overlay ? "eye" : "eye.slash"; size: 12 }
            MouseArea { id: em; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; onClicked: legend.ws.setFlag("showFindings", !legend.d.overlay) }
            ToolTipHelp { text: legend.d.overlay ? qsTr("Hide the problems on the part") : qsTr("Show the problems on the part"); shown: em.containsMouse }
        }
    }
}
