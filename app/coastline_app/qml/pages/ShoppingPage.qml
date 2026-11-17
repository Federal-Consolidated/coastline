import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
import "../workspace"

// What to buy: workholding and tools this job's plan needs, tools near the end of their life,
// and what recorded jobs taught Coastline. Port of ShoppingListPage (Views/JournalViews.swift).
PageScaffold {
    id: page
    title: qsTr("Shopping List")
    readonly property var job: (app.workspace.revision, app.inventory.revision, app.workspace.jobShopping())
    readonly property var reorder: { app.inventory.revision; app.journal.revision; return app.inventory.shoppingRows() }
    readonly property var learned: (app.journal.revision, app.journal.learnedRows())

    Panel {
        anchors.fill: parent
        ws: page.app.workspace
        app: page.app
        maxWidth: 700

        Card {
            large: true
            visible: page.job.holding.length > 0
            title: qsTr("Workholding for %1").arg(page.job.part)
            footer: qsTr("Once it is in your fixtures with its model, Coastline fits it and makes those setups' toolpaths.")
            Repeater {
                model: page.job.holding
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 3
                    Text { text: modelData.title; color: Theme.label; font.pixelSize: 13; font.weight: Font.Bold; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Text { text: modelData.detail; color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Text { text: qsTr("Add It to My Fixtures…"); color: Theme.systemBlue; font.pixelSize: 10
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: page.app.page = "fixtures" } }
                }
            }
        }
        Card {
            large: true
            visible: page.job.tools.length > 0
            title: qsTr("For %1").arg(page.job.part)
            footer: qsTr("The plan uses these; the toolpaths and simulation are made with them. About %1 in all (typical prices).").arg(page.job.total)
            Repeater {
                model: page.job.tools
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 3
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: modelData.name; color: Theme.label; font.pixelSize: 13; font.weight: Font.Bold; Layout.fillWidth: true; elide: Text.ElideRight }
                        Text { text: modelData.cost; color: Theme.label; font.pixelSize: 13 }
                    }
                    Text { text: modelData.note; color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Text { text: modelData.specs; color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Text { text: qsTr("I Have It Now"); color: Theme.systemBlue; font.pixelSize: 10
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: page.app.inventory.markToolsOwned([modelData.id]) } }
                }
            }
        }
        Card {
            large: true
            title: qsTr("Tools to reorder")
            footer: qsTr("Wear comes from the cutting time of recorded jobs (Taylor tool life, in aluminium). Mark a tool worn or broken in Tools to add it here.")
            RowLayout {
                visible: page.reorder.length === 0
                spacing: 8
                Sym { name: "checkmark.circle"; size: 13; color: Theme.ok }
                Text { text: qsTr("Nothing to buy: no tool is near the end of its life."); color: Theme.ok; font.pixelSize: 13 }
            }
            Repeater {
                model: page.reorder
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 3
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: modelData.name; color: Theme.label; font.pixelSize: 13; font.weight: Font.Bold; Layout.fillWidth: true; elide: Text.ElideRight }
                        Text { text: modelData.cost; color: Theme.label; font.pixelSize: 13 }
                    }
                    Text { text: modelData.why; color: Theme.warning; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Text { visible: modelData.maker !== ""; text: modelData.maker; color: Theme.secondaryLabel; font.pixelSize: 10 }
                    Text { visible: modelData.link !== ""; text: qsTr("Product Page"); color: Theme.systemBlue; font.pixelSize: 10
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Qt.openUrlExternally(modelData.link) } }
                }
            }
        }
        Card {
            large: true
            title: qsTr("Learned from your jobs")
            Text {
                visible: page.learned.length === 0
                text: qsTr("Nothing yet: report chatter when you record a job and Coastline slows that tool kind down in that material.")
                color: Theme.secondaryLabel; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true
            }
            Repeater { model: page.learned; delegate: ValueRow { required property var modelData; label: modelData.label; value: modelData.value } }
        }
        Item { Layout.preferredHeight: 16 }
    }
}
