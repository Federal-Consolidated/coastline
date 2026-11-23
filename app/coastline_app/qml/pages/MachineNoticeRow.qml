import QtQuick
import QtQuick.Layouts
import "../components"

Rectangle {
    id: row
    required property var mill
    readonly property var status: mill.state
    implicitHeight: 48
    color: Theme.panelBackground
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12; anchors.rightMargin: 12
        spacing: 10
        Item {
            Layout.minimumWidth: 125
            Layout.preferredWidth: 125
            Layout.maximumWidth: 125
            implicitHeight: 36
            HoverHandler { id: probeHover }
            ToolTipHelp { text: qsTr("The probe input reports contact, not whether the cable is plugged in."); shown: probeHover.hovered }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Row {
                    spacing: 5
                    Sym { name: "scope"; size: 10; color: probeLabel.color; anchors.verticalCenter: parent.verticalCenter }
                    Text { id: probeLabel; text: row.status.probe || ""; color: row.status.probeTripped ? Theme.warning : Theme.secondaryLabel; font.pixelSize: 10 }
                }
                Text {
                    text: qsTr("Release to continue.")
                    font.pixelSize: 10
                    color: Theme.warning
                    opacity: row.status.probeTripped ? 1 : 0
                    Accessible.ignored: !row.status.probeTripped
                }
            }
        }
        Text {
            Layout.fillWidth: true
            text: (row.status.notice || "") === "" ? qsTr("Machine status and setup messages appear here.") : row.status.notice
            color: (row.status.notice || "") === "" ? Theme.secondaryLabel : Theme.warning
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
        SmallButton { title: row.status.homing ? qsTr("Homing…") : qsTr("Home"); symbol: "house"; enabled: row.mill.canHome
            help: row.status.simulated ? qsTr("Home the digital machine") : qsTr("Home the machine before jogging or setting work zero"); onClicked: row.mill.requestHome() }
        SmallButton { visible: row.status.needsReset === true; title: qsTr("Reset"); symbol: "arrow.counterclockwise"; onClicked: row.mill.softReset() }
    }
}
