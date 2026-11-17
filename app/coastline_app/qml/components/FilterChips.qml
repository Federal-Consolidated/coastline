import QtQuick

// FilterChips: one glass capsule per option, the chosen one accent-tinted.
Row {
    id: fc
    property var options: []   // [{value, title}]
    property var value
    signal picked(var value)
    spacing: 6
    Repeater {
        model: fc.options
        delegate: Rectangle {
            required property var modelData
            readonly property bool on: fc.value === modelData.value
            implicitWidth: t.implicitWidth + 24
            implicitHeight: t.implicitHeight + 12
            radius: height / 2
            color: on ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55) : Theme.glass
            border.color: Theme.glassStroke
            Behavior on color { ColorAnimation { duration: 200 } }
            Text { id: t; anchors.centerIn: parent; text: modelData.title; color: Theme.label; font.pixelSize: 12; font.weight: parent.on ? Font.DemiBold : Font.Normal }
            MouseArea { anchors.fill: parent; onClicked: fc.picked(modelData.value) }
        }
    }
}
