import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// Stage 6: what's ready, the delivery, and recording the job in the journal.
// Port of ReviewInspector (Views/StageViews.swift).
Panel {
    id: panel
    readonly property var s: (ws.revision, ws.setups())
    readonly property var r: (ws.revision, ws.results())
    Card {
        visible: panel.s.library && !panel.s.reviewed
        title: qsTr("Finish setup review")
        Text { text: qsTr("Review the placement, secure grip and work zero of every setup before exporting or running."); color: Theme.secondaryLabel; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        LinkButton { symbol: "hand.raised"; title: qsTr("Review Setups"); onClicked: panel.ws.enterStage("setups") }
    }
    Item { Layout.preferredHeight: 0 }
    ResultsCard { visible: panel.r.programs.length > 0; ws: panel.ws; app: panel.app }
    Card {
        LinkButton { symbol: "book.closed"; title: qsTr("Record This Job in the Journal…"); Layout.fillWidth: true; enabled: panel.r.programs.length > 0; onClicked: panel.ws.recordJob() }
        Text { text: qsTr("After it ran on the machine: what you measured, how it went, photos. Tool wear, the stock and the feeds learn from it."); color: Theme.secondaryLabel; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: 10 }
    }
}
