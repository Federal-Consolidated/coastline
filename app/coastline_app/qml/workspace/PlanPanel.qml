import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// Plan: what the part needs from your tools and stock, then the toolpaths and the setups that
// come out of them. Port of JobPlanInspector (Views/JobPlanningGuide.swift), PlanOptionsView
// and PlanCoverageSection.
Item {
    id: panel
    property var ws
    property var app
    readonly property var p: (ws.revision, ws.planInspector())

    Panel {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: bar.top
        ws: panel.ws
        app: panel.app

        Card {
            title: qsTr("The job")
            ValueRow { label: qsTr("Part"); value: panel.p.part }
            ValueRow { label: qsTr("Stock"); value: panel.p.stock }
            Item {
                Layout.fillWidth: true
                implicitHeight: whLabel.implicitHeight
                Text { id: whLabel; text: qsTr("Workholding"); color: Theme.label; font.pixelSize: 13 }
                Text {
                    anchors.right: parent.right
                    text: panel.p.workholding
                    color: Theme.systemBlue
                    font.pixelSize: 13
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.width - whLabel.implicitWidth - 16)
                    horizontalAlignment: Text.AlignRight
                    MouseArea { id: whm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: panel.ws.enterStage("setups") }
                    ToolTipHelp { text: qsTr("Change the workholding in Setups"); shown: whm.containsMouse }
                }
            }
            ValueRow { label: qsTr("Usable tools"); value: String(panel.p.usableTools) }
        }

        Card {
            visible: panel.p.blocker !== ""
            title: qsTr("Before building")
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Sym { name: "hand.raised.fill"; size: 12; color: Theme.warning; Layout.alignment: Qt.AlignTop }
                Text { text: panel.p.blocker; color: Theme.warning; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            }
            SmallButton { visible: panel.p.blockerSetups; title: qsTr("Go to Setups"); onClicked: panel.ws.enterStage("setups") }
        }

        Card {
            visible: panel.p.options.length > 0
            title: qsTr("Machining alternatives")
            ValueRow { visible: panel.p.chosen !== ""; label: qsTr("Current proposal"); value: panel.p.chosen }
            Disclosure {
                title: qsTr("Compare time, finish and tools")
                Text { visible: panel.p.candidates > 0; text: qsTr("All %1 plans compared").arg(panel.p.candidates); color: Theme.label; font.pixelSize: 12 }
                Repeater {
                    model: panel.p.options
                    delegate: Rectangle {
                        id: opt
                        required property var modelData
                        Layout.fillWidth: true
                        radius: 10
                        color: modelData.chosen ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12) : Qt.rgba(0.55, 0.55, 0.55, 0.07)
                        implicitHeight: oc.implicitHeight + 20
                        ColumnLayout {
                            id: oc
                            x: 10; y: 10
                            width: parent.width - 20
                            spacing: 6
                            RowLayout {
                                Layout.fillWidth: true
                                ColumnLayout {
                                    spacing: 0
                                    Layout.fillWidth: true
                                    Text { text: opt.modelData.head; color: Theme.label; font.pixelSize: 13; font.weight: Font.Bold; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { visible: opt.modelData.rest !== ""; text: opt.modelData.rest; color: Theme.secondaryLabel; font.pixelSize: 10; elide: Text.ElideRight; Layout.fillWidth: true }
                                }
                                Rectangle {
                                    visible: opt.modelData.recommended
                                    implicitWidth: rt.implicitWidth + 12; implicitHeight: rt.implicitHeight + 2; radius: height / 2
                                    color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.2)
                                    Text { id: rt; anchors.centerIn: parent; text: qsTr("Recommended"); color: Theme.accent; font.pixelSize: 10; font.weight: Font.DemiBold }
                                }
                                Sym { visible: opt.modelData.chosen; name: "checkmark.circle.fill"; size: 13; color: Theme.ok }
                                GlassButton { title: qsTr("Use This Plan"); prominent: true; large: false; onClicked: panel.ws.usePlan(opt.modelData.id, true) }
                            }
                            Row {
                                spacing: 12
                                IconText { symbol: "clock"; text: opt.modelData.time }
                                IconText { symbol: "sparkles"; text: opt.modelData.finish }
                                IconText {
                                    symbol: ["gauge.with.dots.needle.0percent", "gauge.with.dots.needle.50percent", "exclamationmark.triangle.fill"][opt.modelData.riskLevel]
                                    text: opt.modelData.risk
                                    color: [Theme.ok, Theme.warning, Theme.danger][opt.modelData.riskLevel]
                                }
                            }
                            Text { text: opt.modelData.ops; color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            Repeater {
                                model: opt.modelData.needs
                                delegate: IconText { required property var modelData; Layout.fillWidth: true; symbol: "cart"; text: modelData; color: Theme.warning; wrap: true }
                            }
                            ColumnLayout {
                                visible: opt.modelData.remedies.length > 0
                                spacing: 4
                                Text { text: qsTr("Make it less risky:"); color: Theme.label; font.pixelSize: 10; font.weight: Font.DemiBold }
                                Repeater {
                                    model: opt.modelData.remedies
                                    delegate: Item {
                                        required property var modelData
                                        implicitWidth: rem.implicitWidth; implicitHeight: rem.implicitHeight
                                        IconText { id: rem; symbol: "wand.and.stars"; text: parent.modelData.title; color: Theme.systemBlue }
                                        MouseArea { anchors.fill: parent; onClicked: panel.ws.applyPlanRemedy(opt.modelData.id, parent.modelData.index) }
                                    }
                                }
                            }
                            Disclosure {
                                title: qsTr("Why")
                                fontSize: 10
                                Repeater {
                                    model: opt.modelData.reasons
                                    delegate: IconText {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        wrap: true
                                        symbol: modelData.startsWith("Risk") ? "exclamationmark.triangle" : "lightbulb"
                                        text: modelData
                                        color: modelData.startsWith("Risk") ? Theme.warning : Theme.secondaryLabel
                                    }
                                }
                            }
                        }
                    }
                }
                Text { text: qsTr("Times are estimates. Generating checks them against the simulation, and Coastline learns your real times from it."); color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            }
        }

        Card {
            visible: panel.p.hasCoverage
            title: qsTr("Setups")
            info: qsTr("All six sides of the stock are checked. Each setup has one side toward the spindle. From the part check: the simulation in Toolpaths shows what the toolpaths really cut.")
            footer: panel.p.open > 0 ? (panel.p.open === 1 ? qsTr("1 feature is not in the toolpaths. Toolpaths are made for the rest.")
                                                          : qsTr("%1 features are not in the toolpaths. Toolpaths are made for the rest.").arg(panel.p.open)) : ""
            Repeater {
                model: panel.p.setups
                delegate: FindingRow {
                    required property var modelData
                    title: modelData.title
                    summary: modelData.summary
                    number: String(modelData.number)
                    numberColor: modelData.toolpaths ? Theme.ok : Theme.categoryColor(3)
                    selected: modelData.selected
                    enabled: modelData.enabled
                    onClicked: panel.ws.selectCoverage(modelData.side)
                }
            }
            Disclosure {
                visible: panel.p.unused.length > 0
                title: qsTr("Other sides: %1 not used").arg(panel.p.unused.length)
                fontSize: 12
                Repeater {
                    model: panel.p.unused
                    delegate: FindingRow { required property var modelData; title: modelData.title; summary: modelData.summary
                        symbol: modelData.fits ? "minus.circle" : "xmark.circle"; symbolColor: modelData.fits ? Theme.secondaryLabel : Theme.categoryColor(0) }
                }
            }
            Repeater {
                model: panel.p.gaps
                delegate: FindingRow {
                    required property var modelData
                    title: modelData.title
                    summary: modelData.summary
                    symbol: modelData.notSupported ? "xmark.octagon" : "circle.dashed"
                    symbolColor: modelData.notSupported ? Theme.categoryColor(0) : Theme.categoryColor(3)
                    selected: modelData.selected
                    onClicked: panel.ws.selectFinding(modelData.finding)
                }
            }
        }

        MachinabilityCard { ws: panel.ws; numbered: true; compact: true }

        Card {
            visible: panel.p.error !== ""
            title: qsTr("Planning needs attention")
            Text { text: panel.p.error; color: Theme.label; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }

        Card {
            LinkButton { symbol: "wrench.and.screwdriver"; title: qsTr("Manage Cutting Tools…"); onClicked: panel.app.page = "tools" }
            LinkButton { symbol: "shippingbox"; title: qsTr("Check Collets…"); onClicked: panel.app.page = "accessories" }
        }
        Item { Layout.preferredHeight: 12 }
    }

    // planningAction, on the bar material at the bottom.
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
            spacing: 8
            RowLayout {
                visible: panel.p.planning
                Layout.fillWidth: true
                BusyIndicator { running: visible; implicitWidth: 16; implicitHeight: 16 }
                Text { text: panel.p.status; color: Theme.label; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
            }
            SmallButton { visible: panel.p.planning && panel.p.generating; title: qsTr("Cancel"); onClicked: panel.ws.cancelGeneration() }
            GlassButton {
                visible: !panel.p.planning
                Layout.fillWidth: true
                title: panel.p.hasPrograms ? qsTr("Rebuild Toolpaths") : qsTr("Build Toolpaths")
                symbol: "sparkles"
                prominent: !panel.p.hasPrograms
                enabled: panel.p.buildBlocker === "" && !panel.p.generating && !panel.p.finding
                onClicked: panel.ws.proposeJob()
            }
            RowLayout {
                visible: !panel.p.planning && panel.p.buildBlocker !== ""
                Layout.fillWidth: true
                Text { text: panel.p.buildBlocker; color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                SmallButton { visible: panel.p.buildBlockerSetups; title: qsTr("Go to Setups"); onClicked: panel.ws.enterStage("setups") }
            }
            GlassButton {
                visible: !panel.p.planning && panel.p.hasPrograms
                Layout.fillWidth: true
                title: qsTr("Inspect Toolpaths")
                symbol: "chevron.right"
                prominent: true
                enabled: !panel.p.needsReview
                onClicked: panel.ws.enterStage("machining")
            }
            Text { visible: !panel.p.planning && panel.p.hasPrograms && panel.p.needsReview; text: qsTr("Review each setup above first."); color: Theme.secondaryLabel; font.pixelSize: 10 }
        }
    }
}
