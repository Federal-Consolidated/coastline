pragma Singleton
import QtQuick

// Coastline's look: black, white and greys; red and yellow only for safety (stop, alarms,
// collisions; cautions). Port of Views/Theme.swift.
QtObject {
    property real accentGrey: 0.50   // set from Settings (graphite 0.50, charcoal 0.40, steel 0.58)

    readonly property color window: "#0e0e0e"
    readonly property color panel: "#121212"
    readonly property color card: "#1b1b1d"
    readonly property color cardHover: "#232326"
    readonly property color selection: "#3a3a3e"
    readonly property color line: "#2a2a2d"
    readonly property color text: "#ececec"
    readonly property color secondary: "#9b9b9f"
    readonly property color tertiary: "#6c6c70"
    readonly property color accent: Qt.rgba(accentGrey, accentGrey, accentGrey, 1)
    readonly property color danger: "#ff3b30"
    readonly property color warning: "#ffd60a"
    readonly property color ok: "#e0e0e0"
    readonly property color prepCut: "#d9d9d9"

    // The Mac app's own values (Views/Theme.swift and the macOS 26 dark appearance).
    readonly property color windowBackground: Qt.rgba(0.055, 0.055, 0.055, 1)
    readonly property color panelBackground: Qt.rgba(0.072, 0.072, 0.072, 1)
    readonly property color sidebarBackground: "#1b1b1b"
    readonly property color toolbarBackground: "#1e1e1e"
    readonly property color sidebarSelection: "#3f3f3f"
    readonly property color label: Qt.rgba(1, 1, 1, 0.85)
    readonly property color secondaryLabel: Qt.rgba(1, 1, 1, 0.55)
    readonly property color tertiaryLabel: Qt.rgba(1, 1, 1, 0.25)
    readonly property color separator: "#2b2b2b"
    readonly property color glass: Qt.rgba(0.16, 0.16, 0.17, 0.82)
    readonly property color glassStroke: Qt.rgba(1, 1, 1, 0.08)
    readonly property color formRow: "#191919"
    readonly property color systemYellow: "#ffd60a"
    readonly property color systemRed: "#ff453a"
    readonly property color systemBlue: "#0a84ff"
    readonly property string fontFamily: Qt.platform.os === "osx" ? ".AppleSystemUIFont" : "Segoe UI Variable Text"
    // SwiftUI's text styles on macOS, in points (= QML pixels at 1x).
    readonly property int largeTitle: 26
    readonly property int title1: 22
    readonly property int title2: 17
    readonly property int title3: 15
    readonly property int headline: 13   // bold
    readonly property int body: 13
    readonly property int callout: 12
    readonly property int subheadline: 11
    readonly property int footnote: 10
    readonly property int caption: 10
    readonly property int caption2: 10
    readonly property int sidebarText: 11
    readonly property int sidebarHeader: 10

    readonly property int radius: 10
    readonly property int spacing: 8
    readonly property int fontSize: 13
    readonly property int smallFont: 11
    readonly property int titleFont: 20

    function severityColor(s) {
        return s === "error" ? danger : s === "warning" ? warning : secondary
    }
    function severitySymbol(s) {
        return s === "error" ? "⛔" : s === "warning" ? "⚠" : "ⓘ"
    }
    function categoryColor(c) {   // DFM categories: 0 can't, 1 missing, 2 info, 3 setup, 4 ok
        return c === 0 ? danger : c === 1 ? warning : c === 4 ? ok : secondary
    }
}
