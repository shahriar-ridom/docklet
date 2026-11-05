# Docklet

**A slide-out sidebar and session saver for Hyprland.**

Docklet does two things:

- **Brings your desktop back.** It saves which apps you had open, on which workspace, in which folder, and opens them all again with one click. It autosaves every 10 minutes, so a crash or a reboot doesn't cost you your setup.
- **Gives you a file shelf.** A bar hides on the right edge of your screen. Drag files, images, links or text onto it to keep them handy, then drag them out into any app. Drop a YouTube link on it and it downloads the video.

---

## Install

Paste this into a terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/shahriar-ridom/docklet/main/install.sh | sh
```

Docklet works with **Hyprland on any Linux distro**: Arch, Fedora, Debian, Ubuntu, openSUSE, Void, Alpine, Gentoo, NixOS and their spins.

The installer:

1. Checks that you have Hyprland 0.56 or newer.
2. Works out your distro and offers to install anything missing with your package manager. It asks before using `sudo`.
3. Installs Rust with [rustup](https://rustup.rs) if your distro's Rust is too old. This goes into your home folder and doesn't need `sudo`.
4. Downloads Docklet, builds it, and sets up autosave.

You can run it again at any time to update.

Then start the sidebar:

```sh
qs -c docklet
```

To start it every time you log in, add this inside the `hl.on("hyprland.start", ...)` block of your Hyprland config:

```lua
hl.exec_cmd("qs -c docklet")
```

### What you need

You need **Hyprland 0.56 or newer** (the version with the Lua config) running on Linux. The installer gets everything else for you, except Quickshell on some distros:

| Distro | Getting Quickshell |
|---|---|
| Arch, Manjaro, EndeavourOS, CachyOS | Installed for you |
| Fedora | `sudo dnf copr enable errornointernet/quickshell && sudo dnf install quickshell` |
| NixOS | Add `pkgs.quickshell` to `environment.systemPackages` |
| Gentoo | Enable the GURU overlay, then `sudo emerge --ask gui-apps/quickshell` |
| Others | See [quickshell.org](https://quickshell.org) for packages or building from source |

Everything the installer handles:

| Package | Why |
|---|---|
| Rust 1.88+, git | Building Docklet |
| Python 3, file | The file shelf |
| yt-dlp *(optional)* | Video downloads from links |
| ffmpeg *(optional)* | Videos with sound merged into a single mp4 |
| wl-clipboard *(optional)* | "Copy link" in the shelf menu |
| glib *(optional)* | "Show in folder" highlights the file |

On Gentoo and NixOS the installer won't run your package manager. It prints what to install instead.

**Without systemd** (Void, Artix, Alpine, Gentoo with OpenRC, ...), autosave runs from Hyprland rather than a systemd timer. The installer prints the line to add to your Hyprland config:

```lua
hl.exec_cmd("hyprsess-autosave 10")
```

<details>
<summary>Install options</summary>

Add options after `sh -s --`:

```sh
# Install missing packages without asking
curl -fsSL https://raw.githubusercontent.com/shahriar-ridom/docklet/main/install.sh | sh -s -- --yes

# Don't install any packages, just list what's missing
curl -fsSL https://raw.githubusercontent.com/shahriar-ridom/docklet/main/install.sh | sh -s -- --no-deps

# No autosave
curl -fsSL https://raw.githubusercontent.com/shahriar-ridom/docklet/main/install.sh | sh -s -- --no-timer

