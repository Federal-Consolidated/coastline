import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// Placing a library fixture: its pieces, snapping, the mechanism's joints or the bookends'
// pressure, grip patches on the stock, and saving it for the job.
// Port of Views/FixturePlacementInspector.swift.
Panel {
    id: panel
    readonly property var d: (ws.revision, ws.placementInfo())

    Card {
        title: qsTr("Placing %1").arg(panel.d.name || "")
        Label { visible: panel.d.loading; text: qsTr("Loading the model…"); color: Theme.secondary }
        Label { visible: (panel.d.error || "") !== ""; text: panel.d.error || ""; color: Theme.danger; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        CheckBox { text: qsTr("Snap to the stock's faces"); checked: panel.d.snap === true; onToggled: panel.ws.placementAction("snap", checked) }
        Label { visible: (panel.d.snaps || []).length > 0; text: qsTr("Snapped to ") + (panel.d.snaps || []).join(", "); color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Button { visible: !panel.d.mechanism && !panel.d.bookends; text: qsTr("Snap to Stock"); onClicked: panel.ws.placementAction("snapToStock", null) }
            Button { visible: !panel.d.mechanism && !panel.d.bookends; text: qsTr("Centre on Stock"); onClicked: panel.ws.placementAction("centre", null) }
            Button { visible: !panel.d.mechanism && !panel.d.bookends; text: qsTr("Align Pair"); onClicked: panel.ws.placementAction("align", null) }
            Button { visible: panel.d.mechanism || panel.d.bookends; text: qsTr("Fit to Stock"); onClicked: panel.ws.placementAction("seat", null) }
        }
    }

    Card {
        title: qsTr("Pieces")
        Repeater {
            model: panel.d.components || []
            delegate: ItemDelegate {
                required property var modelData
                Layout.fillWidth: true
                text: modelData.name
                highlighted: modelData.selected
                onClicked: panel.ws.placementAction("select", modelData.id)
            }
        }
        RowLayout {
            visible: !panel.d.mechanism && !panel.d.bookends
            Label { text: qsTr("Turn"); color: Theme.secondary }
            Button { text: "X 90°"; onClicked: panel.ws.rotatePlacementBy(0, 1) }
            Button { text: "Y 90°"; onClicked: panel.ws.rotatePlacementBy(1, 1) }
            Button { text: "Z 90°"; onClicked: panel.ws.rotatePlacementBy(2, 1) }
        }
    }

    Card {
        visible: (panel.d.controls || []).length > 0
        title: qsTr("Adjust")
        Repeater {
            model: panel.d.controls || []
            delegate: FieldRow {
                required property var modelData
                label: modelData.title
                NumberEdit { value: modelData.value; onCommitted: v => panel.ws.setPlacementJointSlot(modelData.id, v) }
            }
        }
    }

    Card {
        visible: panel.d.bookends !== null && panel.d.bookends !== undefined
        title: qsTr("Bookends")
        FieldRow { label: qsTr("Side screw"); NumberEdit { value: panel.d.bookends ? panel.d.bookends.pressure : 0; onCommitted: v => panel.ws.placementAction("pressure", v) } }
        CheckBox { text: qsTr("Fixed base locked"); checked: panel.d.bookends ? panel.d.bookends.fixedLocked : false; onToggled: panel.ws.placementAction("lockFixed", checked) }
        CheckBox { text: qsTr("Clamp base locked"); checked: panel.d.bookends ? panel.d.bookends.clampLocked : false; onToggled: panel.ws.placementAction("lockClamp", checked) }
    }

    Card {
        title: qsTr("Grip patches")
        Label { text: qsTr("Where the fixture grips or supports the stock. Click Mark, then a face of the stock."); color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        Repeater {
            model: panel.d.contacts || []
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                Label { text: "X%1 Y%2 Z%3 · r %4".arg(modelData.x.toFixed(1)).arg(modelData.y.toFixed(1)).arg(modelData.z.toFixed(1)).arg(modelData.radius.toFixed(1)); Layout.fillWidth: true }
                ToolButton { text: "✕"; onClicked: panel.ws.placementAction("removeContact", modelData.id) }
            }
        }
        Button { text: panel.d.pickingGrip ? qsTr("Click a stock face…") : qsTr("Mark a Grip Patch"); checkable: true; checked: panel.d.pickingGrip === true; onToggled: panel.ws.placementAction("pickGrip", checked) }
        CheckBox { text: qsTr("Grip and cutting load reviewed"); checked: panel.d.reviewed === true; onToggled: panel.ws.placementAction("reviewed", checked) }
    }

    RowLayout {
        Layout.fillWidth: true
        Button { text: qsTr("Cancel"); onClicked: panel.ws.placementAction("cancel", null) }
        Item { Layout.fillWidth: true }
        Button { text: qsTr("Use for This Job"); highlighted: true; onClicked: panel.ws.placementAction("save", null) }
    }
}
