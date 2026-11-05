pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs

// Shelf state, shared by every screen's sidebar.
// Item: { id, path, name, mime, copied, added } persisted;
//       { missing, pending } runtime-only.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string dataDir: home + "/.local/share/sessionbar"
    readonly property string dataFile: dataDir + "/shelf.json"
    readonly property string copyDir: home + "/.cache/shelf"

    // Replace the array (never mutate in place) so bindings/ListView update.
    property var items: []
    property var selected: ({})          // id -> true
    readonly property int selectedCount: Object.keys(selected).length
    property bool draggingOut: false     // keeps the bar open during drag-out
    property bool ready: false

    signal notify(string message, bool isError)

    // ---- persistence -------------------------------------------------------

    FileView {
        id: file
        path: root.dataFile
        atomicWrites: true    // write to temp + rename, never a half-written file
        printErrors: false
        onLoaded: root._parse(text())
        onLoadFailed: root.ready = true   // first run: no file yet
    }

    Component.onCompleted: Jobs.run(["mkdir", "-p", dataDir, copyDir], () => file.reload())

    function _parse(text) {
        try {
            const doc = JSON.parse(text);
            items = (doc.items || []).map(it => Object.assign({ missing: false, pending: false }, it));
        } catch (e) {
            console.warn("shelf: bad", dataFile, e);
            items = [];
        }
        ready = true;
        refreshMissing();
        _detectMime(items.filter(it => !it.mime));
    }

    function _save() {
        const clean = items.filter(it => !it.pending).map(it => ({
            id: it.id, path: it.path, name: it.name, mime: it.mime || "", copied: !!it.copied, added: it.added
        }));
        file.setText(JSON.stringify({ version: 1, items: clean }, null, 2));
    }

    function _update(id, patch) {
        items = items.map(it => it.id === id ? Object.assign({}, it, patch) : it);
    }

    // ---- url <-> path ------------------------------------------------------

    function urlToPath(u) {
        const s = String(u);
        if (!s.startsWith("file://")) return "";
        return decodeURIComponent(s.slice(7).replace(/^[^/]*/, ""));   // strip optional host
    }

    function pathToUrl(p) {
        // encodeURIComponent per segment: keeps '/' but escapes #, ?, spaces, quotes.
        return "file://" + p.split("/").map(encodeURIComponent).join("/").replace(/'/g, "%27");
    }

    function basename(p) {
        const parts = p.replace(/\/+$/, "").split("/");
        return parts[parts.length - 1] || p;
    }

    // ---- add / remove ------------------------------------------------------

    function addUrls(urls, copy) {
        const paths = [];
        for (const u of urls) {
            const p = urlToPath(u);
            if (p) paths.push(p);
        }
        if (!paths.length) {
            notify("Only local files can be shelved", true);
            return;
        }
        const added = [];
        for (const p of paths) {
            // Reference mode: don't add the same file twice.
            if (!copy && items.some(it => !it.copied && it.path === p)) continue;
            const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
            const name = basename(p);
            const it = { id, name, mime: "", copied: copy, added: Date.now(), missing: false, pending: copy,
                         path: copy ? `${copyDir}/${id}/${name}` : p, source: p };
            added.push(it);
        }
        items = added.concat(items);   // newest on top
        for (const it of added) {
            if (it.copied) _copy(it);
        }
        if (added.some(it => !it.copied)) _save();
        _detectMime(added.filter(it => !it.copied));
    }

    function _copy(it) {
        // Each copy gets its own dir so identical filenames never collide.
        Jobs.run(["sh", "-c", 'mkdir -p "$1" && cp -r --reflink=auto -- "$2" "$1/"', "sh",
                  `${copyDir}/${it.id}`, it.source], (code, out, err) => {
            if (code === 0) {
                _update(it.id, { pending: false });
                _save();
                _detectMime([it]);
            } else {
                items = items.filter(x => x.id !== it.id);
                Jobs.run(["rm", "-rf", "--", `${copyDir}/${it.id}`]);
                notify(`Copy failed: ${err.trim() || it.name}`, true);
            }
        });
    }

    function remove(ids) {
        const set = new Set(ids);
        for (const it of items) {
            // Only ever delete inside our own cache dir.
            if (set.has(it.id) && it.copied && it.path.startsWith(copyDir + "/" + it.id + "/"))
                Jobs.run(["rm", "-rf", "--", `${copyDir}/${it.id}`]);
        }
        items = items.filter(it => !set.has(it.id));
        const sel = Object.assign({}, selected);
        for (const id of ids) delete sel[id];
        selected = sel;
        _save();
    }

    function clearAll() {
        remove(items.map(it => it.id));
    }

    // ---- selection ---------------------------------------------------------

    function toggleSelected(id) {
        const sel = Object.assign({}, selected);
        if (sel[id]) delete sel[id]; else sel[id] = true;
        selected = sel;
    }

    function selectAll(on) {
        const sel = {};
        if (on) for (const it of items) if (!it.missing && !it.pending) sel[it.id] = true;
        selected = sel;
    }

    // Items a drag starting on `it` should carry: the selection if `it` is in it.
    function dragSet(it) {
        if (selected[it.id])
            return items.filter(x => selected[x.id] && !x.missing && !x.pending);
        return [it];
    }

    function uriList(list) {
        // text/uri-list wants CRLF-separated URIs.
        return list.map(it => pathToUrl(it.path)).join("\r\n") + "\r\n";
    }

    // ---- file actions ------------------------------------------------------

    function open(it) {
        Qt.openUrlExternally(pathToUrl(it.path));
    }

    function showInFolder(it) {
        // org.freedesktop.FileManager1 highlights the file (Thunar/Dolphin/Nautilus);
        // fall back to opening the parent directory.
        const uri = pathToUrl(it.path);
        Jobs.run(["gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1",
                  "--object-path", "/org/freedesktop/FileManager1",
                  "--method", "org.freedesktop.FileManager1.ShowItems", `['${uri}']`, ""], code => {
            if (code !== 0) Qt.openUrlExternally(pathToUrl(it.path.replace(/\/[^/]*$/, "") || "/"));
        });
    }

    // ---- background checks -------------------------------------------------

    function refreshMissing() {
        const list = items.filter(it => !it.pending);
        if (!list.length) return;
        Jobs.sh('for f do [ -e "$f" ] && echo 1 || echo 0; done', list.map(it => it.path), (code, out) => {
            const flags = out.split("\n");
            const missing = {};
            list.forEach((it, i) => missing[it.id] = flags[i] === "0");
            if (list.some(it => it.missing !== missing[it.id]))
                items = items.map(it => it.id in missing ? Object.assign({}, it, { missing: missing[it.id] }) : it);
        });
    }

    function _detectMime(list) {
        if (!list.length) return;
        Jobs.run(["file", "-b", "-L", "--mime-type", "--"].concat(list.map(it => it.path)), (code, out) => {
            const mimes = out.split("\n");
            const byId = {};
            list.forEach((it, i) => {
                const m = (mimes[i] || "").trim();
                if (m.includes("/")) byId[it.id] = m;
            });
            items = items.map(it => byId[it.id] ? Object.assign({}, it, { mime: byId[it.id] }) : it);
            _save();
        });
    }

    // Freedesktop icon name for a mime type, with a generic fallback.
    function iconFor(it) {
        const m = it.mime || "";
        if (m === "inode/directory") return "folder";
        const specific = m.replace("/", "-");
        if (specific && Quickshell.hasThemeIcon(specific)) return specific;
        const major = m.split("/")[0];
        const generic = { image: "image-x-generic", video: "video-x-generic", audio: "audio-x-generic",
                          text: "text-x-generic", font: "font-x-generic" }[major];
        return generic || "text-x-generic";
    }
}
