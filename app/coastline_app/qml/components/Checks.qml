import QtQuick
import QtQuick.Layouts

// IssuesSection: "Checks", a ready line or the issues with their severity icons.
Card {
    id: c
    property var issues: []
    title: qsTr("Checks")
    readonly property var order: ({error: 0, warning: 1, info: 2})
    RowLayout {
        visible: c.issues.length === 0
        spacing: 8
        Sym { name: "checkmark.seal.fill"; size: 13; color: Theme.ok }
        Text { text: qsTr("Ready to use on the machine"); color: Theme.ok; font.pixelSize: 13 }
    }
    Repeater {
        model: c.issues.slice().sort((a, b) => c.order[a.severity] - c.order[b.severity])
        delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: 8
            Sym {
                Layout.alignment: Qt.AlignTop
                name: modelData.severity === "error" ? "xmark.octagon.fill" : modelData.severity === "warning" ? "exclamationmark.triangle.fill" : "info.circle"
                size: 13
                color: modelData.severity === "error" ? Theme.danger : modelData.severity === "warning" ? Theme.warning : Theme.secondaryLabel
            }
            Text { text: modelData.message; color: Theme.label; font.pixelSize: 13; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }
    }
}
