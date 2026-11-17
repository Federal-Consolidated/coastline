import QtQuick
import QtQuick.Shapes

// A dashed outline (a step done by hand).
Shape {
    id: db
    property real radius: 4
    property color color: Qt.rgba(0.55, 0.55, 0.55, 0.7)
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
        strokeColor: db.color
        strokeWidth: 1
        strokeStyle: ShapePath.DashLine
        dashPattern: [3, 2]
        fillColor: "transparent"
        PathRectangle { x: 0.5; y: 0.5; width: db.width - 1; height: db.height - 1; radius: db.radius }
    }
}
