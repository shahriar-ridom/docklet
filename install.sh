#!/bin/sh
# Docklet installer for Hyprland, on any Linux distro. Safe to re-run: it
# updates an existing install.
#
# One-line install (downloads the source, builds, installs):
#   curl -fsSL https://raw.githubusercontent.com/shahriar-ridom/docklet/main/install.sh | sh
#
# From a local checkout:
#   ./install.sh
#
# Run with --help for options.
set -eu

REPO="https://github.com/shahriar-ridom/docklet.git"
RAW="https://raw.githubusercontent.com/shahriar-ridom/docklet/main/install.sh"
HYPR_MIN="0.56.0"   # first release with the Lua config
RUST_MIN="1.88.0"   # edition 2024 + let-chains

usage() {
  cat <<EOF
Docklet installer (Hyprland, any Linux distro)

Usage:
  curl -fsSL $RAW | sh
  curl -fsSL $RAW | sh -s -- [options]
  ./install.sh [options]

Options:
  -y, --yes      install missing packages without asking
  --no-deps      never install packages; just say what's missing
  --no-timer     don't set up autosave
  --uninstall    remove Docklet (your saved sessions and config are kept)
  -h, --help     show this help

Environment:
  AUTOSAVE_MINUTES=10   autosave interval in minutes (default 10)
  DOCKLET_DIR=...       where the one-line install keeps the source
                        (default ~/.local/share/docklet/src)
EOF
}

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
note() { printf '\033[1;33mnote:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ver_ge A B: true when version A >= B (compares up to three numeric parts).
ver_ge() {
  a=$1 b=$2
  for _ in 1 2 3; do
    x=$(printf %s "${a%%.*}" | tr -cd 0-9); y=$(printf %s "${b%%.*}" | tr -cd 0-9)
    x=${x:-0} y=${y:-0}
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
    case $a in *.*) a=${a#*.} ;; *) a=0 ;; esac
    case $b in *.*) b=${b#*.} ;; *) b=0 ;; esac
  done
  return 0
}

# ask QUESTION: yes with --yes; otherwise prompt on the terminal (stdin is
# the script itself under `curl | sh`). No terminal means no.
ask() {
  [ "$YES" = 1 ] && return 0
  [ "$TTY" = 1 ] || return 1
  printf '\033[1;32m?\033[0m %s [Y/n] ' "$1" >/dev/tty
  read -r ans </dev/tty || return 1
  case $ans in ''|y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

# --- distro detection --------------------------------------------------------
detect_distro() {
  OS_ID=linux OS_LIKE= OS_NAME=Linux
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID=${ID:-linux} OS_LIKE=${ID_LIKE:-} OS_NAME=${PRETTY_NAME:-${NAME:-Linux}}
  fi
  case " $OS_ID $OS_LIKE " in
    *" nixos "*)  PM=nix ;;
    *" gentoo "*) PM=emerge ;;
    *)
      if   have pacman;       then PM=pacman
      elif have apt-get;      then PM=apt
      elif have dnf;          then PM=dnf
      elif have zypper;       then PM=zypper
      elif have xbps-install; then PM=xbps
      elif have apk;          then PM=apk
      elif have emerge;       then PM=emerge
      else PM=none
      fi ;;
  esac
}

