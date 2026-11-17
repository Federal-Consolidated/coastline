import QtQuick

// A macOS checkbox (.toggleStyle(.checkbox)): a small rounded square, accent-filled when on.
Rectangle {
    id: cb
    property bool checked: false
    signal toggled(bool on)
    width: 14; height: 14; radius: 3.5
    color: checked ? Theme.accent : Qt.rgba(1, 1, 1, 0.1)
    border.width: checked ? 0 : 1
    border.color: Qt.rgba(1, 1, 1, 0.25)
    Sym { anchors.centerIn: parent; visible: cb.checked; name: "checkmark"; size: 9; weight: "bold"; color: "white" }
    MouseArea { anchors.fill: parent; anchors.margins: -3; onClicked: cb.toggled(!cb.checked) }
}
