import QtQuick

// A playback bar button (BarIconLabel on a glass button); accent when on, its name above it
// on hover (BarToggle).
Rectangle {
    id: b
    property string symbol: ""
    property string title: ""
    property string help: ""
    property bool on: false
    signal clicked()
    implicitWidth: 34
    implicitHeight: 28
    radius: 8
    opacity: enabled ? 1 : 0.4
    color: on ? (ma.pressed ? Qt.darker(Theme.accent, 1.2) : Theme.accent)
              : (ma.pressed ? Qt.rgba(0.24, 0.24, 0.25, 0.9) : Qt.rgba(0.2, 0.2, 0.21, 0.86))
    border.color: Theme.glassStroke
    border.width: on ? 0 : 1
    Sym { anchors.centerIn: parent; name: b.symbol; size: 13; weight: "semibold"; color: b.on ? "white" : Theme.label }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: b.clicked() }
    ToolTipHelp { text: b.help; shown: ma.containsMouse }
    Rectangle {
        visible: ma.containsMouse && b.title !== ""
        y: -30
        anchors.horizontalCenter: parent.horizontalCenter
        width: tip.implicitWidth + 18; height: tip.implicitHeight + 8; radius: height / 2
        color: Qt.rgba(0, 0, 0, 0.78)
        Text { id: tip; anchors.centerIn: parent; text: b.title + (b.on ? qsTr(" · on") : qsTr(" · off")); color: "white"; font.pixelSize: 10; font.weight: Font.DemiBold }
    }
}
