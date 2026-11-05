#!/usr/bin/env python3
"""Web helper for the shelf. Writes JSON lines on stdout; the last one is the result.

  fetch.py meta URL DIR            -> {"type", "title", "icon"}   page title + favicon (saved in DIR)
  fetch.py save URL DIR [REFERER]  -> {"path", "title"}           the file/image/video behind URL
  fetch.py datauri FILE DIR NAME   -> {"path"}                    decode a data: URI read from FILE

While saving, progress lines come first:
  {"progress": 0.42, "done": 1234, "total": 5678, "stage": "downloading"}
  {"title": "Video title"}   (videos, once known)
  stage is "preparing" (finding the video) | "downloading" | "finishing" (merging);
  progress is null when the size isn't known.

Exit codes: 0 ok, 3 nothing downloadable at URL (it's just a page), 1 other errors
(message on stderr), 143 cancelled (SIGTERM).
"""

import base64
import html
import json
import mimetypes
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
TIMEOUT = 20
EXT_FIX = {"image/jpeg": ".jpg", "image/jpg": ".jpg", "image/webp": ".webp", "image/avif": ".avif",
           "video/mp4": ".mp4", "video/webm": ".webm", "audio/mpeg": ".mp3", "text/plain": ".txt",
           "image/svg+xml": ".svg", "image/x-icon": ".ico", "image/vnd.microsoft.icon": ".ico"}


class NothingToSave(Exception):
    pass


def out(obj):
    print(json.dumps(obj), flush=True)


class Progress:
    """Throttled progress reporter: at most ~6 lines a second, and only
    when something visibly changed."""

    def __init__(self):
        self.last_t = 0.0
        self.last = None

    def __call__(self, fraction, done=0, total=0, stage="downloading", force=False):
        if fraction is not None:
            fraction = max(0.0, min(1.0, fraction))
        key = (stage, None if fraction is None else round(fraction, 3))
        now = time.monotonic()
        if not force and (key == self.last or now - self.last_t < 0.16):
            return
        self.last, self.last_t = key, now
        out({"progress": fraction, "done": int(done or 0), "total": int(total or 0), "stage": stage})


progress = Progress()
child = None  # running yt-dlp, killed if we are


def on_term(signum, _frame):
    if child and child.poll() is None:
        child.terminate()
    sys.exit(128 + signum)


def check_url(url):
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise ValueError(f"not a web address: {url}")


def request(url, referer=None, method="GET"):
    h = {"User-Agent": UA, "Accept": "*/*", "Accept-Language": "en;q=0.8"}
    if referer:
        h["Referer"] = referer
    return urllib.request.urlopen(urllib.request.Request(url, headers=h, method=method), timeout=TIMEOUT)


def content_type(resp):
    return (resp.headers.get("Content-Type") or "").split(";")[0].strip().lower()


def safe_name(name, fallback="download"):
    name = urllib.parse.unquote(name or "")
    name = re.sub(r'[\x00-\x1f/\\:*?"<>|]+', " ", name).strip(" .")
    return (name[:100].rstrip(" .") or fallback)


def with_ext(name, ctype):
    """Make the extension match the real content type (CDNs often serve
    "photo?format=jpg" or "image.php")."""
    want = EXT_FIX.get(ctype) or mimetypes.guess_extension(ctype or "") or ""
    if not want:
        return name
    guessed = mimetypes.guess_type(name)[0]
    if guessed == ctype or (guessed and (EXT_FIX.get(guessed) or mimetypes.guess_extension(guessed)) == want):
        return name
    return name + want


def unique(path):
    root, ext = os.path.splitext(path)
    n = 2
    while os.path.exists(path):
        path = f"{root} ({n}){ext}"
        n += 1
    return path


def name_from(resp, url):
    cd = resp.headers.get("Content-Disposition") or ""
    m = re.search(r"filename\*=UTF-8''([^;]+)", cd, re.I) or re.search(r'filename="?([^";]+)"?', cd, re.I)
    if m:
        return safe_name(m.group(1))
    return safe_name(os.path.basename(urllib.parse.urlsplit(resp.geturl() or url).path))


