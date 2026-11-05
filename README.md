# sessionbar

Hyprland (0.56+, Lua config) session manager + Quickshell sidebar with a file shelf.

- `hyprsess/`: Rust CLI that saves and restores window sessions
- `quickshell/`: the sidebar (file shelf; session controls in stage 3)

## hyprsess

```sh
./install.sh                      # builds, installs ~/.local/bin/hyprsess, enables 10-min autosave
AUTOSAVE_MINUTES=5 ./install.sh   # different interval
./install.sh --no-timer           # no systemd timer
```

| Command | What it does |
|---|---|
| `hyprsess save [name]` | Snapshot to `~/.local/share/hyprsess/<name>.json` (default `last`) |
| `hyprsess restore [name]` | Relaunch from a snapshot. `-n` dry run, `-v` verbose, `-f` also launch apps that are already running, `--no-fixup` |
| `hyprsess list` | Saved sessions, newest first |
| `hyprsess show [name]` | What's in a snapshot (commands, cwd, workspaces) |
| `hyprsess delete <name>` | Delete a snapshot |

Add `--json` to any command for machine-readable output (the bar uses this).

### How it works

**Save.** `hyprctl clients -j` → for each window the PID's `/proc/<pid>/cmdline` and `cwd`.
- Windows sharing a PID (Zen/Firefox/Chromium/Electron) are grouped into one launch, and the app restores its own other windows. The fix-up step then puts those windows back on their saved workspaces, matched by title.
- Terminals (kitty, foot, alacritty, wezterm, ghostty): the cwd comes from the shell *inside* the terminal.
- Launch command, in priority order: config override → Flatpak (`/proc/<pid>/root/.flatpak-info`) → Steam `steam_app_<id>` → AppImage (`$APPIMAGE`, or the matching `.desktop` Exec when the binary lives in a `/tmp/.mount_*` that won't survive a reboot) → raw cmdline.
- Skipped: Quickshell, Noctalia, portals, polkit agents, fcitx, plus your `ignore` list.
- An empty snapshot never overwrites an existing one (use `--allow-empty` to force it).

**Restore.** For each app:
```lua
hl.exec_cmd("cd <cwd> && exec <cmd>", { workspace = "3 silent", float = true, size = "900 600", move = "100 80" })
```
sent via `hyprctl eval`. `size`/`move` are set only for floating windows; tiled windows get the workspace only. Pinned, fullscreen and maximized are restored too. Apps whose class is already open are skipped unless you pass `-f` (terminals are always launched).

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
ln -sfn "$PWD/quickshell" ~/.config/quickshell/sessionbar
qs -c sessionbar                  # foreground with logs; Ctrl+C to quit
SESSIONBAR_PIN=1 qs -c sessionbar # keep it open and wide while restyling
```
Quickshell hot-reloads on save. Edit `quickshell/Theme.qml` to restyle (colors, sizes, timings).

| File | Role |
|---|---|
| `shell.qml` | Root: one `Sidebar` per screen |
| `Sidebar.qml` | Layer-shell `PanelWindow`, auto-hide and expand logic, input mask |
| `Theme.qml` | Every color, size and timing |
| `Jobs.qml` / `Job.qml` | Run external commands with a callback |
| `shelf/ShelfStore.qml` | Shelf state and persistence (`~/.local/share/sessionbar/shelf.json`) |
| `shelf/Shelf.qml`, `shelf/ShelfItem.qml` | Shelf UI, drop zones, drag-out |

**Behavior**
- Hidden as a 3 px hover strip on the right edge. Hovering slides the bar in at 64 px; staying on it widens it to 280 px. Dragging files over the edge reveals it right away.
- **Drop in**: two zones appear. *Keep link* stores a reference to the original; *Copy to shelf* copies into `~/.cache/shelf/<id>/`. Dropping anywhere else on the bar counts as *Keep link*. Why not a modifier key: a layer-shell bar has no keyboard focus during a drag, and QML drop events don't expose modifiers.
- **Drag out**: drag any item into a file manager, browser upload field, Discord, Telegram and so on (sent as `text/uri-list`). Click items to select several, then drag one of the selected items to carry them all.
- Double-click opens. Right-click gives Open / Show in folder / Remove / Clear all. "Show in folder" uses the `org.freedesktop.FileManager1` D-Bus API (Thunar highlights the file).
- Missing originals (reference mode) are struck through in red; this is re-checked every time the bar opens. Removing a *copied* item also deletes its cached copy.
