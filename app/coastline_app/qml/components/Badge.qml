import QtQuick

// Badge: a caption in a tinted capsule.
Rectangle {
    id: b
    property string text: ""
    property color tint: Theme.secondaryLabel
    property string symbol: ""
    implicitWidth: r.implicitWidth + 16
    implicitHeight: r.implicitHeight + 6
    radius: height / 2
    color: Qt.rgba(tint.r, tint.g, tint.b, 0.14)
    Row { id: r; anchors.centerIn: parent; spacing: 4
        Sym { visible: b.symbol !== ""; name: b.symbol; size: 10; color: b.tint; anchors.verticalCenter: parent.verticalCenter }
        Text { text: b.text; color: b.tint; font.pixelSize: 10; font.weight: Font.DemiBold } }
}
