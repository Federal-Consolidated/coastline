import QtQuick
import QtQuick.Layouts

// LabeledContent with a macOS Stepper: the small up/down arrows, then the number.
Item {
    id: st
    property string label: ""
    property int value: 0
    property int from: 0
    property int to: 999
    property string display: String(value)
    signal committed(int value)
    Layout.fillWidth: true
    implicitHeight: 22
    Text { text: st.label; color: Theme.label; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
    Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6
        Rectangle {
            width: 15; height: 22; radius: 5
            color: Qt.rgba(1, 1, 1, 0.12)
            anchors.verticalCenter: parent.verticalCenter
            Sym { anchors.horizontalCenter: parent.horizontalCenter; y: 3; name: "chevron.up"; size: 7; weight: "bold"; color: st.value < st.to ? Theme.label : Theme.tertiaryLabel }
            Sym { anchors.horizontalCenter: parent.horizontalCenter; y: 12; name: "chevron.down"; size: 7; weight: "bold"; color: st.value > st.from ? Theme.label : Theme.tertiaryLabel }
            MouseArea { width: parent.width; height: parent.height / 2; onClicked: if (st.value < st.to) st.committed(st.value + 1) }
            MouseArea { y: parent.height / 2; width: parent.width; height: parent.height / 2; onClicked: if (st.value > st.from) st.committed(st.value - 1) }
        }
        Text { text: st.display; color: Theme.label; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
    }
}
