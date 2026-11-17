import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
import "../jobs"
import "../workspace"

// Projects: planned projects open in the Workspace; a generated job run on the machine shows
// its steps here; then the Job Journal. Port of Views/ProjectsPage.swift.
PageScaffold {
    id: page
    property var ws: app.workspace
    property var jobs: app.jobs
    property var journal: app.journal
    property string selection: ""   // "project:<path>", "job:<folder>", "journal:<id>"
    title: qsTr("Projects")

    readonly property var head: (ws.revision, ws.header())
    readonly property var jobRows: (jobs.revision, jobs.entryRows())
    readonly property var journalRows: (journal.revision, journal.rows())

    Component.onCompleted: {
        jobs.reloadJobs()
        var pick = ws.takeProjectsPick()
        if (pick !== "") select(pick)
        else if (jobs.runState().title !== undefined) select("job:" + jobRows.find(r => r.selected).folder)
    }

    function select(s) {
        selection = s
        if (s.startsWith("job:")) jobs.selectJob(s.substring(4))
    }
    function openProject(path) { page.app.page = "workspace"; page.ws.openProject(path) }
    function nameOf(path) { return path.split(/[\\/]/).pop().replace(/\.coastline$/, "") }

    SplitView {
        anchors.fill: parent
        orientation: Qt.Horizontal
        handle: Rectangle { implicitWidth: 1; color: Theme.separator }

        Rectangle {
            SplitView.preferredWidth: 459
            SplitView.minimumWidth: 260
            SplitView.maximumWidth: 460
            color: Theme.panelBackground
            Flickable {
                anchors.fill: parent
                contentHeight: listCol.implicitHeight + 12
                clip: true
                ColumnLayout {
                    id: listCol
                    width: parent.width
                    spacing: 6
                    ListSection {
                        title: qsTr("Your Projects")
                        Text {
                            visible: page.head.recentProjects.length === 0 && page.jobRows.length === 0
                            text: qsTr("Projects you save show here, with the jobs you ran on the machine.")
                            color: Theme.secondaryLabel; font.pixelSize: 12; wrapMode: Text.WordWrap
                            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                        }
                        Repeater {
                            model: page.head.recentProjects
                            delegate: ListRow {
                                id: pr
                                required property var modelData
                                selected: page.selection === "project:" + modelData
                                onClicked: page.select("project:" + modelData)
                                onDoubleClicked: page.openProject(modelData)
                                onContextMenu: (x, y) => projMenu.popup()
                                ProjectRow { title: page.nameOf(pr.modelData); detail: qsTr("Planned in Coastline"); symbol: "doc"; selected: pr.selected }
                                Menu {
                                    id: projMenu
                                    MenuItem { text: qsTr("Open"); onTriggered: page.openProject(pr.modelData) }
                                    MenuItem { text: Qt.platform.os === "osx" ? qsTr("Show in Finder") : qsTr("Show in Explorer"); onTriggered: page.ws.revealPath(pr.modelData) }
                                    MenuSeparator {}
                                    MenuItem { text: qsTr("Remove from the List"); onTriggered: { page.ws.removeRecentProject(pr.modelData); if (pr.selected) page.selection = "" } }
                                }
                            }
                        }
                        Repeater {
                            model: page.jobRows
                            delegate: ListRow {
                                id: jr
                                required property var modelData
                                selected: page.selection === "job:" + modelData.folder
                                onClicked: page.select("job:" + modelData.folder)
                                onContextMenu: (x, y) => jobMenu.popup()
                                ProjectRow { title: jr.modelData.title; selected: jr.selected; symbol: "list.bullet.clipboard"
                                    detail: jr.modelData.programs === 1 ? qsTr("From G-code · 1 program") : qsTr("From G-code · %1 programs").arg(jr.modelData.programs) }
                                Menu {
                                    id: jobMenu
                                    MenuItem { text: Qt.platform.os === "osx" ? qsTr("Show in Finder") : qsTr("Show in Explorer"); onTriggered: page.ws.revealPath(jr.modelData.folder) }
                                    MenuSeparator {}
                                    MenuItem { text: qsTr("Delete"); onTriggered: { if (jr.selected) page.selection = ""; page.jobs.deleteJob(jr.modelData.folder) } }
                                }
                            }
                        }
                    }
                    ListSection {
                        title: qsTr("Job Journal")
                        Text {
                            visible: page.journalRows.length === 0
                            text: qsTr("No jobs yet. After a job has run, record it from the Review stage: what you measured, how it went, photos.")
                            color: Theme.secondaryLabel; font.pixelSize: 12; wrapMode: Text.WordWrap
                            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                        }
                        Repeater {
                            model: page.journalRows
                            delegate: ListRow {
                                id: er
                                required property var modelData
                                selected: page.selection === "journal:" + modelData.id
                                onClicked: page.select("journal:" + modelData.id)
                                onContextMenu: (x, y) => entryMenu.popup()
                                Column {
                                    width: parent.width
                                    spacing: 2
                                    Row {
                                        spacing: 6
                                        Sym { anchors.verticalCenter: parent.verticalCenter; size: 12
                                            name: er.modelData.outcomeKey === "good" ? "checkmark.seal.fill" : er.modelData.outcomeKey === "scrapped" ? "xmark.seal.fill" : "exclamationmark.triangle.fill"
                                            color: er.selected ? "white" : er.modelData.outcomeKey === "good" ? Theme.ok : er.modelData.outcomeKey === "scrapped" ? Theme.danger : Theme.warning }
                                        Text { text: er.modelData.part; color: er.selected ? "white" : Theme.label; font.pixelSize: 13; font.weight: Font.Bold }
                                        Text { visible: er.modelData.copies > 1; text: "×" + er.modelData.copies; color: er.selected ? "white" : Theme.secondaryLabel; font.pixelSize: 13 }
                                    }
                                    Text { text: er.modelData.line; color: er.selected ? Qt.rgba(1, 1, 1, 0.8) : Theme.secondaryLabel; font.pixelSize: 10; elide: Text.ElideRight; width: parent.width }
                                }
                                Menu { id: entryMenu; MenuItem { text: qsTr("Delete…"); onTriggered: deleteDialog.ask(er.modelData) } }
                            }
                        }
                    }
                }
            }
        }

        Item {
            SplitView.fillWidth: true
            SplitView.minimumWidth: 420
            Rectangle { anchors.fill: parent; color: Theme.panelBackground }
            Loader {
                anchors.fill: parent
                sourceComponent: page.selection.startsWith("project:") ? projectDetail
                               : page.selection.startsWith("job:") ? jobPane
                               : page.selection.startsWith("journal:") ? journalDetail : nothing
            }
        }
    }

    Component {
        id: nothing
        Item {
            ContentUnavailable {
                anchors.centerIn: parent
                width: parent.width - 80
                title: qsTr("No Project Selected")
                symbol: "folder"
                description: qsTr("Pick a project to see what's in it, or a job from the journal.")
            }
        }
    }
    Component {
        id: projectDetail
        Panel {
            id: pd
            ws: page.ws
            app: page.app
            readonly property string path: page.selection.substring(8)
            readonly property var info: page.ws.projectSummary(path)
            Card {
                large: true
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 16
                    Sym { Layout.alignment: Qt.AlignTop; name: "doc"; size: 60; color: Theme.secondaryLabel }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Text { text: page.nameOf(pd.path); color: Theme.label; font.pixelSize: 17; font.weight: Font.DemiBold; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                        GlassButton { title: qsTr("Open"); symbol: "arrow.forward.circle"; prominent: true; large: false; Layout.topMargin: 4; onClicked: page.openProject(pd.path) }
                    }
                }
            }
            Card {
                large: true
                visible: pd.info.ok === true
                title: qsTr("Job")
                ValueRow { visible: (pd.info.part || "") !== ""; label: qsTr("Part"); value: pd.info.part || "" }
                ValueRow { visible: (pd.info.stock || "") !== ""; label: qsTr("Stock"); value: pd.info.stock || "" }
                ValueRow { label: qsTr("Holding"); value: pd.info.holding || "" }
                ValueRow { label: qsTr("Sides"); value: pd.info.sides || "" }
                ValueRow { label: qsTr("Operations"); value: String(pd.info.operations || 0) }
            }
            Card {
                large: true
                visible: pd.info.ok === true && pd.info.programs > 0
                title: qsTr("Toolpaths")
                footer: qsTr("Saved with the project: it opens ready, nothing is generated again.")
                ValueRow { label: qsTr("Programs"); value: String(pd.info.programs || 0) }
                ValueRow { label: qsTr("Machining"); value: pd.info.machining || "" }
                ValueRow { label: qsTr("Tools"); value: pd.info.tools || "" }
            }
            Card {
                large: true
                visible: pd.info.ok !== true
                Text { text: qsTr("This project file couldn't be read."); color: Theme.secondaryLabel; font.pixelSize: 13 }
            }
            Card {
                large: true
                ValueRow { label: qsTr("File"); value: pd.path }
                LinkButton { symbol: "folder"; title: Qt.platform.os === "osx" ? qsTr("Show in Finder") : qsTr("Show in Explorer"); onClicked: page.ws.revealPath(pd.path) }
            }
        }
    }
    Component { id: jobPane; JobPane { app: page.app } }
    Component { id: journalDetail; JournalDetail { app: page.app; entryId: page.selection.substring(8) } }

    Dialog {
        id: deleteDialog
        property var entry: null
        function ask(e) { entry = e; open() }
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        title: qsTr("Delete the journal entry for %1?").arg(entry ? entry.part : qsTr("this job"))
        Text { text: qsTr("Its measurements and notes go with it. This can't be undone."); color: Theme.secondaryLabel; font.pixelSize: 12 }
        standardButtons: Dialog.Cancel | Dialog.Ok
        onAccepted: { if (page.selection === "journal:" + entry.id) page.selection = ""; page.journal.remove(entry.id) }
    }
}
