import QtQuick

// On every page: the machine's state (click to open Machine Control), and while it is connected
// Feed Hold, Resume and Stop. Port of Views/Control/MillToolbar.swift.
GlassCapsule {
    id: bar
    property var app
    readonly property bool open: app.mill.state.open === true
    ToolbarIcon {
        symbol: bar.open ? "cable.connector" : "cable.connector.slash"
        title: qsTr("Mill · %1").arg(bar.app.mill.state.stateWord || qsTr("Not connected"))
        showTitle: true
        help: qsTr("Open Machine Control (⇧⌘M)")
        onClicked: bar.app.page = "control"
    }
    ToolbarIcon {
        visible: bar.open || bar.app.page === "control"
        symbol: "pause.fill"; tint: Theme.systemYellow; enabled: bar.open
        help: qsTr("Feed hold (⇧⌘H)"); onClicked: bar.app.mill.feedHold()
    }
    ToolbarIcon {
        visible: bar.open || bar.app.page === "control"
        symbol: "play.fill"; enabled: bar.app.mill.canResume
        help: qsTr("Resume after a feed hold"); onClicked: bar.app.mill.resume()
    }
    ToolbarIcon {
        visible: bar.open || bar.app.page === "control"
        symbol: "stop.fill"; tint: Theme.systemRed; enabled: bar.open
        help: qsTr("Stop the machine (⇧⌘.)"); onClicked: bar.app.mill.stop()
    }
}
