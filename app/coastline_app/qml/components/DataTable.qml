import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A sortable, selectable table over an array of row objects (each with an `id`).
// columns: [{title, role, width (px, or 0 to fill), sort (role to sort by, "" = not sortable),
//            align ("left"|"right"), color (optional function(row) -> color)}]
Rectangle {
    id: table
    property var rows: []
    property var columns: []
    property var selection: []          // selected ids
    property string sortKey: ""
    property bool ascending: true
    property Component rowDecoration: null   // optional extra content per row (gets `row`)
    signal activated(string id)
    signal sortRequested(string key, bool ascending)
    signal contextMenuRequested(var ids, real x, real y)
    color: Theme.panelBackground
    clip: true

    function isSelected(id) { return selection.indexOf(id) >= 0 }
    function select(id, modifiers) {
        if (modifiers & Qt.ControlModifier || modifiers & Qt.MetaModifier) {
            var s = selection.slice()
            var k = s.indexOf(id)
            if (k >= 0) s.splice(k, 1); else s.push(id)
            selection = s
        } else if (modifiers & Qt.ShiftModifier && selection.length > 0) {
            var ids = rows.map(r => r.id)
            var a = ids.indexOf(selection[selection.length - 1]), b = ids.indexOf(id)
            if (a < 0 || b < 0) { selection = [id]; return }
            selection = ids.slice(Math.min(a, b), Math.max(a, b) + 1)
        } else {
            selection = [id]
        }
    }
    // Columns of width 0 share what's left, never under their minimum (minWidth, else 200): when
    // the table is narrower than that it scrolls sideways, like a Table.
    readonly property real fixedWidth: { var f = 0; for (var i = 0; i < columns.length; i++) if (columns[i].width > 0) f += columns[i].width; return f }
    readonly property int fills: { var n = 0; for (var i = 0; i < columns.length; i++) if (!(columns[i].width > 0)) n++; return n }
    readonly property real minFill: { var m = 0; for (var i = 0; i < columns.length; i++) if (!(columns[i].width > 0)) m = Math.max(m, columns[i].minWidth || 200); return m }
    readonly property real contentWidth: Math.max(width, fixedWidth + 28 + fills * minFill)
    function fillWidth() { return Math.max(minFill, (contentWidth - fixedWidth - 28) / Math.max(fills, 1)) }
    function colWidth(c) { return c.width > 0 ? c.width : fillWidth() }

    Flickable {
        id: hscroll
        anchors.fill: parent
        contentWidth: table.contentWidth
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentWidth > width
        ScrollBar.horizontal: ScrollBar { policy: hscroll.contentWidth > hscroll.width ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }
    ColumnLayout {
        width: table.contentWidth
        height: hscroll.height
        spacing: 0
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 28
            color: Theme.panelBackground
            Row {
                anchors.fill: parent
                anchors.leftMargin: 14
                Repeater {
                    model: table.columns
                    delegate: Item {
                        required property var modelData
                        required property int index
                        width: table.colWidth(modelData)
                        height: 28
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            horizontalAlignment: modelData.align === "right" ? Text.AlignRight : Text.AlignLeft
                            text: modelData.title
                            color: Theme.secondaryLabel
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        Sym {
                            visible: table.sortKey !== "" && table.sortKey === modelData.sort
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            name: table.ascending ? "chevron.up" : "chevron.down"
                            size: 8
                            weight: "bold"
                            color: Theme.secondaryLabel
                        }
                        Rectangle { visible: modelData.title !== "" || index > 0; anchors.left: parent.left; anchors.leftMargin: -6; anchors.verticalCenter: parent.verticalCenter; width: 1; height: 14; color: Qt.rgba(1, 1, 1, 0.1) }
                        MouseArea {
                            anchors.fill: parent
                            enabled: (modelData.sort || "") !== ""
                            onClicked: table.sortRequested(modelData.sort, table.sortKey === modelData.sort ? !table.ascending : true)
                        }
                    }
                }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
        }
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: table.rows
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            // Alternating stripes below the last row, as a Table draws them.
            Column {
                parent: list
                z: -1
                y: list.contentHeight - list.contentY
                visible: y < list.height
                Repeater {
                    model: Math.max(0, Math.ceil(list.height / 24) + 1)
                    delegate: Rectangle { required property int index; width: table.contentWidth; height: 24
                        color: (table.rows.length + index) % 2 ? Qt.rgba(1, 1, 1, 0.03) : "transparent" }
                }
            }
            delegate: Rectangle {
                id: rowItem
                required property var modelData
                required property int index
                width: table.contentWidth
                height: Math.max(26, cells.implicitHeight + 8)
                color: table.isSelected(modelData.id) ? Qt.rgba(1, 1, 1, 0.14) : (index % 2 ? Qt.rgba(1, 1, 1, 0.03) : "transparent")
                HoverHandler { id: hover }
                Row {
                    id: cells
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    Repeater {
                        model: table.columns
                        delegate: Item {
                            required property var modelData
                            width: table.colWidth(modelData)
                            implicitHeight: modelData.cell ? custom.implicitHeight : cell.implicitHeight
                            height: implicitHeight
                            Loader {
                                id: custom
                                active: !!modelData.cell
                                width: parent.width - 8
                                anchors.verticalCenter: parent.verticalCenter
                                sourceComponent: modelData.cell || null
                                property var row: rowItem.modelData
                                property bool selected: table.isSelected(rowItem.modelData.id)
                            }
                            Text {
                                id: cell
                                visible: !modelData.cell
                                width: parent.width - 8
                                horizontalAlignment: modelData.align === "right" ? Text.AlignRight : Text.AlignLeft
                                text: {
                                    var v = rowItem.modelData[modelData.role]
                                    return v === undefined || v === null ? "" : String(v)
                                }
                                color: modelData.color ? modelData.color(rowItem.modelData) : Theme.label
                                font.pixelSize: 13
                                font.family: modelData.mono ? "Menlo" : Theme.fontFamily
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                            }
                        }
                    }
                }
                Loader {
                    anchors.fill: parent
                    sourceComponent: table.rowDecoration
                    property var row: rowItem.modelData
                }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) {
                            if (!table.isSelected(rowItem.modelData.id)) table.selection = [rowItem.modelData.id]
                            var p = mapToItem(table, mouse.x, mouse.y)
                            table.contextMenuRequested(table.selection, p.x, p.y)
                        } else {
                            table.select(rowItem.modelData.id, mouse.modifiers)
                        }
                    }
                    onDoubleClicked: table.activated(rowItem.modelData.id)
                }
            }
        }
    }
    }
    Text {
        anchors.centerIn: parent
        visible: table.rows.length === 0
        text: qsTr("Nothing to show")
        color: Theme.tertiaryLabel
        font.pixelSize: Theme.fontSize
    }
}
