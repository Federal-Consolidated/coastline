import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

ScrollView {
    id: insp
    property var inventory
    property var app
    property string toolId: ""
    property var tool: { inventory.revision; return toolId === "" ? ({}) : inventory.item("tools", toolId) }
    property string specError: ""
    clip: true
    contentWidth: availableWidth

    function set(key, value) { inventory.setField("tools", toolId, key, value) }

    ContentUnavailable { visible: insp.toolId === ""; anchors.centerIn: parent; title: qsTr("No Tool Selected"); symbol: "wrench.and.screwdriver"; description: "" }

    ColumnLayout {
        visible: insp.toolId !== ""
        x: 10
        width: insp.availableWidth - 20
        spacing: 0

        ColumnLayout {
            visible: insp.tool._needsSpecs !== true
            Layout.fillWidth: true
            Layout.topMargin: 10
            spacing: 8
            PreviewCard {
                app: insp.app
                kind: "tools"
                itemId: insp.toolId
                drawingHeight: 190
                drawing: Component { ToolDrawing { tool: insp.tool } }
            }
            Text { text: qsTr("Drag to orbit · Pinch to zoom · Double-click to fit"); color: Theme.secondaryLabel; font.pixelSize: 10; Layout.leftMargin: 10; Layout.bottomMargin: 4 }
        }
        Card {
            visible: insp.tool._needsSpecs === true
            title: qsTr("Specifications")
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: Theme.secondaryLabel
                font.pixelSize: 10
                text: {
                    insp.tool
                    var missing = insp.inventory.missingSpecifications(insp.toolId)
                    return missing.length === 0 ? qsTr("Values entered. Confirm them against the tool or its specification sheet.")
                                                : qsTr("Still needed: ") + missing.join(", ")
                }
            }
            LinkButton { symbol: "checkmark.circle"; title: qsTr("Confirm Specifications"); onClicked: insp.specError = insp.inventory.confirmSpecifications(insp.toolId) }
            Text { visible: insp.specError !== ""; text: insp.specError; color: Theme.warning; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }
        Card {
            title: qsTr("Tool")
            FieldRow { label: qsTr("Name"); TextEdit { value: insp.tool.name || ""; onCommitted: t => insp.set("name", t) } }
            FieldRow { label: qsTr("Type"); ChoiceEdit { choices: insp.inventory.choices("ToolKind"); value: insp.tool.kind; onCommitted: v => insp.set("kind", v) } }
            FieldRow { label: qsTr("Vendor"); TextEdit { value: insp.tool.vendor || ""; onCommitted: t => insp.set("vendor", t) } }
            FieldRow { label: qsTr("Part number"); TextEdit { value: insp.tool.partNumber || ""; onCommitted: t => insp.set("partNumber", t) } }
            FieldRow { label: qsTr("Intended for"); TextEdit { value: insp.tool.intendedFor || ""; placeholderText: qsTr("e.g. Aluminium, brass"); onCommitted: t => insp.set("intendedFor", t) } }
            Item {
                visible: (insp.tool.productLink || "") !== ""
                Layout.fillWidth: true
                implicitHeight: 18
                Row { spacing: 6
                    Sym { name: "safari"; size: 13; color: Theme.systemBlue; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: qsTr("Product Page"); color: Theme.systemBlue; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter } }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Qt.openUrlExternally(insp.tool.productLink) }
            }
        }
        Card {
            title: qsTr("Geometry")
            NumberRow { label: qsTr("Diameter"); value: insp.tool.diameter || 0; onCommitted: v => insp.set("diameter", v) }
            NumberRow { label: qsTr("Shank diameter"); value: insp.tool.shankDiameter || 0; onCommitted: v => insp.set("shankDiameter", v) }
            StepperRow { label: qsTr("Flutes"); from: (insp.tool.flutes || 0) === 0 ? 0 : 1; to: 8; value: insp.tool.flutes || 0; onCommitted: v => insp.set("flutes", v) }
            NumberRow { label: qsTr("Flute length"); value: insp.tool.fluteLength || 0; onCommitted: v => insp.set("fluteLength", v) }
            NumberRow { label: qsTr("Stick-out"); tip: qsTr("From the collet nut to the tip"); value: insp.tool.stickout || 0; onCommitted: v => insp.set("stickout", v) }
            NumberRow { label: qsTr("Overall length"); value: insp.tool.overallLength || 0; onCommitted: v => insp.set("overallLength", v) }
            FieldRow {
                visible: insp.tool.kind === "bullNoseEndMill"
                label: qsTr("Corner radius")
                NumberEdit { value: insp.tool.cornerRadius; onCommitted: v => insp.set("cornerRadius", v) }
            }
            FieldRow {
                visible: ["chamferMill", "engraver", "drill", "spotDrill"].indexOf(insp.tool.kind) >= 0
                label: insp.tool.kind === "drill" || insp.tool.kind === "spotDrill" ? qsTr("Point angle") : qsTr("Half angle")
                NumberEdit { value: insp.tool.angle === undefined ? null : insp.tool.angle; unit: "°"; optional: true; onCommitted: v => insp.set("angle", v) }
            }
            FieldRow {
                visible: ["chamferMill", "engraver", "drill", "spotDrill"].indexOf(insp.tool.kind) >= 0
                label: qsTr("Tip diameter")
                NumberEdit { value: insp.tool.tipDiameter; onCommitted: v => insp.set("tipDiameter", v) }
            }
        }
        Card {
            title: qsTr("Material")
            FieldRow { label: qsTr("Tool material"); ChoiceEdit { choices: insp.inventory.choices("ToolMaterial"); value: insp.tool.toolMaterial; onCommitted: v => insp.set("toolMaterial", v) } }
            FieldRow { label: qsTr("Coating"); ChoiceEdit { choices: insp.inventory.choices("Coating"); value: insp.tool.coating; onCommitted: v => insp.set("coating", v) } }
        }
        Card {
            title: qsTr("Ownership")
            StepperRow { label: qsTr("Quantity"); value: insp.tool.quantity || 0; onCommitted: v => insp.set("quantity", v) }
            FieldRow { label: qsTr("Condition"); ChoiceEdit { choices: insp.inventory.choices("Condition"); value: insp.tool.condition; onCommitted: v => insp.set("condition", v) } }
            NumberRow { label: qsTr("Price each"); optional: true; value: insp.tool.unitCost === undefined ? null : insp.tool.unitCost; unit: ""; decimals: 2; onCommitted: v => insp.set("unitCost", v) }
            FieldRow { label: qsTr("Notes"); TextEdit { value: insp.tool.notes || ""; onCommitted: t => insp.set("notes", t) } }
            ValueRow { visible: (insp.tool.source || "") !== ""; label: qsTr("Source"); value: insp.tool.source || ""; valueColor: Theme.secondaryLabel }
        }
        Checks { visible: insp.tool._needsSpecs !== true; issues: insp.tool._issues || [] }
        Card {
            visible: (insp.tool.presets || []).length > 0
            title: qsTr("Library presets")
            footer: qsTr("For reference. Coastline computes its own feeds per material and operation.")
            Repeater {
                model: insp.tool.presets || []
                delegate: ColumnLayout {
                    required property var modelData
                    Text { text: modelData.name; color: Theme.label; font.pixelSize: 12; font.weight: Font.Medium }
                    Text { text: Math.round(modelData.rpm) + " RPM · feed " + Math.round(modelData.feed) + " · plunge " + Math.round(modelData.plungeFeed) + " mm/min"; color: Theme.secondaryLabel; font.pixelSize: 10 }
                }
            }
        }
        Item { implicitHeight: 24 }
    }
}
