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

if [ "${1:-}" != "--no-timer" ]; then
  install -Dm644 systemd/hyprsess-autosave.service "$UNITS/hyprsess-autosave.service"
  sed "s/@MINUTES@/$MIN/g" systemd/hyprsess-autosave.timer > "$UNITS/hyprsess-autosave.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now hyprsess-autosave.timer
  echo "autosave timer enabled (every $MIN min)"
fi
