//@ pragma IconTheme Papirus-Dark
// ^ Quickshell pragma: which icon theme Quickshell.iconPath() resolves against.

import QtQuick
import Quickshell

// Run with: qs -c sessionbar   (config symlinked to ~/.config/quickshell/sessionbar)
ShellRoot {
    // One sidebar per monitor; `modelData` is the ShellScreen.
    Variants {
        model: Quickshell.screens
        Sidebar {}
    }
}
