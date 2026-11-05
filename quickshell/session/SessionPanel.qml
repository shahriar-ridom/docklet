import QtQuick
import QtQuick.Layouts
import qs
import qs.session

// Bottom section: save button (+ name prompt) and saved sessions list.
Item {
    id: panel

    property bool expanded: true
    property real maxHeight: 400
    readonly property bool prompting: prompt.visible

    implicitHeight: Math.min(maxHeight, header.height + (prompt.visible ? prompt.height + Theme.spacing : 0)
                             + (expanded ? Theme.spacing + list.contentHeight : 0))

    function openPrompt() {
        nameInput.text = "";
        prompt.visible = true;
        nameInput.forceActiveFocus();
    }
    function closePrompt() { prompt.visible = false; }
    function submit() {
        const name = nameInput.text.trim();
        prompt.visible = false;
        Hyprsess.save(name);
    }

    // ---- header ------------------------------------------------------------
    RowLayout {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 28
        spacing: 2

        Text {
            visible: panel.expanded
            Layout.leftMargin: 4
            text: "Sessions"
            color: Theme.textDim
            font.family: Theme.font; font.pixelSize: Theme.fontSize; font.weight: Font.DemiBold
        }
        Item { Layout.fillWidth: true }
        IconButton {
            // In the 64px state this is the only visible control, centered.
            Layout.alignment: Qt.AlignHCenter
            glyph: Hyprsess.busy === "save" ? "" : ""   // spinner / floppy
            tip: "Save session"
            onClicked: if (!Hyprsess.busy) panel.openPrompt()
        }
        Item { Layout.fillWidth: true; visible: !panel.expanded }
    }

    // ---- save prompt -------------------------------------------------------
    Rectangle {
        id: prompt
        visible: false
        anchors { top: header.bottom; topMargin: Theme.spacing; left: parent.left; right: parent.right }
        height: 36
        radius: Theme.itemRadius
        color: Theme.surface
        border.color: Theme.accent
        border.width: 1

        TextInput {
            id: nameInput
            anchors { left: parent.left; right: okBtn.left; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 4 }
            color: Theme.text
            selectionColor: Theme.accentStrong
            font.family: Theme.font; font.pixelSize: Theme.fontSize
            clip: true
            // Same rule as the CLI: letters, digits, - _ . (max 64).
            validator: RegularExpressionValidator { regularExpression: /[A-Za-z0-9_\-][A-Za-z0-9._\-]{0,63}/ }
            Keys.onReturnPressed: panel.submit()
            Keys.onEnterPressed: panel.submit()
            Keys.onEscapePressed: panel.closePrompt()

            Text {
                // Placeholder / overwrite hint.
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                visible: !nameInput.text || Hyprsess.exists(nameInput.text.trim())
                text: !nameInput.text ? "name (empty = last)" : "will overwrite"
                color: !nameInput.text ? Theme.textDim : Theme.danger
                horizontalAlignment: !nameInput.text ? Text.AlignLeft : Text.AlignRight
                font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall
            }
        }
        IconButton {
            id: okBtn
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 4 }
            glyph: ""
            tip: "Save"
            onClicked: panel.submit()
        }
    }

    // ---- sessions list -----------------------------------------------------
    ListView {
        id: list
        visible: panel.expanded
        anchors { top: prompt.visible ? prompt.bottom : header.bottom; topMargin: Theme.spacing
                  left: parent.left; right: parent.right; bottom: parent.bottom }
        clip: true
        spacing: Theme.spacing
        boundsBehavior: Flickable.StopAtBounds
        model: Hyprsess.sessions

        delegate: SessionRow { width: list.width }
    }

    component SessionRow: Rectangle {
        id: row
        required property var modelData
        readonly property var s: modelData
        readonly property bool restoring: Hyprsess.busy === "restore:" + s.name
        property bool armed: false   // two-step delete

        height: 42
        radius: Theme.itemRadius
        color: rowHover.hovered ? Theme.surfaceHover : Theme.surface
        HoverHandler { id: rowHover }

        ColumnLayout {
            anchors { left: parent.left; right: actions.left; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 4 }
            spacing: 0
            RowLayout {
                spacing: 6
                Text {
                    Layout.fillWidth: true
                    text: row.s.name
                    elide: Text.ElideRight
                    color: Theme.text
                    font.family: Theme.font; font.pixelSize: Theme.fontSize; font.weight: Font.Medium
                }
                Rectangle {
                    visible: row.s.name === "autosave"
                    implicitWidth: autoTag.implicitWidth + 8; implicitHeight: 14; radius: 7
                    color: Theme.accentSoft
                    Text { id: autoTag; anchors.centerIn: parent; text: "auto"; color: Theme.accent
                           font.family: Theme.font; font.pixelSize: 8 }
                }
            }
            Text {
                Layout.fillWidth: true
                text: row.restoring ? "restoring…"
                    : `${Hyprsess.ago(row.s.created)} · ${row.s.windows} window${row.s.windows === 1 ? "" : "s"}`
                elide: Text.ElideRight
                color: row.restoring ? Theme.accent : Theme.textDim
                font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall
            }
        }

        Row {
            id: actions
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 6 }
            spacing: 2
            // Only show actions on hover (or while armed/busy) to keep it calm.
            opacity: rowHover.hovered || row.armed || row.restoring ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 100 } }

            IconButton {
                glyph: row.restoring ? "" : ""   // spinner / play
                tip: "Restore"
                onClicked: if (!Hyprsess.busy) Hyprsess.restore(row.s.name)
            }
            IconButton {
                glyph: row.armed ? "" : ""       // confirm / trash
                danger: row.armed
                tip: row.armed ? "Click again to delete" : "Delete"
                onClicked: {
                    if (Hyprsess.busy) return;
                    if (row.armed) { row.armed = false; Hyprsess.remove(row.s.name); }
                    else { row.armed = true; disarm.restart(); }
                }
            }
        }
        Timer { id: disarm; interval: 2500; onTriggered: row.armed = false }
    }
}
