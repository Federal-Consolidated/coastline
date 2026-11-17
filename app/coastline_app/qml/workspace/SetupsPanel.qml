import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// Setups: how the stock is held, which way the part faces, where it sits and work zero.
// Port of JobSetupsInspector, WorkholdingChoiceSection and PlacementSection.
Item {
    id: panel
    property var ws
    property var app
    readonly property var wh: (ws.revision, ws.workholdingChoice())
    readonly property var o: (ws.revision, ws.orientation())
    readonly property var pl: (ws.revision, ws.placement())
    readonly property var head: (ws.revision, ws.header())
    readonly property var stages: (ws.revision, ws.stages())
    readonly property var setupsStage: stages.find(s => s.id === "setups") || {}
    readonly property var planStage: stages.find(s => s.id === "planning") || {}

    Panel {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: bar.top
        ws: panel.ws
        app: panel.app

        Card {
            title: qsTr("Workholding")
            Text {
                visible: panel.wh.fromLibrary && panel.wh.rows.length === 0
                text: qsTr("Add workholding from your library to preview it around this stock.")
                color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true
            }
            Text {
                visible: panel.wh.fromLibrary && panel.wh.automatic
                text: qsTr("Coastline fits these to the stock and picks one for each cut. Click one to place it by hand.")
                color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true
            }
            LinkButton {
                visible: panel.wh.fromLibrary && !panel.wh.automatic && panel.wh.planFromLibrary
                symbol: "wand.and.stars"; title: qsTr("Choose Automatically")
                onClicked: panel.ws.useAutomaticWorkholding()
            }
            Repeater {
                model: panel.wh.fromLibrary ? panel.wh.rows : []
                delegate: Item {
                    id: fx
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: 94
                    opacity: modelData.enabled ? 1 : 0.5
                    Rectangle {
                        id: thumb
                        width: 100; height: 88
                        y: 3
                        radius: 8
                        color: Qt.rgba(0.55, 0.55, 0.55, 0.08)
                        FixtureThumb { anchors.fill: parent; ws: panel.ws; fixtureId: fx.modelData.id; hasModel: fx.modelData.hasModel }
                    }
                    Column {
                        x: thumb.width + 12
                        width: parent.width - x - 24
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        Text { text: fx.modelData.name; color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold; width: parent.width; wrapMode: Text.WordWrap }
                        Text { text: fx.modelData.detail; color: Theme.secondaryLabel; font.pixelSize: 10; width: parent.width; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight }
                    }
                    Sym { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; name: fx.modelData.selected ? "checkmark.circle.fill" : "chevron.right"; size: 12; color: Theme.secondaryLabel }
                    MouseArea {
                        id: fxm
                        anchors.fill: parent
                        enabled: fx.modelData.enabled
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: m => { if (m.button === Qt.RightButton) { if (fx.modelData.selected) ctx.popup() } else panel.ws.placeFixture(fx.modelData.id) }
                    }
                    ToolTipHelp { text: fx.modelData.help; shown: fxm.containsMouse }
                    Menu { id: ctx; MenuItem { text: qsTr("Remove from Job"); onTriggered: panel.ws.removeJobFixture(fx.modelData.id) } }
                }
            }
            LinkButton { visible: panel.wh.fromLibrary; symbol: "plus"; title: qsTr("Add Workholding…"); onClicked: panel.app.page = "fixtures" }
            ValueRow { visible: !panel.wh.fromLibrary; label: qsTr("Method"); value: panel.wh.method }
            LinkButton { visible: !panel.wh.fromLibrary; symbol: "square.grid.2x2"; title: qsTr("Choose from Library"); onClicked: panel.ws.setLibraryPlanning(true) }
            LinkButton { visible: !panel.wh.fromLibrary; title: qsTr("Fixture Placement and Grip…"); onClicked: manual.open() }
        }

        Card {
            title: qsTr("Part orientation and access")
            PopupPicker {
                label: qsTr("First face toward spindle")
                value: panel.o.facing
                options: panel.o.facings.map(f => ({title: f.title, value: f.value}))
                onPicked: v => panel.ws.setFacing(v)
            }
            PopupPicker {
                label: qsTr("Turn around spindle")
                value: panel.o.spin
                options: [0, 1, 2, 3].map(k => ({title: (k * 90) + "°", value: k}))
                onPicked: v => panel.ws.setSpin(v)
            }
            SwitchRow {
                label: qsTr("Machine both sides")
                checked: (panel.ws.revision, panel.ws.sides().twoSided)
                onToggled: on => panel.ws.setTwoSided(on)
            }
            Text { text: qsTr("Plan shows what each orientation can reach. Changing it clears the toolpaths."); color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }

        Card {
            title: qsTr("Placement in the stock")
            info: qsTr("Drag the part in 3D, enter an offset, or snap it to a stock face. Zero allowance is valid for a face that stays as supplied. Grip and fixture clearance depend on your choice in Holding.")
            NumberRow { label: qsTr("Up / down (X)"); value: panel.pl.x; onCommitted: v => panel.ws.setPlacement("x", v) }
            NumberRow { label: qsTr("Left / right (Y)"); value: panel.pl.y; onCommitted: v => panel.ws.setPlacement("y", v) }
            NumberRow { label: qsTr("Below the face (Z)"); value: panel.pl.z; onCommitted: v => panel.ws.setPlacement("z", v)
                tip: qsTr("Stock above the part's top. Zero keeps the existing face and skips automatic facing. More pushes the part toward the back of the stock.") }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: [{t: qsTr("Centre"), s: "dot.squareshape", v: "centre"}, {t: qsTr("To the face"), s: "arrow.up.to.line", v: "face"},
                            {t: qsTr("To the back"), s: "arrow.down.to.line", v: "back"}]
                    delegate: SnapButton { required property var modelData; title: modelData.t; symbol: modelData.s; onClicked: panel.ws.snapPart(modelData.v) }
                }
            }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: [{t: qsTr("Up"), s: "arrow.up", v: "top"}, {t: qsTr("Down"), s: "arrow.down", v: "bottom"},
                            {t: qsTr("Left"), s: "arrow.left", v: "left"}, {t: qsTr("Right"), s: "arrow.right", v: "right"}]
                    delegate: SnapButton { required property var modelData; title: modelData.t; symbol: modelData.s; onClicked: panel.ws.snapPart(modelData.v) }
                }
            }
        }

        Checks { visible: panel.head.hasPart && panel.head.hasStock; issues: (panel.ws.revision, panel.ws.stockContainmentIssues()) }
        Item { Layout.preferredHeight: 12 }
    }

    Rectangle {
        id: bar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: barCol.implicitHeight + 32
        color: Theme.toolbarBackground
        Rectangle { width: parent.width; height: 1; color: Theme.separator }
        ColumnLayout {
            id: barCol
            x: 16; y: 16
            width: parent.width - 32
            spacing: 6
            GlassButton {
                Layout.fillWidth: true
                title: qsTr("Continue to Plan")
                symbol: "chevron.right"
                prominent: true
                enabled: panel.planStage.enabled === true
                onClicked: panel.ws.enterStage("planning")
            }
            Text { visible: panel.setupsStage.state === "todo"; text: panel.setupsStage.why || ""; color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }
    }

    Popup {
        id: manual
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 500; height: 700
        modal: true
        padding: 0
        background: Rectangle { color: Theme.panelBackground; radius: 12; border.color: Theme.glassStroke }
        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            ManualHoldingPanel { ws: panel.ws; app: panel.app; Layout.fillWidth: true; Layout.fillHeight: true }
            RowLayout { Layout.margins: 16; Item { Layout.fillWidth: true } SmallButton { title: qsTr("Done"); onClicked: manual.close() } }
        }
    }
}
