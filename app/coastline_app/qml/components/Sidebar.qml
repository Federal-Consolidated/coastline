import QtQuick
import QtQuick.Layouts

// The sidebar (ContentView's List): a glass panel under the traffic lights with the pages in
// three sections, each row an SF Symbol, the title and a count.
Rectangle {
    id: bar
    property var app
    property var counts: (app.inventory.revision, app.inventory.counts())
    property int due: (app.journal.revision, app.journal.dueCount())
    readonly property string millWord: app.mill.state.open ? (app.mill.state.stateWord || "") : qsTr("Off")
    color: Theme.sidebarBackground
    radius: 20
    border.color: Theme.glassStroke
    border.width: 1

    WindowDragArea { width: parent.width; height: 40 }
    ToolbarIcon {
        x: parent.width - width - 6
        y: 1
        symbol: "sidebar.left"
        symbolSize: 16
        tint: Theme.secondaryLabel
        help: qsTr("Hide sidebar")
    }

    Column {
        x: 10
        y: 42
        width: parent.width - 20
        spacing: 0
        Repeater {
            model: [
                {header: qsTr("Machine")},
                {page: "control", title: qsTr("Machine Control"), symbol: "cable.connector", badge: bar.millWord},
                {page: "machine", title: qsTr("Machine"), symbol: "gearshape.2", badge: bar.due > 0 ? String(bar.due) : ""},
                {header: qsTr("Project")},
                {page: "workspace", title: qsTr("Workspace"), symbol: "cube.transparent", badge: ""},
                {page: "projects", title: qsTr("Projects"), symbol: "folder", badge: ""},
                {header: qsTr("Inventory")},
                {page: "stock", title: qsTr("Stock"), symbol: "shippingbox", badge: String(bar.counts.stockQuantity !== undefined ? bar.counts.stockQuantity : bar.counts.stock)},
                {page: "tools", title: qsTr("Tools"), symbol: "wrench.and.screwdriver", badge: String(bar.counts.toolQuantity !== undefined ? bar.counts.toolQuantity : bar.counts.tools)},
                {page: "fixtures", title: qsTr("Fixtures"), symbol: "square.grid.3x3.square", badge: String(bar.counts.fixtures)},
                {page: "measuring", title: qsTr("Measuring Tools"), symbol: "ruler", badge: String(bar.counts.measuring)},
                {page: "accessories", title: qsTr("Accessories"), symbol: "circle.circle", badge: String(bar.counts.accessories)},
                {page: "shopping", title: qsTr("Shopping List"), symbol: "cart", badge: String(bar.counts.shopping)}
            ]
            delegate: Item {
                id: row
                required property var modelData
                required property int index
                readonly property bool header: modelData.header !== undefined
                readonly property bool selected: !header && bar.app.page === modelData.page
                width: parent.width
                height: header ? (index === 0 ? 22 : 33) : 24.5
                Text {
                    visible: row.header
                    text: row.modelData.header || ""
                    x: 12
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 4
                    color: Theme.secondaryLabel
                    font.pixelSize: 11
                    font.weight: Font.Bold
                }
                Rectangle {
                    visible: !row.header
                    anchors.fill: parent
                    radius: 7
                    color: row.selected ? Theme.sidebarSelection : "transparent"
                }
                Sym {
                    visible: !row.header
                    name: row.modelData.symbol || ""
                    size: 12
                    color: Theme.label
                    x: 25 - width / 2
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    visible: !row.header
                    x: 41
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.title || ""
                    color: Theme.label
                    font.pixelSize: Theme.sidebarText
                }
                Text {
                    visible: !row.header && (row.modelData.badge || "") !== "" && row.modelData.badge !== "0"
                    anchors.right: parent.right
                    anchors.rightMargin: 9
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.badge || ""
                    color: Theme.secondaryLabel
                    font.pixelSize: 11
                    font.weight: Font.Medium
                }
                MouseArea { visible: !row.header; anchors.fill: parent; onClicked: bar.app.page = row.modelData.page }
            }
        }
    }
}
