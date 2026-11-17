import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// Measuring results, floating over the viewport.
FloatCard {
    id: hud
    property var ws
    readonly property var d: (ws.revision, ws.measureInfo())
    Label { text: qsTr("Measure"); font.weight: Font.DemiBold }
    Label {
        visible: hud.d.points.length === 0
        text: qsTr("Click a face to see what it is (flat, cylinder radius, curvature). Click a second point for the distance.")
        wrapMode: Text.WordWrap; color: Theme.secondary; Layout.fillWidth: true
    }
    Repeater {
        model: hud.d.points
        delegate: RowLayout {
            required property var modelData
            required property int index
            Label { text: index === 0 ? "A" : "B"; font.weight: Font.Bold }
            Label { text: modelData; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }
    }
    Label { visible: hud.d.distance !== ""; text: hud.d.distance + " mm"; font.pixelSize: 20; font.weight: Font.DemiBold }
    Label { visible: hud.d.delta !== ""; text: hud.d.delta; color: Theme.secondary; font.pixelSize: Theme.smallFont }
}
