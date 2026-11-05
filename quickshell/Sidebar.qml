import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs
import qs.shelf
import qs.session

// Right-edge auto-hiding sidebar, one per screen.
PanelWindow {
    id: win

    required property ShellScreen modelData
    screen: modelData

    anchors { top: true; bottom: true; right: true }
    // The surface is always as wide as the expanded bar. Only `mask` below
    // decides what receives input; the rest is click-through. Resizing the
    // layer surface on every hover would make Hyprland re-layout constantly.
    implicitWidth: Theme.expandedWidth + Theme.edgeMargin * 2
    exclusiveZone: 0                   // overlay windows, don't push them aside
    color: "transparent"

    WlrLayershell.namespace: "sessionbar"   // for Hyprland layer rules (blur)
    WlrLayershell.layer: WlrLayer.Top
    // Keyboard only while typing a session name; otherwise never steal focus.
    // Exclusive = typing works immediately, no extra click into the field.
    WlrLayershell.keyboardFocus: sessions.prompting ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // Input region: a thin strip at the edge while hidden, the whole panel while shown.
    mask: Region { item: hitArea }

    // ---- state machine -----------------------------------------------------
    readonly property bool dragIncoming: edgeDrop.containsDrag || shelf.dropHover
    readonly property bool wantShown: hover.hovered || dragIncoming || ShelfStore.draggingOut || shelf.menuOpen
    // SESSIONBAR_PIN=1 keeps the bar open and wide (handy while restyling).
    readonly property bool pinned: Quickshell.env("SESSIONBAR_PIN") === "1"
    property bool shown: pinned
    property bool expanded: pinned

    onWantShownChanged: {
        if (wantShown) {
            hideTimer.stop();
            if (dragIncoming) win.shown = true;    // drags reveal instantly
            else revealTimer.restart();
        } else {
            revealTimer.stop();
            hideTimer.restart();
        }
    }
    onDragIncomingChanged: if (dragIncoming) { shown = true; expanded = true; }
    onShownChanged: if (shown) { ShelfStore.refreshMissing(); Hyprsess.refresh(); }

    Timer { id: revealTimer; interval: Theme.revealDelay; onTriggered: if (win.wantShown) win.shown = true }
    Timer {
        id: hideTimer
        // Longer grace while the name prompt is open, so a stray pointer move
        // doesn't throw away what you're typing.
        interval: sessions.prompting ? 4000 : Theme.hideDelay
        onTriggered: {
            if (win.pinned) return;
            sessions.closePrompt();   // also releases the keyboard grab
            win.shown = false;
            win.expanded = false;
        }
    }
    Timer {
        // Widen after hovering the revealed bar for a moment.
        interval: Theme.expandDelay
        running: win.shown && hover.hovered && !win.expanded
        onTriggered: win.expanded = true
    }

    // ---- content -----------------------------------------------------------
    Item {
        id: root
        anchors.fill: parent

        // Parent of everything, so hovering any child still counts as hovered.
        HoverHandler { id: hover }

        Item {
            id: hitArea
            readonly property real panelX: win.width - Theme.edgeMargin - panel.targetWidth
            x: win.shown ? panelX : win.width - Theme.stripWidth
            width: win.width - x
            height: parent.height
        }

        // Catches drags anywhere on the strip/panel. It's where a drag first
        // arrives, so it works out what's coming (files, a web image or link,
        // text) for the shelf's drop zones. Dropping outside the zones does
        // what the first zone does.
        DropArea {
            id: edgeDrop
            anchors.fill: parent
            onEntered: drag => {
                drag.accepted = ShelfStore.acceptsDrag(drag);
                if (drag.accepted) ShelfStore.incoming = ShelfStore.inspect(drag);
            }
            onDropped: drop => {
                if (!ShelfStore.acceptsDrag(drop)) return;
                drop.accept(Qt.CopyAction);   // never "move": the source must keep its file
                ShelfStore.handleDrop(drop, ShelfStore.zonesFor(ShelfStore.incoming || ShelfStore.inspect(drop))[0].role);
            }
        }

        Rectangle {
            id: panel
            readonly property real targetWidth: win.expanded ? Theme.expandedWidth : Theme.collapsedWidth

            anchors { right: parent.right; top: parent.top; bottom: parent.bottom
                      topMargin: Theme.edgeMargin; bottomMargin: Theme.edgeMargin }
            // Slide by animating the right margin: fully off-screen when hidden.
            anchors.rightMargin: win.shown ? Theme.edgeMargin : -width - 2
            Behavior on anchors.rightMargin { NumberAnimation { duration: Theme.animMs; easing.type: Theme.ease } }

            width: targetWidth
            Behavior on width { NumberAnimation { duration: Theme.animMs; easing.type: Theme.ease } }

            radius: Theme.radius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1
            clip: true

            // Faint highlight along the top edge: light catching the glass.
            Rectangle {
                anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 1
                          leftMargin: Theme.radius; rightMargin: Theme.radius }
                height: 1
                color: Theme.sheen
            }

            ColumnLayout {
                anchors { fill: parent; margins: Theme.padding; topMargin: Theme.padding + 4 }
                spacing: 18

                Shelf {
                    id: shelf
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    expanded: win.expanded
                    dragIncoming: win.dragIncoming
                }

                SessionPanel {
                    id: sessions
                    Layout.fillWidth: true
                    Layout.preferredHeight: implicitHeight
                    maxHeight: panel.height * 0.45
                    expanded: win.expanded
                }
            }

            Toast {
                id: toast
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: Theme.padding }
            }
        }
    }

    Connections {
        target: ShelfStore
        function onNotify(message, isError) { toast.show(message, isError); }
    }
    Connections {
        target: Hyprsess
        function onNotify(message, isError) { toast.show(message, isError); }
    }
}
