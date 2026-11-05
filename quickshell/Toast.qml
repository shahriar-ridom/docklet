import QtQuick
import qs

// Transient success/error message at the bottom of the panel.
Rectangle {
    id: toast

    property bool isError: false

    function show(message, error) {
        label.text = message;
        isError = !!error;
        opacity = 1;
        hideTimer.restart();
    }

    height: label.implicitHeight + 12
    radius: Theme.itemRadius
    color: isError ? Theme.dangerSoft : Theme.accentSoft
    border.color: isError ? Theme.danger : Theme.accent
    border.width: 1
    opacity: 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 150 } }

    Text {
        id: label
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 8 }
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        color: toast.isError ? Theme.danger : Theme.text
        font.family: Theme.font
        font.pixelSize: Theme.fontSizeSmall
    }

    Timer { id: hideTimer; interval: toast.isError ? 5000 : 2500; onTriggered: toast.opacity = 0 }

    MouseArea { anchors.fill: parent; onClicked: toast.opacity = 0 }
}
