import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs
import qs.shelf

// One shelf entry. Click toggles selection, double-click opens, right-click
// asks the parent for a context menu, dragging hands the file(s) to other apps.
Item {
    id: root

    required property var modelData
    property bool expanded: true
    readonly property var item: modelData
    readonly property bool selected: !!ShelfStore.selected[item.id]
    readonly property bool usable: !item.missing && !item.pending
    readonly property bool isLink: item.kind === "link"
    readonly property bool isImage: (item.mime || "").startsWith("image/") && usable && !isLink
    // Picture shown in the thumbnail slot: the image itself, or a link's favicon.
    readonly property string picture: isImage ? ShelfStore.pathToUrl(item.path)
                                    : isLink && item.icon ? ShelfStore.pathToUrl(item.icon) : ""

    // Live download progress (see ShelfStore.progress), or null.
    readonly property var prog: item.pending ? (ShelfStore.progress[item.id] || null) : null
    readonly property bool indeterminate: !prog || prog.progress === null || prog.stage !== "downloading"

    signal contextMenu(var item, real x, real y)

    function bytes(n) {
        if (n < 1024 * 1024) return `${Math.max(1, Math.round(n / 1024))} KB`;
        if (n < 1024 * 1024 * 1024) { const m = n / 1048576; return `${m < 10 ? m.toFixed(1) : Math.round(m)} MB`; }
        return `${(n / 1073741824).toFixed(1)} GB`;
    }

    function status() {
        const p = prog;
        if (!p) return item.from ? "Starting download…" : "Copying…";
        if (p.stage === "preparing") return "Finding the video…";
        if (p.stage === "finishing") return "Finishing…";
        if (p.progress === null) return p.done ? `${bytes(p.done)} so far` : "Downloading…";
        const pct = `${Math.floor(p.progress * 100)}%`;
        return p.total ? `${pct}, ${bytes(p.done)} of ${bytes(p.total)}` : pct;
    }

    implicitHeight: Theme.itemHeight

    // "PNG image", "PDF document", "Folder"… instead of a raw mime type.
    function kind(it) {
        if (it.kind === "link") return ShelfStore._hostOf(it.url) || "Link";
        const m = it.mime || "";
        const ext = (it.name.includes(".") ? it.name.split(".").pop() : "").toUpperCase();
        if (m === "inode/directory") return "Folder";
        if (m === "application/pdf") return "PDF document";
        if (m.startsWith("image/")) return (ext || "Image") + " image";
        if (m.startsWith("video/")) return (ext || "Video") + " video";
        if (m.startsWith("audio/")) return (ext || "Audio") + " audio";
        if (/zip|tar|compressed|x-7z|rar/.test(m)) return (ext || "Archive") + " archive";
        if (m.startsWith("text/")) return ext ? ext + " text" : "Text";
        return ext ? ext + " file" : "File";
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.itemRadius
        color: root.selected ? (mouse.containsMouse ? Theme.accentStrong : Theme.accentSoft)
             : mouse.pressed ? Theme.surfacePressed
             : mouse.containsMouse ? Theme.surfaceHover : Theme.surface
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: (Theme.collapsedWidth - 2 * Theme.padding - Theme.thumbSize) / 2
        anchors.rightMargin: Theme.padding
        spacing: 11

        // Thumbnail: real preview for images, theme mime icon otherwise.
        Item {
            id: thumb
            Layout.preferredWidth: Theme.thumbSize
            Layout.preferredHeight: Theme.thumbSize
            opacity: root.usable ? 1 : 0.4

            // Favicons sit on a light tile, like a browser tab chip: many are
            // dark-on-transparent and would vanish on the panel otherwise.
            Rectangle {
                anchors.fill: parent
                radius: 7
                visible: root.isLink
                color: !!root.picture && favicon.status === Image.Ready ? "#e8e9ec" : Theme.field
            }
            ClippingRectangle {
                anchors.centerIn: parent
                width: root.isLink ? 18 : parent.width
                height: width
                radius: root.isLink ? 4 : 7
                color: "transparent"
                visible: !!root.picture && favicon.status !== Image.Error
                Image {
                    id: favicon
                    anchors.fill: parent
                    source: root.picture
                    sourceSize: Qt.size(Theme.thumbSize * 2, Theme.thumbSize * 2)  // decode small
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                }
            }
            IconImage {
                anchors.centerIn: parent
                implicitSize: root.isLink ? 20 : Theme.thumbSize
                visible: !root.picture || favicon.status === Image.Error
                source: Quickshell.iconPath(ShelfStore.iconFor(root.item), "text-x-generic")
                asynchronous: true
            }
            // Small corner badge: copy (in cache) vs reference. The ring in the
            // panel colour separates it from the thumbnail.
            Rectangle {
                visible: root.item.copied
                width: 13; height: 13; radius: 6.5
                anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.margins: -3
                color: Theme.accent
                border.width: 2
                border.color: "#14171c"
                Text {
                    anchors.centerIn: parent
                    text: ""   // nf-fa-copy
                    font.family: Theme.iconFont; font.pixelSize: 7
                    color: "#121315"
                }
            }
            // Spinner-ish dot while copying.
            Rectangle {
                visible: root.item.pending
                anchors.centerIn: parent
                width: 10; height: 10; radius: 5
                color: Theme.accent
                SequentialAnimation on opacity {
                    running: root.item.pending; loops: Animation.Infinite
                    NumberAnimation { to: 0.2; duration: 400 }
                    NumberAnimation { to: 1; duration: 400 }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1
            visible: root.expanded
            opacity: root.expanded ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.animMs; easing.type: Theme.ease } }

            Text {
                Layout.fillWidth: true
                text: root.item.name
                elide: Text.ElideMiddle
                color: root.item.missing ? Theme.textDim : Theme.text
                font.family: Theme.font; font.pixelSize: Theme.fontSize
                font.strikeout: root.item.missing
            }
            Text {
                Layout.fillWidth: true
                // Leave room for the cancel button while a download is hovered.
                Layout.rightMargin: root.item.pending && rowHover.hovered ? 26 : 0
                text: root.item.missing ? "Original was moved or deleted"
                    : root.item.pending ? root.status()
                    : root.kind(root.item) + (root.item.copied ? ", copied" : "")
                elide: Text.ElideRight
                color: root.item.missing ? Theme.danger : root.item.pending ? Theme.textDim : Theme.textFaint
                font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall
                font.features: { "tnum": 1 }   // steady digits while the numbers tick
            }

            // Download progress: a thin track with an accent fill. Before the
            // size is known (or while merging) a short segment sweeps instead.
            Rectangle {
                id: track
                visible: !!root.item.from && root.item.pending
                Layout.fillWidth: true
                Layout.topMargin: 3
                implicitHeight: 3
                radius: 1.5
                color: Theme.field
                clip: true

                Rectangle {
                    visible: !root.indeterminate
                    height: parent.height
                    radius: parent.radius
                    width: root.prog && root.prog.progress !== null ? Math.max(height, parent.width * root.prog.progress) : 0
                    color: Theme.accent
                    Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                }
                Rectangle {
                    id: sweep
                    visible: root.indeterminate && track.visible
                    height: parent.height
                    radius: parent.radius
                    width: parent.width * 0.3
                    color: Theme.accent
                    opacity: 0.8
                    NumberAnimation on x {
                        running: sweep.visible
                        loops: Animation.Infinite
                        from: -sweep.width; to: track.width
                        duration: 1100
                        easing.type: Easing.InOutSine
                    }
                }
            }
        }
    }

    HoverHandler { id: rowHover }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: ev => {
            if (ev.button === Qt.RightButton)
                root.contextMenu(root.item, ev.x, ev.y);
            else if (root.usable)
                ShelfStore.toggleSelected(root.item.id);
        }
        onDoubleClicked: ev => {
            if (ev.button !== Qt.LeftButton || !root.usable) return;
            ShelfStore.toggleSelected(root.item.id);   // undo the first click's toggle
            ShelfStore.open(root.item);
        }
    }

    // Cancel a download in progress (same as removing the item).
    IconButton {
        z: 2
        visible: root.item.pending && rowHover.hovered && root.expanded
        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
        glyph: "\uf00d"
        danger: true
        tip: "Cancel"
        onClicked: ShelfStore.remove([root.item.id])
    }

    // ---- drag out ----------------------------------------------------------
    // Drag.Automatic hands the drag to the OS (Wayland data-device), so the
    // drop target can be any app. A DragHandler with target:null just detects
    // the gesture; the invisible proxy carries the mime data.
    DragHandler {
        id: dragHandler
        target: null
        enabled: root.usable
        dragThreshold: 6
    }

    Item {
        id: dragProxy
        anchors.fill: parent

        Drag.active: dragHandler.active
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: Qt.CopyAction | Qt.LinkAction
        Drag.proposedAction: Qt.CopyAction
        Drag.mimeData: ShelfStore.dragMime(ShelfStore.dragSet(root.item))
        Drag.imageSource: root.picture || Quickshell.iconPath(ShelfStore.iconFor(root.item), "text-x-generic")
        Drag.imageSourceSize: Qt.size(48, 48)   // keep the drag ghost small
        Drag.hotSpot.x: 16
        Drag.hotSpot.y: 16

        Drag.onDragStarted: ShelfStore.draggingOut = true
        Drag.onDragFinished: ShelfStore.draggingOut = false
    }
}