# pkg_for TOOL: the package that provides TOOL with this package manager,
# or nothing when there isn't one in the standard repos.
pkg_for() {
  case "$PM:$1" in
    *:git)                         echo git ;;
    emerge:git)                    echo dev-vcs/git ;;
    pacman:cargo)                  echo rust ;;
    emerge:cargo)                  echo dev-lang/rust-bin ;;
    *:cargo)                       echo cargo ;;
    pacman:python3)                echo python ;;
    emerge:python3)                echo dev-lang/python ;;
    *:python3)                     echo python3 ;;
    emerge:file)                   echo sys-apps/file ;;
    *:file)                        echo file ;;
    pacman:qs|nix:qs)              echo quickshell ;;
    emerge:yt-dlp)                 echo net-misc/yt-dlp ;;
    *:yt-dlp)                      echo yt-dlp ;;
    dnf:ffmpeg)                    echo ffmpeg-free ;;
    emerge:ffmpeg)                 echo media-video/ffmpeg ;;
    *:ffmpeg)                      echo ffmpeg ;;
    emerge:wl-copy)                echo gui-apps/wl-clipboard ;;
    *:wl-copy)                     echo wl-clipboard ;;
    pacman:gdbus)                  echo glib2 ;;
    apt:gdbus)                     echo libglib2.0-bin ;;
    dnf:gdbus)                     echo glib2 ;;
    zypper:gdbus)                  echo glib2-tools ;;
    emerge:gdbus)                  echo dev-libs/glib ;;
    *:gdbus)                       echo glib ;;
  esac
}

# The command that installs packages "$@", as text (for printing).
pm_cmd() {
  case "$PM" in
    pacman) echo "$SUDO pacman -S --needed --noconfirm $*" ;;
    apt)    echo "$SUDO apt-get install -y $*" ;;
    dnf)    echo "$SUDO dnf install -y $*" ;;
    zypper) echo "$SUDO zypper --non-interactive install $*" ;;
    xbps)   echo "$SUDO xbps-install -Sy $*" ;;
    apk)    echo "$SUDO apk add $*" ;;
    emerge) echo "sudo emerge --ask $*" ;;
    nix)    echo "nix-shell -p $*   (or add them to environment.systemPackages)" ;;
  esac
}

# Package managers Docklet drives itself. Gentoo and NixOS are left to you.
can_auto_install() {
  case "$PM" in pacman|apt|dnf|zypper|xbps|apk) [ "$SUDO_OK" = 1 ] ;; *) return 1 ;; esac
}

pm_install() {
  # shellcheck disable=SC2046
  $(pm_cmd "$@" | sed 's/^ *//') </dev/null
}

quickshell_hint() {
  case "$PM:$OS_ID" in
    pacman:*)    echo "sudo pacman -S quickshell" ;;
    dnf:*)       echo "sudo dnf copr enable errornointernet/quickshell && sudo dnf install quickshell" ;;
    nix:*)       echo "add pkgs.quickshell to environment.systemPackages" ;;
    emerge:*)    echo "enable the GURU overlay, then: sudo emerge --ask gui-apps/quickshell" ;;
    *)           echo "see https://quickshell.org for packages and build instructions" ;;
  esac
}

# --- Hyprland check ----------------------------------------------------------
check_hyprland() {
  if ! have hyprctl && ! have Hyprland; then
    die "Hyprland isn't installed. Docklet only works on Hyprland.
       Install guide: https://wiki.hypr.land/Getting-Started/Installation/"
  fi
  HYPR_JSON=$(hyprctl version -j 2>/dev/null || true)
  HYPR_VER=$(printf '%s\n' "$HYPR_JSON" | sed -n 's/.*"version": *"\([0-9][0-9.]*\)".*/\1/p' | head -n1)
  if [ -z "$HYPR_VER" ]; then
    HYPR_VER=$(printf '%s\n' "$HYPR_JSON" | sed -n 's/.*"tag": *"v*\([0-9][0-9.]*\).*/\1/p' | head -n1)
  fi
  if [ -z "$HYPR_VER" ] && have Hyprland; then
    HYPR_VER=$(Hyprland --version 2>/dev/null | sed -n 's/^Hyprland v*\([0-9][0-9.]*\).*/\1/p' | head -n1)
  fi
  if [ -z "$HYPR_VER" ]; then
    note "couldn't tell which Hyprland version you have. Docklet needs $HYPR_MIN or newer."
  elif ! ver_ge "$HYPR_VER" "$HYPR_MIN"; then
    die "Docklet needs Hyprland $HYPR_MIN or newer (the Lua config). You have $HYPR_VER.
       Update Hyprland first: https://wiki.hypr.land/Getting-Started/Installation/"
  else
    say "Found Hyprland $HYPR_VER"
  fi
  if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    note "you're not inside a Hyprland session right now. That's fine for installing."
  fi
}

