import QtQuick
import qs

// Result of an action, floating above the bottom of the panel. Slides up into
// place so it reads as an answer to what you just did; click to dismiss.
Rectangle {
    id: toast

    property bool isError: false
    property bool open: false

    function show(message, error) {
        label.text = message;
        isError = !!error;
        open = true;
        hideTimer.restart();
    }

    height: Math.max(34, label.implicitHeight + 16)
    radius: Math.min(height / 2, Theme.itemRadius + 4)
    color: "#1a1d23"
    border.color: isError ? Qt.rgba(0.94, 0.64, 0.61, 0.35) : Theme.border
    border.width: 1

    opacity: open ? 1 : 0
    visible: opacity > 0
    transform: Translate { y: toast.open ? 0 : 8; Behavior on y { NumberAnimation { duration: Theme.animMs; easing.type: Theme.ease } } }
    Behavior on opacity { NumberAnimation { duration: Theme.animMs; easing.type: Theme.ease } }

    Text {
        id: mark
        anchors { left: parent.left; leftMargin: 12; top: parent.top; topMargin: (Math.min(parent.height, 34) - height) / 2 }
        text: toast.isError ? "\uf06a" : "\uf00c"     // alert-circle / check
        font.family: Theme.iconFont
        font.pixelSize: 12
        color: toast.isError ? Theme.danger : Theme.success
    }

    Text {
        id: label
        anchors { left: mark.right; leftMargin: 8; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        lineHeight: 1.15
        color: Theme.text
        font.family: Theme.font
        font.pixelSize: Theme.fontSizeSmall + 1
    }

    Timer { id: hideTimer; interval: toast.isError ? 5000 : 2600; onTriggered: toast.open = false }

    MouseArea { anchors.fill: parent; onClicked: toast.open = false }
}
