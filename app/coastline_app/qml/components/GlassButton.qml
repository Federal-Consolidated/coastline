import QtQuick

// SwiftUI's .glass / .glassProminent button (and GlassToggle: accent-tinted when on).
Rectangle {
    id: b
    property string title: ""
    property string symbol: ""
    property bool prominent: false
    property bool on: false
    property bool large: true
    property bool iconOnly: false
    property string help: ""
    signal clicked()
    readonly property bool tinted: prominent || on
    implicitHeight: large ? 33 : 26
    implicitWidth: row.implicitWidth + (iconOnly ? 18 : large ? 32 : 24)
    radius: height / 2
    color: tinted ? (ma.pressed ? Qt.darker(Theme.accent, 1.2) : Theme.accent)
                  : (ma.pressed ? Qt.rgba(0.24, 0.24, 0.25, 0.9) : ma.containsMouse ? Qt.rgba(0.2, 0.2, 0.21, 0.86) : Theme.glass)
    border.color: Theme.glassStroke
    border.width: tinted ? 0 : 1
    opacity: enabled ? 1 : 0.4
    Behavior on color { ColorAnimation { duration: 150 } }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 7
        Sym { name: b.symbol; size: b.large ? 13 : 11; color: b.tinted ? "white" : Theme.label; anchors.verticalCenter: parent.verticalCenter }
        Text {
            visible: !b.iconOnly && b.title !== ""
            text: b.title
            color: b.tinted ? "white" : Theme.label
            font.pixelSize: b.large ? 13 : 12
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: b.clicked() }
    ToolTipHelp { text: b.help; shown: ma.containsMouse }
}
