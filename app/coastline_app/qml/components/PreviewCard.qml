import QtQuick
import QtQuick.Layouts

// PreviewCard: the item in 3D (orbit, zoom) or as a dimensioned drawing, switched by the
// small Drawing | 3D control in the corner; one rounded panel for both.
Rectangle {
    id: card
    property var app
    property string kind: "stock"
    property string itemId: ""
    property Component drawing: null
    property bool show3D: true
    property real drawingHeight: 150
    onItemIdChanged: show3D = true
    Layout.fillWidth: true
    implicitHeight: show3D ? 190 : drawingHeight
    radius: 14
    color: Qt.rgba(0.55, 0.55, 0.55, 0.08)
    clip: true
    ItemPreview3D {
        visible: card.show3D
        anchors.fill: parent
        app: card.app
        kind: card.kind
        itemId: card.itemId
        color: "transparent"
    }
    Loader { visible: !card.show3D; active: !card.show3D; anchors.fill: parent; sourceComponent: card.drawing }
    Segmented {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 6
        implicitHeight: 20
        small: true
        options: [{value: false, title: qsTr("Drawing")}, {value: true, title: "3D"}]
        value: card.show3D
        onPicked: v => card.show3D = v
    }
}
