import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// A scrolling column of cards (a grouped Form).
ScrollView {
    id: panel
    default property alias content: column.data
    property var ws
    property var app
    property real maxWidth: 100000   // a grouped Form keeps to a readable width, centred
    clip: true
    contentWidth: availableWidth
    ColumnLayout {
        id: column
        width: Math.min(panel.availableWidth - 20, panel.maxWidth)
        x: (panel.availableWidth - width) / 2
        spacing: 0
        Item { Layout.preferredHeight: 2 }
    }
}