# Autosave every 5 minutes instead of 10
curl -fsSL https://raw.githubusercontent.com/shahriar-ridom/docklet/main/install.sh | AUTOSAVE_MINUTES=5 sh
```

To install from a clone instead:

```sh
git clone https://github.com/shahriar-ridom/docklet.git
cd docklet
./install.sh
```

Run `./install.sh --help` to see every option.
</details>

---

## Using the sidebar

Move your mouse to the **right edge** of the screen. The bar slides in, and it gets wider if you keep the mouse on it.

**Putting things on the shelf.** Drag something onto the bar and drop zones appear:

| You drag | You can |
|---|---|
| Files | **Keep link** (points to the original) or **Copy to shelf** (keeps a copy) |
| An image from a web page | **Save image** at full size |
| A link | **Save link**, or **Download** the file or video behind it |
| Selected text | **Save text** as a `.txt` file |

Your originals are never moved.

**Getting things out.** Drag any item into a file manager, an upload box, Discord, Telegram and so on. Click several items to select them, then drag one to carry them all.

**Other actions.** Double-click an item to open it. Right-click for *Open*, *Show in folder*, *Copy path*, *Remove* and more. A download shows a progress bar; hover it and click × to cancel.

Items whose original file has gone missing are struck through in red.

## Saving and restoring sessions

At the bottom of the bar:

- Click **💾** to save. Type a name, or leave it empty. Choose **This desktop** or **All desktops** (Tab switches between them), then press Enter.
- Hover a saved session and click **▶** to restore it, or **🗑** twice to delete it.

Docklet also saves automatically every 10 minutes to a session called `autosave`. After a crash or reboot, restore `autosave`.

### From the terminal

```sh
hyprsess save work          # save everything as "work"
hyprsess save -w current    # save only the current desktop
hyprsess restore work       # bring it back
hyprsess restore -n work    # dry run: show what would open
hyprsess list               # all saved sessions
hyprsess show work          # what's inside one
hyprsess delete work
```

### Save when you log out

Autosave runs every 10 minutes, so it can miss your last few minutes. To save right before you leave, log out or shut down through `hyprsess-power`:

```sh
hyprsess-power logout     # or: poweroff, reboot
```

Example keybinds (and an optional "restore on login") are in [examples/hyprland-snippets.lua](examples/hyprland-snippets.lua). You can also point your power menu at `hyprsess-power`.

### What gets restored, and what doesn't

Docklet reopens your **apps**: each on the right workspace, at the right size and in the right folder.

- **Terminals** reopen in the folder you were in. If a program was running in one (`nvim`, `btop`), it starts again. Claude Code sessions resume the same conversation.
- **Browsers** reopen their windows on the right desktops, but each new window starts on the start page, not the tabs it had.
- **What's inside apps** (unsaved documents, terminal scrollback, a running `npm run dev`) can't be brought back, unless the app restores it itself. For terminals, [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) does this well.
- **Tiled layouts** come back close to how they were, but not always exactly.
- Commands run with `sudo` are never saved.

---

## Settings

**Sessions:** `~/.config/hyprsess/config.toml` (created on install). Use it to change an app's launch command, ignore apps, or adjust timing. Every setting is explained in [examples/config.toml](examples/config.toml).

**Sidebar look:** colors, sizes and animation speeds are all in `quickshell/Theme.qml`, inside the folder the sidebar runs from (`~/.local/share/docklet/src` for a one-line install). Changes apply as soon as you save the file. To keep the bar open while you tweak it:

```sh
DOCKLET_PIN=1 qs -c docklet
```

Note: the next update will fail if you've edited files in that folder. Undo your edits with `git -C ~/.local/share/docklet/src stash`, run the installer, then bring them back with `git -C ~/.local/share/docklet/src stash pop`.

**Blur:** to blur the area behind the bar, copy the `layer_rule` from [examples/hyprland-snippets.lua](examples/hyprland-snippets.lua) into your Hyprland config.

## Update

Run the install command again.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/shahriar-ridom/docklet/main/install.sh | sh -s -- --uninstall
```

This keeps your saved sessions (`~/.local/share/hyprsess`) and settings (`~/.config/hyprsess`). Delete those folders too if you want everything gone.

## Troubleshooting

