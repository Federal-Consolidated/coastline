import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A number field with a unit; accepts "1/4\"" style inch input when the unit is mm.
RowLayout {
    id: edit
    property var value: 0
    property string unit: "mm"
    property int decimals: 3
    property bool optional: false     // empty clears the value (null)
    property bool integer: false
    signal committed(var value)
    width: parent ? parent.width : 200
    spacing: 6

    function format(v) {
        if (v === null || v === undefined) return ""
        if (integer) return String(Math.round(v))
        var s = Number(v).toFixed(decimals)
        return s.indexOf(".") >= 0 ? s.replace(/0+$/, "").replace(/\.$/, "") : s
    }
    function parse(t) {
        t = t.trim().replace(",", ".")
        if (t === "") return optional ? null : undefined
        var inch = t.match(/^(\d+(?:\.\d+)?)?\s*(?:(\d+)\/(\d+))?\s*(?:"|in)$/)
        if (inch && unit === "mm") {
            var whole = inch[1] ? parseFloat(inch[1]) : 0
            var frac = inch[2] ? parseFloat(inch[2]) / parseFloat(inch[3]) : 0
            return (whole + frac) * 25.4
        }
        var frac2 = t.match(/^(\d+)\/(\d+)$/)
        if (frac2) return parseFloat(frac2[1]) / parseFloat(frac2[2])
        var n = Number(t)
        return isNaN(n) ? undefined : (integer ? Math.round(n) : n)
    }

    TextField {
        id: field
        Layout.fillWidth: true
        text: edit.format(edit.value)
        color: Theme.text
        font.pixelSize: Theme.fontSize
        horizontalAlignment: Text.AlignRight
        selectByMouse: true
        placeholderText: edit.optional ? "—" : ""
        placeholderTextColor: Theme.secondaryLabel
        // A field in a grouped form: borderless, right-aligned, a focus ring only while typing.
        padding: 2
        background: Rectangle {
            radius: 4
            color: field.activeFocus ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
            border.width: field.activeFocus ? 2 : 0
            border.color: Qt.rgba(Theme.systemBlue.r, Theme.systemBlue.g, Theme.systemBlue.b, 0.6)
        }
        onEditingFinished: {
            var v = edit.parse(text)
            if (v === undefined) { text = edit.format(edit.value); return }
            if (v !== edit.value) edit.committed(v)
        }
        Connections {
            target: edit
            function onValueChanged() { if (!field.activeFocus) field.text = edit.format(edit.value) }
        }
    }
    Text {
        visible: edit.unit !== ""
        text: edit.unit
        color: Theme.secondaryLabel
        font.pixelSize: Theme.fontSize
    }
}
