import QtQuick
import QtQuick.Layouts
import "../components"

// A dark rounded card floating over the 3D view.
Rectangle {
    id: card
    default property alias content: column.data
    property alias spacing: column.spacing
    radius: 14
    color: Qt.rgba(0.08, 0.08, 0.09, 0.93)
    border.color: Theme.line
    implicitHeight: column.implicitHeight + 24
    implicitWidth: column.implicitWidth + 24
    ColumnLayout {
        id: column
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8
    }
}