def better_url(url):
    # Twitter/X image CDN serves a downscaled copy unless asked for the original.
    p = urllib.parse.urlsplit(url)
    if p.netloc == "pbs.twimg.com" and p.path.startswith("/media/"):
        q = dict(urllib.parse.parse_qsl(p.query))
        q["name"] = "orig"
        return urllib.parse.urlunsplit(p._replace(query=urllib.parse.urlencode(q)))
    return url


def download(resp, url, d):
    ctype = content_type(resp)
    path = unique(os.path.join(d, with_ext(name_from(resp, url), ctype)))
    total = int(resp.headers.get("Content-Length") or 0)
    done = 0
    progress(0.0 if total else None, 0, total, force=True)
    with open(path + ".part", "wb") as f:
        while chunk := resp.read(1 << 16):
            f.write(chunk)
            done += len(chunk)
            progress(done / total if total else None, done, total)
    os.replace(path + ".part", path)
    return path


def page_meta(text, base):
    def meta(prop):
        m = re.search(r'<meta[^>]+(?:property|name)=["\']' + prop + r'["\'][^>]*content=["\']([^"\']*)', text, re.I) \
            or re.search(r'<meta[^>]+content=["\']([^"\']*)["\'][^>]*(?:property|name)=["\']' + prop, text, re.I)
        return html.unescape(m.group(1)).strip() if m else ""
    title = meta("og:title")
    if not title:
        m = re.search(r"<title[^>]*>(.*?)</title>", text, re.I | re.S)
        title = html.unescape(re.sub(r"\s+", " ", m.group(1))).strip() if m else ""
    icon = ""
    for m in re.finditer(r"<link[^>]+>", text, re.I):
        tag = m.group(0)
        rel = re.search(r'rel=["\']([^"\']+)', tag, re.I)
        href = re.search(r'href=["\']([^"\']+)', tag, re.I)
        if rel and href and "icon" in rel.group(1).lower() and "mask" not in rel.group(1).lower():
            icon = urllib.parse.urljoin(base, html.unescape(href.group(1)))
            if "apple-touch" in rel.group(1).lower():
                break  # bigger, looks better at thumbnail size
    return title, icon or urllib.parse.urljoin(base, "/favicon.ico")


def cmd_meta(url, d):
    check_url(url)
    with request(url) as r:
        ctype = content_type(r)
        title, icon_url = "", ""
        if ctype in ("text/html", "application/xhtml+xml"):
            text = r.read(600_000).decode(r.headers.get_content_charset() or "utf-8", "replace")
            title, icon_url = page_meta(text, r.geturl())
    icon = ""
    if icon_url:
        try:
            with request(icon_url, referer=url) as ir:
                ict = content_type(ir)
                data = ir.read(1_000_000)
                if ict.startswith("image/") and data:
                    os.makedirs(d, exist_ok=True)
                    icon = os.path.join(d, ".favicon" + (EXT_FIX.get(ict) or mimetypes.guess_extension(ict) or ".img"))
                    with open(icon, "wb") as f:
                        f.write(data)
        except Exception:
            icon = ""
    out({"type": ctype, "title": title, "icon": icon})


NOT_A_VIDEO = re.compile(r"Unsupported URL|No video|no suitable|There's no video|No media found", re.I)
PROGRESS_TEMPLATE = ("download:@@P %(progress.status)s %(progress.downloaded_bytes)s %(progress.total_bytes)s "
                     "%(progress.total_bytes_estimate)s %(progress.fragment_index)s %(progress.fragment_count)s")


def _num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return 0.0


