import QtQuick
import QtQuick.Layouts

// LabeledContent with a control: the label on the left, the control on the right.
Item {
    id: row
    property string label: ""
    property string help: ""
    default property alias control: holder.data
    Layout.fillWidth: true
    readonly property var first: holder.children.length > 0 ? holder.children[0] : null
    implicitHeight: Math.max(22, labelText.implicitHeight, first ? first.implicitHeight : 0)

    Text {
        id: labelText
        text: row.label
        color: Theme.label
        font.pixelSize: 13
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        width: Math.min(implicitWidth, row.width - holder.width - 10)
    }
    Item {
        id: holder
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(row.first ? Math.max(row.first.implicitWidth, 60) : 0, row.width * 0.62)
        height: row.first ? row.first.implicitHeight : 0
    }
}
