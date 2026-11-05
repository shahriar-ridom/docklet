pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs

// Shelf state, shared by every screen's sidebar.
// Item: { id, path, name, mime, copied, added, kind, url, icon, from } persisted;
//       { missing, pending } runtime-only.
//   kind "file" (default): a local file; `copied` = it lives in copyDir/<id>/.
//   kind "link": a web address (`url`), opened in the browser; `icon` = favicon.
//   Downloads (images, videos, text snippets) are copied files with `from` = source URL.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string dataDir: home + "/.local/share/docklet"
    readonly property string dataFile: dataDir + "/shelf.json"
    readonly property string copyDir: home + "/.cache/shelf"
    readonly property string fetcher: Quickshell.shellDir + "/shelf/fetch.py"

    // One-shot file writers for bytes/text that arrive with a drop.
    property Component _writerComp: Component {
        FileView { blockLoading: true; printErrors: false; atomicWrites: true }
    }

    // Replace the array (never mutate in place) so bindings/ListView update.
    property var items: []
    property var selected: ({})          // id -> true
    readonly property int selectedCount: Object.keys(selected).length
    property bool draggingOut: false     // keeps the bar open during drag-out
    property var incoming: null          // inspect() of the drag hovering the bar
    // Live download progress, id -> { progress (0..1 or null), done, total, stage }.
    // Kept apart from `items` so updates don't rebuild the list.
    property var progress: ({})
    property var _jobs: ({})             // id -> running StreamJob (downloads)
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
        _sweepOrphans();
        refreshMissing();
        _detectMime(items.filter(it => !it.mime && it.kind !== "link"));
    }

    function _save() {
        const clean = items.filter(it => !it.pending).map(it => ({
            id: it.id, path: it.path, name: it.name, mime: it.mime || "", copied: !!it.copied, added: it.added,
            kind: it.kind || "file", url: it.url || "", icon: it.icon || "", from: it.from || ""
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
            if (!set.has(it.id)) continue;
            if (_jobs[it.id]) {
                // Still downloading: stop it. Its exit handler deletes the
                // folder once the process can no longer write into it.
                _jobs[it.id].running = false;
                _forget(it.id);
                continue;
            }
            // Only ever delete inside our own cache dir (copies, downloads, favicons).
            const own = it.kind === "link" || (it.copied && (it.path || "").startsWith(`${copyDir}/${it.id}/`));
            if (own) Jobs.run(["rm", "-rf", "--", `${copyDir}/${it.id}`]);
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


    // ---- drops from browsers and other apps ------------------------------
    // Browsers hand over a mix: text/uri-list (the link, or the image's own
    // URL), text/x-moz-url ("url\ntitle", Firefox), text/html (<a><img src>),
    // and often the image itself as image/png bytes.

    function _isWeb(u) { return /^https?:\/\//i.test(u || ""); }
    function _looksLikeImage(u) { return /\.(jpe?g|png|gif|webp|avif|bmp|svg)(\?|#|$)/i.test(u || ""); }
    function _imageFormat(fs) {
        return (fs || []).find(f => /^image\/(png|jpeg|gif|webp|avif|bmp)$/.test(f)) || "";
    }
    function _imgSrc(html) {
        const m = /<img\b[^>]*?\ssrc\s*=\s*["']([^"']+)["']/i.exec(html || "");
        return m ? m[1].replace(/&amp;/g, "&") : "";
    }
    function _str(d, fmt) {
        try { return (d.formats || []).includes(fmt) ? String(d.getDataAsString(fmt) || "") : ""; }
        catch (e) { return ""; }
    }
    function _hostOf(u) {
        const m = /^[a-z]+:\/\/([^\/?#]+)/i.exec(u || "");
        return m ? m[1].replace(/^www\./, "") : "";
    }
    function _strip(html) {
        return (html || "").replace(/<[^>]*>/g, " ").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
                           .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"")
                           .replace(/\s+/g, " ").trim();
    }

    // Everything we need from a drag/drop event, read up front (the event
    // object is only valid during the handler).
    function inspect(d) {
        const urls = (d.urls || []).map(String);
        const fileUrls = urls.filter(u => u.startsWith("file://"));
        if (fileUrls.length && fileUrls.length === urls.length)
            return { kind: "files", urls: fileUrls };

        const fs = d.formats || [];
        const html = d.hasHtml ? String(d.html || "") : _str(d, "text/html");
        const moz = _str(d, "text/x-moz-url").split(/\r?\n/);
        const text = d.hasText ? String(d.text || "") : "";
        const trimmed = text.trim();

        let link = urls.find(_isWeb) || (_isWeb(moz[0]) ? moz[0] : "")
                || (/^https?:\/\/\S+$/i.test(trimmed) ? trimmed : "");
        const src = _imgSrc(html);
        const imgFmt = _imageFormat(fs);
        const image = !!(src || imgFmt || fs.includes("application/x-moz-nativeimage") || _looksLikeImage(link));
        const imageUrl = src || (_looksLikeImage(link) ? link : "");
        const anchor = /<a\b[^>]*>([\s\S]*?)<\/a>/i.exec(html);
        const title = (moz[1] || "").trim() || (anchor ? _strip(anchor[1]) : "");

        if (image || link)
            return { kind: "web", link, image, imageUrl, imgFmt, title };
        if (trimmed || html)
            return { kind: "text", text: trimmed || _strip(html) };
        return { kind: "none" };
    }

    function acceptsDrag(d) {
        return d.hasUrls || d.hasText || d.hasHtml || !!_imageFormat(d.formats)
            || (d.formats || []).includes("application/x-moz-nativeimage");
    }

    // Drop targets offered for what's being dragged, primary first. `role`
    // is what handleDrop() does; `weight` is the zone's share of the height.
    function zonesFor(info) {
        const k = info ? info.kind : "files";
        if (k === "web") {
            const z = [];
            if (info.image)
                z.push({ role: "image", glyph: "", label: "Save image", hint: "Downloads the picture", weight: 3 });
            const page = info.link && info.link !== info.imageUrl;
            if (page || !info.image)
                z.push({ role: "weblink", glyph: "", label: "Save link", hint: "Double-click it later to open in your browser", weight: 2 });
            if (page && !_looksLikeImage(info.link))
                z.push({ role: "download", glyph: "", label: "Download", hint: "Saves the video or file the link points to", weight: 2 });
            if (!z.length)
                z.push({ role: "weblink", glyph: "", label: "Save link", hint: "Double-click it later to open in your browser", weight: 2 });
            return z;
        }
        if (k === "text")
            return [{ role: "text", glyph: "", label: "Save text", hint: "Keeps it as a text file", weight: 1 }];
        return [
            { role: "file-link", glyph: "", label: "Keep link", hint: "Points to the original file", weight: 3 },
            { role: "file-copy", glyph: "", label: "Copy to shelf", hint: "Keeps its own copy, even if the original moves", weight: 2 }
        ];
    }

    function handleDrop(drop, role) {
        const info = inspect(drop);
        // Image bytes can only be read now, while the drop event is alive.
        let bytes = null, bytesFmt = "";
        if (role === "image" && info.imgFmt) {
            try { bytes = drop.getDataAsArrayBuffer(info.imgFmt); bytesFmt = info.imgFmt; } catch (e) { bytes = null; }
        }
        switch (role) {
        case "file-link": return addUrls(info.urls || drop.urls, false);
        case "file-copy": return addUrls(info.urls || drop.urls, true);
        case "image":     return _saveImage(info, bytes, bytesFmt);
        case "weblink":   return addLink(info.link || info.imageUrl, info.title);
        case "download":  return download(info.link, info.title);
        case "text":      return _saveText(info.text);
        }
    }

    function _newId() {
        return Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
    }

    function _push(it) {
        items = [Object.assign({ missing: false, pending: false, copied: false, kind: "file", url: "", icon: "",
                                 from: "", mime: "", path: "", added: Date.now() }, it)].concat(items);
        return it.id;
    }

    function _fail(id, message) {
        items = items.filter(x => x.id !== id);
        Jobs.run(["rm", "-rf", "--", `${copyDir}/${id}`]);
        notify(message, true);
    }

    // A finished download/write: the item becomes a normal copied file.
    function _landed(id, path, from) {
        _update(id, { path, name: basename(path), pending: false, copied: true, from: from || "" });
        _save();
        const it = items.find(x => x.id === id);
        if (it) _detectMime([it]);
    }

    // Copy/download folders whose item is gone (e.g. a download interrupted
    // by a restart). Only touches names shaped like our ids.
    function _sweepOrphans() {
        Jobs.sh('d=$1; shift; for p in "$d"/*/; do [ -d "$p" ] || continue; id=${p%/}; id=${id##*/}; ' +
                'case $id in *[!a-z0-9]*|"") continue;; esac; [ ${#id} -ge 10 ] || continue; keep=; ' +
                'for k do [ "$k" = "$id" ] && keep=1 && break; done; [ -n "$keep" ] || rm -rf -- "$p"; done',
                [copyDir].concat(items.map(it => it.id)));
    }

    function _forget(id) {
        delete _jobs[id];
        if (id in progress) {
            const p = Object.assign({}, progress);
            delete p[id];
            progress = p;
        }
    }

    // A download with live progress. `cb(code, result, error)` runs only if
    // the item still exists; a cancelled item's folder is removed instead.
    function _fetchTracked(id, args, cb) {
        _jobs[id] = Jobs.stream(["python3", fetcher].concat(args), line => {
            let ev = null;
            try { ev = JSON.parse(line); } catch (e) { return; }
            if (!ev || !items.some(x => x.id === id)) return;
            if (ev.title) _update(id, { name: ev.title });
            if ("progress" in ev) {
                const p = Object.assign({}, progress);
                p[id] = ev;
                progress = p;
            }
        }, (code, last, err) => {
            _forget(id);
            if (!items.some(x => x.id === id)) {
                Jobs.run(["rm", "-rf", "--", `${copyDir}/${id}`]);
                return;
            }
            let res = null;
            try { res = JSON.parse(last); } catch (e) {}
            cb(code, res, (err || "").trim().split("\n").pop());
        });
    }

    function _fetch(args, cb) {
        Jobs.run(["python3", fetcher].concat(args), (code, out, err) => {
            let res = null;
            try { res = JSON.parse(out); } catch (e) {}
            cb(code, res, (err || "").trim().split("\n").pop());
        });
    }

    function _write(path, data, isText, cb) {
        Jobs.run(["mkdir", "-p", path.replace(/\/[^\/]*$/, "")], () => {
            const w = _writerComp.createObject(root, { path });
            w.saved.connect(() => { cb(true); w.destroy(); });
            w.saveFailed.connect(() => { cb(false); w.destroy(); });
            if (isText) w.setText(data); else w.setData(data);
        });
    }

    function addLink(url, title) {
        if (!_isWeb(url)) { notify("That isn't a web address", true); return; }
        if (items.some(it => it.kind === "link" && it.url === url)) { notify("That link is already on the shelf", false); return; }
        const id = _newId();
        _push({ id, kind: "link", url, name: title || _hostOf(url) || url, mime: "text/x-uri" });
        _save();
        // Fill in the page title and favicon in the background.
        _fetch(["meta", url, `${copyDir}/${id}`], (code, res, err) => {
            if (code !== 0 || !res) { console.warn("shelf: no title for", url, err); return; }
            const patch = {};
            if (res.title && (!title || title === url)) patch.name = res.title;
            if (res.icon) patch.icon = res.icon;
            if (Object.keys(patch).length) { _update(id, patch); _save(); }
        });
    }

    // The file behind a link: a direct file, or the video on a page (yt-dlp).
    // A plain page with nothing to download is kept as a link instead.
    function download(url, title) {
        if (!_isWeb(url)) { notify("That isn't a web address", true); return; }
        const id = _newId();
        _push({ id, name: title || _hostOf(url), pending: true, copied: true, from: url });
        _fetchTracked(id, ["save", url, `${copyDir}/${id}`], (code, res, err) => {
            if (code === 0 && res && res.path) {
                _landed(id, res.path, url);
                notify(`Saved ${basename(res.path)}`, false);
            } else if (code === 3) {
                items = items.filter(x => x.id !== id);
                addLink(url, title);
                notify("Nothing to download there, so the link was saved", false);
            } else {
                _fail(id, `Download failed: ${err || "unknown error"}`);
            }
        });
    }

    function _saveImage(info, bytes, bytesFmt) {
        const id = _newId();
        const dir = `${copyDir}/${id}`;
        const page = info.link && info.link !== info.imageUrl ? info.link : "";
        _push({ id, name: info.title || "Image", pending: true, copied: true, from: info.imageUrl || page });

        const fromBytes = () => {
            if (!bytes) {
                _fail(id, "Couldn't save that image: the site doesn't share it");
                return;
            }
            const ext = { "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp",
                          "image/avif": "avif", "image/bmp": "bmp" }[bytesFmt] || "png";
            const path = `${dir}/image-${Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss")}.${ext}`;
            _write(path, bytes, false, ok => ok ? _landed(id, path, page) : _fail(id, "Couldn't write the image"));
        };

        const src = info.imageUrl;
        if (src.startsWith("data:")) {
            // Inline image: hand the URI to the helper through a file (too long for argv).
            const tmp = `${dir}/.datauri`;
            _write(tmp, src, true, ok => {
                if (!ok) return fromBytes();
                _fetch(["datauri", tmp, dir, "image"], (code, res) => code === 0 && res ? _landed(id, res.path, page) : fromBytes());
            });
        } else if (_isWeb(src)) {
            // Prefer the original file (full size, real format) over the dragged bitmap.
            _fetchTracked(id, ["save", src, dir, page], (code, res) => code === 0 && res && res.path ? _landed(id, res.path, src) : fromBytes());
        } else {
            fromBytes();
        }
    }

    function _saveText(text) {
        if (!text) return;
        const id = _newId();
        const first = text.split(/\r?\n/)[0].replace(/[\/\\:*?"<>|\x00-\x1f]+/g, " ").trim().slice(0, 40).trim();
        const path = `${copyDir}/${id}/${first || "Text"}.txt`;
        _push({ id, name: basename(path), pending: true, copied: true });
        _write(path, text + "\n", true, ok => ok ? _landed(id, path, "") : _fail(id, "Couldn't save the text"));
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

    function uriOf(it) {
        return it.kind === "link" ? it.url : pathToUrl(it.path);
    }

    function uriList(list) {
        // text/uri-list wants CRLF-separated URIs.
        return list.map(uriOf).join("\r\n") + "\r\n";
    }

    // What a drag out of the shelf carries. Web links also go as plain text,
    // so they can be dropped into chat boxes and text fields.
    function dragMime(list) {
        const m = { "text/uri-list": uriList(list) };
        if (list.length && list.every(it => it.kind === "link"))
            m["text/plain"] = list.map(it => it.url).join("\n");
        return m;
    }

    // ---- file actions ------------------------------------------------------

    // Files open in their default app, links in the default browser.
    function open(it) {
        Qt.openUrlExternally(uriOf(it));
    }

    function copyLink(it) {
        Jobs.run(["wl-copy", "--", it.kind === "link" ? it.url : it.path], code => {
            if (code === 0) notify("Copied to clipboard", false);
            else notify("Couldn't copy: wl-copy isn't available", true);
        });
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
        const list = items.filter(it => !it.pending && it.kind !== "link");
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
        if (it.kind === "link") return "applications-internet";
        if (it.pending && it.from) return "folder-download";
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
