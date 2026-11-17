import QtQuick

// A macOS slider: a thin track, the accent fill and a round white knob.
Item {
    id: sl
    property real from: 0
    property real to: 1
    property real value: 0
    signal moved(real value)
    implicitHeight: 20
    implicitWidth: 120
    readonly property real t: to > from ? Math.min(Math.max((value - from) / (to - from), 0), 1) : 0
    Rectangle { id: track; anchors.verticalCenter: parent.verticalCenter; x: 8; width: parent.width - 16; height: 4; radius: 2; color: Qt.rgba(1, 1, 1, 0.15)
        Rectangle { width: parent.width * sl.t; height: parent.height; radius: 2; color: Theme.accent } }
    Rectangle {
        x: track.x + track.width * sl.t - width / 2
        anchors.verticalCenter: parent.verticalCenter
        width: 16; height: 16; radius: 8
        color: "white"
        border.color: Qt.rgba(0, 0, 0, 0.25)
    }
    MouseArea {
        anchors.fill: parent
        function at(mx) { const f = Math.min(Math.max((mx - track.x) / Math.max(track.width, 1), 0), 1); sl.moved(sl.from + f * (sl.to - sl.from)) }
        onPressed: m => at(m.x)
        onPositionChanged: m => { if (pressed) at(m.x) }
    }
}
