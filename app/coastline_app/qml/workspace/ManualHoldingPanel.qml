import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// Stage 4: workholding, orientation, placement in the stock, the sides and the setups of the
// plan. Port of JobSetupsInspector, WorkholdingChoiceSection, PlacementSection,
// CustomHoldingInspector and LibraryWorkholdingSection.
Panel {
    id: panel
    readonly property var s: (ws.revision, ws.setups())
    readonly property var o: (ws.revision, ws.orientation())
    readonly property var pl: (ws.revision, ws.placement())
    readonly property var sd: (ws.revision, ws.sides())

    Card {
        title: qsTr("Workholding")
        Segmented {
            options: [{value: true, title: qsTr("From my library")}, {value: false, title: qsTr("My own vise / fixture")}]
            value: panel.s.library
            onPicked: v => panel.ws.setLibraryPlanning(v)
        }
        Label {
            visible: panel.s.library
            text: panel.s.automatic ? qsTr("Coastline fits these to the stock and picks one for each cut. Click one to place it by hand.")
                                    : qsTr("Placed by hand for this job.")
            color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        Repeater {
            model: panel.s.library ? panel.s.fixtures : []
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                Label {
                    text: (panel.s.fitted.indexOf(modelData.name) >= 0 ? "✓  " : "") + modelData.name
                    Layout.fillWidth: true; elide: Text.ElideRight
                    color: panel.s.fitted.indexOf(modelData.name) >= 0 ? Theme.text : Theme.secondary
                }
                Button { text: qsTr("Place…"); enabled: modelData.hasModel; onClicked: panel.ws.placeFixture(modelData.id) }
                Button { visible: panel.s.selected.indexOf(modelData.id) >= 0; text: qsTr("Remove"); onClicked: panel.ws.removeJobFixture(modelData.id) }
            }
        }
        Repeater {
            model: panel.s.library && panel.s.fitted.length === 0 ? panel.s.why : []
            delegate: Label { required property var modelData; text: modelData.name + ": " + modelData.why; color: Theme.tertiary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
        }
        Button { visible: panel.s.library && !panel.s.automatic; text: qsTr("Choose Automatically"); onClicked: panel.ws.useAutomaticWorkholding() }
        Button { visible: panel.s.library; text: qsTr("Manage Fixtures…"); flat: true; onClicked: panel.app.page = "fixtures" }
    }

    Card {
        visible: !panel.s.library
        title: qsTr("Vise / custom fixture")
        FieldRow { label: qsTr("Fixture"); TextField { width: parent.width; text: panel.sd.custom.name; onEditingFinished: panel.ws.setCustomFixture("name", text) } }
        FieldRow { label: qsTr("Stock above the table"); NumberEdit { value: panel.sd.custom.height; onCommitted: v => panel.ws.setCustomFixture("height", v) } }
        FieldRow { label: qsTr("Face past table edge"); NumberEdit { value: panel.sd.custom.faceProtrusion; onCommitted: v => panel.ws.setCustomFixture("faceProtrusion", v) } }
        TextArea { Layout.fillWidth: true; placeholderText: qsTr("Setup notes"); text: panel.sd.custom.notes; wrapMode: Text.WordWrap; onEditingFinished: panel.ws.setCustomFixture("notes", text) }
        Label { text: qsTr("Custom fixture geometry is not modelled. Machine and table checks still apply; verify clearance to your vise, jaws and fasteners."); color: Theme.tertiary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
    }

    Card {
        title: qsTr("Part orientation and access")
        FieldRow {
            label: qsTr("Toward the spindle")
            ComboBox {
                width: parent.width
                model: panel.o.facings.map(f => f.title)
                currentIndex: Math.max(0, panel.o.facings.findIndex(f => f.value === panel.o.facing))
                onActivated: i => panel.ws.setFacing(panel.o.facings[i].value)
            }
        }
        FieldRow {
            label: qsTr("Turn around spindle")
            Segmented {
                options: [{value: 0, title: "0°"}, {value: 1, title: "90°"}, {value: 2, title: "180°"}, {value: 3, title: "270°"}]
                value: panel.o.spin
                onPicked: v => panel.ws.setSpin(v)
            }
        }
        CheckBox { text: qsTr("Machine both sides"); checked: panel.sd.twoSided; onToggled: panel.ws.setTwoSided(checked) }
        Label { visible: !panel.sd.twoSided && panel.sd.backHasShape; text: qsTr("⚠  The back has shape (red). From one side it stays uncut."); color: Theme.warning; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        IssueList { issues: panel.o.containment }
    }

    Card {
        title: qsTr("Placement in the stock")
        FieldRow { label: qsTr("Up / down (X)"); NumberEdit { value: panel.pl.x; onCommitted: v => panel.ws.setPlacement("x", v) } }
        FieldRow { label: qsTr("Left / right (Y)"); NumberEdit { value: panel.pl.y; onCommitted: v => panel.ws.setPlacement("y", v) } }
        FieldRow { label: qsTr("Below the face (Z)"); NumberEdit { value: panel.pl.z; onCommitted: v => panel.ws.setPlacement("z", v) } }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: [["centre", qsTr("Centre")], ["face", qsTr("To the face")], ["back", qsTr("To the back")], ["top", qsTr("Up")],
                        ["bottom", qsTr("Down")], ["left", qsTr("Left")], ["right", qsTr("Right")]]
                delegate: Button { required property var modelData; text: modelData[1]; onClicked: panel.ws.snapPart(modelData[0]) }
            }
        }
        Label { text: qsTr("Or drag the part with the arrows in 3D; click an arrow to type a move."); color: Theme.tertiary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
        IssueList { issues: panel.pl.issues }
    }

    Card {
        visible: panel.sd.twoSided || panel.sd.throughExcess >= 0
        title: qsTr("Sides")
        ValueRow { visible: panel.sd.twoSided && panel.sd.split !== ""; label: qsTr("Split at"); value: "Z" + panel.sd.split + qsTr(" (the widest section)") }
        Segmented {
            options: panel.sd.twoSided ? [{value: true, title: qsTr("Tabs")}, {value: false, title: qsTr("Web")}]
                                       : [{value: true, title: qsTr("Cut through, on tabs")}, {value: false, title: qsTr("Leave it on the bar")}]
            value: panel.sd.holdWithTabs
            onPicked: v => panel.ws.setHoldWithTabs(v)
        }
        FieldRow { visible: panel.sd.holdWithTabs; label: qsTr("Tabs (pairs)"); SpinBox { from: 2; to: 8; stepSize: 2; value: panel.sd.tabsCount; onValueModified: panel.ws.setTabs("count", value) } }
        FieldRow { visible: panel.sd.holdWithTabs; label: qsTr("Tab width"); NumberEdit { value: panel.sd.tabsWidth; onCommitted: v => panel.ws.setTabs("width", v) } }
        FieldRow { visible: panel.sd.holdWithTabs; label: qsTr("Tab height"); NumberEdit { value: panel.sd.tabsHeight; onCommitted: v => panel.ws.setTabs("height", v) } }
        Button { visible: panel.sd.holdWithTabs && panel.sd.twoSided; text: qsTr("Suggest for This Material"); flat: true; onClicked: panel.ws.suggestTabs() }
        FieldRow { visible: !panel.sd.holdWithTabs && panel.sd.twoSided; label: qsTr("Web between sides"); NumberEdit { value: panel.sd.web; onCommitted: v => panel.ws.setWebThickness(v) } }
    }

    Card {
        visible: panel.s.library
        title: qsTr("Setups in this plan")
        Label { visible: panel.s.steps.length === 0; text: qsTr("Build the plan to see its setups here."); color: Theme.secondary }
        Repeater {
            model: panel.s.steps
            delegate: Rectangle {
                id: st
                required property var modelData
                Layout.fillWidth: true
                radius: 8
                color: modelData.current ? Theme.selection : Theme.cardHover
                implicitHeight: sc.implicitHeight + 14
                MouseArea { anchors.fill: parent; onClicked: panel.ws.inspectLibraryStep(st.modelData.id) }
                ColumnLayout {
                    id: sc
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 7
                    spacing: 3
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: st.modelData.title; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                        Chip { visible: st.modelData.standIn; text: qsTr("To buy"); tint: Theme.warning }
                        Chip { visible: st.modelData.reviewed; text: qsTr("Reviewed") }
                    }
                    Label { text: st.modelData.operations.join(", "); color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
                    Label { visible: st.modelData.current; text: st.modelData.instructions; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
                    RowLayout {
                        visible: st.modelData.current
                        Button { text: st.modelData.reviewed ? qsTr("Reviewed ✓") : qsTr("Mark Reviewed"); enabled: !st.modelData.reviewed; onClicked: panel.ws.reviewLibraryStep(st.modelData.id) }
                        Button { text: "↑"; onClicked: panel.ws.moveLibraryStep(st.modelData.id, -1) }
                        Button { text: "↓"; onClicked: panel.ws.moveLibraryStep(st.modelData.id, 1) }
                    }
                }
            }
        }
        Label { visible: panel.s.orderNote !== ""; text: panel.s.orderNote; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
        Repeater {
            model: panel.s.issues
            delegate: Label { required property var modelData; text: "⛔  " + modelData; color: Theme.danger; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }
    }

    MachinabilityCard { ws: panel.ws; title: qsTr("Analysis") }
}
