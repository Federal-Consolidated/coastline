import QtQuick
import QtQuick.Layouts
import "../components"

// Machinability on the part (Plan): a numbered pin on every problem area, in its colour, and
// the picked problem's card beside its pin. Port of FindingPinsOverlay and FindingCard.
Item {
    id: layer
    property var ws
    property var pins: []
    property var card: ({})
    function refresh() { pins = ws.findingPins(); card = ws.findingCard() }
    Connections { target: layer.ws; function onRevisionChanged() { layer.refresh() } }
    Repeater {
        model: layer.pins
        delegate: Rectangle {
            required property var modelData
            readonly property real d: modelData.selected ? 26 : 22
            x: modelData.x - d / 2
            y: modelData.y - d / 2
            width: d; height: d; radius: d / 2
            color: modelData.color
            border.color: Qt.rgba(1, 1, 1, modelData.selected ? 1 : 0.8)
            border.width: modelData.selected ? 2 : 1
            Text { anchors.centerIn: parent; text: modelData.number; color: "white"; font.pixelSize: modelData.selected ? 14 : 12; font.weight: Font.Bold }
            MouseArea { id: pm; anchors.fill: parent; hoverEnabled: true; onClicked: layer.ws.selectFinding(modelData.id) }
            ToolTipHelp { text: modelData.title + ": " + modelData.summary; shown: pm.containsMouse }
        }
    }

    // The picked problem's card, beside its pin on the side with more room.
    Rectangle {
        id: cardBox
        visible: layer.card.id !== undefined
        readonly property var anchor: layer.pins.find(p => p.id === layer.card.id)
        width: 320
        height: cardCol.implicitHeight + 24
        radius: 14
        color: Qt.rgba(0.15, 0.15, 0.16, 0.94)
        border.color: Theme.glassStroke
        x: {
            if (!anchor) return Math.max(layer.width - width - 16, 16)
            const v = anchor.x < layer.width / 2 ? anchor.x + 22 : anchor.x - 22 - width
            return Math.min(Math.max(v, 12), Math.max(layer.width - width - 12, 12))
        }
        y: anchor ? Math.min(Math.max(anchor.y - 30, 70), Math.max(layer.height - 330, 70)) : 120
        ColumnLayout {
            id: cardCol
            x: 12; y: 12
            width: parent.width - 24
            spacing: 8
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    width: 20; height: 20; radius: 10
                    color: layer.card.color || "grey"
                    Text { anchors.centerIn: parent; text: layer.card.number || ""; color: "white"; font.pixelSize: 12; font.weight: Font.Bold }
                }
                ColumnLayout {
                    spacing: 1
                    Layout.fillWidth: true
                    Text { text: layer.card.title || ""; color: Theme.label; font.pixelSize: 13; font.weight: Font.Bold; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Text { text: layer.card.category || ""; color: layer.card.color || Theme.secondaryLabel; font.pixelSize: 10 }
                }
                Item {
                    Layout.alignment: Qt.AlignTop
                    width: 14; height: 14
                    Sym { anchors.centerIn: parent; name: "xmark.circle.fill"; size: 13; color: Theme.secondaryLabel }
                    MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: layer.ws.selectFinding(layer.card.id) }
                }
            }
            IconText { visible: (layer.card.measure || "") !== ""; symbol: "ruler"; text: layer.card.measure || ""; color: Theme.secondaryLabel; wrap: true; Layout.fillWidth: true }
            Text { text: layer.card.summary || ""; color: Theme.label; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            IconText { visible: (layer.card.fix || "") !== ""; symbol: "wrench.adjustable"; text: layer.card.fix || ""; fontSize: 12; wrap: true; Layout.fillWidth: true }
            Repeater {
                model: layer.card.remedies || []
                delegate: GlassButton { required property var modelData; title: modelData.title; large: false; onClicked: layer.ws.applyRemedy(layer.card.id, modelData.index) }
            }
            Disclosure {
                visible: (layer.card.details || []).length > 0
                title: qsTr("Details")
                fontSize: 10
                Repeater {
                    model: layer.card.details || []
                    delegate: Text { required property var modelData; text: modelData; color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                }
            }
        }
    }
}
