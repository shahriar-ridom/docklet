#!/bin/sh
# Install hyprsess + helper + systemd timer. Re-run safely after changes.
#   AUTOSAVE_MINUTES=10 ./install.sh          (default 10)
#   ./install.sh --no-timer                   (skip the systemd timer)
set -eu
cd "$(dirname "$0")"
MIN="${AUTOSAVE_MINUTES:-10}"
BIN="$HOME/.local/bin"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

cargo build --release --manifest-path hyprsess/Cargo.toml
install -Dm755 hyprsess/target/release/hyprsess "$BIN/hyprsess"
install -Dm755 bin/hyprsess-power "$BIN/hyprsess-power"
echo "installed $BIN/hyprsess and $BIN/hyprsess-power"

CFG="${XDG_CONFIG_HOME:-$HOME/.config}/hyprsess/config.toml"
if [ ! -e "$CFG" ]; then
  install -Dm644 examples/config.toml "$CFG"
  echo "created $CFG"
fi

# What the sidebar calls out to. Missing required tools are an error; optional
# ones only disable a feature.
missing=
for t in qs hyprctl python3 file; do command -v "$t" >/dev/null || missing="$missing $t"; done
[ -z "$missing" ] || { echo "error: missing required tools:$missing" >&2; exit 1; }
opt() { command -v "$1" >/dev/null || echo "note: $1 not found, $2"; }
opt yt-dlp "the shelf can't download videos from links"
opt ffmpeg "videos with separate audio won't be merged into one mp4"
opt wl-copy "\"Copy link\" in the shelf menu won't work"
opt gdbus "\"Show in folder\" falls back to opening the folder"

if [ "${1:-}" != "--no-timer" ]; then
  install -Dm644 systemd/hyprsess-autosave.service "$UNITS/hyprsess-autosave.service"
  sed "s/@MINUTES@/$MIN/g" systemd/hyprsess-autosave.timer > "$UNITS/hyprsess-autosave.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now hyprsess-autosave.timer
  echo "autosave timer enabled (every $MIN min)"
fi
