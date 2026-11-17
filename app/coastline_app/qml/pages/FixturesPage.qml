import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import "../components"

// Fixtures: clamps, vises, jigs. Port of FixturesPage / FixtureInspector (SimplePages.swift).
ItemListPage {
    id: page
    listName: "fixtures"
    title: qsTr("Fixtures")
    noun: qsTr("fixture")
    kindEnum: "FixtureKind"
    extraAddItems: [{title: qsTr("Import Jig Model…"), action: () => importDialog.open()}]
    addTitle: qsTr("Add Fixture")
    emptySymbol: "square.grid.3x3.square"
    emptyTitle: qsTr("No Fixtures")
    columns: [
        {title: qsTr("Fixture"), role: "name", width: 0, cell: page.nameCell},
        {title: qsTr("Type"), role: "kind", width: 140, color: r => Theme.secondaryLabel},
        {title: qsTr("Clamps"), role: "clamps", width: 60},
        {title: qsTr("Probing"), role: "probing", width: 80, color: r => Theme.secondaryLabel},
        {title: qsTr("3D Model"), role: "modelMark", width: 70, color: r => Theme.secondaryLabel},
        {title: qsTr("Qty"), role: "quantity", width: 44}
    ]
    FileDialog {
        id: importDialog
        title: qsTr("Import Jig Model")
        nameFilters: [qsTr("CAD models (*.step *.stp *.iges *.igs *.3dm *.stl *.3mf)")]
        onAccepted: page.table.selection = [page.inventory.importFixtureModel(page.app.localPath(selectedFile))]
    }
    FileDialog {
        id: modelDialog
        title: qsTr("Choose Model")
        nameFilters: [qsTr("CAD models (*.step *.stp *.iges *.igs *.3dm *.stl *.3mf)")]
        onAccepted: page.inventory.setFixtureModel(page.selectedId, page.app.localPath(selectedFile))
    }
    itemInspector: Component {
        ColumnLayout {
            spacing: 0
            Card {
                title: page.item.planned === true ? qsTr("Assembly and stock") : ""
                ItemPreview3D { app: page.app; kind: "fixtures"; itemId: page.item.id || ""; color: "transparent"; Layout.preferredHeight: 200 }
                LinkButton { symbol: "move.3d"; title: qsTr("Place Around Stock in Workspace…"); enabled: (page.app.workspace.revision, page.app.workspace.header().hasPart && page.app.workspace.header().hasStock)
                    onClicked: { page.app.workspace.placeFixture(page.item.id); page.app.page = "workspace" } }
            }
            Card {
                title: qsTr("Fixture")
                FieldRow { label: qsTr("Name"); TextEdit { value: page.item.name || ""; onCommitted: t => page.set("name", t) } }
                FieldRow { label: qsTr("Type"); ChoiceEdit { choices: page.inventory.choices("FixtureKind"); value: page.item.kind; onCommitted: v => page.set("kind", v) } }
                StepperRow { label: qsTr("Quantity"); value: page.item.quantity || 0; onCommitted: v => page.set("quantity", v) }
            }
            Card {
                title: qsTr("Workholding")
                footer: qsTr("Isolated fixtures let the machine's probe wire touch off on the part (conductive probing). The universal clamp clamps along X, a vise along Y.")
                FieldRow { label: qsTr("Clamps along"); ChoiceEdit { choices: page.inventory.choices("ClampAxis"); value: page.item.clampAxis; onCommitted: v => page.set("clampAxis", v) } }
                Item {
                    Layout.fillWidth: true
                    implicitHeight: 22
                    Text { text: qsTr("Grips stock"); color: Theme.label; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        NumberEdit { width: 56; unit: ""; value: page.item.gripRange ? page.item.gripRange[0] : null; optional: true
                            onCommitted: v => page.set("gripRange", v === null ? null : [v, page.item.gripRange ? page.item.gripRange[1] : v]) }
                        Text { text: "–"; color: Theme.secondaryLabel; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                        NumberEdit { width: 76; value: page.item.gripRange ? page.item.gripRange[1] : null; optional: true
                            onCommitted: v => page.set("gripRange", v === null ? null : [page.item.gripRange ? page.item.gripRange[0] : 0, v]) }
                    }
                }
                NumberRow { label: qsTr("Raises stock by"); value: page.item.height || 0; onCommitted: v => page.set("height", v) }
                SwitchRow { label: qsTr("Electrically isolated"); checked: page.item.isolated === true; onToggled: on => page.set("isolated", on) }
            }
            Card {
                title: qsTr("Model")
                LinkButton { symbol: "folder"; title: (page.item.modelPath || "") === "" ? qsTr("Choose Model…") : qsTr("Replace Model…"); onClicked: modelDialog.open() }
                FieldRow { label: qsTr("3D model file"); TextEdit { value: page.item.modelPath || ""; placeholderText: qsTr("STEP, 3MF or STL"); onCommitted: t => page.set("modelPath", t === "" ? null : t) } }
                FieldRow { label: qsTr("Notes"); TextEdit { value: page.item.notes || ""; onCommitted: t => page.set("notes", t) } }
                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: Theme.secondaryLabel
                    font.pixelSize: 10
                    text: qsTr("Imported models are copied into Coastline's library. An assembled jig with a planning definition is available for cut-driven fixture selection and clearance checks.")
                }
            }
            Card {
                id: planning
                title: qsTr("Automatic setup planning")
                footer: qsTr("Use a closed-solid STEP assembly with the fixture and hardware, without the stock or part. Define the stock and grip for this assembled state once.")
                readonly property var ex: page.app.inventoryExtras
                readonly property string fid: page.item.id || ""
                readonly property var p: (ex.revision, fid === "" ? ({}) : ex.fixturePlanning(fid))
                function set(k, v) { ex.setFixturePlanning(fid, k, v) }
                CheckRow { text: qsTr("Consider this fixture when planning"); checked: planning.p.enabled === true; onToggled: on => planning.set("enabled", on) }
                ColumnLayout {
                    visible: planning.p.defined === true
                    Layout.fillWidth: true
                    spacing: 6
                    LinkButton {
                        title: qsTr("Use This Job's Stock Dimensions")
                        enabled: page.app.jobStockSize().length === 3
                        onClicked: planning.ex.useStockSizeForFixture(planning.fid, page.app.jobStockSize())
                    }
                    Text { text: qsTr("Stock held by this assembly"); color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold }
                    NumberRow { label: qsTr("Stock X · up"); value: planning.p.stockX; onCommitted: v => planning.set("stockX", v) }
                    NumberRow { label: qsTr("Stock Y · across"); value: planning.p.stockY; onCommitted: v => planning.set("stockY", v) }
                    NumberRow { label: qsTr("Stock Z · depth"); value: planning.p.stockZ; onCommitted: v => planning.set("stockZ", v) }
                    NumberRow { label: qsTr("Face past table edge"); value: planning.p.facePastTable; onCommitted: v => planning.set("facePastTable", v) }
                    CheckRow { text: qsTr("Suitable for roughing and facing"); checked: planning.p.allowsRoughing === true; onToggled: on => planning.set("allowsRoughing", on) }
                    Text { text: qsTr("CAD datum (stock-face centre in the model) and orientation"); color: Theme.secondaryLabel; font.pixelSize: 10 }
                    NumberRow { label: qsTr("CAD datum X"); value: planning.p.datumX; onCommitted: v => planning.set("datumX", v) }
                    NumberRow { label: qsTr("CAD datum Y"); value: planning.p.datumY; onCommitted: v => planning.set("datumY", v) }
                    NumberRow { label: qsTr("CAD datum Z"); value: planning.p.datumZ; onCommitted: v => planning.set("datumZ", v) }
                    FieldRow { label: qsTr("CAD face toward spindle"); ChoiceEdit { choices: planning.p.facings || []; value: planning.p.facing; onCommitted: v => planning.set("facing", v) } }
                    FieldRow { label: qsTr("Turn around spindle"); ChoiceEdit { choices: [{value: 0, title: "0°"}, {value: 1, title: "90°"}, {value: 2, title: "180°"}, {value: 3, title: "270°"}]; value: planning.p.spin; onCommitted: v => planning.set("spin", v) } }
                    Text { text: qsTr("Grip / support patches"); color: Theme.label; font.pixelSize: 12; font.weight: Font.DemiBold }
                    Text { text: qsTr("Points in stock work coordinates: X up, Y across, Z from 0 at the front face toward negative depth."); color: Theme.secondaryLabel; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: 10 }
                    Repeater {
                        model: planning.p.contacts || []
                        delegate: ColumnLayout {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            RowLayout { Text { text: qsTr("Patch %1").arg(index + 1); color: Theme.label; font.pixelSize: 12; Layout.fillWidth: true } SmallButton { title: qsTr("Remove"); onClicked: planning.ex.removeContact(planning.fid, modelData.id) } }
                            NumberRow { label: "X"; value: modelData.x; onCommitted: v => planning.ex.setContact(planning.fid, modelData.id, "x", v) }
                            NumberRow { label: "Y"; value: modelData.y; onCommitted: v => planning.ex.setContact(planning.fid, modelData.id, "y", v) }
                            NumberRow { label: "Z"; value: modelData.z; onCommitted: v => planning.ex.setContact(planning.fid, modelData.id, "z", v) }
                            FieldRow { label: qsTr("Face normal"); ChoiceEdit { choices: [{value: "x", title: "X"}, {value: "y", title: "Y"}, {value: "z", title: "Z"}]; value: modelData.normal; onCommitted: v => planning.ex.setContact(planning.fid, modelData.id, "normal", v) } }
                            NumberRow { label: qsTr("Radius"); value: modelData.radius; onCommitted: v => planning.ex.setContact(planning.fid, modelData.id, "radius", v) }
                        }
                    }
                    LinkButton { symbol: "plus"; title: qsTr("Add Grip / Support Patch"); onClicked: planning.ex.addContact(planning.fid) }
                    CheckRow { text: qsTr("Grip, mounting and cutting-load definition reviewed"); checked: planning.p.reviewed === true; onToggled: on => planning.set("reviewed", on) }
                    Repeater { model: planning.p.issues || []; delegate: Text { required property var modelData; text: modelData; color: Theme.secondaryLabel; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: 10 } }
                }
            }
            Item { implicitHeight: 24 }
        }
    }
}
