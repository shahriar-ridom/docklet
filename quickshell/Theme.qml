pragma Singleton

import QtQuick
import Quickshell

// All colors, sizes and timings live here. The accent is Noctalia's primary
// (#b3c8e5) so the bar sits with the rest of the desktop.
Singleton {
    // --- Palette -----------------------------------------------------------
    // Graphite glass, a hair cooler than neutral so it reads with the steel accent.
    readonly property color bg: Qt.rgba(0.055, 0.063, 0.078, 0.92)       // #0e1014 @ 92%
    readonly property color border: Qt.rgba(1, 1, 1, 0.07)
    readonly property color sheen: Qt.rgba(1, 1, 1, 0.035)                // 1px top highlight
    // Rows have no fill at rest; these only appear on interaction.
    readonly property color surface: "transparent"
    readonly property color surfaceHover: Qt.rgba(1, 1, 1, 0.055)
    readonly property color surfacePressed: Qt.rgba(1, 1, 1, 0.09)
    readonly property color field: Qt.rgba(1, 1, 1, 0.06)                 // text inputs, segmented control

    readonly property color text: "#e8e9ec"
    readonly property color textDim: "#8a909c"
    readonly property color textFaint: "#5b616c"

    readonly property color accent: "#b3c8e5"
    readonly property color accentSoft: Qt.rgba(0.70, 0.78, 0.90, 0.16)
    readonly property color accentStrong: Qt.rgba(0.70, 0.78, 0.90, 0.24)

    readonly property color danger: "#f0a39b"
    readonly property color dangerSoft: Qt.rgba(0.94, 0.64, 0.61, 0.14)
    readonly property color success: "#a8d5a2"

    // --- Type --------------------------------------------------------------
    readonly property string font: "SF Pro Text"
    readonly property string fontDisplay: "SF Pro Display"   // section titles only
    readonly property string iconFont: "CaskaydiaCove NF"    // Nerd Font glyphs for buttons
    readonly property int fontSizeTitle: 13
    readonly property int fontSize: 12
    readonly property int fontSizeSmall: 10
    readonly property int iconSize: 14

    // --- Geometry ----------------------------------------------------------
    readonly property int collapsedWidth: 60
    readonly property int expandedWidth: 284
    readonly property int stripWidth: 3       // invisible hover strip at the screen edge
    readonly property int edgeMargin: 8       // gap between panel and screen edges
    readonly property int radius: 20
    readonly property int itemRadius: 11
    readonly property int itemHeight: 44
    readonly property int thumbSize: 30
    readonly property int padding: 10
    readonly property int spacing: 2

    // --- Behaviour (ms) ----------------------------------------------------
    readonly property int revealDelay: 90     // hover the edge this long before sliding in
    readonly property int hideDelay: 380      // grace period after the pointer leaves
    readonly property int expandDelay: 240    // hover the bar this long to widen it
    readonly property int animMs: 160         // slide / widen
    readonly property int fastMs: 90          // hovers, fades
    readonly property int ease: Easing.OutQuint
}
