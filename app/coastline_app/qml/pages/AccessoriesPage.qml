import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

ItemListPage {
    id: page
    listName: "accessories"
    title: qsTr("Accessories")
    noun: qsTr("accessory")
    kindEnum: "AccessoryKind"
    note: qsTr("Collets matter: a tool can only be used if you own an ER-11 collet for its shank size. Coastline checks this for every tool.")
    noteSymbol: "circle.circle"
    addTitle: qsTr("Add Accessory")
    emptySymbol: "circle.circle"
    columns: [
        {title: qsTr("Item"), role: "name", width: 0, cell: page.nameCell},
        {title: qsTr("Type"), role: "kind", width: 130, color: r => Theme.secondaryLabel},
        {title: qsTr("Size"), role: "size", width: 120},
        {title: qsTr("Qty"), role: "quantity", width: 44}
    ]
    itemInspector: Component {
        ColumnLayout {
            spacing: 0
            Card {
                title: qsTr("Accessory")
                FieldRow { label: qsTr("Name"); TextEdit { value: page.item.name || ""; onCommitted: t => page.set("name", t) } }
                FieldRow { label: qsTr("Type"); ChoiceEdit { choices: page.inventory.choices("AccessoryKind"); value: page.item.kind; onCommitted: v => page.set("kind", v) } }
                FieldRow { label: page.item.kind === "collet" ? qsTr("Bore") : qsTr("Size"); NumberEdit { value: page.item.size === undefined ? null : page.item.size; optional: true; onCommitted: v => page.set("size", v) } }
                StepperRow { label: qsTr("Quantity"); value: page.item.quantity || 0; onCommitted: v => page.set("quantity", v) }
                FieldRow { label: qsTr("Notes"); TextEdit { value: page.item.notes || ""; onCommitted: t => page.set("notes", t) } }
            }
            Item { implicitHeight: 24 }
        }
    }
}
