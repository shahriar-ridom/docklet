pragma Singleton

import QtQuick
import Quickshell
import qs

// Talks to the hyprsess CLI (always with --json) and holds the session list.
Singleton {
    id: root

    // Absolute path: Hyprland's PATH may not include ~/.local/bin on every setup.
    readonly property string bin: Quickshell.env("HOME") + "/.local/bin/hyprsess"

    property var sessions: []        // [{ name, created, apps, windows }], newest first
    property string busy: ""         // "" | "save" | "restore:<name>" | "delete:<name>"
    property real now: Date.now()    // ticks so "5m ago" stays fresh

    signal notify(string message, bool isError)

    Component.onCompleted: refresh()

    Timer {
        interval: 30000; running: true; repeat: true
        onTriggered: root.now = Date.now()
    }

    function _call(args, onOk) {
        Jobs.run([bin, "--json"].concat(args), (code, out, err) => {
            let res = null;
            try { res = JSON.parse(out); } catch (e) {}
            if (res === null) {
                // Binary missing or crashed: no JSON at all.
                notify(err.trim() || `hyprsess exited with ${code}`, true);
                busy = "";
                return;
            }
            if (res.ok === false && res.error) {
                notify(res.error, true);
                busy = "";
                return;
            }
            onOk(res);
            busy = "";
        });
    }

    function refresh() {
        Jobs.run([bin, "--json", "list"], (code, out) => {
            try { sessions = JSON.parse(out); } catch (e) {
                if (code === 127) notify(`hyprsess not found at ${bin} — run ./install.sh`, true);
            }
            now = Date.now();
        });
    }

    function exists(name) {
        return sessions.some(s => s.name === name);
    }

    function save(name) {
        busy = "save";
        _call(["save", name || "last"], res => {
            const warn = (res.warnings || []).length ? ` (${res.warnings.length} skipped)` : "";
            notify(`Saved “${res.name}”: ${res.windows} windows${warn}`, false);
            refresh();
        });
    }

    function restore(name) {
        busy = "restore:" + name;
        _call(["restore", name], res => {
            const r = res.report;
            let msg = `Restored ${r.launched.length} app${r.launched.length === 1 ? "" : "s"}`;
            if (r.skipped.length) msg += ` · ${r.skipped.length} already open`;
            if (r.unplaced) msg += ` · ${r.unplaced} window${r.unplaced === 1 ? "" : "s"} didn't appear`;
            if (r.errors.length) msg += `\n${r.errors[0]}`;
            notify(msg, r.errors.length > 0);
        });
    }

    function remove(name) {
        busy = "delete:" + name;
        _call(["delete", name], () => {
            sessions = sessions.filter(s => s.name !== name);   // instant feedback
            refresh();
        });
    }

    // "just now", "5m ago", "3h ago", then a date.
    function ago(created) {
        const s = Math.max(0, (now / 1000) - created);
        if (s < 60) return "just now";
        if (s < 3600) return `${Math.floor(s / 60)}m ago`;
        if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
        return Qt.formatDateTime(new Date(created * 1000), "MMM d, HH:mm");
    }
}
