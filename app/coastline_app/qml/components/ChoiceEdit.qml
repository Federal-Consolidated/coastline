import QtQuick
import QtQuick.Controls

// A picker over [{value, title}] that commits the chosen value; drawn like a macOS pop-up in a
// grouped form: the choice and the up/down chevrons, no box.
ComboBox {
    id: box
    property var choices: []
    property var value
    signal committed(var value)
    width: parent ? parent.width : 200
    implicitWidth: Math.max(80, shown.implicitWidth + 30)
    implicitHeight: 22
    model: choices
    textRole: "title"
    valueRole: "value"
    font.pixelSize: 13
    currentIndex: indexOfValue(value)
    onActivated: index => { if (choices[index].value !== value) committed(choices[index].value) }
    onValueChanged: currentIndex = indexOfValue(value)
    onChoicesChanged: currentIndex = indexOfValue(value)
    onCountChanged: currentIndex = indexOfValue(value)
    Component.onCompleted: currentIndex = indexOfValue(value)
    background: Item {}
    indicator: Rectangle {
        x: box.width - width
        anchors.verticalCenter: parent.verticalCenter
        width: 16; height: 16; radius: 4
        color: Qt.rgba(1, 1, 1, 0.14)
        Sym { anchors.centerIn: parent; name: "chevron.up.chevron.down"; size: 8; weight: "bold" }
    }
    contentItem: Text {
        id: shown
        rightPadding: 22
        text: box.displayText
        color: box.enabled ? Theme.label : Theme.secondaryLabel
        font.pixelSize: 13
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
}
