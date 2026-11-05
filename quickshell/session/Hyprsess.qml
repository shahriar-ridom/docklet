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
    property string desktop: ""      // focused workspace name, refreshed when the prompt opens

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
                if (code === 127) notify(`hyprsess not found at ${bin} — re-run the Docklet installer`, true);
            }
            now = Date.now();
        });
    }

    function refreshDesktop() {
        Jobs.run(["hyprctl", "-j", "activeworkspace"], (code, out) => {
            try { desktop = JSON.parse(out).name || ""; } catch (e) { desktop = ""; }
        });
    }

    function exists(name) {
        return sessions.some(s => s.name === name);
    }

    // `ws` = workspace name to limit the save to, or "" for all desktops.
    function save(name, ws) {
        busy = "save";
        const args = ["save", name || "last"];
        if (ws) args.push("--workspace", ws);
        _call(args, res => {
            const warn = (res.warnings || []).length ? ` (${res.warnings.length} skipped)` : "";
            const where = res.scope ? ` from desktop ${res.scope}` : "";
            notify(`Saved “${res.name}”: ${res.windows} windows${where}${warn}`, false);
            refresh();
        });
    }

    function restore(name) {
        busy = "restore:" + name;
        _call(["restore", name], res => {
            const r = res.report;
            let msg = `Restored ${r.launched.length} app${r.launched.length === 1 ? "" : "s"}`;
            const bg = r.background || 0;
            if (bg) msg += ` · ${bg} left in background`;
            if (r.skipped.length > bg) msg += ` · ${r.skipped.length - bg} already open`;
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

    // "just now", "4 min ago", "2 h ago", "yesterday, 19:04", then a date.
    function ago(created) {
        const s = Math.max(0, (now / 1000) - created);
        const d = new Date(created * 1000);
        if (s < 60) return "just now";
        if (s < 3600) return `${Math.floor(s / 60)} min ago`;
        if (s < 6 * 3600) return `${Math.floor(s / 3600)} h ago`;
        const today = new Date(now); today.setHours(0, 0, 0, 0);
        if (d >= today) return "today, " + Qt.formatDateTime(d, "HH:mm");
        if (d >= today - 86400000) return "yesterday, " + Qt.formatDateTime(d, "HH:mm");
        return Qt.formatDateTime(d, "MMM d, HH:mm");
    }
}
