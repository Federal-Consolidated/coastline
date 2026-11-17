import QtQuick
import "../components"

// The empty workspace's prompt: import a part. It appears after a moment, so a part being
// opened never flashes it. Port of EmptyWorkspacePrompt.
Rectangle {
    id: card
    signal importPart()
    width: col.implicitWidth + 48
    height: col.implicitHeight + 48
    radius: 22
    color: Qt.rgba(0.15, 0.15, 0.16, 0.96)
    border.color: Theme.glassStroke
    opacity: 0
    Column {
        id: col
        anchors.centerIn: parent
        spacing: 12
        Text { text: qsTr("No part open"); color: Theme.label; font.pixelSize: Theme.title3; font.weight: Font.DemiBold; anchors.horizontalCenter: parent.horizontalCenter }
        Text { text: qsTr("STEP, IGES or Rhino (.3dm). Rhino surfaces are imported exactly."); color: Theme.secondaryLabel; font.pixelSize: Theme.callout; anchors.horizontalCenter: parent.horizontalCenter }
        GlassButton { title: qsTr("Import Part…"); symbol: "square.and.arrow.down"; prominent: true; anchors.horizontalCenter: parent.horizontalCenter; onClicked: card.importPart() }
    }
    onVisibleChanged: { opacity = 0; if (visible) appear.restart() }
    Component.onCompleted: if (visible) appear.restart()
    SequentialAnimation {
        id: appear
        PauseAnimation { duration: 600 }
        NumberAnimation { target: card; property: "opacity"; to: 1; duration: 250; easing.type: Easing.OutQuad }
    }
}