# cargo_ver: "1.99.0" from "cargo 1.99.0 (...)", or nothing if cargo is broken.
cargo_ver() {
  out=$(cargo --version 2>/dev/null) || return 0
  out=${out#cargo }; out=${out%% *}; printf '%s' "${out%%-*}"
}

rust_ok() {
  have cargo || return 1
  v=$(cargo_ver)
  [ -n "$v" ] && ver_ge "$v" "$RUST_MIN"
}

systemd_user_ok() {
  have systemctl && systemctl --user show-environment >/dev/null 2>&1
}

# Everything runs inside main(), called on the last line, so a download cut
# off halfway through `curl | sh` can't execute a partial script.
main() {
  MIN="${AUTOSAVE_MINUTES:-10}"
  BIN="$HOME/.local/bin"
  CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
  UNITS="$CONF/systemd/user"
  QS_LINK="$CONF/quickshell/docklet"
  SRC="${DOCKLET_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/docklet/src}"

  NO_TIMER=0 UNINSTALL=0 YES=0 NO_DEPS=0
  for arg in "$@"; do
    case "$arg" in
      --no-timer)  NO_TIMER=1 ;;
      --uninstall) UNINSTALL=1 ;;
      -y|--yes)    YES=1 ;;
      --no-deps)   NO_DEPS=1 ;;
      -h|--help)   usage; exit 0 ;;
      *) usage >&2; echo >&2; die "unknown option: $arg" ;;
    esac
  done

  case "$MIN" in
    ''|*[!0-9]*|0) die "AUTOSAVE_MINUTES must be a whole number above 0 (got '$MIN')" ;;
  esac

  # --- uninstall -------------------------------------------------------------
  if [ "$UNINSTALL" = 1 ]; then
    say "Removing Docklet"
    if have systemctl; then
      systemctl --user disable --now hyprsess-autosave.timer 2>/dev/null || true
    fi
    rm -f "$UNITS/hyprsess-autosave.service" "$UNITS/hyprsess-autosave.timer"
    if have systemctl; then systemctl --user daemon-reload 2>/dev/null || true; fi
    pkill -f "$BIN/hyprsess-autosave" 2>/dev/null || true
    rm -f "$BIN/hyprsess" "$BIN/hyprsess-power" "$BIN/hyprsess-autosave"
    if [ -L "$QS_LINK" ]; then rm -f "$QS_LINK"; fi
    if [ -d "$SRC/.git" ]; then rm -rf "$SRC"; fi
    say "Done. Kept your sessions (~/.local/share/hyprsess) and config ($CONF/hyprsess)."
    exit 0
  fi

  # --- system checks ---------------------------------------------------------
  [ "$(uname -s)" = Linux ] || die "Docklet runs on Linux only (it reads Linux's /proc to save sessions)."

  TTY=0
  if (: </dev/tty) 2>/dev/null; then TTY=1; fi
  SUDO= SUDO_OK=1
  if [ "$(id -u)" != 0 ]; then
    if have sudo; then SUDO=sudo
    elif have doas; then SUDO=doas
    else SUDO_OK=0
    fi
  fi

  detect_distro
  say "Detected $OS_NAME (package manager: $PM)"
  check_hyprland

  # Rust installed with rustup isn't always on PATH in a fresh shell.
  if [ -d "$HOME/.cargo/bin" ]; then PATH="$HOME/.cargo/bin:$PATH"; export PATH; fi

  # Running from a checkout uses it in place; otherwise we'll clone.
  HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
  ROOT=
  if [ -n "$HERE" ] && [ -f "$HERE/hyprsess/Cargo.toml" ] && [ -d "$HERE/quickshell" ]; then
    ROOT="$HERE"
  fi

  # --- dependencies ----------------------------------------------------------
  need=
  [ -n "$ROOT" ] || have git || need="$need git"
  rust_ok || need="$need cargo"
  for t in python3 file qs; do have "$t" || need="$need $t"; done
  want=
  for t in yt-dlp ffmpeg wl-copy gdbus; do have "$t" || want="$want $t"; done

  if [ "$NO_DEPS" = 0 ] && [ -n "$need$want" ] && can_auto_install; then
    req_pkgs= opt_pkgs=
    for t in $need; do
      # Distro Rust that's present but too old: upgrading the package rarely
      # helps, rustup does (below).
      if [ "$t" = cargo ] && have cargo; then continue; fi
      p=$(pkg_for "$t"); [ -n "$p" ] && req_pkgs="$req_pkgs $p"
    done
    for t in $want; do p=$(pkg_for "$t"); [ -n "$p" ] && opt_pkgs="$opt_pkgs $p"; done
    if [ -n "$req_pkgs$opt_pkgs" ]; then
      echo
      say "These packages are missing:${req_pkgs}${opt_pkgs:+ (optional:$opt_pkgs)}"
      if ask "Install them now with $PM?"; then
        if [ "$PM" = apt ]; then $SUDO apt-get update -qq </dev/null || true; fi
        if [ -n "$req_pkgs" ]; then
          # shellcheck disable=SC2086
          pm_install $req_pkgs || die "package install failed. Run it yourself: $(pm_cmd $req_pkgs)"
        fi
        for p in $opt_pkgs; do
          pm_install "$p" >/dev/null 2>&1 || note "couldn't install optional package $p, skipping it"
        done
      else
        note "skipping package install"
      fi
    fi
  fi

  # Rust missing or older than $RUST_MIN: offer rustup (per-user, no sudo).
  if ! rust_ok; then
    v=$(cargo_ver)
    if [ -n "$v" ]; then
      note "your Rust ($v) is too old. Docklet needs $RUST_MIN or newer."
    elif have cargo; then
      note "cargo is installed but has no working Rust toolchain."
    fi
    if [ "$NO_DEPS" = 0 ] && have rustup; then
      # rustup is already here (some distros ship `cargo` as a rustup shim
      # with no toolchain): just fetch a current stable toolchain.
      if ask "Install the latest stable Rust with rustup (into ~/.rustup, no sudo)?"; then
        rustup toolchain install stable --profile minimal </dev/null >/dev/null
        rustup default stable </dev/null >/dev/null
      fi
    elif [ "$NO_DEPS" = 0 ] && ask "Install the latest Rust with rustup (into ~/.cargo, no sudo)?"; then
      if ! have curl && ! have wget && can_auto_install; then
        pm_install curl >/dev/null 2>&1 || true
      fi
      if have curl; then fetch="curl --proto =https --tlsv1.2 -sSf"
      elif have wget; then fetch="wget -qO-"
      else die "need curl or wget to download rustup. Install one and run the installer again."
      fi
      $fetch https://sh.rustup.rs \
        | RUSTUP_INIT_SKIP_PATH_CHECK=yes sh -s -- -y --profile minimal --no-modify-path >/dev/null
      PATH="$HOME/.cargo/bin:$PATH"; export PATH
    fi
    if [ "$NO_DEPS" = 0 ] && have rustup && ! rust_ok; then
      die "rustup ran but cargo $RUST_MIN+ still isn't available. Try: rustup default stable"
    fi
  fi

  # Whatever is still missing, explain how to get it.
  missing=
  [ -n "$ROOT" ] || have git || missing="$missing git"
  rust_ok || missing="$missing cargo"
  for t in python3 file qs; do have "$t" || missing="$missing $t"; done
  if [ -n "$missing" ]; then
    echo >&2
    printf '\033[1;31merror:\033[0m still missing:%s\n' "$missing" >&2
    for t in $missing; do
      case $t in
        qs)    echo "  quickshell -> $(quickshell_hint)" >&2 ;;
        cargo) echo "  rust $RUST_MIN+ -> https://rustup.rs (or your distro's rust package if it's new enough)" >&2 ;;
        *)     p=$(pkg_for "$t")
               if [ -n "$p" ]; then hint=$(pm_cmd "$p"); else hint="your distro's $t package"; fi
               echo "  $t -> $hint" >&2 ;;
      esac
    done
    exit 1
  fi

  # --- fetch the source ------------------------------------------------------
  if [ -z "$ROOT" ]; then
    if [ -d "$SRC/.git" ]; then
      say "Updating Docklet in $SRC"
      git -C "$SRC" pull --ff-only --quiet || die "couldn't update $SRC. Delete that folder and run the installer again."
    elif [ -e "$SRC" ] && [ -n "$(ls -A "$SRC" 2>/dev/null)" ]; then
      die "$SRC exists and isn't a Docklet checkout. Move it away or set DOCKLET_DIR."
    else
      say "Downloading Docklet to $SRC"
      mkdir -p "$(dirname "$SRC")"
      git clone --depth 1 --quiet "$REPO" "$SRC"
    fi
    ROOT="$SRC"
  fi
  cd "$ROOT"

  # --- build and install -----------------------------------------------------
  say "Building hyprsess (the first build takes a minute or two)"
  cargo build --release --quiet --manifest-path hyprsess/Cargo.toml </dev/null
  install -Dm755 hyprsess/target/release/hyprsess "$BIN/hyprsess"
  install -Dm755 bin/hyprsess-power "$BIN/hyprsess-power"
  install -Dm755 bin/hyprsess-autosave "$BIN/hyprsess-autosave"
  say "Installed hyprsess, hyprsess-power and hyprsess-autosave to $BIN"

  CFG="$CONF/hyprsess/config.toml"
  if [ ! -e "$CFG" ]; then
    install -Dm644 examples/config.toml "$CFG"
    say "Created $CFG"
  fi

  # Sidebar: point Quickshell's 'docklet' config at the source folder.
  mkdir -p "$(dirname "$QS_LINK")"
  if [ -L "$QS_LINK" ] || [ ! -e "$QS_LINK" ]; then
    ln -sfn "$ROOT/quickshell" "$QS_LINK"
    say "Linked sidebar to $QS_LINK"
  else
    note "$QS_LINK already exists and isn't a link; left it alone."
  fi

  # --- autosave --------------------------------------------------------------
  AUTOSAVE_LINE=
  if [ "$NO_TIMER" = 0 ]; then
    if systemd_user_ok; then
      install -Dm644 systemd/hyprsess-autosave.service "$UNITS/hyprsess-autosave.service"
      sed "s/@MINUTES@/$MIN/g" systemd/hyprsess-autosave.timer > "$UNITS/hyprsess-autosave.timer"
      systemctl --user daemon-reload
      systemctl --user enable --now hyprsess-autosave.timer >/dev/null 2>&1 \
        || die "couldn't enable the autosave timer. Re-run with --no-timer to skip it."
      say "Autosave enabled (every $MIN min, systemd timer)"
    else
      # runit, OpenRC, s6...: Hyprland starts a small loop instead.
      AUTOSAVE_LINE="hl.exec_cmd(\"hyprsess-autosave $MIN\")"
      say "No systemd user session, so autosave runs from Hyprland (see below)"
    fi
  fi

  # --- optional extras -------------------------------------------------------
  opt() { have "$1" || note "$1 not found: $2"; }
  opt yt-dlp "the shelf can't download videos from links"
  opt ffmpeg "videos with separate audio won't be merged into one mp4"
  opt wl-copy "\"Copy link\" in the shelf menu won't work"
  opt gdbus "\"Show in folder\" falls back to opening the folder"

  case ":$PATH:" in
    *":$BIN:"*) ;;
    *) note "$BIN is not on your PATH. Add it to your shell profile." ;;
  esac

  echo
  say "All set! Start the sidebar with:  qs -c docklet"
  echo "    To start it on login, add this inside hl.on(\"hyprland.start\", ...) in your Hyprland config:"
  echo "      hl.exec_cmd(\"qs -c docklet\")"
  if [ -n "$AUTOSAVE_LINE" ]; then echo "      $AUTOSAVE_LINE"; fi
}

main "$@"
