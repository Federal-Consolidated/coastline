import QtQuick
import QtQuick.Layouts

// A Section of a grouped Form (.formStyle(.grouped)): the header above, the rows on a rounded
// background with hairlines between them, the footer below.
Item {
    id: card
    default property alias content: column.data
    property string title: ""
    property string footer: ""
    property alias spacing: column.spacing
    property string info: ""   // an InfoTip after the title
    property bool large: false // a Form in the main column (not an inspector): headline headers
    readonly property real headerHeight: title !== "" ? (large ? 40 : 30) : 0
    implicitHeight: headerHeight + box.height + (footer !== "" ? footerText.implicitHeight + (large ? 14 : 6) : 0)
    Layout.fillWidth: true

    Row {
        id: headerRow
        visible: card.title !== ""
        x: 10
        y: card.headerHeight - 7 - height
        spacing: 6
        Text {
            text: card.title
            color: card.large ? Theme.label : Theme.secondaryLabel
            font.pixelSize: card.large ? 13 : 11
            font.weight: Font.Bold
            anchors.verticalCenter: parent.verticalCenter
        }
        InfoTip { visible: card.info !== ""; text: card.info; anchors.verticalCenter: parent.verticalCenter }
    }
    Rectangle {
        id: box
        y: card.headerHeight
        width: parent.width
        height: column.implicitHeight + 20
        radius: 10
        color: Theme.formRow
        ColumnLayout {
            id: column
            x: 10
            y: 10
            width: parent.width - 20
            spacing: 20
            onImplicitHeightChanged: Qt.callLater(card.findSeparators)
        }
        Repeater {
            model: card.separators
            delegate: Rectangle { required property real modelData; x: 10; width: box.width - 20; y: modelData; height: 1; color: Theme.separator }
        }
    }
    Text {
        id: footerText
        visible: card.footer !== ""
        text: card.footer
        color: Theme.secondaryLabel
        font.pixelSize: card.large ? 11 : 10
        wrapMode: Text.WordWrap
        x: 10
        width: parent.width - 20
        y: box.y + box.height + (card.large ? 10 : 6)
    }

    // Hairlines halfway between visible rows.
    property var separators: []
    function findSeparators() {
        const ys = []
        let last = null
        for (let i = 0; i < column.children.length; i++) {
            const c = column.children[i]
            if (!c.visible || c.height <= 0) continue
            if (last !== null) ys.push(Math.round(10 + (last.y + last.height + c.y) / 2))
            last = c
        }
        separators = ys
    }
    Component.onCompleted: Qt.callLater(findSeparators)
    onWidthChanged: Qt.callLater(findSeparators)
}
