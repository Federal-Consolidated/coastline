import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Coastline.Viewport

// The selected item in 3D (tools, stock, fixtures), at the top of its inspector.
Rectangle {
    id: box
    property var app
    property string kind: "tools"
    property string itemId: ""
    property var preview: app.itemPreview
    Layout.fillWidth: true
    Layout.preferredHeight: 190
    radius: Theme.radius
    color: Theme.card
    clip: true
    function refresh() { preview.show(kind, itemId) }
    onItemIdChanged: refresh()
    Connections { target: box.app.inventory; function onRevisionChanged() { box.refresh() } }
    Viewport {
        id: view
        anchors.fill: parent
        anchors.margins: 2
        scene: box.preview.viewScene
        Component.onCompleted: { box.preview.attachViewport(view); box.refresh() }
        Component.onDestruction: box.preview.detachViewport(view)
    }
    Label {
        anchors.centerIn: parent
        text: (box.preview.revision, box.preview.note())
        color: Theme.secondary
        font.pixelSize: Theme.smallFont
    }
}
