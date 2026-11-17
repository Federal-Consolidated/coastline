import QtQuick
import QtQuick.Layouts

// A Section of a macOS List: the bold header, then rows with hairlines between them.
ColumnLayout {
    id: ls
    property string title: ""
    default property alias rows: body.data
    Layout.fillWidth: true
    spacing: 0
    Text { text: ls.title; color: Theme.secondaryLabel; font.pixelSize: 11; font.weight: Font.Bold; Layout.leftMargin: 14; Layout.topMargin: 8; Layout.bottomMargin: 6 }
    Rectangle { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 4; implicitHeight: 1; color: Theme.separator }
    ColumnLayout { id: body; Layout.fillWidth: true; spacing: 0 }
}
