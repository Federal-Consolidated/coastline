import QtQuick
import QtQuick.Layouts

// LabeledContent(label, value): the label on the left, the value on the right in grey; a long
// value moves under the label, still right-aligned.
Item {
    id: row
    property string label: ""
    property string value: ""
    property color valueColor: Theme.secondaryLabel
    Layout.fillWidth: true
    // SwiftUI's LabeledContent gives the value about the trailing 70 %: longer values go under the label.
    readonly property bool wraps: valueText.implicitWidth > (width - labelText.implicitWidth - 16) * 0.86
    implicitHeight: wraps ? labelText.implicitHeight + 6 + valueText.height : Math.max(labelText.implicitHeight, valueText.height)
    Text {
        id: labelText
        text: row.label
        color: Theme.label
        font.pixelSize: 13
    }
    Text {
        id: valueText
        text: row.value
        color: row.valueColor
        font.pixelSize: 13
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignRight
        width: row.wraps ? row.width : implicitWidth
        x: row.width - width
        y: row.wraps ? labelText.implicitHeight + 6 : 0
    }
}