def ytdlp(url, d):
    """Video on a web page. Two steps so progress is honest across the
    separate video and audio streams yt-dlp downloads and then merges:
    resolve the formats (and their sizes) first, then download those."""
    global child
    if not shutil.which("yt-dlp"):
        raise NothingToSave("yt-dlp isn't installed")
    # Up to 1080p: social clips don't need 4K, and it keeps downloads quick.
    common = ["--no-playlist", "--no-warnings", "--no-mtime",
              "-f", "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b"]
    if shutil.which("ffmpeg"):
        common += ["--merge-output-format", "mp4"]

    progress(None, stage="preparing", force=True)
    child = subprocess.Popen(["yt-dlp", *common, "-J", "--", url], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
    info_text, err = child.communicate()
    if child.returncode != 0:
        if NOT_A_VIDEO.search(err):
            raise NothingToSave("no video or file at that link")
        raise RuntimeError((err.strip().splitlines() or ["yt-dlp failed"])[-1].removeprefix("ERROR: "))
    info = json.loads(info_text)
    if info.get("_type") == "playlist":
        raise NothingToSave("no single video at that link")
    if info.get("title"):
        out({"title": info["title"]})  # lets the shelf name the item before the download ends
    parts = info.get("requested_formats") or [info]
    sizes = [_num(p.get("filesize") or p.get("filesize_approx")) for p in parts]
    grand = sum(sizes) if all(sizes) else 0
    weights = [s / grand for s in sizes] if grand else [1 / len(parts)] * len(parts)

    info_path = os.path.join(d, ".info.json")
    with open(info_path, "w") as f:
        f.write(info_text)
    child = subprocess.Popen(
        ["yt-dlp", *common, "--load-info-json", info_path, "-P", d, "-o", "%(title).90B [%(id)s].%(ext)s",
         "--newline", "--progress", "--progress-template", PROGRESS_TEMPLATE,
         "--print", "after_move:@@F %(filepath)s", "--quiet"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    part, base, path, tail = 0, 0.0, "", []
    for line in child.stdout:
        line = line.rstrip("\n")
        if line.startswith("@@P "):
            status, done, total, est, fi, fc = (line[4:].split(" ") + ["NA"] * 6)[:6]
            size = _num(total) or _num(est)
            frac = _num(done) / size if size else (_num(fi) / _num(fc) if _num(fc) else None)
            w = weights[min(part, len(weights) - 1)]
            overall = base + w * frac if frac is not None else None
            progress(overall, (grand * overall) if (grand and overall is not None) else _num(done), grand or size)
            if status == "finished":
                base += w
                part += 1
                if part >= len(parts):
                    progress(1.0, grand, grand, stage="finishing", force=True)
        elif line.startswith("@@F "):
            path = line[4:].strip()
        elif line.strip():
            tail = (tail + [line])[-5:]
    child.wait()
    os.path.exists(info_path) and os.remove(info_path)
    if child.returncode == 0 and path and os.path.exists(path):
        return path
    err = "\n".join(tail)
    if NOT_A_VIDEO.search(err):
        raise NothingToSave("no video or file at that link")
    raise RuntimeError((tail[-1] if tail else "yt-dlp failed").removeprefix("ERROR: "))


def cmd_save(url, d, referer=None):
    check_url(url)
    os.makedirs(d, exist_ok=True)
    url = better_url(url)
    with request(url, referer=referer) as r:
        ctype = content_type(r)
        if ctype not in ("text/html", "application/xhtml+xml"):
            path = download(r, url, d)
            out({"path": path, "title": os.path.basename(path)})
            return
    # A web page: maybe it holds a video (YouTube, X, Instagram, Reddit, TikTok…).
    path = ytdlp(url, d)
    out({"path": path, "title": os.path.basename(path)})


def cmd_datauri(src, d, name):
    text = open(src, encoding="ascii", errors="replace").read().strip()
    m = re.match(r"data:([\w.+/-]+)?(;base64)?,(.*)", text, re.S)
    if not m:
        raise ValueError("not a data: URI")
    ctype = (m.group(1) or "application/octet-stream").lower()
    raw = base64.b64decode(m.group(3)) if m.group(2) else urllib.parse.unquote_to_bytes(m.group(3))
    os.makedirs(d, exist_ok=True)
    path = unique(os.path.join(d, with_ext(safe_name(name, "image"), ctype)))
    with open(path, "wb") as f:
        f.write(raw)
    os.remove(src)
    out({"path": path})


def main(argv):
    signal.signal(signal.SIGTERM, on_term)
    try:
        if len(argv) >= 3 and argv[0] == "meta":
            cmd_meta(argv[1], argv[2])
        elif len(argv) >= 3 and argv[0] == "save":
            cmd_save(argv[1], argv[2], argv[3] if len(argv) > 3 and argv[3] else None)
        elif len(argv) >= 4 and argv[0] == "datauri":
            cmd_datauri(argv[1], argv[2], argv[3])
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except NothingToSave as e:
        print(str(e), file=sys.stderr)
        return 3
    except urllib.error.HTTPError as e:
        print(f"the site refused the download ({e.code})", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001 - report anything to the bar
        print(str(e) or type(e).__name__, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
