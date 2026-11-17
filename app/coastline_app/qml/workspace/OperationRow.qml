import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// One operation: on/off, its tool and state; open for its settings, cutting data and the
// generated path's warnings. Port of OperationRow, EngravingFields and ThreadFields.
ColumnLayout {
    id: row
    required property var modelData
    property var ws
    property bool open: false
    readonly property var op: modelData
    readonly property bool generating: (ws.revision, ws.header().isGenerating)
    Layout.fillWidth: true
    spacing: 4

    // The label: chevron, checkbox, the operation's symbol, its title and tool, its state.
    Item {
        Layout.fillWidth: true
        implicitHeight: Math.max(38, titles.implicitHeight + 8)
        Sym { id: chev; name: "chevron.right"; size: 10; weight: "bold"; rotation: row.open ? 90 : 0; anchors.verticalCenter: parent.verticalCenter
            Behavior on rotation { NumberAnimation { duration: 150 } } }
        MouseArea { anchors.fill: parent; onClicked: row.open = !row.open }
        Row {
            x: 18
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            opacity: row.op.enabled ? 1 : 0.5
            CheckMark { anchors.verticalCenter: parent.verticalCenter; checked: row.op.enabled; onToggled: on => row.ws.setOperationField(row.op.id, "enabled", on) }
            Item { width: 18; height: 18; anchors.verticalCenter: parent.verticalCenter
                Sym { anchors.centerIn: parent; name: row.op.symbol; size: 13; color: Theme.accent } }
            Column {
                id: titles
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                Text { text: row.op.title; color: Theme.label; font.pixelSize: 13 }
                Text { text: row.op.toolName || qsTr("No tool chosen"); color: row.op.toolName ? Theme.secondaryLabel : Theme.warning; font.pixelSize: 10
                    width: Math.min(implicitWidth, row.width - 120); elide: Text.ElideRight }
            }
        }
        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Sym { visible: row.op.state === "queued" && row.generating; name: "circle.dotted"; size: 12; color: Theme.secondaryLabel }
            BusyIndicator { visible: row.op.state === "running" && row.generating; running: visible; width: 14; height: 14 }
            Item { visible: row.op.state === "failed"; width: 14; height: 14
                Sym { anchors.centerIn: parent; name: "xmark.octagon.fill"; size: 12; color: Theme.danger }
                MouseArea { id: fm; anchors.fill: parent; hoverEnabled: true }
                ToolTipHelp { text: qsTr("Failed: %1 Retry redoes only this one.").arg(row.op.failed); shown: fm.containsMouse } }
            Item { visible: row.op.warnings.length > 0; width: 14; height: 14
                Sym { anchors.centerIn: parent; name: "exclamationmark.triangle.fill"; size: 12; color: Theme.warning }
                MouseArea { id: wm; anchors.fill: parent; hoverEnabled: true }
                ToolTipHelp { text: row.op.warnings.join("\n"); shown: wm.containsMouse } }
        }
    }

    ColumnLayout {
        visible: row.open
        Layout.fillWidth: true
        Layout.leftMargin: 18
        spacing: 6
        FieldRow {
            label: qsTr("Tool")
            ComboBox {
                width: parent.width
                model: [qsTr("Choose…")].concat(row.op.tools.map(t => t.name))
                currentIndex: row.op.tools.findIndex(t => t.id === row.op.toolId) + 1
                onActivated: i => row.ws.setOperationField(row.op.id, "toolId", i === 0 ? "" : row.op.tools[i - 1].id)
            }
        }
        Label { visible: row.op.explanation !== ""; text: row.op.explanation; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
        FieldRow { visible: row.op.kind === "adaptive"; label: qsTr("Leave on walls"); NumberEdit { value: row.op.leaveRadial; onCommitted: v => row.ws.setOperationField(row.op.id, "leaveRadial", v) } }
        FieldRow { visible: row.op.kind === "adaptive"; label: qsTr("Leave on floors"); NumberEdit { value: row.op.leaveAxial; onCommitted: v => row.ws.setOperationField(row.op.id, "leaveAxial", v) } }
        FieldRow { visible: row.op.kind === "adaptive"; label: qsTr("Depth per pass"); NumberEdit { optional: true; value: row.op.stepdown > 0 ? row.op.stepdown : null; onCommitted: v => row.ws.setOperationField(row.op.id, "stepdown", v === null ? -1 : v) } }
        FieldRow { visible: row.op.kind === "facing"; label: qsTr("Face depth"); NumberEdit { value: row.op.faceDepth; onCommitted: v => row.ws.setOperationField(row.op.id, "faceDepth", v) } }
        CheckBox { visible: row.op.kind === "contour"; text: qsTr("Spring pass"); checked: row.op.springPass; onToggled: row.ws.setOperationField(row.op.id, "springPass", checked) }
        FieldRow { visible: row.op.is3d; label: qsTr("Cusp height"); NumberEdit { value: row.op.cusp; unit: "µm"; decimals: 1; onCommitted: v => row.ws.setOperationField(row.op.id, "cusp", v) } }
        FieldRow { visible: ["parallel", "steep_shallow", "rest"].indexOf(row.op.kind) >= 0; label: qsTr("Pass angle"); NumberEdit { value: row.op.angle; unit: "°"; onCommitted: v => row.ws.setOperationField(row.op.id, "angle", v) } }
        FieldRow { visible: row.op.kind === "steep_shallow"; label: qsTr("Steep from"); NumberEdit { value: row.op.steepAngle; unit: "°"; onCommitted: v => row.ws.setOperationField(row.op.id, "steepAngle", v) } }
        FieldRow { visible: row.op.kind === "thread"; label: qsTr("Thread"); TextField { width: parent.width; text: row.op.thread; onEditingFinished: row.ws.setOperationField(row.op.id, "thread", text) } }
        ColumnLayout {
            visible: row.op.engraving !== null
            Layout.fillWidth: true
            FieldRow { label: qsTr("Text"); TextField { width: parent.width; text: row.op.engraving ? row.op.engraving.text : ""; onEditingFinished: row.ws.setOperationField(row.op.id, "engraving.text", text) } }
            FieldRow { label: qsTr("Depth"); NumberEdit { value: row.op.engraving ? row.op.engraving.depth : 0.15; onCommitted: v => row.ws.setOperationField(row.op.id, "engraving.depth", v) } }
            FieldRow { label: qsTr("On"); Segmented { options: [{value: 0, title: qsTr("Side A")}, {value: 1, title: qsTr("Side B")}]; value: row.op.engraving ? row.op.engraving.side : 0; onPicked: v => row.ws.setOperationField(row.op.id, "engraving.side", v) } }
            CheckBox { text: qsTr("Follow the probed face"); checked: row.op.engraving ? row.op.engraving.probe : false; onToggled: row.ws.setOperationField(row.op.id, "engraving.probe", checked) }
        }
        GridLayout {
            visible: row.op.data.rpm !== undefined
            columns: 2
            columnSpacing: 12
            Label { text: qsTr("Speed"); color: Theme.secondary } Label { text: (row.op.data.rpm || 0) + " RPM" }
            Label { text: qsTr("Feed"); color: Theme.secondary } Label { text: (row.op.data.feed || 0) + " mm/min · plunge " + (row.op.data.plunge || 0) }
            Label { text: qsTr("Chip load"); color: Theme.secondary } Label { text: (row.op.data.chipLoad || "") + " mm/tooth" }
            Label { visible: (row.op.data.stepdown || "") !== ""; text: qsTr("Depth/pass"); color: Theme.secondary } Label { visible: (row.op.data.stepdown || "") !== ""; text: (row.op.data.stepdown || "") + " mm" }
            Label { visible: (row.op.data.stepover || "") !== ""; text: qsTr("Stepover"); color: Theme.secondary } Label { visible: (row.op.data.stepover || "") !== ""; text: (row.op.data.stepover || "") + " mm" }
            Label { text: qsTr("Power"); color: Theme.secondary } Label { text: "≈ " + (row.op.data.power || 0) + " W" }
        }
        Repeater { model: row.op.data.notes || []; delegate: Label { required property var modelData; text: "💡 " + modelData; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont } }
        Repeater { model: row.op.warnings; delegate: Label { required property var modelData; text: "⚠  " + modelData; color: Theme.warning; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont } }
        Repeater { model: row.op.notes; delegate: Label { required property var modelData; text: "✓  " + modelData; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont } }
        RowLayout {
            SmallButton { title: "↑"; onClicked: row.ws.moveOperation(row.op.id, -1) }
            SmallButton { title: "↓"; onClicked: row.ws.moveOperation(row.op.id, 1) }
            Item { Layout.fillWidth: true }
            SmallButton { title: qsTr("Delete Operation"); onClicked: row.ws.removeOperation(row.op.id) }
        }
    }
}