| Problem | Fix |
|---|---|
| `hyprsess: command not found` | Add `~/.local/bin` to your `PATH` in your shell profile. |
| The bar says "hyprsess not found" | Run the install command again. |
| The bar doesn't appear | Run `qs -c docklet` in a terminal and read the errors. |
| Video downloads don't work | Install `yt-dlp` (and `ffmpeg`). |
| An app restores with the wrong command | Set its `command` in `~/.config/hyprsess/config.toml`. |
| Is autosave running? | With systemd: `systemctl --user list-timers hyprsess*`. Without: `pgrep -af hyprsess-autosave`. |
| "Docklet needs Hyprland 0.56 or newer" | Your distro's Hyprland is too old. Get a newer build: [Hyprland install guide](https://wiki.hypr.land/Getting-Started/Installation/). |
| "your Rust is too old" | Let the installer set up rustup, or install it yourself from [rustup.rs](https://rustup.rs). |

---

<details>
<summary><b>How it works</b> (for the curious and for contributors)</summary>

The project has two parts:

- `hyprsess/`: a Rust CLI that saves and restores sessions. Every command takes `--json`, which the bar uses.
- `quickshell/`: the sidebar, written in QML for Quickshell.

### Saving

`hyprctl clients -j` lists the windows. For each one, hyprsess reads `/proc/<pid>/cmdline` and `cwd`.

- Windows that share a PID (Firefox, Chromium, Zen, Electron apps) become one launch, since the app reopens its own other windows. A fix-up step then moves those windows to their saved workspaces, matched by title.
- Terminals (kitty, foot, alacritty, wezterm, ghostty): the folder comes from the shell *inside* the terminal. The program in the shell's foreground process group is saved too. Claude Code is saved as `claude --resume <session-id>`, read from `~/.claude/sessions/<pid>.json`. `sudo`, `doas`, `su` and `pkexec` are never saved. Turn this off with `terminal_programs = false`.
- The launch command is picked in this order: config override → Flatpak (`/proc/<pid>/root/.flatpak-info`) → Steam `steam_app_<id>` → AppImage (`$APPIMAGE`, or the matching `.desktop` Exec when the binary lives in a `/tmp/.mount_*`) → raw cmdline.
- Quickshell, Noctalia, portals, polkit agents, fcitx and your `ignore` list are skipped.
- An empty snapshot never overwrites an existing one (`--allow-empty` forces it).

### Restoring

Apps launch **one at a time**. Restore waits for each app's first window (`window_timeout_ms`, 10 s by default), places it, then launches the next. Dwindle inserts windows in the order they appear, so this keeps the tiled layout close to the snapshot. Each app is launched with:

```lua
hl.exec_cmd("cd <cwd> && exec <cmd>", { workspace = "3 silent", float = true, size = "900 600", move = "100 80" })
```

sent through `hyprctl eval`. A terminal that was running a program launches as `kitty /usr/bin/zsh -ic '<program>; exec /usr/bin/zsh'`, so your rc file's PATH applies and you're left at a prompt when the program exits. Size and position are set only for floating windows. Pinned, fullscreen and maximized states are restored too.

Every app in the session is launched, even one that's already open (`--skip-running` turns that off; terminals are never skipped). A running browser won't replay its session for a new launch, so it's launched once per saved window. An app running **in the background with no window** (a tray icon, `thunar --daemon`) is left alone, because launching it again would open its main window; `-f` launches it anyway. A window owned by a background service is relaunched from its `.desktop` file.

Restore flags: `-n` dry run, `-v` verbose, `--skip-running`, `-f`, `--no-fixup`.

### Fix-up

hyprsess polls `hyprctl clients` for new windows, matches them to saved ones by class (preferring an exact title match), and corrects them with `hl.dsp.window.move/float/resize/pin`. Resize runs before move, because Hyprland's resize keeps the window centered.

### Why `hyprsess-power` instead of a logout hook

Without uwsm, `graphical-session.target` is never active, so its stop hooks never fire. Hyprland's `hyprland.shutdown` event runs while the compositor is tearing down, so `hyprctl` calls from there can race or deadlock. Saving *before* exiting is the reliable option. To power off or reboot, `hyprsess-power` uses `systemctl` on systemd, `loginctl` on elogind (Artix, Void, Gentoo), and plain `poweroff`/`reboot` otherwise.

### Sidebar files

| File | Role |
|---|---|
| `shell.qml` | Root: one `Sidebar` per screen |
| `Sidebar.qml` | Layer-shell `PanelWindow`, auto-hide and expand logic, input mask |
| `Theme.qml` | Every color, size and timing |
| `Jobs.qml` / `Job.qml` / `StreamJob.qml` | Run external commands with a callback |
| `Toast.qml`, `IconButton.qml` | Shared UI pieces |
| `shelf/ShelfStore.qml` | Shelf state and persistence (`~/.local/share/docklet/shelf.json`) |
| `shelf/Shelf.qml`, `shelf/ShelfItem.qml` | Shelf UI, drop zones, drag-out |
| `shelf/fetch.py` | Page title and favicon, downloads, videos via `yt-dlp` |
| `session/Hyprsess.qml` | Runs `hyprsess --json …`, holds the session list |
| `session/SessionPanel.qml` | Save prompt, session list, restore/delete |

Shelf copies live in `~/.cache/shelf/<id>/`. Drops are always accepted as a copy, so a file manager never moves your original. A layer-shell bar has no keyboard focus during a drag and QML drop events don't expose modifier keys, which is why drop zones are used instead of Ctrl/Shift. "Show in folder" uses the `org.freedesktop.FileManager1` D-Bus API. Videos are capped at 1080p, and X/Twitter images are fetched at `name=orig`.

### Development

```sh
ln -sfn "$PWD/quickshell" ~/.config/quickshell/docklet   # ./install.sh does this for you
qs -c docklet                                            # run in the foreground with logs
cargo build --release --manifest-path hyprsess/Cargo.toml
```

Quickshell hot-reloads QML on save.
</details>
