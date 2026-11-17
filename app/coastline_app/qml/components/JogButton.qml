import QtQuick
import QtQuick.Controls

// One jog target: a step per click, or in hold-to-jog, motion while pressed. A small bordered
// button; without a title, a dot when it can't jog (NativeJogTarget).
Button {
    id: b
    required property var mill
    property real jx: 0
    property real jy: 0
    property real jz: 0
    property string symbol: ""
    property bool held: mill.heldKey === (jx + "," + jy + "," + jz)
    onClicked: if (!mill.jogHold) mill.jog(jx, jy, jz)
    onPressed: if (mill.jogHold) mill.startHold(jx, jy, jz)
    onReleased: if (mill.jogHold) mill.endHold()
    onCanceled: if (mill.jogHold) mill.endHold()
    background: Rectangle {
        visible: b.enabled || b.text !== ""
        radius: 5
        color: b.held ? Theme.accent : b.down ? Qt.rgba(1, 1, 1, 0.24) : Qt.rgba(1, 1, 1, 0.14)
        opacity: b.enabled ? 1 : 0.4
    }
    contentItem: Item {
        Rectangle { visible: !b.enabled && b.text === "" && b.symbol === ""; anchors.centerIn: parent; width: 4; height: 4; radius: 2; color: Theme.tertiaryLabel }
        Sym { visible: b.symbol !== "" && b.enabled; anchors.centerIn: parent; name: b.symbol; size: 11 }
        Rectangle { visible: b.symbol !== "" && !b.enabled; anchors.centerIn: parent; width: 4; height: 4; radius: 2; color: Theme.tertiaryLabel }
        Text { visible: b.text !== ""; anchors.centerIn: parent; text: b.text; color: b.enabled ? Theme.label : Theme.tertiaryLabel; font.pixelSize: 11 }
    }
}
