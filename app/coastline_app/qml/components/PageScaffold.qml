import QtQuick
import QtQuick.Layouts

// A page as NavigationSplitView's detail shows it: the 52-point toolbar (title and subtitle,
// the page's items, the mill state and the inspector toggle on the right) above the content,
// and the inspector column on the right reaching up under the toolbar.
Item {
    id: page
    property var app
    property string title: ""
    property string subtitle: ""
    property Component inspector: null
    property real inspectorWidth: 331
    property bool showMill: true
    property bool titleBold: true
    property string searchPlaceholder: ""   // .searchable: a search field in the toolbar, over the inspector
    property string searchText: ""
    default property alias content: contentArea.data
    property alias leading: leadingRow.data      // before the title (undo/redo)
    property alias trailing: trailingRow.data    // the page's own items, before the mill and inspector
    property alias inspectorItems: inspectorRow.data  // items after the inspector toggle (the workspace's menus)
    property alias inspectorJoin: joinRow.data        // items sharing the inspector toggle's capsule
    readonly property bool inspectorShown: inspector !== null && app.showInspector
    readonly property real detailWidth: width - (inspectorShown ? inspectorWidth : 0)

    // Toolbar strip over the detail.
    Rectangle { x: 0; y: 0; width: page.detailWidth; height: 52; color: Theme.toolbarBackground }
    WindowDragArea { x: 0; y: 0; width: page.width; height: 52 }
    Item {
        id: contentArea
        x: 0
        y: 52
        width: page.detailWidth
        height: page.height - 52
        clip: true
    }
    // The inspector column.
    Rectangle {
        visible: page.inspectorShown
        x: page.detailWidth
        width: page.inspectorWidth
        height: page.height
        color: Theme.panelBackground
        Rectangle { width: 1; height: parent.height; color: Theme.separator }
        Loader {
            x: 1
            y: 52
            width: parent.width - 1
            height: parent.height - 52
            sourceComponent: page.inspector
        }
    }

    // Toolbar items.
    Row {
        id: leadingRow
        x: 12
        height: 52
        spacing: 8
    }
    Column {
        x: leadingRow.x + leadingRow.width + (leadingRow.children.length > 0 ? 16 : 6)
        anchors.top: parent.top
        anchors.topMargin: page.subtitle === "" ? 15 : 8
        spacing: 0
        Text {
            text: page.title
            color: Theme.label
            font.pixelSize: Theme.headline
            font.weight: Font.Bold
        }
        Text {
            visible: page.subtitle !== ""
            text: page.subtitle
            color: Theme.secondaryLabel
            font.pixelSize: 11
            elide: Text.ElideRight
            width: Math.min(implicitWidth, page.width - parent.x - 520)
        }
    }
    // The search field: over the inspector column when it shows, else at the end of the toolbar.
    Rectangle {
        id: searchBox
        visible: page.searchPlaceholder !== ""
        readonly property real w: page.inspectorShown ? page.inspectorWidth - 18 : 200
        x: page.width - w - 10
        y: 9
        width: w
        height: 34
        radius: 17
        color: Theme.glass
        border.color: Theme.glassStroke
        Sym { id: lens; x: 12; anchors.verticalCenter: parent.verticalCenter; name: "magnifyingglass"; size: 12; color: Theme.secondaryLabel }
        TextInput {
            id: searchInput
            x: lens.x + lens.width + 6
            width: parent.width - x - 28
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.label
            font.pixelSize: 13
            clip: true
            selectByMouse: true
            text: page.searchText
            onTextEdited: page.searchText = text
            Text { visible: searchInput.text === ""; text: page.searchPlaceholder; color: Theme.secondaryLabel; font.pixelSize: 13 }
        }
        Item {
            visible: searchInput.text !== ""
            anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
            width: 16; height: 16
            Sym { anchors.centerIn: parent; name: "xmark.circle.fill"; size: 12; color: Theme.secondaryLabel }
            MouseArea { anchors.fill: parent; onClicked: { page.searchText = ""; searchInput.text = "" } }
        }
    }
    Row {
        anchors.right: searchBox.visible ? searchBox.left : parent.right
        anchors.rightMargin: 10
        y: 9
        spacing: 10
        Row { id: trailingRow; spacing: 10 }
        MillToolbar { visible: page.showMill; app: page.app }
        GlassCapsule {
            ToolbarIcon {
                symbol: "sidebar.right"
                symbolSize: 16
                checked: false
                help: qsTr("Show or hide the inspector (⌥⌘I)")
                onClicked: page.app.showInspector = !page.app.showInspector
            }
            Row { id: joinRow }
        }
        Row { id: inspectorRow; spacing: 10 }
    }
}
