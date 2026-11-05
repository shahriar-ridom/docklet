import QtQuick
import qs

// Small glyph button. With `label` set it becomes a pill: glyph + text.
Rectangle {
    id: btn

    property string glyph
    property string label: ""
    property string tip                // kept for callers; also the accessible name
    property bool danger: false
    property bool primary: false       // accent-tinted (the one main action in a section)
    property bool spinning: false      // rotate the glyph (busy indicator)
    signal clicked

    Accessible.role: Accessible.Button
    Accessible.name: label || tip

    implicitHeight: 26
    implicitWidth: label ? row.implicitWidth + 18 : 26
    radius: height / 2
    color: ma.pressed ? (danger ? Theme.dangerSoft : primary ? Theme.accentStrong : Theme.surfacePressed)
         : ma.containsMouse ? (danger ? Theme.dangerSoft : primary ? Theme.accentSoft : Theme.surfaceHover)
         : (primary && label ? Theme.accentSoft : "transparent")
    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

    scale: ma.pressed ? 0.92 : 1
    Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Theme.ease } }

    readonly property color ink: danger ? Theme.danger
                               : primary ? Theme.accent
                               : ma.containsMouse ? Theme.text : Theme.textDim

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 5
        Text {
            id: glyphText
            anchors.verticalCenter: parent.verticalCenter
            text: btn.glyph
            font.family: Theme.iconFont
            font.pixelSize: 13
            color: btn.ink
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            RotationAnimation on rotation {
                running: btn.spinning
                loops: Animation.Infinite
                from: 0; to: 360; duration: 800
                onStopped: glyphText.rotation = 0
            }
        }
        Text {
            visible: !!btn.label
            anchors.verticalCenter: parent.verticalCenter
            text: btn.label
            font.family: Theme.font
            font.pixelSize: Theme.fontSizeSmall + 1
            font.weight: Font.Medium
            color: btn.ink
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        anchors.margins: -3        // a slightly larger hit target than the drawn shape
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
