import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs
import qs.session

// Bottom section: save button (+ name prompt) and saved sessions list.
Item {
    id: panel

    property bool expanded: true
    property real maxHeight: 400
    readonly property bool prompting: prompt.visible

    readonly property real listHeight: Hyprsess.sessions.length ? list.contentHeight : emptyState.implicitHeight
    implicitHeight: Math.min(maxHeight, headerRow.height + (prompt.visible ? prompt.height + 8 : 0)
                             + (expanded ? 6 + listHeight : 0))

    // Save just the focused desktop (default) or every desktop.
    property bool allDesktops: false
    // Empty name → "desktop-<ws>" for a one-desktop save, "last" for all.
    readonly property string defaultName: !allDesktops && Hyprsess.desktop
        ? "desktop-" + Hyprsess.desktop.replace(/[^A-Za-z0-9._\-]/g, "-") : "last"
    readonly property string effectiveName: nameInput.text.trim() || defaultName

    function openPrompt() {
        nameInput.text = "";
        allDesktops = false;
        Hyprsess.refreshDesktop();
        prompt.visible = true;
        nameInput.forceActiveFocus();
    }
    function closePrompt() { prompt.visible = false; }
    function submit() {
        const name = effectiveName;
        prompt.visible = false;
        Hyprsess.save(name, allDesktops ? "" : Hyprsess.desktop);
    }

    // ---- header ------------------------------------------------------------
    RowLayout {
        id: headerRow
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 26
        spacing: 2

        Text {
            visible: panel.expanded
            Layout.leftMargin: 6
            text: "Sessions"
            color: Theme.text
            font.family: Theme.fontDisplay; font.pixelSize: Theme.fontSizeTitle; font.weight: Font.DemiBold
        }
        Item { Layout.fillWidth: true }
        IconButton {
            // In the narrow state this is the only control, centered.
            Layout.alignment: Qt.AlignHCenter
            glyph: Hyprsess.busy === "save" ? "\uf110" : !panel.expanded ? "\uf0c7"
                 : prompt.visible ? "\uf00d" : "\uf067"          // spinner / floppy / close / plus
            spinning: Hyprsess.busy === "save"
            label: panel.expanded ? (prompt.visible ? "Cancel" : "Save") : ""
            primary: panel.expanded && !prompt.visible
            tip: "Save session"
            onClicked: if (!Hyprsess.busy) (prompt.visible ? panel.closePrompt() : panel.openPrompt())
        }
        Item { Layout.fillWidth: true; visible: !panel.expanded }
    }

    // ---- save prompt -------------------------------------------------------
    Item {
        id: prompt
        visible: false
        anchors { top: headerRow.bottom; topMargin: 8; left: parent.left; right: parent.right }
        height: field.height + 6 + scopeRow.height

        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }

        Rectangle {
            id: field
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 36
            radius: Theme.itemRadius
            color: Theme.field
            border.width: 1
            border.color: nameInput.activeFocus ? Qt.rgba(0.70, 0.78, 0.90, 0.55) : "transparent"
            Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

            TextInput {
                id: nameInput
                anchors { left: parent.left; right: okBtn.left; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 6 }
                color: Theme.text
                selectionColor: Theme.accentStrong
                selectedTextColor: Theme.text
                font.family: Theme.font; font.pixelSize: Theme.fontSize
                clip: true
                // Same rule as the CLI: letters, digits, - _ . (max 64).
                validator: RegularExpressionValidator { regularExpression: /[A-Za-z0-9_\-][A-Za-z0-9._\-]{0,63}/ }
                Keys.onReturnPressed: panel.submit()
                Keys.onEnterPressed: panel.submit()
                Keys.onEscapePressed: panel.closePrompt()
                Keys.onTabPressed: panel.allDesktops = !panel.allDesktops

                Text {
                    // Placeholder, or an overwrite warning once the name is taken.
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: !nameInput.text || Hyprsess.exists(panel.effectiveName)
                    text: !nameInput.text ? panel.defaultName : "Replaces saved"
                    color: !nameInput.text ? Theme.textFaint : Theme.danger
                    horizontalAlignment: !nameInput.text ? Text.AlignLeft : Text.AlignRight
                    font.family: Theme.font
                    font.pixelSize: !nameInput.text ? Theme.fontSize : Theme.fontSizeSmall
                }
            }
            IconButton {
                id: okBtn
                anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 5 }
                glyph: ""
                primary: true
                tip: "Save"
                onClicked: panel.submit()
            }
        }

        // Scope toggle (Tab in the name field also flips it).
        Rectangle {
            id: scopeRow
            anchors { top: field.bottom; topMargin: 6; left: parent.left; right: parent.right }
            height: 28
            radius: Theme.itemRadius
            color: Theme.field

            // Sliding thumb under the active option.
            Rectangle {
                x: 3 + (panel.allDesktops ? (scopeRow.width - 6) / 2 : 0)
                y: 3
                width: (scopeRow.width - 6) / 2
                height: scopeRow.height - 6
                radius: Theme.itemRadius - 3
                color: Theme.accentSoft
                Behavior on x { NumberAnimation { duration: Theme.animMs; easing.type: Theme.ease } }
            }

            Row {
                anchors.fill: parent
                anchors.margins: 3
                Repeater {
                    model: [
                        { all: false, label: Hyprsess.desktop ? `Desktop ${Hyprsess.desktop}` : "This desktop" },
                        { all: true, label: "All desktops" }
                    ]
                    delegate: Item {
                        required property var modelData
                        readonly property bool active: panel.allDesktops === modelData.all
                        width: (scopeRow.width - 6) / 2
                        height: parent.height
                        Text {
                            anchors.centerIn: parent
                            width: parent.width - 8
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            text: modelData.label
                            color: active ? Theme.accent : (segMa.containsMouse ? Theme.text : Theme.textDim)
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                            font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall + 1
                            font.weight: active ? Font.Medium : Font.Normal
                        }
                        MouseArea {
                            id: segMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { panel.allDesktops = modelData.all; nameInput.forceActiveFocus(); }
                        }
                    }
                }
            }
        }
    }

    // ---- sessions list -----------------------------------------------------
    ListView {
        id: list
        visible: panel.expanded
        anchors { top: prompt.visible ? prompt.bottom : headerRow.bottom; topMargin: 6
                  left: parent.left; right: parent.right; bottom: parent.bottom }
        clip: true
        spacing: Theme.spacing
        boundsBehavior: Flickable.StopAtBounds
        model: Hyprsess.sessions

        delegate: SessionRow { width: list.width }
    }

    Column {
        id: emptyState
        visible: panel.expanded && Hyprsess.sessions.length === 0
        anchors { top: list.top; left: parent.left; right: parent.right; leftMargin: 6; rightMargin: 6 }
        topPadding: 4
        bottomPadding: 6
        spacing: 3
        Text {
            text: "Nothing saved yet"
            color: Theme.textDim
            font.family: Theme.font; font.pixelSize: Theme.fontSize; font.weight: Font.Medium
        }
        Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: "Save your open windows to bring them back later."
            color: Theme.textFaint
            font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall + 1
        }
    }

    // App icon for a window class: its .desktop entry's icon, else a themed
    // icon named after the class, else "" (the caller draws an initial).
    function iconFor(cls) {
        const e = DesktopEntries.heuristicLookup(cls);
        const p = e && e.icon ? Quickshell.iconPath(e.icon, true) : "";
        return p || Quickshell.iconPath(cls.toLowerCase(), true) || "";
    }

    component SessionRow: Rectangle {
        id: row
        required property var modelData
        readonly property var s: modelData
        readonly property bool restoring: Hyprsess.busy === "restore:" + s.name
        readonly property bool active: rowHover.hovered || armed || restoring
        property bool armed: false   // two-step delete

        height: 46
        radius: Theme.itemRadius
        color: rowHover.hovered ? Theme.surfaceHover : Theme.surface
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        HoverHandler { id: rowHover }

        // Double-clicking the row restores, like the play button.
        TapHandler {
            onDoubleTapped: if (!Hyprsess.busy) Hyprsess.restore(row.s.name)
        }

        ColumnLayout {
            anchors { left: parent.left; right: tail.left; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 8 }
            spacing: 2
            Text {
                Layout.fillWidth: true
                text: row.s.name
                elide: Text.ElideRight
                color: Theme.text
                font.family: Theme.font; font.pixelSize: Theme.fontSize; font.weight: Font.Medium
            }
            Text {
                Layout.fillWidth: true
                text: row.restoring ? "Restoring…"
                    : row.armed ? "Click again to delete"
                    : (row.s.name === "autosave" ? "Autosaved " : "") + Hyprsess.ago(row.s.created)
                      + (row.s.scope ? `, desktop ${row.s.scope}` : "")
                elide: Text.ElideRight
                color: row.restoring ? Theme.accent : row.armed ? Theme.danger : Theme.textFaint
                font.family: Theme.font; font.pixelSize: Theme.fontSizeSmall
            }
        }

        // Right side: the apps this session brings back; swapped for actions on hover.
        Item {
            id: tail
            anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
            width: Math.max(stack.width, actions.width)
            height: 26

            AppStack {
                id: stack
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                classes: row.s.classes || []
                opacity: row.active ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
            }

            Row {
                id: actions
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 2
                opacity: row.active ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }

                IconButton {
                    glyph: row.armed ? "" : ""       // confirm / trash
                    danger: true
                    tip: row.armed ? "Click again to delete" : "Delete"
                    onClicked: {
                        if (Hyprsess.busy) return;
                        if (row.armed) { row.armed = false; Hyprsess.remove(row.s.name); }
                        else { row.armed = true; disarm.restart(); }
                    }
                }
                IconButton {
                    glyph: row.restoring ? "" : ""   // spinner / play
                    spinning: row.restoring
                    primary: true
                    tip: "Restore"
                    onClicked: if (!Hyprsess.busy) Hyprsess.restore(row.s.name)
                }
            }
        }
        Timer { id: disarm; interval: 2500; onTriggered: row.armed = false }
    }

    // Overlapping app icons, at most four, then "+N".
    component AppStack: Row {
        id: stackRoot
        property var classes: []
        readonly property int shown: Math.min(classes.length, classes.length > 4 ? 3 : 4)
        spacing: -5
        layoutDirection: Qt.LeftToRight

        Repeater {
            model: stackRoot.classes.slice(0, stackRoot.shown)
            delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property string src: panel.iconFor(modelData)
                z: 10 - index                       // first app on top
                width: 24; height: 24; radius: 12
                color: "#14171c"                    // ring in the panel colour separates overlaps
                IconImage {
                    anchors.centerIn: parent
                    implicitSize: 19
                    visible: !!parent.src
                    source: parent.src
                    asynchronous: true
                }
                Rectangle {
                    visible: !parent.src
                    anchors.centerIn: parent
                    width: 19; height: 19; radius: 9.5
                    color: Qt.rgba(0.70, 0.78, 0.90, 0.18)
                    Text {
                        anchors.centerIn: parent
                        text: (parent.parent.modelData || "?").charAt(0).toUpperCase()
                        color: Theme.accent
                        font.family: Theme.font; font.pixelSize: 9; font.weight: Font.DemiBold
                    }
                }
            }
        }
        Rectangle {
            visible: stackRoot.classes.length > stackRoot.shown
            z: 0
            width: more.implicitWidth + 14; height: 24; radius: 12
            color: "#14171c"
            Rectangle {
                anchors { fill: parent; margins: 2 }
                radius: height / 2
                color: Theme.field
            }
            Text {
                id: more
                anchors.centerIn: parent
                text: "+" + (stackRoot.classes.length - stackRoot.shown)
                color: Theme.textDim
                font.family: Theme.font; font.pixelSize: 9; font.weight: Font.Medium
            }
        }
    }
}
