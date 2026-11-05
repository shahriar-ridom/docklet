import QtQuick
import qs

// Small round Nerd-Font glyph button.
Rectangle {
    id: btn

    property string glyph
    property string tip
    property bool danger: false
    property bool spinning: false      // rotate the glyph (busy indicator)
    signal clicked

    implicitWidth: 26
    implicitHeight: 26
    radius: width / 2
    color: ma.containsMouse ? (danger ? Theme.dangerSoft : Theme.surfaceHover) : "transparent"
    Behavior on color { ColorAnimation { duration: 100 } }

    Text {
        id: glyphText
        anchors.centerIn: parent
        text: btn.glyph
        font.family: Theme.iconFont
        font.pixelSize: 13
        color: btn.danger ? Theme.danger : (ma.containsMouse ? Theme.text : Theme.textDim)
        RotationAnimation on rotation {
            running: btn.spinning
            loops: Animation.Infinite
            from: 0; to: 360; duration: 900
            onStopped: glyphText.rotation = 0
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        onClicked: btn.clicked()
    }
}
