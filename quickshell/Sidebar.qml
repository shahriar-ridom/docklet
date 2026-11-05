import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs
import qs.shelf

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
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

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
    onShownChanged: if (shown) ShelfStore.refreshMissing()

    Timer { id: revealTimer; interval: Theme.revealDelay; onTriggered: if (win.wantShown) win.shown = true }
    Timer { id: hideTimer; interval: Theme.hideDelay; onTriggered: if (!win.pinned) { win.shown = false; win.expanded = false; } }
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

        // Catches drags anywhere on the strip/panel; dropping outside the two
        // zones defaults to "keep link".
        DropArea {
            id: edgeDrop
            anchors.fill: parent
            onEntered: drag => drag.accepted = drag.hasUrls
            onDropped: drop => {
                if (!drop.hasUrls) return;
                drop.acceptProposedAction();
                ShelfStore.addUrls(drop.urls, false);
            }
        }

        Rectangle {
            id: panel
            readonly property real targetWidth: win.expanded ? Theme.expandedWidth : Theme.collapsedWidth

            anchors { right: parent.right; top: parent.top; bottom: parent.bottom
                      topMargin: Theme.edgeMargin; bottomMargin: Theme.edgeMargin }
            // Slide by animating the right margin: fully off-screen when hidden.
            anchors.rightMargin: win.shown ? Theme.edgeMargin : -width - 2
            Behavior on anchors.rightMargin { NumberAnimation { duration: Theme.animMs; easing.type: Easing.OutCubic } }

            width: targetWidth
            Behavior on width { NumberAnimation { duration: Theme.animMs; easing.type: Easing.OutCubic } }

            radius: Theme.radius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1
            clip: true

            ColumnLayout {
                anchors { fill: parent; margins: Theme.padding }
                spacing: Theme.padding

                Shelf {
                    id: shelf
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    expanded: win.expanded
                    dragIncoming: win.dragIncoming
                }

                // Stage 3: SessionPanel goes here.
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
}
