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
    readonly property bool isImage: (item.mime || "").startsWith("image/") && usable

    signal contextMenu(var item, real x, real y)

    implicitHeight: Theme.itemHeight

    Rectangle {
        anchors.fill: parent
        radius: Theme.itemRadius
        color: root.selected ? Theme.accentStrong
             : mouse.containsMouse ? Theme.surfaceHover : Theme.surface
        border.width: root.selected ? 1 : 0
        border.color: Theme.accent
        Behavior on color { ColorAnimation { duration: 100 } }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: (Theme.collapsedWidth - 2 * Theme.padding - Theme.thumbSize) / 2
        anchors.rightMargin: Theme.padding
        spacing: Theme.padding

        // Thumbnail: real preview for images, theme mime icon otherwise.
        Item {
            id: thumb
            Layout.preferredWidth: Theme.thumbSize
            Layout.preferredHeight: Theme.thumbSize
            opacity: root.usable ? 1 : 0.4

            ClippingRectangle {
                anchors.fill: parent
                radius: 6
                color: "transparent"
                visible: root.isImage
                Image {
                    anchors.fill: parent
                    source: root.isImage ? ShelfStore.pathToUrl(root.item.path) : ""
                    sourceSize: Qt.size(Theme.thumbSize * 2, Theme.thumbSize * 2)  // decode small
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                }
            }
            IconImage {
                anchors.fill: parent
                visible: !root.isImage
                source: Quickshell.iconPath(ShelfStore.iconFor(root.item), "text-x-generic")
                asynchronous: true
            }
            // Small corner badge: copy (in cache) vs reference.
            Rectangle {
                visible: root.item.copied
                width: 12; height: 12; radius: 6
                anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.margins: -3
                color: Theme.accent
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
            spacing: 0
            visible: root.expanded
            opacity: root.expanded ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.animMs } }

            Text {
                Layout.fillWidth: true
                text: root.item.name
                elide: Text.ElideMiddle
                color: root.item.missing ? Theme.danger : Theme.text
                font.family: Theme.font; font.pixelSize: Theme.fontSize
                font.strikeout: root.item.missing
            }
            Text {
                Layout.fillWidth: true
                text: root.item.missing ? "missing" : root.item.pending ? "copying…"
                    : (root.item.copied ? "copy · " : "") + (root.item.mime || "")
                elide: Text.ElideRight
                color: root.item.missing ? Theme.danger : Theme.textDim
                font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

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
        Drag.mimeData: ({ "text/uri-list": ShelfStore.uriList(ShelfStore.dragSet(root.item)) })
        Drag.imageSource: root.isImage ? ShelfStore.pathToUrl(root.item.path)
                                       : Quickshell.iconPath(ShelfStore.iconFor(root.item), "text-x-generic")
        Drag.imageSourceSize: Qt.size(48, 48)   // keep the drag ghost small
        Drag.hotSpot.x: 16
        Drag.hotSpot.y: 16

        Drag.onDragStarted: ShelfStore.draggingOut = true
        Drag.onDragFinished: ShelfStore.draggingOut = false
    }
}
