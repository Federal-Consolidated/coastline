import QtQuick
import QtQuick.Controls

// A view's .help(): the text in a tooltip after a moment's hover.
ToolTip {
    property bool shown: false
    visible: shown && text !== ""
    delay: 800
}
