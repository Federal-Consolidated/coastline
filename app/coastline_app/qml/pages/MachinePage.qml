import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Coastline.Viewport
import "../components"
import "../workspace"

// Machine profiles: each one as a digital model you can move by hand (no physical motion), its
// definition, "Use for Job", and the current machine's maintenance.
// Port of Views/MachineProfilesPage.swift.
PageScaffold {
    id: page
    property var preview: app.machinePreview
    property var library: app.machineProfiles
    property string tab: "motion"
    readonly property var d: (preview.revision, library.revision, preview.info())
    readonly property var maint: (app.journal.revision, app.journal.maintenanceRows())
    title: qsTr("Machine Profiles")
    showMill: false
    Component.onCompleted: { if (page.d.rows.length === 0) page.library.reloadSlot(); else page.preview.load_selected() }
    inspector: Component {
        Item {
            Segmented {
                id: tabs
                anchors.horizontalCenter: parent.horizontalCenter
                y: 12
                options: [{value: "motion", title: qsTr("Setup")}, {value: "definition", title: qsTr("Definition")}]
                value: page.tab
                onPicked: v => page.tab = v
            }
            RowLayout {
                id: status
                visible: page.d.name !== undefined
                x: 16
                width: parent.width - 32
                y: tabs.y + tabs.height + 12
                spacing: 6
                Sym { name: "cube.transparent"; size: 10; color: Theme.secondaryLabel }
                Text { text: qsTr("Planning profile"); color: Theme.secondaryLabel; font.pixelSize: 10; Layout.fillWidth: true }
                Text { text: page.d.inJob ? qsTr("In this job") : qsTr("Available"); color: Theme.secondaryLabel; font.pixelSize: 10 }
                InfoTip { text: qsTr("Use for Job applies this machine's model and limits to workspace setup and CAM planning. Physical control is commissioned separately.") }
            }
            Panel {
                visible: page.d.name !== undefined
                anchors.top: status.bottom
                anchors.topMargin: 2
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                ws: page.app.workspace
                app: page.app
                Card {
                    visible: page.tab === "motion" && (page.d.stock || "") !== ""
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: rsCol.implicitHeight
                        Column {
                            id: rsCol
                            spacing: 3
                            Text { text: qsTr("Reference stock"); color: Theme.label; font.pixelSize: 13 }
                            Text { text: page.d.stock || ""; color: Theme.secondaryLabel; font.pixelSize: 10 }
                        }
                        SwitchRow { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; width: 40; label: ""
                            checked: page.d.referenceStock === true; onToggled: on => page.preview.setOption("referenceStock", on) }
                    }
                }
                Card {
                    visible: page.tab === "motion"
                    title: qsTr("Axes · mm")
                    info: qsTr("Moves the digital model within its axis limits. No physical motion or live collision checking.")
                    footer: page.d.referencePose ? qsTr("Choose Show Home to move the axes.") : ""
                    Repeater {
                        model: page.d.axes || []
                        delegate: RowLayout {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            spacing: 6
                            opacity: page.d.referencePose ? 0.45 : 1
                            enabled: !page.d.referencePose
                            Text { text: modelData.name; color: Theme.label; font.pixelSize: 13; font.weight: Font.Bold; Layout.preferredWidth: 14 }
                            SmallButton { symbol: "minus"; implicitWidth: 24; help: qsTr("Move the digital %1 axis by −1 mm").arg(modelData.name); onClicked: page.preview.setAxis(index, modelData.value - 1) }
                            MacSlider { Layout.fillWidth: true; from: modelData.lower; to: modelData.upper; value: modelData.value; onMoved: v => page.preview.setAxis(index, v) }
                            SmallButton { symbol: "plus"; implicitWidth: 24; help: qsTr("Move the digital %1 axis by 1 mm").arg(modelData.name); onClicked: page.preview.setAxis(index, modelData.value + 1) }
                            Text { text: page.d.referencePose ? "—" : modelData.value.toFixed(2); color: Theme.label; font.pixelSize: 11; Layout.preferredWidth: 54; horizontalAlignment: Text.AlignRight }
                        }
                    }
                }
                Card {
                    visible: page.tab === "definition"
                    title: qsTr("Identity")
                    ValueRow { label: qsTr("Name"); value: page.d.name || "" }
                    ValueRow { label: qsTr("Revision"); value: String(page.d.revision || "") }
                    ValueRow { label: qsTr("ID"); value: page.d.id || "" }
                    ValueRow { visible: (page.d.manufacturer || "") !== ""; label: qsTr("Manufacturer"); value: page.d.manufacturer || "" }
                    ValueRow { label: qsTr("Process"); value: qsTr("Three-axis milling") }
                    ValueRow { label: qsTr("Controller"); value: page.d.controller || "" }
                }
                Card {
                    visible: page.tab === "definition"
                    title: qsTr("Spindle & tooling")
                    ValueRow { label: qsTr("Usable speed"); value: page.d.rpm || "" }
                    ValueRow { label: qsTr("Collet"); value: page.d.collet || "" }
                    ValueRow { label: qsTr("Shank limit"); value: page.d.shank || "" }
                    ValueRow { label: qsTr("Tool length limit"); value: page.d.toolLength || "" }
                }
                Card {
                    visible: page.tab === "definition"
                    title: qsTr("Reference frames · mm")
                    Repeater {
                        model: page.d.frames || []
                        delegate: ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 2
                            ValueRow { label: modelData.id; value: modelData.origin }
                            Text { text: qsTr("Attached to %1").arg(modelData.component); color: Theme.secondaryLabel; font.pixelSize: 10 }
                        }
                    }
                }
                Card {
                    visible: page.tab === "definition"
                    title: qsTr("Mounting interfaces")
                    Repeater {
                        model: page.d.mounts || []
                        delegate: ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            ValueRow { label: modelData.id; value: qsTr("%1 T-slots").arg(modelData.slots.length) }
                            Repeater { model: modelData.slots; delegate: ValueRow { required property var modelData; label: modelData.id; value: modelData.size } }
                        }
                    }
                }
                Card {
                    visible: page.tab === "definition"
                    title: qsTr("Assemblies")
                    Repeater { model: page.d.components || []; delegate: ValueRow { required property var modelData; label: modelData.id; value: modelData.parent } }
                }
                Item { Layout.preferredHeight: 16 }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        // The header: the profile, Use for Job, Import and More.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 44
            color: Theme.panelBackground
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
            RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 12
                Text { visible: page.d.rows.length > 0; text: qsTr("Profile"); color: Theme.label; font.pixelSize: 11 }
                Rectangle {
                    visible: page.d.rows.length > 0
                    implicitWidth: Math.min(330, profilePicker.implicitWidth + 30)
                    implicitHeight: 20
                    radius: 5
                    color: Qt.rgba(1, 1, 1, 0.12)
                    PopupPicker {
                        id: profilePicker
                        anchors.fill: parent
                        anchors.leftMargin: 8; anchors.rightMargin: 4
                        implicitWidth: 120
                        value: page.d.selected
                        options: page.d.rows.map(r => ({title: r.title, value: r.key}))
                        onPicked: v => page.library.selectedKey = v
                    }
                }
                Item { Layout.fillWidth: true }
                SmallButton {
                    visible: page.d.name !== undefined
                    title: page.d.inJob ? qsTr("Used for Job") : qsTr("Use for Job")
                    symbol: page.d.inJob ? "checkmark" : "checkmark.circle"
                    enabled: !page.d.inJob && !page.d.loading
                    help: qsTr("Use this machine for the current job and new jobs. Generated toolpaths will be cleared.")
                    onClicked: page.preview.useForJob()
                }
                SmallButton { title: qsTr("Import Profile…"); symbol: "square.and.arrow.down"; onClicked: importDialog.open() }
                MenuLabel {
                    id: moreMenu
                    title: qsTr("More"); symbol: "ellipsis.circle"
                    onClicked: more.popup(moreMenu, 0, moreMenu.height + 4)
                    Menu {
                        id: more
                        MenuItem { text: qsTr("Reload Profiles"); onTriggered: page.library.reloadSlot() }
                        MenuSeparator {}
                        MenuItem { text: qsTr("Current Machine & Maintenance…"); onTriggered: maintenance.open() }
                    }
                }
            }
        }
        // The preview bar.
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.topMargin: 8; Layout.bottomMargin: 8
            spacing: 10
            SmallButton { title: qsTr("Reference Pose"); help: qsTr("Show the CAD model exactly as exported, which may lie outside operating travel"); onClicked: page.preview.showReference() }
            SmallButton { title: qsTr("Show Home"); symbol: "house"; help: qsTr("Preview the profile's home position without moving a physical machine"); onClicked: page.preview.showHome() }
            Item { Layout.fillWidth: true }
            MenuLabel {
                id: viewMenu
                title: qsTr("View"); symbol: "cube"
                onClicked: views.popup(viewMenu, 0, viewMenu.height + 4)
                Menu {
                    id: views
                    MenuItem { text: qsTr("Isometric"); onTriggered: page.preview.setView("iso") }
                    MenuItem { text: qsTr("Front"); onTriggered: page.preview.setView("front") }
                    MenuItem { text: qsTr("Top"); onTriggered: page.preview.setView("top") }
                    MenuItem { text: qsTr("Right"); onTriggered: page.preview.setView("right") }
                    MenuSeparator {}
                    MenuItem { text: qsTr("Reference Stock"); checkable: true; checked: page.d.referenceStock === true; enabled: (page.d.stock || "") !== ""; onTriggered: page.preview.setOption("referenceStock", checked) }
                    MenuItem { text: qsTr("Enclosure"); checkable: true; checked: page.d.enclosure === true; onTriggered: page.preview.setOption("enclosure", checked) }
                    MenuItem { text: qsTr("Moving Parts Only"); checkable: true; checked: page.d.movingOnly === true; onTriggered: page.preview.setOption("movingOnly", checked) }
                    MenuItem { text: qsTr("Frames & T-slots"); checkable: true; checked: page.d.interfaces === true; onTriggered: page.preview.setOption("interfaces", checked) }
                }
            }
            SmallButton { symbol: "viewfinder"; implicitWidth: 28; help: qsTr("Fit machine in the view"); onClicked: page.preview.frame() }
        }
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Rectangle { anchors.fill: parent; color: Theme.windowBackground }
            Viewport {
                id: view
                anchors.fill: parent
                scene: page.preview.viewScene
                Component.onCompleted: page.preview.attachViewport(view)
                Component.onDestruction: page.preview.detachViewport(view)
            }
            Row {
                anchors.centerIn: parent
                visible: page.d.loading === true
                spacing: 8
                BusyIndicator { running: parent.visible; width: 16; height: 16 }
                Text { text: qsTr("Loading machine model…"); color: Theme.secondaryLabel; font.pixelSize: 12 }
            }
            ContentUnavailable {
                visible: (page.d.problem || "") !== ""
                anchors.centerIn: parent
                width: parent.width * 0.6
                title: qsTr("Couldn't Load Model")
                symbol: "cube"
                description: page.d.problem || ""
            }
        }
        // The footer.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 32
            color: Theme.panelBackground
            Rectangle { width: parent.width; height: 1; color: Theme.separator }
            Row {
                x: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10
                Row { spacing: 5
                    Sym { name: "cube.transparent"; size: 10; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: qsTr("Digital setup"); color: Theme.label; font.pixelSize: 10; font.weight: Font.DemiBold } }
                Text { text: page.d.referencePose ? qsTr("CAD reference pose") : qsTr("Digital axis position"); color: Theme.secondaryLabel; font.pixelSize: 10 }
            }
        }
    }

    FolderDialog {
        id: importDialog
        title: qsTr("Choose a machine profile folder")
        onAccepted: page.library.install(page.app.localPath(selectedFolder))
    }

    Dialog {
        id: maintenance
        title: qsTr("Current machine & maintenance")
        modal: true
        anchors.centerIn: Overlay.overlay
        width: 520
        standardButtons: Dialog.Close
        ColumnLayout {
            anchors.fill: parent
            spacing: 8
            Label { text: qsTr("Machine Control drives %1.").arg(page.app.controlMachineName); color: Theme.secondary }
            Repeater {
                model: page.maint
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Label { text: (modelData.due ? "⚠  " : "") + modelData.title; color: modelData.due ? Theme.warning : Theme.text; font.weight: Font.DemiBold }
                        Label { text: modelData.why || modelData.detail; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.smallFont }
                    }
                    Button { text: qsTr("Done"); onClicked: page.app.journal.markDone(modelData.id) }
                }
            }
        }
    }
}
