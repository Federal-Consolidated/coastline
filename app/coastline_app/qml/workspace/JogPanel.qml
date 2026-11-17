import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// Jogging the modelled machine by hand: machine and work coordinates, named places, a bit in
// the collet or not. Port of Views/JogPanel.swift.
FloatCard {
    id: panel
    property var ws
    property real step: 1
    readonly property var d: (ws.revision, ws.jogInfo())
    implicitWidth: 280
    Label { text: qsTr("Jog"); font.weight: Font.DemiBold }
    Label { text: "X %1  Y %2  Z %3".arg(panel.d.x.toFixed(2)).arg(panel.d.y.toFixed(2)).arg(panel.d.z.toFixed(2)); font.family: "monospace" }
    Label {
        visible: panel.d.work.length === 3
        text: qsTr("Work") + "  X %1  Y %2  Z %3".arg((panel.d.work[0] || 0).toFixed(2)).arg((panel.d.work[1] || 0).toFixed(2)).arg((panel.d.work[2] || 0).toFixed(2))
        color: Theme.secondary; font.family: "monospace"
    }
    Segmented {
        options: [{value: 0.1, title: "0.1"}, {value: 1, title: "1"}, {value: 10, title: "10"}, {value: 50, title: "50"}]
        value: panel.step
        onPicked: v => panel.step = v
    }
    GridLayout {
        columns: 3
        Repeater {
            model: [["X+", 0, 1], ["Y−", 1, -1], ["Z+", 2, 1], ["X−", 0, -1], ["Y+", 1, 1], ["Z−", 2, -1]]
            delegate: Button {
                required property var modelData
                text: modelData[0]
                Layout.fillWidth: true
                onClicked: panel.ws.jogBy(modelData[1], modelData[2] * panel.step)
            }
        }
    }
    ComboBox {
        Layout.fillWidth: true
        model: [qsTr("No bit")].concat(panel.d.tools.map(t => t.name))
        currentIndex: Math.max(0, panel.d.tools.findIndex(t => t.name === panel.d.tool) + 1)
        onActivated: i => panel.ws.setJogTool(i === 0 ? "" : panel.d.tools[i - 1].id)
    }
    ComboBox {
        Layout.fillWidth: true
        displayText: qsTr("Go to…")
        model: panel.d.places.map(p => p.name)
        onActivated: i => panel.ws.jogToPlace(panel.d.places[i].q)
    }
}
