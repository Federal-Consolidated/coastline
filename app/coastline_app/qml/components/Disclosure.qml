import QtQuick
import QtQuick.Layouts

// DisclosureGroup: a chevron and a label; a click shows the content under it.
ColumnLayout {
    id: dg
    property string title: ""
    property color titleColor: Theme.label
    property real fontSize: 13
    property string symbol: ""
    property bool expanded: false
    property bool bold: false
    default property alias content: body.data
    Layout.fillWidth: true
    spacing: 8
    Item {
        Layout.fillWidth: true
        implicitHeight: Math.max(18, t.implicitHeight)
        Row {
            spacing: 6
            anchors.verticalCenter: parent.verticalCenter
            Sym { name: "chevron.right"; size: 10; weight: "bold"; rotation: dg.expanded ? 90 : 0; anchors.verticalCenter: parent.verticalCenter
                Behavior on rotation { NumberAnimation { duration: 150 } } }
            Sym { visible: dg.symbol !== ""; name: dg.symbol; size: dg.fontSize; color: dg.titleColor; anchors.verticalCenter: parent.verticalCenter }
            Text { id: t; text: dg.title; color: dg.titleColor; font.pixelSize: dg.fontSize; font.weight: dg.bold ? Font.DemiBold : Font.Normal; anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea { anchors.fill: parent; onClicked: dg.expanded = !dg.expanded }
    }
    ColumnLayout {
        id: body
        visible: dg.expanded
        Layout.fillWidth: true
        Layout.leftMargin: 16
        spacing: 8
    }
}
