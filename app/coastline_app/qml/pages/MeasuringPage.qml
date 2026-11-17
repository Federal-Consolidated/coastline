import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

ItemListPage {
    id: page
    listName: "measuring"
    title: qsTr("Measuring Tools")
    noun: qsTr("instrument")
    kindEnum: "MeasuringKind"
    note: qsTr("Guided measuring steps only ask for instruments listed here. A digital caliper (0.01 mm) covers most checks; a micrometer (0.001 mm) is worth having for jewellery fits.")
    noteSymbol: "ruler"
    addTitle: qsTr("Add Instrument")
    emptySymbol: "ruler"
    columns: [
        {title: qsTr("Instrument"), role: "name", width: 0, cell: page.nameCell},
        {title: qsTr("Type"), role: "kind", width: 150, color: r => Theme.secondaryLabel},
        {title: qsTr("Range"), role: "range", width: 110},
        {title: qsTr("Resolution"), role: "resolution", width: 90},
        {title: qsTr("Qty"), role: "quantity", width: 44}
    ]
    itemInspector: Component {
        ColumnLayout {
            spacing: 0
            Card {
                title: qsTr("Instrument")
                FieldRow { label: qsTr("Name"); TextEdit { value: page.item.name || ""; onCommitted: t => page.set("name", t) } }
                FieldRow { label: qsTr("Type"); ChoiceEdit { choices: page.inventory.choices("MeasuringKind"); value: page.item.kind; onCommitted: v => page.set("kind", v) } }
                StepperRow { label: qsTr("Quantity"); value: page.item.quantity || 0; onCommitted: v => page.set("quantity", v) }
            }
            Card {
                title: qsTr("Specification")
                Item {
                    Layout.fillWidth: true
                    implicitHeight: 22
                    Text { text: qsTr("Range"); color: Theme.label; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        NumberEdit { width: 56; unit: ""; value: page.item.range ? page.item.range[0] : null; optional: true
                            onCommitted: v => page.set("range", v === null ? null : [v, page.item.range ? page.item.range[1] : v]) }
                        Text { text: "–"; color: Theme.secondaryLabel; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                        NumberEdit { width: 76; value: page.item.range ? page.item.range[1] : null; optional: true
                            onCommitted: v => page.set("range", v === null ? null : [page.item.range ? page.item.range[0] : 0, v]) }
                    }
                }
                NumberRow { label: qsTr("Resolution"); optional: true; value: page.item.resolution === undefined ? null : page.item.resolution; onCommitted: v => page.set("resolution", v) }
                NumberRow { label: qsTr("Accuracy ±"); optional: true; value: page.item.accuracy === undefined ? null : page.item.accuracy; onCommitted: v => page.set("accuracy", v) }
            }
            Card {
                title: qsTr("Notes")
                FieldRow { label: qsTr("Notes"); TextEdit { value: page.item.notes || ""; onCommitted: t => page.set("notes", t) } }
            }
            Item { implicitHeight: 24 }
        }
    }
}
