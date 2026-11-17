import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Coastline.Viewport
import "../components"
import "../workspace"

// The workspace: the part, the stock and the machine in 3D, with the job's stages in the
// inspector on the left. Port of Views/WorkspaceView.swift.
PageScaffold {
    id: page
    property var ws: app.workspace
    readonly property var head: (ws.revision, ws.header())
    title: head.hasPart ? head.title : qsTr("Workspace")
    subtitle: ws.status
    inspector: Component { WorkspaceInspector { ws: page.ws; app: page.app } }

    leading: [
        Row {
            y: 9
            ToolbarIcon {
                symbol: "arrow.uturn.backward"
                enabled: page.head.canUndo
                help: page.head.canUndo ? qsTr("Undo %1 (⌘Z)").arg(page.head.undoName) : qsTr("Nothing to undo")
                onClicked: page.ws.undoAction()
            }
            ToolbarIcon {
                symbol: "arrow.uturn.forward"
                enabled: page.head.canRedo
                help: page.head.canRedo ? qsTr("Redo %1 (⇧⌘Z)").arg(page.head.redoName) : qsTr("Nothing to redo")
                onClicked: page.ws.redoAction()
            }
        }
    ]

    inspectorItems: [
        GlassCapsule {
            ToolbarIcon {
                id: machineButton
                symbol: "gearshape.2"
                chevron: true
                enabled: page.head.canChangeMachine
                help: qsTr("Machine for this job. Changing it clears generated toolpaths.")
                onClicked: machineMenu.popup(machineButton, 0, machineButton.height + 6)
                Component.onCompleted: page.ws.loadMachineProfiles()
                Menu {
                    id: machineMenu
                    Repeater {
                        model: (page.ws.revision, page.ws.machineChoices())
                        delegate: MenuItem {
                            required property var modelData
                            text: modelData.title
                            checkable: true
                            checked: modelData.selected
                            onTriggered: page.ws.usePlanningMachine(modelData.key)
                        }
                    }
                    MenuSeparator {}
                    MenuItem { text: qsTr("Machine Profiles…"); onTriggered: page.app.page = "machine" }
                }
            }
        },
        GlassCapsule {
            ToolbarIcon {
                id: resourcesButton
                symbol: "shippingbox"
                chevron: true
                help: qsTr("Apply library edits to this job. Generated toolpaths will be cleared.")
                onClicked: resourcesMenu.popup(resourcesButton, 0, resourcesButton.height + 6)
                Menu {
                    id: resourcesMenu
                    MenuItem { text: qsTr("This job keeps its selected stock, material and tool definitions."); enabled: false }
                    MenuItem { text: qsTr("Update from Library"); enabled: page.head.canChangeMachine && page.head.hasStock; onTriggered: page.ws.updateJobResources() }
                }
            }
        },
        GlassCapsule {
            ToolbarIcon {
                symbol: "square.and.arrow.down"
                enabled: !page.ws.isBusy && !page.head.placing
                help: qsTr("Import Part… (⌘I)")
                onClicked: openDialog.open()
            }
        }
    ]

    Viewport {
        id: viewport
        objectName: "viewport"
        anchors.fill: parent
        scene: page.ws.viewScene
        realistic: page.ws.realistic
        Component.onCompleted: page.ws.attachViewport(viewport)
        Component.onDestruction: page.ws.detachViewport(viewport)
        onClicked: (x, y) => page.ws.click(x, y)
        onCameraChanged: pins.refresh()
    }

    FindingPins { id: pins; anchors.fill: parent; ws: page.ws }
    TypedMoveField { ws: page.ws }

    // Top trailing: the view cube and the jog panel.
    Column {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 10
        anchors.rightMargin: 14
        spacing: 10
        ViewCube {
            width: 96; height: 96
            anchors.right: parent.right
            viewport: viewport
            onPicked: (nx, ny, nz, view) => view !== "" ? page.ws.setView(view) : page.ws.lookFrom(nx, ny, nz)
        }
        JogPanel { visible: page.head.jogOpen; ws: page.ws; anchors.right: parent.right }
    }

    // Bottom: playback and the control bar.
    Column {
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - 32
        spacing: 10
        PlaybackBar {
            visible: page.head.hasTimeline && page.head.showsResults
            ws: page.ws
            width: Math.min(1100, parent.width)
            anchors.horizontalCenter: parent.horizontalCenter
        }
        ControlBar { ws: page.ws; anchors.horizontalCenter: parent.horizontalCenter }
    }

    // Top leading: display modes, banners, legends, the step card.
    Column {
        x: 16
        y: 16
        width: Math.min(360, parent.width - 32)
        spacing: 10
        Loader { sourceComponent: page.head.placing ? placementBanner : viewModes }
        Rectangle {
            visible: page.head.partChanged
            width: changedRow.implicitWidth + 20; height: changedRow.implicitHeight + 20
            radius: height / 2; color: Theme.glass; border.color: Theme.glassStroke
            Row {
                id: changedRow
                anchors.centerIn: parent
                spacing: 10
                Sym { name: "arrow.triangle.2.circlepath"; size: 13; anchors.verticalCenter: parent.verticalCenter }
                Text { text: qsTr("%1 changed on disk").arg(page.head.title); color: Theme.label; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                GlassButton { title: qsTr("Reload"); prominent: true; large: false; onClicked: page.ws.reloadPart() }
            }
        }
        Banner {
            visible: page.ws.errorMessage !== ""
            text: page.ws.errorMessage
            tint: Theme.danger
            action: "✕"
            onTriggered: page.ws.dismissError()
        }
        FindingsLegend { ws: page.ws }
        Banner { visible: page.head.undercutLegend; text: qsTr("Red: faces turned away from the spindle (the back). Machined from side B.") }
        Banner { visible: page.head.loosePieces > 0 && page.head.showsResults; tint: Theme.danger
            text: qsTr("%1 piece(s) come loose here: nothing holds them once cut free.").arg(page.head.loosePieces) }
        MeasureHud { visible: page.ws.measuring; ws: page.ws; width: parent.width }
        ToolChangeCard { ws: page.ws; width: parent.width }
        StepCard {
            ws: page.ws
            width: parent.width
            visible: page.head.showsResults && page.head.showStepCard && !page.ws.measuring && !page.head.placing
                     && (page.ws.revision, page.ws.toolChangeCard().phase === undefined)
                     && (page.ws.revision, page.ws.inspectedInfo().operation === undefined)
        }
        Banner {
            visible: page.head.manualEdgeFinding
            tint: Theme.warning
            text: qsTr("Simulation only: by hand at the machine. The machine can't feel this stock (not insulated, or against the acetal stop on the bed). In Machine Control, jog the spinning edge finder to each edge until it kicks, then store it. This shows only the order and the edges.")
        }
        InspectCard { ws: page.ws; width: parent.width }
    }

    EmptyWorkspacePrompt {
        visible: !page.head.hasPart && page.head.machineLoaded && !page.ws.isBusy
        anchors.centerIn: parent
        onImportPart: openDialog.open()
    }

    Component { id: viewModes; ViewModeBar { ws: page.ws } }
    Component { id: placementBanner; Banner { text: qsTr("Placing a fixture: pick a piece, drag the arrows to move and the rings to turn it.") } }

    function save() { if (!ws.saveProject()) saveProjectDialog.open() }

    Shortcut { sequences: [StandardKey.Undo]; enabled: page.visible; onActivated: page.ws.undoAction() }
    Shortcut { sequences: [StandardKey.Redo]; enabled: page.visible; onActivated: page.ws.redoAction() }
    Shortcut { sequences: [StandardKey.Save]; enabled: page.visible; onActivated: page.save() }
    Shortcut { sequences: [StandardKey.Open]; enabled: page.visible; onActivated: openProjectDialog.open() }
    Shortcut { sequence: "Ctrl+I"; enabled: page.visible; onActivated: openDialog.open() }
    Shortcut { sequence: "Ctrl+G"; enabled: page.visible; onActivated: page.ws.generate() }
    Shortcut { sequence: "Space"; enabled: page.visible && page.head.hasTimeline; onActivated: page.ws.togglePlay() }
    Shortcut { sequence: "M"; enabled: page.visible && page.head.hasPart; onActivated: page.ws.measuring = !page.ws.measuring }
    Shortcut { sequence: "Escape"; enabled: page.visible; onActivated: { page.ws.closeTypedMove(); page.ws.cancelToolChange() } }

    DropArea {
        anchors.fill: parent
        onDropped: drop => {
            if (!drop.hasUrls) return
            var u = String(drop.urls[0])
            if (u.toLowerCase().endsWith(".coastline")) page.ws.openProject(u); else page.ws.importPart(u)
        }
    }
    FileDialog {
        id: openDialog
        title: qsTr("Import Part")
        nameFilters: [qsTr("CAD files (*.step *.stp *.iges *.igs *.3dm)"), qsTr("All files (*)")]
        onAccepted: page.ws.importPart(String(selectedFile))
    }
    FileDialog {
        id: openProjectDialog
        title: qsTr("Open Job")
        nameFilters: [qsTr("Coastline jobs (*.coastline)"), qsTr("All files (*)")]
        onAccepted: page.ws.openProject(String(selectedFile))
    }
    FileDialog {
        id: saveProjectDialog
        title: qsTr("Save Job")
        fileMode: FileDialog.SaveFile
        defaultSuffix: "coastline"
        nameFilters: [qsTr("Coastline jobs (*.coastline)")]
        currentFile: page.ws.suggestedProjectName()
        onAccepted: page.ws.saveProjectAs(String(selectedFile))
    }
}
