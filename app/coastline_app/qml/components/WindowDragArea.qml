import QtQuick

// The title bar's empty space: drag to move the window, double-click to zoom it (the content
// reaches under the transparent title bar, so the system's own drag area is covered).
Item {
    id: area
    DragHandler {
        target: null
        grabPermissions: PointerHandler.CanTakeOverFromAnything
        onActiveChanged: if (active && area.Window.window) area.Window.window.startSystemMove()
    }
    TapHandler {
        onDoubleTapped: {
            const w = area.Window.window
            if (!w) return
            if (w.visibility === Window.Maximized) w.showNormal(); else w.showMaximized()
        }
    }
}
