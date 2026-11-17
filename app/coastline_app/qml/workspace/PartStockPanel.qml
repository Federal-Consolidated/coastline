import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

// Stage 1 and 2: the part, and the stock it's cut from. Port of SetupInspector (part, stock)
// and OwnedStockSuggestions.
Panel {
    id: panel
    property string scope: "part"
    readonly property var part: (ws.revision, ws.partInfo())
    readonly property var stock: (ws.revision, ws.stockInfo())
    readonly property var choices: (ws.revision, ws.stockChoices())

    Card {
        visible: panel.scope === "part" && panel.part.file !== undefined
        title: qsTr("Part")
        ValueRow { label: qsTr("File"); value: panel.part.file || "" }
        ValueRow { label: qsTr("Size"); value: panel.part.size || "" }
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Text { text: qsTr("Scale"); color: Theme.label; font.pixelSize: 13 }
            InfoTip { text: qsTr("Machines the part smaller (or bigger) than modelled, the same in every direction, e.g. to fit the stock you have. 100 % is as designed.") }
            Item { Layout.fillWidth: true }
            NumberEdit { width: 80; Layout.preferredWidth: 80; value: panel.part.scale || 100; unit: "%"; decimals: 1; onCommitted: v => panel.ws.setPartScale(v) }
            GlassButton {
                visible: (panel.part.fitScale || 0) > 0
                title: qsTr("Fit")
                large: false
                help: qsTr("The largest scale at which the part fits inside the stock. Workholding is checked separately.")
                onClicked: panel.ws.setPartScale(panel.part.fitScale)
            }
        }
        Repeater {
            model: panel.part.warnings || []
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 6
                Sym { name: "exclamationmark.triangle.fill"; size: 12; color: Theme.warning; Layout.alignment: Qt.AlignTop }
                Text { text: modelData; color: Theme.warning; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            }
        }
    }
    Card {
        visible: panel.scope === "part" && panel.part.file !== undefined
        title: qsTr("Next")
        Text { text: qsTr("Choose stock from your library. Coastline will then propose machining and workholding together; orientation and work zero are reviewed in Setups."); wrapMode: Text.WordWrap; color: Theme.secondaryLabel; font.pixelSize: 12; Layout.fillWidth: true }
        GlassButton { title: qsTr("Choose Stock"); symbol: "chevron.right"; prominent: true; large: false; implicitHeight: 24; onClicked: panel.ws.enterStage("stock") }
    }

    Card {
        visible: panel.scope === "stock" && panel.part.file !== undefined
        id: ownedCard
        title: qsTr("From your stock library")
        readonly property var owned: (panel.ws.revision, panel.ws.ownedStockSuggestions())
        Text {
            visible: ownedCard.owned.length === 0
            text: qsTr("No owned blank currently fits the part. Add the stock you have below, or choose a different orientation in Setups.")
            color: Theme.secondaryLabel; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        Repeater {
            model: ownedCard.owned
            delegate: Item {
                required property var modelData
                Layout.fillWidth: true
                implicitHeight: col.implicitHeight
                Column {
                    id: col
                    width: parent.width - 24
                    spacing: 3
                    Text { text: modelData.title; color: Theme.label; font.pixelSize: 12; font.weight: Font.Medium; width: parent.width; wrapMode: Text.WordWrap }
                    Text { text: modelData.detail; color: Theme.secondaryLabel; font.pixelSize: 10 }
                    Text { visible: modelData.recommended; text: qsTr("Recommended from your library"); color: Theme.accent; font.pixelSize: 10 }
                }
                Sym { anchors.right: parent.right; y: 1; name: modelData.selected ? "checkmark.circle.fill" : "circle"; size: 13 }
                MouseArea { anchors.fill: parent; onClicked: panel.ws.chooseStock(modelData.id) }
            }
        }
    }

    Card {
        visible: panel.scope === "stock"
        title: qsTr("Stock")
        info: qsTr("Choose the material and blank you actually have. This step checks that the part fits. Workholding, machining allowance and work zero are reviewed together in Setups.")
        PopupPicker {
            label: qsTr("Stock")
            value: panel.stock.size !== undefined ? (panel.choices.find(c => c.selected) || {}).id : ""
            options: {
                const owned = panel.choices.filter(c => c.owned), standard = panel.choices.filter(c => !c.owned)
                let o = [{title: qsTr("None"), value: ""}, {header: true, title: qsTr("Your Stock")}]
                o = o.concat(owned.map(c => ({title: c.title, value: c.id})))
                if (standard.length > 0) o = o.concat([{header: true, title: qsTr("Standard Sizes to Buy (Not Owned)")}], standard.map(c => ({title: c.title, value: c.id})))
                if (panel.stock.size !== undefined) o.push({title: qsTr("Edit This Stock…"), value: "#edit"})
                o.push({title: qsTr("New Stock…"), value: "#new"})
                if (panel.stock.size !== undefined) o.push({title: qsTr("Duplicate This One…"), value: "#duplicate"})
                return o
            }
            onPicked: v => { if (v === "#edit" || v === "#new" || v === "#duplicate") panel.app.page = "stock"; else panel.ws.chooseStock(v) }
        }
        Column {
            visible: (panel.stock.standardFits || []).length > 0
            Layout.fillWidth: true
            spacing: 6
            Text { text: qsTr("Standard sizes this part fits in"); color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold }
            Repeater {
                model: panel.stock.standardFits || []
                delegate: GlassButton { required property var modelData; title: modelData.title; symbol: "cart"; large: false; onClicked: panel.ws.useStandardStock(modelData.id) }
            }
        }
        RowLayout {
            visible: panel.stock.size !== undefined && !panel.stock.owned
            Layout.fillWidth: true
            Sym { name: "cart"; size: 12; color: Theme.warning }
            Text { text: qsTr("This stock is not marked as owned."); color: Theme.warning; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
            GlassButton { title: qsTr("I Have It Now"); large: false; onClicked: panel.ws.markStockOwned() }
        }
        ValueRow { visible: panel.stock.size !== undefined; label: qsTr("Size"); value: panel.stock.size || "" }
        RowLayout {
            visible: panel.stock.size !== undefined
            Layout.fillWidth: true
            spacing: 8
            Sym { name: panel.stock.fits ? "checkmark.circle.fill" : "xmark.octagon.fill"; size: 13; color: panel.stock.fits ? Theme.ok : Theme.danger; Layout.alignment: Qt.AlignTop }
            Text { text: panel.stock.fitsText || ""; color: panel.stock.fits ? Theme.ok : Theme.danger; font.pixelSize: 13; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }
        MenuButtonRow {
            visible: panel.stock.size !== undefined && (panel.stock.orientations || []).length > 0
            symbol: "rotate.3d"
            title: panel.stock.orientation || qsTr("How it sits")
            help: qsTr("Which stock dimension runs along each work axis. Any orientation that contains the part can be chosen; workholding is assessed separately.")
            Repeater {
                model: panel.stock.orientations || []
                delegate: MenuItem {
                    required property var modelData
                    text: modelData.summary
                    enabled: modelData.workable
                    checkable: true
                    checked: modelData.selected
                    onTriggered: panel.ws.useStockAxesSlot(modelData.axes)
                }
            }
        }
    }
    Card {
        visible: panel.scope === "stock" && panel.stock.size !== undefined
        GlassButton {
            title: qsTr("Plan with My Library")
            symbol: "sparkles"
            prominent: true
            large: false
            implicitHeight: 24
            enabled: panel.stock.canPlan === true
            onClicked: panel.ws.enterStage("planning")
        }
    }
}
