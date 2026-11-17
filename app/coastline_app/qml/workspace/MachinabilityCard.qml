import QtQuick
import QtQuick.Layouts
import "../components"

// Can this part be made with what you own: one row per finding, what blocks the job first.
// Picking a row lights its faces. Port of Views/MachinabilitySection.swift.
Card {
    id: card
    property var ws
    property bool numbered: false   // Plan: rows numbered like the pins on the part
    property bool compact: false    // Plan: one line with the rows behind it
    title: qsTr("Machinability")
    info: qsTr("Checked on the exact CAD as the part sits now, against your tools, collets, stock and machine. Problems are marked on the part: click a pin or a row.")
    footer: compact ? "" : qsTr("Not checked: cutting force, rigidity, clamping, fixtures before toolpaths, and the spindle above the collet nut.")
    readonly property var d: (ws.revision, ws.machinability())
    readonly property var problems: d.ready ? d.findings.filter(f => f.category !== "ok") : []
    readonly property var passed: d.ready ? d.findings.filter(f => f.category === "ok") : []

    RowLayout {
        visible: card.d.ready && card.problems.length === 0
        spacing: 6
        Sym { name: "checkmark.circle"; size: 12; color: Theme.ok }
        Text { text: qsTr("No problems found for this setup."); color: Theme.ok; font.pixelSize: 12 }
    }
    Disclosure {
        visible: card.d.ready && card.problems.length > 0 && card.compact
        title: card.problems.length === 1 ? qsTr("1 warning on this part") : qsTr("%1 warnings on this part").arg(card.problems.length)
        symbol: "exclamationmark.triangle.fill"
        titleColor: Theme.warning
        fontSize: 12
        Repeater { model: card.compact ? card.problems : []; delegate: rowComponent }
    }
    Repeater { model: card.d.ready && !card.compact ? card.problems : []; delegate: rowComponent }
    Disclosure {
        visible: card.passed.length > 0
        title: card.passed.length === 1 ? qsTr("1 check passed") : qsTr("%1 checks passed").arg(card.passed.length)
        fontSize: 12
        Repeater { model: card.passed; delegate: rowComponent }
    }
    RowLayout {
        visible: !card.d.ready && card.d.failed
        FindingRow { title: qsTr("Couldn't check the part"); summary: qsTr("The part analysis failed."); symbol: "exclamationmark.triangle"; symbolColor: Theme.warning }
        GlassButton { title: qsTr("Try Again"); large: false; onClicked: card.ws.retryAnalysisSlot() }
    }
    FindingRow {
        visible: !card.d.ready && !card.d.failed
        title: qsTr("Checking the part…")
        summary: qsTr("Tool reach, access and stock for this setup.")
        symbol: "hourglass"
    }

    Component {
        id: rowComponent
        ColumnLayout {
            id: row
            required property var modelData
            required property int index
            Layout.fillWidth: true
            spacing: 6
            readonly property bool ok: modelData.category === "ok"
            FindingRow {
                title: row.modelData.title
                summary: row.modelData.summary
                selected: row.modelData.selected
                number: card.numbered && !row.ok ? String(row.index + 1) : ""
                numberColor: row.modelData.color
                symbol: row.modelData.symbol
                symbolColor: row.modelData.color
                onClicked: card.ws.selectFinding(row.modelData.id)
            }
            RowLayout {
                visible: row.modelData.selected && row.modelData.fix !== ""
                Layout.fillWidth: true
                spacing: 6
                Sym { name: "wrench.adjustable"; size: 10; Layout.alignment: Qt.AlignTop }
                Text { text: row.modelData.fix; color: Theme.label; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            }
            Text { visible: row.modelData.selected && !card.numbered && row.modelData.measure !== ""; text: row.modelData.measure; color: Theme.secondaryLabel; font.pixelSize: 10 }
            Disclosure {
                visible: row.modelData.selected && !card.numbered && row.modelData.details.length > 0
                title: qsTr("Details")
                fontSize: 10
                Repeater {
                    model: row.modelData.details
                    delegate: Text { required property var modelData; text: modelData; color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                }
            }
            Repeater {
                model: row.modelData.selected && !card.numbered ? row.modelData.stickout : []
                delegate: RowLayout { required property var modelData; spacing: 6
                    Sym { name: "ruler"; size: 10 } Text { text: modelData; color: Theme.label; font.pixelSize: 10 } }
            }
            Flow {
                visible: row.modelData.selected && !card.numbered
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: row.modelData.remedies
                    delegate: GlassButton { required property var modelData; title: modelData.title; large: false; onClicked: card.ws.applyRemedy(row.modelData.id, modelData.index) }
                }
            }
        }
    }
}
