import QtQuick
import QtQuick.Controls
import QtQuick.Window
import QtQuick.Layouts
import "components"
import "pages"
import "jobs"

// The window: a sidebar of pages (Machine · Project · Inventory) and the page on the right.
// Port of Views/ContentView.swift.
ApplicationWindow {
    id: window
    required property var app
    property var backend: app.workspace
    readonly property bool pageReady: pageLoader.status === Loader.Ready

    width: 1171
    flags: Qt.Window | Qt.ExpandedClientAreaHint | Qt.NoTitleBarBackgroundHint
    height: 829
    // Centred on the screen (with the content under the title bar Qt would place it above the top).
    x: Screen.virtualX + Math.max(0, (Screen.desktopAvailableWidth - width) / 2)
    y: Screen.virtualY + Math.max(40, (Screen.desktopAvailableHeight - height) / 2)
    visible: true
    title: "Coastline"
    color: Theme.windowBackground
    // The content reaches under the transparent title bar (the traffic lights float over the sidebar).
    topPadding: 0
    leftPadding: 0
    rightPadding: 0
    bottomPadding: 0
    // Dark controls on every system (Windows in light mode too).
    palette.window: Theme.window
    palette.windowText: Theme.text
    palette.base: Theme.card
    palette.alternateBase: Theme.cardHover
    palette.text: Theme.text
    palette.button: "#2a2a2d"
    palette.buttonText: Theme.text
    palette.brightText: "#ffffff"
    palette.highlight: "#5a5a60"
    palette.highlightedText: "#ffffff"
    palette.light: "#3a3a3e"
    palette.midlight: "#303034"
    palette.mid: "#232326"
    palette.dark: "#121212"
    palette.shadow: "#000000"
    palette.placeholderText: Theme.tertiary
    palette.toolTipBase: "#2a2a2d"
    palette.toolTipText: Theme.text
    palette.link: "#d0d0d0"
    palette.disabled.windowText: Theme.tertiary
    palette.disabled.text: Theme.tertiary
    palette.disabled.buttonText: Theme.tertiary
    palette.disabled.button: "#1f1f22"

    Binding { target: Theme; property: "accentGrey"; value: window.app.settings.accentGrey(window.app.settings.accent) }

    Shortcut { sequence: "Ctrl+Alt+I"; onActivated: window.app.showInspector = !window.app.showInspector }
    Shortcut { sequence: "Ctrl+1"; onActivated: window.app.page = "workspace" }
    Shortcut { sequence: "Ctrl+2"; onActivated: window.app.page = "projects" }
    Shortcut { sequence: "Ctrl+3"; onActivated: window.app.page = "stock" }
    Shortcut { sequence: "Ctrl+4"; onActivated: window.app.page = "tools" }
    Shortcut { sequence: "Ctrl+5"; onActivated: window.app.page = "fixtures" }

    // The sidebar floats over the window background; the page fills the rest (ContentView).
    Sidebar {
        id: sidebar
        app: window.app
        x: 8
        y: 8
        width: 229
        height: window.height - 16
        z: 2
    }
    Loader {
        id: pageLoader
        objectName: "pageLoader"
        x: sidebar.x + sidebar.width + 1
        width: window.width - x
        height: window.height
        readonly property var files: ({tools: "ToolsPage", stock: "StockPage", fixtures: "FixturesPage", measuring: "MeasuringPage",
                                      accessories: "AccessoriesPage", shopping: "ShoppingPage", machine: "MachinePage",
                                      control: "ControlPage", projects: "ProjectsPage", workspace: "WorkspacePage"})
        function load() {
            setSource("pages/" + (files[window.app.page] || "WorkspacePage") + ".qml", {app: window.app})
        }
        Component.onCompleted: load()
        Connections { target: window.app; function onPageChanged() { pageLoader.load() } }
        onStatusChanged: if (status === Loader.Error) console.warn("page failed to load", source)
    }

    MillDialogs { mill: window.app.mill }
    Shortcut { sequence: "Ctrl+Shift+M"; onActivated: window.app.page = "control" }
    Shortcut { sequence: "Ctrl+Shift+H"; onActivated: window.app.mill.feedHold() }
    Shortcut { sequence: "Ctrl+Shift+."; onActivated: window.app.mill.stop() }

    Rectangle {
        visible: window.app.inventory.lastError !== ""
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 20
        radius: height / 2
        color: "#3a1512"
        implicitWidth: errorRow.implicitWidth + 24
        implicitHeight: 36
        RowLayout {
            id: errorRow
            anchors.centerIn: parent
            Text { text: window.app.inventory.lastError; color: Theme.text; font.pixelSize: Theme.fontSize }
            Button { text: "✕"; flat: true; onClicked: window.app.inventory.lastError = "" }
        }
    }

    SettingsDialog { id: settingsDialog; app: window.app }
    Shortcut { sequences: [StandardKey.Preferences, "Ctrl+,"]; onActivated: settingsDialog.open() }

    // Recording a job after it ran (from Review).
    RecordJobDialog { journal: window.app.journal }
}
