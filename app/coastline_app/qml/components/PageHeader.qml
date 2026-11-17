import QtQuick
import QtQuick.Layouts

// A page's title row with room for actions on the right.
RowLayout {
    id: header
    property string title: ""
    property string subtitle: ""
    default property alias actions: actionRow.data
    spacing: 12
    Layout.fillWidth: true
    ColumnLayout {
        spacing: 2
        Text { text: header.title; color: Theme.text; font.pixelSize: Theme.titleFont; font.weight: Font.DemiBold }
        Text { visible: header.subtitle !== ""; text: header.subtitle; color: Theme.secondary; font.pixelSize: Theme.smallFont + 1 }
    }
    Item { Layout.fillWidth: true }
    RowLayout { id: actionRow; spacing: 8 }
}
