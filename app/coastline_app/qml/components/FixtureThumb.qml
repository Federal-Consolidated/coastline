import QtQuick
import QtQuick.Controls

// FixtureThumbnail: the fixture's model as a small picture; a spinner while it's drawn.
Item {
    id: th
    property var ws
    property string fixtureId: ""
    property bool hasModel: true
    readonly property string key: (ws.revision, ws.fixtureThumbnail(fixtureId))
    Image {
        anchors.fill: parent
        anchors.margins: 4
        visible: th.key !== "" && th.key !== "failed"
        source: visible ? "image://thumb/" + th.key : ""
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
    }
    Sym { anchors.centerIn: parent; visible: th.key === "failed"; name: "cube.transparent"; size: 22; color: Theme.secondaryLabel }
    BusyIndicator { anchors.centerIn: parent; visible: th.key === ""; running: visible; width: 16; height: 16 }
}
