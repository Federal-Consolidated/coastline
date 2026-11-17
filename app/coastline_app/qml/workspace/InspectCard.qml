import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// The clicked toolpath move: operation, role, feed, position and its G-code lines.
FloatCard {
    id: card
    property var ws
    readonly property var d: (ws.revision, ws.inspectedInfo())
    visible: d.operation !== undefined
    RowLayout {
        Layout.fillWidth: true
        Label { text: card.d.operation || ""; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
        ToolButton { text: "✕"; onClicked: card.ws.closeInspected() }
    }
    Label { text: (card.d.role || "") + " · " + (card.d.feed || 0) + " mm/min · at " + (card.d.time || ""); color: Theme.secondary }
    Label { text: card.d.position || ""; font.family: "monospace" }
    Repeater {
        model: card.d.context || []
        delegate: Label {
            required property var modelData
            text: modelData.n + "  " + modelData.text
            font.family: "monospace"
            font.pixelSize: Theme.smallFont
            color: modelData.here ? Theme.text : Theme.tertiary
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
    }
}
