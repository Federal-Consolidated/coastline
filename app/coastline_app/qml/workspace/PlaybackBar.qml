import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// The toolpath timeline: the job's chapters (JobStrip), the transport, and the open chapter as
// a timeline of its steps. Port of Views/PlaybackBar.swift and Views/JobStrip.swift.
Rectangle {
    id: bar
    property var ws
    readonly property var d: (ws.revision, ws.playback())
    radius: 20
    color: Theme.glass
    border.color: Theme.glassStroke
    implicitHeight: column.implicitHeight + 20

    ColumnLayout {
        id: column
        x: 16; y: 10
        width: parent.width - 32
        spacing: 8

        // JobStrip: closed chapters as small cards, the open one with its steps.
        Flickable {
            id: strip
            Layout.fillWidth: true
            Layout.preferredHeight: 72
            contentWidth: Math.max(chapterRow.implicitWidth, width)
            contentHeight: 72
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds
            Row {
                id: chapterRow
                spacing: 6
                x: Math.max((strip.width - implicitWidth) / 2, 0) * 0
                Repeater {
                    model: bar.d.chapters
                    delegate: Loader {
                        required property var modelData
                        sourceComponent: modelData.open ? openChapter : closedChapter
                        property var ch: modelData
                    }
                }
                Rectangle {
                    visible: bar.d.generating
                    anchors.verticalCenter: parent.verticalCenter
                    width: tally.implicitWidth + 16; height: 22; radius: 11
                    color: Qt.rgba(0.55, 0.55, 0.55, 0.12)
                    Row { id: tally; anchors.centerIn: parent; spacing: 5
                        BusyIndicator { running: true; width: 12; height: 12 }
                        Text { text: qsTr("%1 of %2 ready").arg(bar.d.readyCount).arg(bar.d.chapters.length); color: Theme.secondaryLabel; font.pixelSize: 10 } }
                }
            }
            function centreOpen() {
                for (let i = 0; i < chapterRow.children.length; i++) {
                    const c = chapterRow.children[i]
                    if (c.ch && c.ch.open) { contentX = Math.max(0, Math.min(c.x + c.width / 2 - width / 2, contentWidth - width)); return }
                }
            }
            Component.onCompleted: Qt.callLater(centreOpen)
            Connections { target: bar; function onDChanged() { Qt.callLater(strip.centreOpen) } }
        }

        // Generating, nothing ready yet.
        RowLayout {
            visible: bar.d.empty
            Layout.fillWidth: true
            spacing: 8
            BusyIndicator { running: parent.visible; implicitWidth: 16; implicitHeight: 16 }
            Text { text: qsTr("Generating the toolpaths: each chapter opens when it's ready."); color: Theme.secondaryLabel; font.pixelSize: 10; Layout.fillWidth: true }
        }

        // The transport row: what plays on the left, what's shown on the right.
        RowLayout {
            visible: !bar.d.empty
            Layout.fillWidth: true
            Layout.preferredHeight: 32
            spacing: 14
            Row {
                spacing: 6
                BarButton { symbol: "backward.end.fill"; help: qsTr("Previous Operation (⌥←)"); onClicked: bar.ws.jumpOperation(-1) }
                BarButton { symbol: "backward.frame.fill"; help: qsTr("Previous Move (←)"); onClicked: bar.ws.stepBy(-1) }
                BarButton { symbol: bar.d.playing ? "pause.fill" : "play.fill"; on: true; enabled: !bar.d.toolChange
                    help: bar.d.playing ? qsTr("Pause (Space)") : qsTr("Play this step (Space)"); onClicked: bar.ws.togglePlay() }
                BarButton { symbol: "forward.frame.fill"; help: qsTr("Next Move (→)"); onClicked: bar.ws.stepBy(1) }
                BarButton { symbol: "forward.end.fill"; help: qsTr("Next Operation (⌥→)"); onClicked: bar.ws.jumpOperation(1) }
            }
            Text { text: bar.d.clock; color: Theme.secondaryLabel; font.pixelSize: 12; font.features: {"tnum": 1} }
            Rectangle {
                id: speed
                implicitWidth: sp.implicitWidth + 24
                implicitHeight: 28
                radius: 14
                color: speedMa.pressed ? Qt.rgba(0.24, 0.24, 0.25, 0.9) : Qt.rgba(0.2, 0.2, 0.21, 0.86)
                border.color: Theme.glassStroke
                Row { id: sp; anchors.centerIn: parent; spacing: 6
                    Sym { name: "gauge.with.dots.needle.33percent"; size: 12; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: Math.round(bar.d.speed) + "×"; color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                    Sym { name: "chevron.down"; size: 9; weight: "bold"; anchors.verticalCenter: parent.verticalCenter } }
                MouseArea { id: speedMa; anchors.fill: parent; hoverEnabled: true; onClicked: speedMenu.popup(speed, 0, -speedMenu.implicitHeight - 4) }
                ToolTipHelp { text: qsTr("Playback speed: 1× is real time, as long as the cut takes at the machine"); shown: speedMa.containsMouse }
                Menu {
                    id: speedMenu
                    Repeater {
                        model: [1, 5, 20, 100, 500]
                        delegate: MenuItem { required property var modelData; text: modelData + "×"; checkable: true; checked: Math.round(bar.d.speed) === modelData; onTriggered: bar.ws.setPlaySpeed(modelData) }
                    }
                }
            }
            Item { Layout.fillWidth: true }
            Row {
                spacing: 6
                BarButton { symbol: "point.topleft.down.to.point.bottomright.curvepath"; on: bar.d.pathsVisible; title: qsTr("Toolpaths")
                    help: qsTr("Toolpaths: Show the toolpath lines. Off: just the stock being cut and the tool."); onClicked: bar.ws.pathsVisible = !bar.d.pathsVisible }
                BarButton { symbol: "rectangle.dashed"; on: bar.d.workArea; title: qsTr("Work Area")
                    help: qsTr("Work Area: The blue box: where the tool can reach on the stock face."); onClicked: bar.ws.showWorkArea = !bar.d.workArea }
                BarButton { symbol: "cube.fill"; on: bar.d.simulate; title: qsTr("Simulate Cutting")
                    help: qsTr("Simulate Cutting: Show the stock being cut away as it plays."); onClicked: bar.ws.setSimulate(!bar.d.simulate) }
                BarButton { symbol: "scope"; on: bar.d.inspecting; title: qsTr("Pick a Toolpath")
                    help: qsTr("Pick a Toolpath: Click a toolpath line to see its G-code line, feed and position."); onClicked: bar.ws.setFlag("inspecting", !bar.d.inspecting) }
            }
        }

        // Scrubber: the open chapter's title and its steps as a timeline.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 26
            spacing: 10
            Text { text: bar.d.openTitle; color: Theme.accent; font.pixelSize: 10; font.weight: Font.DemiBold }
            Item {
                id: timeline
                Layout.fillWidth: true
                Layout.preferredHeight: 22
                readonly property var steps: bar.d.steps
                readonly property var widths: {
                    const n = steps.length, m = 16, gap = 2
                    if (n === 0) return []
                    const free = Math.max(width - gap * (n - 1), m * n)
                    const w = steps.map(() => m), fixed = new Set()
                    for (let it = 0; it < n; it++) {
                        const rest = [...Array(n).keys()].filter(i => !fixed.has(i))
                        const sum = rest.reduce((a, i) => a + steps[i].duration, 0)
                        const room = free - m * fixed.size
                        let changed = false
                        for (const i of rest) {
                            const v = sum > 0 ? steps[i].duration / sum * room : room / rest.length
                            if (v < m) { fixed.add(i); w[i] = m; changed = true } else w[i] = v
                        }
                        if (!changed) break
                    }
                    return w
                }
                Row {
                    spacing: 2
                    anchors.verticalCenter: parent.verticalCenter
                    Repeater {
                        model: timeline.steps
                        delegate: Item {
                            id: seg
                            required property var modelData
                            required property int index
                            width: timeline.widths[index] || 16
                            height: 22
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width
                                height: seg.modelData.active ? 14 : 10
                                radius: 4
                                color: seg.modelData.active ? Theme.accent : Qt.rgba(0.55, 0.55, 0.55, seg.modelData.byHand ? 0.22 : 0.4)
                                DashedBorder { anchors.fill: parent; visible: seg.modelData.byHand; radius: 4 }
                            }
                            Rectangle {
                                visible: seg.modelData.active && seg.modelData.progress >= 0
                                width: 14; height: 14; radius: 7
                                color: "white"
                                anchors.verticalCenter: parent.verticalCenter
                                x: seg.modelData.progress * Math.max(seg.width - 14, 0)
                            }
                            MouseArea {
                                id: segMa
                                anchors.fill: parent
                                hoverEnabled: true
                                function at(mx) {
                                    if (seg.modelData.active && seg.modelData.start >= 0) {
                                        bar.ws.seekTo(seg.modelData.start + Math.min(Math.max(mx / Math.max(seg.width, 1), 0), 1) * (seg.modelData.end - seg.modelData.start))
                                    } else if (!seg.modelData.active) bar.ws.goToStep(seg.modelData.id)
                                }
                                onPressed: m => at(m.x)
                                onPositionChanged: m => { if (pressed) at(m.x) }
                            }
                            ToolTipHelp { text: seg.modelData.number + " · " + seg.modelData.title + " · " + (seg.modelData.byHand ? qsTr("by hand, about %1").arg(seg.modelData.minutes) : "≈ " + seg.modelData.minutes); shown: segMa.containsMouse }
                        }
                    }
                }
            }
        }
    }

    // A closed chapter: its number in a ring and the first step's symbol.
    Component {
        id: closedChapter
        Rectangle {
            id: cc
            readonly property var ch: parent ? parent.ch : ({})
            width: 40
            height: 72
            radius: 16
            color: Qt.rgba(0.55, 0.55, 0.55, 0.08)
            border.color: Qt.rgba(0.55, 0.55, 0.55, 0.16)
            opacity: cc.ch.ready ? 1 : 0.7
            Rectangle {
                x: 11; y: 7
                width: 18; height: 18; radius: 9
                color: cc.ch.ready ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.22) : "transparent"
                border.width: 1
                border.color: cc.ch.ready ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.7) : Qt.rgba(0.55, 0.55, 0.55, 0.6)
                Text { anchors.centerIn: parent; text: cc.ch.number; color: cc.ch.ready ? Theme.label : Theme.secondaryLabel; font.pixelSize: 11; font.weight: Font.Bold }
            }
            Sym { anchors.horizontalCenter: parent.horizontalCenter; y: 25 + (72 - 25 - 7 - height) / 2; name: cc.ch.symbol || "circle"; size: 10; color: Theme.secondaryLabel }
            MouseArea { id: ccm; anchors.fill: parent; enabled: cc.ch.ready; hoverEnabled: true; onClicked: bar.ws.goToStep(cc.ch.first) }
            ToolTipHelp { text: qsTr("Chapter %1 · %2 · %3 steps").arg(cc.ch.number).arg(cc.ch.title).arg(cc.ch.count); shown: ccm.containsMouse }
        }
    }

    // The open chapter: its title and its steps as chips.
    Component {
        id: openChapter
        Rectangle {
            id: oc
            readonly property var ch: parent ? parent.ch : ({})
            width: ocCol.implicitWidth + 14
            height: 72
            radius: 16
            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.10)
            border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55)
            Column {
                id: ocCol
                x: 7; y: 7
                spacing: 5
                Row {
                    spacing: 6
                    Rectangle { width: 18; height: 18; radius: 9; color: Theme.accent
                        Text { anchors.centerIn: parent; text: oc.ch.number; color: "white"; font.pixelSize: 11; font.weight: Font.Bold } }
                    Text { text: oc.ch.title; color: Theme.accent; font.pixelSize: 10; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: oc.ch.count === 1 ? qsTr("1 step") : qsTr("%1 steps").arg(oc.ch.count); color: Theme.secondaryLabel; font.pixelSize: 10; anchors.verticalCenter: parent.verticalCenter }
                }
                Row {
                    spacing: 3
                    Repeater {
                        model: bar.d.steps
                        delegate: Rectangle {
                            id: chip
                            required property var modelData
                            readonly property bool active: modelData.active
                            readonly property bool manual: modelData.byHand
                            width: chipRow.implicitWidth + (active ? 16 : 10)
                            height: 34
                            radius: 9
                            color: active ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.85) : manual ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(0.55, 0.55, 0.55, 0.12)
                            DashedBorder { anchors.fill: parent; visible: chip.manual && !chip.active; radius: 9 }
                            Row {
                                id: chipRow
                                anchors.centerIn: parent
                                spacing: chip.active ? 6 : 3
                                Rectangle {
                                    width: Math.max(16, nn.implicitWidth + 6); height: 16; radius: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: chip.active ? Qt.rgba(1, 1, 1, 0.9) : Qt.rgba(0.55, 0.55, 0.55, 0.25)
                                    Text { id: nn; anchors.centerIn: parent; text: chip.modelData.number; color: chip.active ? Theme.accent : Theme.label; font.pixelSize: 10; font.weight: Font.Bold }
                                }
                                Sym { name: chip.modelData.symbol; size: 10; color: chip.active ? "white" : Theme.label; anchors.verticalCenter: parent.verticalCenter }
                                Column {
                                    visible: chip.active
                                    anchors.verticalCenter: parent.verticalCenter
                                    Text { text: chip.modelData.title; color: "white"; font.pixelSize: 10; font.weight: Font.DemiBold }
                                    Text { text: chip.modelData.subtitle; color: Qt.rgba(1, 1, 1, 0.85); font.pixelSize: 10 }
                                }
                            }
                            MouseArea { id: chm; anchors.fill: parent; hoverEnabled: true; onClicked: bar.ws.goToStep(chip.modelData.id) }
                            ToolTipHelp { text: chip.modelData.number + " · " + chip.modelData.title + ": " + chip.modelData.detail; shown: chm.containsMouse }
                        }
                    }
                }
            }
        }
    }
}
