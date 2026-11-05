pragma Singleton

import QtQuick
import Quickshell

// All colors, sizes and timings live here. Palette matches your Noctalia theme
// (primary #b3c8e5, surface #121315, on_surface #e3e2e4).
Singleton {
    // --- Palette -----------------------------------------------------------
    readonly property color bg: Qt.rgba(0.071, 0.075, 0.082, 0.82)   // panel, translucent
    readonly property color surface: Qt.rgba(1, 1, 1, 0.045)         // item background
    readonly property color surfaceHover: Qt.rgba(1, 1, 1, 0.09)
    readonly property color border: Qt.rgba(1, 1, 1, 0.08)
    readonly property color text: "#e3e2e4"
    readonly property color textDim: "#8e9099"
    readonly property color accent: "#b3c8e5"
    readonly property color accentSoft: Qt.rgba(0.70, 0.78, 0.90, 0.16)
    readonly property color accentStrong: Qt.rgba(0.70, 0.78, 0.90, 0.32)
    readonly property color danger: "#ffb4ab"
    readonly property color dangerSoft: Qt.rgba(1.0, 0.70, 0.67, 0.14)
    readonly property color success: "#a8d5a2"

    // --- Fonts -------------------------------------------------------------
    readonly property string font: "SF Pro Text"
    readonly property string iconFont: "CaskaydiaCove NF"   // Nerd Font glyphs for buttons
    readonly property int fontSize: 11
    readonly property int fontSizeSmall: 9
    readonly property int iconSize: 15

    // --- Geometry ----------------------------------------------------------
    readonly property int collapsedWidth: 64
    readonly property int expandedWidth: 280
    readonly property int stripWidth: 3       // invisible hover strip at the screen edge
    readonly property int edgeMargin: 6       // gap between panel and screen edges
    readonly property int radius: 16
    readonly property int itemRadius: 10
    readonly property int itemHeight: 46
    readonly property int thumbSize: 32
    readonly property int padding: 8
    readonly property int spacing: 4

    // --- Behaviour (ms) ----------------------------------------------------
    readonly property int revealDelay: 120    // hover the edge this long before sliding in
    readonly property int hideDelay: 450      // grace period after the pointer leaves
    readonly property int expandDelay: 300    // hover the bar this long to widen it
    readonly property int animMs: 180
}
