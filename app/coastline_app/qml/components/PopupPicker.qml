import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A Picker in a grouped form (the .menu style): the label on the left, the choice and the
// up/down chevrons on the right; a click opens the menu. Options: [{title, value, header?,
// separator?, enabled?}]; header rows are section titles.
Item {
    id: pk
    property string label: ""
    property var options: []
    property var value
    property string placeholder: ""
    signal picked(var value)
    Layout.fillWidth: true
    implicitHeight: 22
    readonly property var current: options.find(o => !o.header && !o.separator && o.value === value)

    Text {
        id: labelText
        visible: pk.label !== ""
        text: pk.label
        color: Theme.label
        font.pixelSize: 13
        anchors.verticalCenter: parent.verticalCenter
    }
    Row {
        id: choice
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6
        Text {
            text: pk.current ? pk.current.title : pk.placeholder
            color: Theme.label
            font.pixelSize: 13
            elide: Text.ElideRight
            width: Math.min(implicitWidth, pk.width - (pk.label !== "" ? labelText.implicitWidth + 24 : 0) - 26)
            anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
            width: 16; height: 16; radius: 4
            color: Qt.rgba(1, 1, 1, 0.14)
            anchors.verticalCenter: parent.verticalCenter
            Sym { anchors.centerIn: parent; name: "chevron.up.chevron.down"; size: 8; weight: "bold" }
        }
    }
    MouseArea { anchors.fill: choice; anchors.margins: -4; onClicked: menu.popup(choice, 0, choice.height + 4) }
    Menu {
        id: menu
        Repeater {
            model: pk.options
            delegate: MenuItem {
                required property var modelData
                text: modelData.separator ? "" : modelData.title
                height: modelData.separator ? 9 : implicitHeight
                enabled: !modelData.header && !modelData.separator && modelData.enabled !== false
                font.weight: modelData.header ? Font.Bold : Font.Normal
                checkable: !modelData.header && !modelData.separator
                checked: checkable && modelData.value === pk.value
                onTriggered: pk.picked(modelData.value)
            }
        }
    }
}
