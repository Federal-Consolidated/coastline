import QtQuick
import QtQuick.Controls

// A text field that commits when editing finishes (Return or focus out).
TextField {
    id: field
    property string value: ""
    signal committed(string text)
    text: value
    color: Theme.label
    font.pixelSize: 13
    selectByMouse: true
    // A text field in a grouped form: borderless, right-aligned, a ring only while typing.
    horizontalAlignment: Text.AlignRight
    padding: 2
    placeholderTextColor: Theme.tertiaryLabel
    background: Rectangle {
        radius: 4
        color: field.activeFocus ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
        border.width: field.activeFocus ? 2 : 0
        border.color: Qt.rgba(Theme.systemBlue.r, Theme.systemBlue.g, Theme.systemBlue.b, 0.6)
    }
    width: parent ? parent.width : 200
    onEditingFinished: if (text !== value) committed(text)
    onValueChanged: if (!activeFocus) text = value
}
