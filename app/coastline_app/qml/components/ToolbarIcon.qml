import QtQuick
import QtQuick.Controls

// A toolbar button: an SF Symbol, optionally with its title (labelStyle .titleAndIcon), and a
// menu chevron. The help text shows on hover.
Item {
    id: btn
    property string symbol: ""
    property string title: ""
    property bool showTitle: false
    property bool chevron: false
    property string help: ""
    property bool checked: false
    property color tint: Theme.label
    property real symbolSize: 15
    signal clicked()
    implicitHeight: 34
    implicitWidth: Math.max(36, row.implicitWidth + 20)
    opacity: enabled ? 1 : 0.35
    Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        radius: height / 2
        color: btn.checked ? Qt.rgba(1, 1, 1, 0.16) : mouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent"
    }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Sym { name: btn.symbol; size: btn.symbolSize; color: btn.tint; anchors.verticalCenter: parent.verticalCenter }
        Text { visible: btn.showTitle && btn.title !== ""; text: btn.title; color: btn.tint; font.pixelSize: Theme.title3 - 2; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
        Sym { visible: btn.chevron; name: "chevron.down"; size: 9; weight: "bold"; color: btn.tint; anchors.verticalCenter: parent.verticalCenter }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: btn.clicked()
    }
    ToolTip.visible: mouse.containsMouse && btn.help !== ""
    ToolTip.delay: 800
    ToolTip.text: btn.help
}
