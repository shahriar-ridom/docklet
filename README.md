# Docklet

Hyprland (0.56+, Lua config) session manager + Quickshell sidebar with a file shelf.

- `hyprsess/`: Rust CLI that saves and restores window sessions
- `quickshell/`: the sidebar (file shelf + session controls)

## hyprsess

```sh
./install.sh                      # builds, installs ~/.local/bin/hyprsess, enables 10-min autosave
AUTOSAVE_MINUTES=5 ./install.sh   # different interval
./install.sh --no-timer           # no systemd timer
```

| Command | What it does |
|---|---|
| `hyprsess save [name]` | Snapshot to `~/.local/share/hyprsess/<name>.json` (default `last`). `-w current` (or a workspace id/name) saves only that desktop; the default is all desktops |
| `hyprsess restore [name]` | Relaunch from a snapshot. `-n` dry run, `-v` verbose, `--skip-running` don't launch apps that are already open, `-f` also launch apps running in the background, `--no-fixup` |
| `hyprsess list` | Saved sessions, newest first |
| `hyprsess show [name]` | What's in a snapshot (commands, cwd, workspaces) |
| `hyprsess delete <name>` | Delete a snapshot |

Add `--json` to any command for machine-readable output (the bar uses this).

### How it works

**Save.** `hyprctl clients -j` → for each window the PID's `/proc/<pid>/cmdline` and `cwd`.
- Windows sharing a PID (Zen/Firefox/Chromium/Electron) are grouped into one launch, and the app restores its own other windows. The fix-up step then puts those windows back on their saved workspaces, matched by title.
- Terminals (kitty, foot, alacritty, wezterm, ghostty): the cwd comes from the shell *inside* the terminal. If a program is running in it (the shell's foreground process group, e.g. `nvim`, `btop`), that command is saved too. Claude Code is saved as `claude --resume <session-id>`, read from `~/.claude/sessions/<pid>.json`, so the same conversation comes back. `sudo`/`doas`/`su`/`pkexec` are never saved. Turn this off with `terminal_programs = false`.
- Launch command, in priority order: config override → Flatpak (`/proc/<pid>/root/.flatpak-info`) → Steam `steam_app_<id>` → AppImage (`$APPIMAGE`, or the matching `.desktop` Exec when the binary lives in a `/tmp/.mount_*` that won't survive a reboot) → raw cmdline.
- Skipped: Quickshell, Noctalia, portals, polkit agents, fcitx, plus your `ignore` list.
- An empty snapshot never overwrites an existing one (use `--allow-empty` to force it).

**Restore.** Apps launch **one at a time**: restore waits for each app's first window to appear (`window_timeout_ms`, 10 s default), places it, then launches the next. Dwindle inserts windows in the order they appear, so this keeps the tiled layout matching the snapshot. For each app:
```lua
hl.exec_cmd("cd <cwd> && exec <cmd>", { workspace = "3 silent", float = true, size = "900 600", move = "100 80" })
```
sent via `hyprctl eval`. A terminal that had a program running is launched as `kitty /usr/bin/zsh -ic '<program>; exec /usr/bin/zsh'`: the program runs in an interactive shell (so your rc file's PATH applies), and you're left at a prompt when it exits. `size`/`move` are set only for floating windows; tiled windows get the workspace only. Pinned, fullscreen and maximized are restored too. Every app in the session is launched, even one that's already open elsewhere (`--skip-running` turns that off; terminals are never skipped). A running browser doesn't replay its saved session for a new launch, so it's launched once per saved window and each new window is moved to its saved desktop. Those windows open on the browser's start page, not the tabs they had. An app that's running **in the background with no window** (a tray icon, `thunar --daemon`) is left alone, because launching it again would open its main window. It's found by the executable name recorded at save time, by the Flatpak id, or by the exact command line for python/node/electron apps. `-f` launches it anyway. A window owned by a background service (`thunar --daemon`, `--gapplication-service`) is relaunched from its `.desktop` file instead.

**Fix-up.** It polls `hyprctl clients` for windows that weren't there before, matches them to saved windows by class (preferring an exact title match), and corrects them with `hl.dsp.window.move/float/resize/pin` dispatches. Resize runs before move because Hyprland's resize keeps the window centered.

### Config

`~/.config/hyprsess/config.toml`: see [examples/config.toml](examples/config.toml). It covers per-class `command`, `delay_ms`, `ignore` and `single_instance`, a global `ignore` regex list, the launch delay and fix-up timeout. Overrides also apply at restore time, so editing the config fixes old snapshots too.

### Autosave and save on logout

- **Timer**: `hyprsess-autosave.timer` saves to `autosave` every N minutes. This covers crashes and power loss.
  `systemctl --user list-timers hyprsess*` · `journalctl --user -u hyprsess-autosave`
- **On logout/shutdown**: use `hyprsess-power logout|poweroff|reboot`, which saves and then performs the action. Bind it, and point your power menu (Noctalia's session menu) at it.
  Why not a systemd stop hook? Your Hyprland isn't started through uwsm, so `graphical-session.target` is never active and its stop hooks never fire. Hyprland's Lua `hyprland.shutdown` event runs while the compositor is tearing down, so `hyprctl` queries from there can race or deadlock. Saving *before* exiting is the only reliable way.
- **Restore on login (opt-in)**: see [examples/hyprland-snippets.lua](examples/hyprland-snippets.lua).

### Limits

hyprsess restarts **programs**; it can't restore what's inside them:
- Unsaved documents, form inputs and in-app state are lost unless the app restores them itself (browsers, VS Code and Obsidian do).
- Terminals reopen in the right directory, but scrollback and running processes (`npm run dev`, ssh, nvim buffers) are gone. Use **tmux** with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) + [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) for that, and make the terminal's command `kitty -e tmux new -A -s main` via a config override.
- Tiled layout is approximate: windows land on the right workspace, but the dwindle split arrangement depends on launch order.
- Apps that fork through a launcher may escape the exec rules. The fix-up step catches these as long as the class matches.

## Sidebar (Quickshell)

```sh
ln -sfn "$PWD/quickshell" ~/.config/quickshell/docklet
qs -c docklet                  # foreground with logs; Ctrl+C to quit
DOCKLET_PIN=1 qs -c docklet # keep it open and wide while restyling
```
Quickshell hot-reloads on save. Edit `quickshell/Theme.qml` to restyle (colors, sizes, timings).

| File | Role |
|---|---|
| `shell.qml` | Root: one `Sidebar` per screen |
| `Sidebar.qml` | Layer-shell `PanelWindow`, auto-hide and expand logic, input mask |
| `Theme.qml` | Every color, size and timing |
| `Jobs.qml` / `Job.qml` | Run external commands with a callback |
| `shelf/ShelfStore.qml` | Shelf state and persistence (`~/.local/share/docklet/shelf.json`) |
| `shelf/Shelf.qml`, `shelf/ShelfItem.qml` | Shelf UI, drop zones, drag-out |
| `shelf/fetch.py` | Web helper: page title + favicon, downloads, videos via `yt-dlp` |
| `session/Hyprsess.qml` | Runs `hyprsess --json …`, holds the session list |
| `session/SessionPanel.qml` | Save button + name prompt, session list, restore/delete |

**Behavior**
- Hidden as a 3 px hover strip on the right edge. Hovering slides the bar in at 64 px; staying on it widens it to 280 px. Dragging files over the edge reveals it right away.
- **Drop in**: zones appear, matching what you're dragging. Dropping anywhere else on the bar does what the first zone does.
  - *Files*: *Keep link* stores a reference to the original; *Copy to shelf* copies into `~/.cache/shelf/<id>/`.
  - *An image from a web page*: *Save image* downloads the original file (full size; X/Twitter images are fetched at `name=orig`). If the site won't hand it out (`blob:` images, signed CDNs), the bitmap the browser put in the drag is saved instead.
  - *A link*: *Save link* keeps it as a link item (title and favicon are fetched in the background); double-click opens it in your default browser. *Download* saves what's behind it: a direct file, or the video on a page via `yt-dlp` (YouTube, X, Instagram, Reddit, TikTok…). A page with nothing to download is saved as a link instead. Videos are capped at 1080p.
  - *Selected text*: *Save text* stores it as a `.txt` file.
  - Drops are always accepted as a copy, so a file manager never moves your original.
- **Downloads** show a progress bar with size and percentage. Videos show *Finding the video…* while `yt-dlp` resolves the formats, then one bar across the video and audio streams, then *Finishing…* while they're merged. Hover a download and click × (or remove it) to cancel; the partial file is deleted. Folders left behind by an interrupted download are cleaned up the next time the bar starts. Why not a modifier key: a layer-shell bar has no keyboard focus during a drag, and QML drop events don't expose modifiers.
- **Drag out**: drag any item into a file manager, browser upload field, Discord, Telegram and so on (sent as `text/uri-list`). Click items to select several, then drag one of the selected items to carry them all.
- Double-click opens (links in the browser). Right-click gives Open / Show in folder / Copy path, or for links Open in browser / Copy link / Download video or file, plus Remove / Clear all. Dragging a link back out carries both the URL and plain text, so it drops into chat boxes too. "Show in folder" uses the `org.freedesktop.FileManager1` D-Bus API (Thunar highlights the file).
- Missing originals (reference mode) are struck through in red; this is re-checked every time the bar opens. Removing a *copied* item also deletes its cached copy.

**Sessions section** (bottom of the bar)
- 💾 opens a name prompt. The bar takes the keyboard only while the prompt is open. Enter saves, Esc cancels, and an existing name shows "will overwrite". Below the name is a **This desktop / All desktops** toggle (Tab flips it). The default is the focused desktop, and an empty name then saves to `desktop-<n>`; with All desktops it saves to `last`. One-desktop sessions show a `desktop N` tag in the list.
- Hover a session for ▶ restore and 🗑 delete (click twice to confirm). Everything in the session is launched, even apps that are already open, except apps running in the background (tray/daemon), which stay hidden.
- Results and errors show as a toast. The list refreshes every time the bar opens, so timer autosaves appear too.
- Calls `~/.local/bin/hyprsess` by absolute path. If it's missing, the toast tells you to run `./install.sh`.
