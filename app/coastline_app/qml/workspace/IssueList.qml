import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// Issues as lines with their severity (IssuesSection).
ColumnLayout {
    id: list
    property var issues: []
    spacing: 4
    Layout.fillWidth: true
    Repeater {
        model: list.issues
        delegate: Label {
            required property var modelData
            text: Theme.severitySymbol(modelData.severity) + "  " + modelData.message
            color: Theme.severityColor(modelData.severity)
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
    }
}
