import QtQuick
import QtQuick.Window

// An SF Symbol (image://sf), drawn at its point size on any screen; layouts see its point size.
Item {
    id: sym
    property string name: ""
    property real size: 13
    property string weight: "regular"
    property color color: Theme.label
    readonly property real scale_: Math.max(1, Screen.devicePixelRatio)
    visible: name !== ""
    implicitWidth: img.implicitWidth / scale_
    implicitHeight: img.implicitHeight / scale_
    Image {
        id: img
        anchors.centerIn: parent
        width: implicitWidth / sym.scale_
        height: implicitHeight / sym.scale_
        source: sym.name === "" ? "" : "image://sf/" + sym.name + "?size=" + sym.size + "&weight=" + sym.weight + "&scale=" + sym.scale_ + "&color=" + encodeURIComponent(sym.color.toString())
        smooth: true
        mipmap: true
        fillMode: Image.PreserveAspectFit
    }
}
