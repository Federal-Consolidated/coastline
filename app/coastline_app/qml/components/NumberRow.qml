import QtQuick
import QtQuick.Layouts

// NumberField(title:, value:, tip:): a label (with an optional InfoTip) and a number in mm.
Item {
    id: nr
    property string label: ""
    property string tip: ""
    property var value: 0
    property string unit: "mm"
    property int decimals: 3
    property bool optional: value === null || value === undefined
    signal committed(var value)
    Layout.fillWidth: true
    implicitHeight: 22
    Row {
        spacing: 6
        anchors.verticalCenter: parent.verticalCenter
        Text { text: nr.label; color: Theme.label; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
        InfoTip { visible: nr.tip !== ""; text: nr.tip; anchors.verticalCenter: parent.verticalCenter }
    }
    NumberEdit {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 110
        value: nr.value
        unit: nr.unit
        decimals: nr.decimals
        optional: nr.optional
        onCommitted: v => nr.committed(v)
    }
}
