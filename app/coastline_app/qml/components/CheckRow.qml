import QtQuick
import QtQuick.Layouts

// Toggle(.checkbox) in a form: the checkbox, then its label.
Item {
    id: cr
    property string text: ""
    property bool checked: false
    signal toggled(bool on)
    Layout.fillWidth: true
    implicitHeight: Math.max(18, t.implicitHeight)
    CheckMark { id: box; anchors.verticalCenter: parent.verticalCenter; checked: cr.checked; onToggled: on => cr.toggled(on) }
    Text { id: t; x: 22; width: parent.width - 22; anchors.verticalCenter: parent.verticalCenter; text: cr.text; color: Theme.label; font.pixelSize: 13; wrapMode: Text.WordWrap }
    MouseArea { anchors.fill: t; onClicked: cr.toggled(!cr.checked) }
}
