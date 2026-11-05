import QtQuick
import QtQuick.Layouts
import qs
import qs.shelf

// File shelf: header + list + drop zones + context menu.
Item {
    id: shelf

    property bool expanded: true
    property bool dragIncoming: false            // set by Sidebar while a drag hovers the bar
    readonly property bool dropHover: linkZone.containsDrag || copyZone.containsDrag
    readonly property bool menuOpen: menu.visible

    // ---- header ------------------------------------------------------------
    RowLayout {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 28
        spacing: 2

        Text {
            Layout.leftMargin: shelf.expanded ? 4 : 0
            Layout.fillWidth: !shelf.expanded
            horizontalAlignment: Text.AlignHCenter
            text: shelf.expanded ? "Shelf" : ""   // nf-fa-archive
            color: Theme.textDim
            font.family: shelf.expanded ? Theme.font : Theme.iconFont
            font.pixelSize: shelf.expanded ? Theme.fontSize : Theme.iconSize
            font.weight: Font.DemiBold
        }
        Text {
            visible: shelf.expanded && ShelfStore.items.length > 0
            text: ShelfStore.selectedCount ? `${ShelfStore.selectedCount}/${ShelfStore.items.length}` : ShelfStore.items.length
            color: Theme.textDim
            font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall
        }
        Item { Layout.fillWidth: true; visible: shelf.expanded }

        IconButton {
            visible: shelf.expanded && ShelfStore.items.length > 0
            glyph: ShelfStore.selectedCount ? "" : ""   // square / check-square
            tip: ShelfStore.selectedCount ? "Select none" : "Select all"
            onClicked: ShelfStore.selectAll(ShelfStore.selectedCount === 0)
        }
        IconButton {
            visible: shelf.expanded && ShelfStore.selectedCount > 0
            glyph: ""   // trash
            tip: "Remove selected"
            onClicked: ShelfStore.remove(Object.keys(ShelfStore.selected))
        }
        IconButton {
            id: clearBtn
            // Two-step: first click arms, second within 2.5 s clears.
            property bool armed: false
            visible: shelf.expanded && ShelfStore.items.length > 0
            glyph: armed ? "" : ""   // check / eraser
            danger: armed
            tip: armed ? "Click again to clear all" : "Clear all"
            onClicked: {
                if (armed) { ShelfStore.clearAll(); armed = false; }
                else { armed = true; disarm.restart(); }
            }
            Timer { id: disarm; interval: 2500; onTriggered: clearBtn.armed = false }
        }
    }

    // ---- list --------------------------------------------------------------
    ListView {
        id: list
        anchors { top: header.bottom; topMargin: Theme.spacing; left: parent.left; right: parent.right; bottom: parent.bottom }
        clip: true
        spacing: Theme.spacing
        model: ShelfStore.items
        boundsBehavior: Flickable.StopAtBounds
        // Flicking would steal the gesture from the item DragHandlers.
        interactive: false
        WheelHandler {
            onWheel: ev => list.contentY = Math.max(0, Math.min(list.contentHeight - list.height,
                                                                 list.contentY - ev.angleDelta.y))
        }

        delegate: ShelfItem {
            width: list.width
            expanded: shelf.expanded
            onContextMenu: (it, x, y) => menu.openFor(it, mapToItem(shelf, x, y))
        }
    }

    // Empty state.
    Column {
        anchors.centerIn: list
        visible: ShelfStore.ready && ShelfStore.items.length === 0 && !shelf.dragIncoming
        spacing: 6
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: ""   // cloud-download-ish
            font.family: Theme.iconFont; font.pixelSize: 22
            color: Theme.textDim
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: shelf.expanded
            text: "Drop files here"
            font.family: Theme.font; font.pixelSize: Theme.fontSize
            color: Theme.textDim
        }
    }

    // ---- drop zones (shown while a drag hovers the bar) ---------------------
    // Two zones instead of a modifier key: a layer-shell bar has no keyboard
    // focus during DnD, so it can't see Ctrl/Shift reliably.
    ColumnLayout {
        anchors.fill: list
        spacing: Theme.spacing
        visible: shelf.dragIncoming || shelf.dropHover
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }

        DropZone {
            id: linkZone
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredHeight: 3
            glyph: ""; label: "Keep link"; hint: "reference the original"
            expanded: shelf.expanded
            onDroppedUrls: urls => ShelfStore.addUrls(urls, false)
        }
        DropZone {
            id: copyZone
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredHeight: 2
            glyph: ""; label: "Copy to shelf"; hint: "~/.cache/shelf"
            expanded: shelf.expanded
            onDroppedUrls: urls => ShelfStore.addUrls(urls, true)
        }
    }

    // ---- context menu ------------------------------------------------------
    // Drawn inside the panel (no popup window needed). A full-size catcher
    // closes it on any outside click.
    MouseArea {
        anchors.fill: parent
        visible: menu.visible
        acceptedButtons: Qt.AllButtons
        onPressed: menu.visible = false
    }
    Rectangle {
        id: menu
        property var target: null
        visible: false
        width: Math.min(170, shelf.width - 8)
        height: menuCol.implicitHeight + 8
        radius: Theme.itemRadius
        color: "#1b1c1f"
        border.color: Theme.border
        z: 10

        function openFor(it, pos) {
            target = it;
            x = Math.max(4, Math.min(pos.x, shelf.width - width - 4));
            y = Math.max(4, Math.min(pos.y, shelf.height - height - 4));
            visible = true;
        }

        Column {
            id: menuCol
            anchors { fill: parent; margins: 4 }
            MenuEntry { glyph: ""; label: "Open"; enabled: !!menu.target && !menu.target.missing
                        onTriggered: ShelfStore.open(menu.target) }
            MenuEntry { glyph: ""; label: "Show in folder"; enabled: !!menu.target && !menu.target.missing
                        onTriggered: ShelfStore.showInFolder(menu.target) }
            MenuEntry { glyph: ""; label: "Remove"; danger: true
                        onTriggered: ShelfStore.remove([menu.target.id]) }
            MenuEntry { glyph: ""; label: "Clear all"; danger: true
                        onTriggered: ShelfStore.clearAll() }
        }
    }

    // ---- small inline components ------------------------------------------
    component MenuEntry: Rectangle {
        id: entry
        property string glyph
        property string label
        property bool danger: false
        signal triggered
        width: parent.width
        height: 28
        radius: 6
        opacity: enabled ? 1 : 0.4
        color: ma.containsMouse ? Theme.surfaceHover : "transparent"
        Row {
            anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 8 }
            spacing: 8
            Text { text: entry.glyph; font.family: Theme.iconFont; font.pixelSize: 12
                   color: entry.danger ? Theme.danger : Theme.textDim; width: 14 }
            Text { text: entry.label; font.family: Theme.font; font.pixelSize: Theme.fontSize
                   color: entry.danger ? Theme.danger : Theme.text }
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            onClicked: { menu.visible = false; entry.triggered(); }
        }
    }

    component DropZone: DropArea {
        id: zone
        property string glyph
        property string label
        property string hint
        property bool expanded
        signal droppedUrls(var urls)

        onEntered: drag => drag.accepted = drag.hasUrls
        onDropped: drop => {
            if (!drop.hasUrls) return;
            drop.acceptProposedAction();
            zone.droppedUrls(drop.urls);
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.itemRadius
            color: zone.containsDrag ? Theme.accentStrong : Theme.accentSoft
            border.width: 1
            border.color: zone.containsDrag ? Theme.accent : Theme.border
            Behavior on color { ColorAnimation { duration: 100 } }

            Column {
                anchors.centerIn: parent
                spacing: 4
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: zone.glyph
                       font.family: Theme.iconFont; font.pixelSize: 20; color: Theme.accent }
                Text { anchors.horizontalCenter: parent.horizontalCenter; visible: zone.expanded
                       text: zone.label; font.family: Theme.font; font.pixelSize: Theme.fontSize
                       font.weight: Font.DemiBold; color: Theme.text }
                Text { anchors.horizontalCenter: parent.horizontalCenter; visible: zone.expanded
                       text: zone.hint; font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall
                       color: Theme.textDim }
            }
        }
    }
}
