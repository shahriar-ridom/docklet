import QtQuick
import QtQuick.Layouts
import qs
import qs.shelf

// File shelf: header + list + drop zones + context menu.
Item {
    id: shelf

    property bool expanded: true
    property bool dragIncoming: false            // set by Sidebar while a drag hovers the bar
    property int _zonesHovered: 0
    readonly property bool dropHover: _zonesHovered > 0
    // Zones for whatever is being dragged in (set by Sidebar's edge DropArea).
    readonly property var zones: ShelfStore.zonesFor(ShelfStore.incoming)
    readonly property bool menuOpen: menu.visible

    // ---- header ------------------------------------------------------------
    RowLayout {
        id: headerRow
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 26
        spacing: 2

        Text {
            Layout.leftMargin: shelf.expanded ? 6 : 0
            Layout.fillWidth: !shelf.expanded
            horizontalAlignment: Text.AlignHCenter
            text: shelf.expanded ? "Shelf" : "\uf187"   // nf-fa-archive
            color: shelf.expanded ? Theme.text : Theme.textDim
            font.family: shelf.expanded ? Theme.fontDisplay : Theme.iconFont
            font.pixelSize: shelf.expanded ? Theme.fontSizeTitle : Theme.iconSize
            font.weight: Font.DemiBold
        }
        Text {
            Layout.leftMargin: 4
            visible: shelf.expanded && ShelfStore.items.length > 0
            text: ShelfStore.selectedCount ? `${ShelfStore.selectedCount} of ${ShelfStore.items.length} selected` : ShelfStore.items.length
            color: ShelfStore.selectedCount ? Theme.accent : Theme.textFaint
            font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall + 1
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
        anchors { top: headerRow.bottom; topMargin: 6; left: parent.left; right: parent.right; bottom: parent.bottom }
        clip: true
        spacing: Theme.spacing
        model: ShelfStore.items
        // Step aside while something is being dragged in, so the zones read cleanly.
        opacity: shelf.dragIncoming || shelf.dropHover ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
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

    // Empty state: says what the shelf is for, in one line.
    Column {
        anchors.centerIn: list
        visible: ShelfStore.ready && ShelfStore.items.length === 0 && !shelf.dragIncoming
        spacing: 8
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "\uf01c"   // inbox
            font.family: Theme.iconFont; font.pixelSize: 20
            color: Theme.textFaint
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: shelf.expanded
            text: "Drop files here"
            font.family: Theme.font; font.pixelSize: Theme.fontSize; font.weight: Font.Medium
            color: Theme.textDim
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: shelf.expanded
            width: 180
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: "Park them for a moment, then drag them into any app."
            font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall + 1
            lineHeight: 1.2
            color: Theme.textFaint
        }
    }

    // ---- drop zones (shown while a drag hovers the bar) ---------------------
    // Zones instead of a modifier key: a layer-shell bar has no keyboard focus
    // during DnD, so it can't see Ctrl/Shift reliably. Which zones appear
    // depends on what's dragged (ShelfStore.zonesFor).
    ColumnLayout {
        anchors.fill: list
        spacing: Theme.spacing
        visible: shelf.dragIncoming || shelf.dropHover
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }

        Repeater {
            model: shelf.zones
            delegate: DropZone {
                required property var modelData
                Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredHeight: modelData.weight
                glyph: modelData.glyph; label: modelData.label; hint: modelData.hint
                role: modelData.role
                expanded: shelf.expanded
                onContainsDragChanged: shelf._zonesHovered += containsDrag ? 1 : -1
                Component.onDestruction: if (containsDrag) shelf._zonesHovered -= 1
            }
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
        width: Math.min(176, shelf.width - 8)
        height: menuCol.implicitHeight + 10
        radius: Theme.itemRadius + 2
        color: "#1a1d23"
        border.color: Theme.border
        z: 10
        // Pops from where you clicked.
        scale: visible ? 1 : 0.96
        transformOrigin: Item.TopLeft
        Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Theme.ease } }

        function openFor(it, pos) {
            target = it;
            x = Math.max(4, Math.min(pos.x, shelf.width - width - 4));
            y = Math.max(4, Math.min(pos.y, shelf.height - height - 4));
            visible = true;
        }

        Column {
            id: menuCol
            anchors { fill: parent; margins: 5 }
            MenuEntry { readonly property bool isLink: !!menu.target && menu.target.kind === "link"
                        glyph: "\uf35d"; label: isLink ? "Open in browser" : "Open"
                        enabled: !!menu.target && !menu.target.missing && !menu.target.pending
                        onTriggered: ShelfStore.open(menu.target) }
            MenuEntry { glyph: "\uf07c"; label: "Show in folder"
                        visible: !!menu.target && menu.target.kind !== "link"
                        enabled: !!menu.target && !menu.target.missing && !menu.target.pending
                        onTriggered: ShelfStore.showInFolder(menu.target) }
            MenuEntry { readonly property bool isLink: !!menu.target && menu.target.kind === "link"
                        glyph: "\uf0c5"; label: isLink ? "Copy link" : "Copy path"
                        enabled: !!menu.target && !menu.target.pending
                        onTriggered: ShelfStore.copyLink(menu.target) }
            MenuEntry { glyph: "\uf019"; label: "Download video or file"
                        visible: !!menu.target && menu.target.kind === "link"
                        onTriggered: ShelfStore.download(menu.target.url, menu.target.name) }
            Rectangle { width: parent.width; height: 9; color: "transparent"
                        Rectangle { anchors.centerIn: parent; width: parent.width - 16; height: 1; color: Theme.border } }
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
        radius: 8
        opacity: enabled ? 1 : 0.4
        color: ma.containsMouse ? (entry.danger ? Theme.dangerSoft : Theme.surfaceHover) : "transparent"
        Row {
            anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 9 }
            spacing: 9
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
        property string role

        onEntered: drag => drag.accepted = ShelfStore.acceptsDrag(drag)
        onDropped: drop => {
            if (!ShelfStore.acceptsDrag(drop)) return;
            drop.accept(Qt.CopyAction);
            ShelfStore.handleDrop(drop, zone.role);
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.itemRadius + 4
            color: "#12151a"
        }
        Rectangle {
            anchors.fill: parent
            radius: Theme.itemRadius + 4
            color: zone.containsDrag ? Theme.accentStrong : Qt.rgba(0.70, 0.78, 0.90, 0.06)
            border.width: 1
            border.color: zone.containsDrag ? Theme.accent : Qt.rgba(0.70, 0.78, 0.90, 0.22)
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

            Column {
                anchors.centerIn: parent
                width: parent.width - 24
                spacing: 5
                scale: zone.containsDrag ? 1.04 : 1
                Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Theme.ease } }
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: zone.glyph
                       font.family: Theme.iconFont; font.pixelSize: 20; color: Theme.accent }
                Text { anchors.horizontalCenter: parent.horizontalCenter; visible: zone.expanded
                       text: zone.label; font.family: Theme.font; font.pixelSize: Theme.fontSize
                       font.weight: Font.DemiBold; color: Theme.text }
                Text { width: parent.width; visible: zone.expanded; horizontalAlignment: Text.AlignHCenter
                       wrapMode: Text.Wrap
                       text: zone.hint; font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall + 1
                       color: Theme.textDim }
            }
        }
    }
}
