//! Relaunch apps with exec rules, then optionally poll and fix placement.

use crate::config::Loaded;
use crate::hypr::{self, Client, lua_str, lua_table};
use crate::procinfo::{self, Proc};
use crate::snapshot::{App, Session, Window, shell_quote};
use anyhow::Result;
use serde::Serialize;
use std::collections::HashSet;
use std::thread::sleep;
use std::time::{Duration, Instant};

#[derive(Default, Serialize)]
pub struct Report {
    pub launched: Vec<String>,
    pub skipped: Vec<String>,
    /// How many of `skipped` were left alone because they run in the background.
    pub background: usize,
    pub fixed: usize,
    pub unplaced: usize,
    pub errors: Vec<String>,
}

pub struct Opts {
    pub dry_run: bool,
    /// Skip apps whose class already has open windows (old default).
    pub skip_running: bool,
    /// Also launch apps that are only running in the background (tray,
    /// daemon); by default they're left alone so their window doesn't pop up.
    pub wake_background: bool,
    pub no_fixup: bool,
    pub verbose: bool,
}

/// `cd <dir> && exec <cmd>`: `exec` keeps the PID Hyprland is watching, so
/// the exec rules still apply to the real app process.
///
/// A terminal that had a program running gets it back inside an interactive
/// shell (so PATH/aliases from the rc file apply), and drops to that shell
/// when the program exits instead of closing the window:
///   kitty /usr/bin/zsh -ic 'claude --resume …; exec /usr/bin/zsh'
fn full_command(cfg: &Loaded, app: &App) -> String {
    let mut cmd = app.command.clone();
    if let Some(inner) = app.inner.as_ref().filter(|_| app.terminal && cfg.cfg.terminal_programs) {
        let sh = shell_quote(&inner.shell);
        let script = format!("{}; exec {sh}", inner.command);
        let args = cfg.exec_args_for(&app.class);
        let sep = if args.is_empty() { String::new() } else { format!(" {args}") };
        cmd = format!("{cmd}{sep} {sh} -ic {}", shell_quote(&script));
    }
    match &app.cwd {
        Some(d) if std::path::Path::new(d).is_dir() => format!("cd {} && exec {cmd}", shell_quote(d)),
        _ => cmd,
    }
}

/// Exec rules for the app's first window. size/move only for floating windows.
fn rules(w: &Window) -> String {
    let mut r: Vec<(&str, String)> = vec![("workspace", lua_str(&format!("{} silent", w.workspace_selector())))];
    if w.floating || w.pinned {
        r.push(("float", "true".into()));
        r.push(("size", lua_str(&format!("{} {}", w.size[0], w.size[1]))));
        r.push(("move", lua_str(&format!("{} {}", w.at[0], w.at[1]))));
    } else {
        r.push(("float", "false".into()));
    }
    if w.pinned {
        r.push(("pin", "true".into()));
    }
    match w.fullscreen {
        2 => r.push(("fullscreen", "true".into())),
        1 => r.push(("maximize", "true".into())),
        _ => {}
    }
    lua_table(&r)
}

/// The first word of a shell command (as written by `shell_quote`: plain, or
/// single-quoted with `'\''` for quotes), as a file name.
fn command_program(cmd: &str) -> Option<String> {
    let mut word = String::new();
    let mut chars = cmd.trim_start().chars().peekable();
    let mut quoted = false;
    while let Some(c) = chars.next() {
        match c {
            '\'' => quoted = !quoted,
            '\\' if !quoted => word.extend(chars.next()),
            c if c.is_whitespace() && !quoted => break,
            c => word.push(c),
        }
    }
    let name = std::path::Path::new(&word).file_name()?.to_string_lossy().into_owned();
    (!name.is_empty()).then_some(name)
}

/// A process of this app that's running without any window: a tray icon or
/// a daemon (thunar --daemon). Launching the app again would open its window.
fn background_pid(app: &App, procs: &[Proc]) -> Option<i32> {
    if app.terminal || app.source == "steam" {
        return None; // several terminals is normal; a game ≠ the Steam client
    }
    let me = std::process::id() as i32;
    let procs = procs.iter().filter(|p| p.pid != me);
    if app.source == "flatpak" {
        let id = app.command.split_whitespace().nth(2)?.trim_matches('\'');
        return procs.filter(|p| p.flatpak.as_deref() == Some(id)).map(|p| p.pid).next();
    }
    let name = app.process.clone().or_else(|| command_program(&app.command))?;
    if procinfo::is_interpreter(&name) {
        // python/node/electron…: only an identical command line counts.
        return procs
            .filter(|p| p.argv.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" ") == app.command)
            .map(|p| p.pid)
            .next();
    }
    // comm is cut to 15 bytes by the kernel.
    let short: String = name.chars().take(15).collect();
    procs.filter(|p| p.exe_name == name || p.comm == short).map(|p| p.pid).next()
}

fn same_class(a: &str, c: &Client) -> bool {
    a.eq_ignore_ascii_case(&c.class) || a.eq_ignore_ascii_case(&c.initial_class)
}

pub fn run(cfg: &Loaded, session: &Session, opts: &Opts) -> Result<Report> {
    let mut rep = Report::default();
    let before = hypr::clients()?;
    let monitors = hypr::monitors().unwrap_or_default();
    // Only scan /proc when it can matter, and only read Flatpak ids if a Flatpak app is in the session.
    let procs = if opts.wake_background {
        Vec::new()
    } else {
        procinfo::processes(session.apps.iter().any(|a| a.source == "flatpak"))
    };
    // Addresses already matched (or pre-existing); never matched again.
    let mut claimed: HashSet<String> = before.iter().map(|c| c.address.clone()).collect();
    // Saved windows still waiting for a live window to appear, with a unique id.
    let mut pending: Vec<(usize, Window)> = Vec::new();
    let mut next_id = 0usize;
    let fixup = cfg.cfg.fixup && !opts.no_fixup;

    for app in &session.apps {
        // Everything in the session is launched, even if the app is already
        // open elsewhere: restoring a desktop should bring all its windows
        // back. --skip-running opts out (terminals are never skipped).
        let running = before.iter().any(|c| same_class(&app.class, c));
        if running && !app.terminal && opts.skip_running {
            rep.skipped.push(format!("{} (already running)", app.class));
            continue;
        }
        // Running but windowless (tray/daemon): leave it in the background.
        if !running && !opts.wake_background
            && let Some(pid) = background_pid(app, &procs) {
                rep.skipped.push(format!("{} (running in background, pid {pid})", app.class));
                rep.background += 1;
                continue;
            }
        // A running browser won't replay its saved session for a new launch;
        // each launch just opens one more window. So launch once per saved
        // window. (Not running: one launch, the app restores its own windows.)
        let launches = if running && !app.terminal { app.windows.len() } else { 1 };
        // A config override applies on restore too, so you can fix old snapshots.
        let mut app = app.clone();
        if let Some(cmd) = cfg.app(&app.class).and_then(|a| a.command.clone()) {
            app.command = cmd;
        }
        let cmd = full_command(cfg, &app);
        let mut failed = false;
        for w in app.windows.iter().take(launches) {
            let lua = format!("hl.exec_cmd({}, {})", lua_str(&cmd), rules(w));
            if opts.dry_run || opts.verbose {
                eprintln!("[{}] {}", app.class, lua);
            }
            if opts.dry_run {
                continue;
            }
            if let Err(e) = hypr::eval(&lua) {
                rep.errors.push(format!("{}: {e:#}", app.class));
                failed = true;
                break;
            }
            if launches > 1 {
                // Let each new window map before asking for the next one.
                sleep(Duration::from_millis(cfg.delay_for(&app.class).max(300)));
            }
        }
        if failed {
            continue;
        }
        rep.launched.push(app.class.clone());
        if opts.dry_run {
            continue;
        }
        let first_id = next_id;
        for w in &app.windows {
            pending.push((next_id, w.clone()));
            next_id += 1;
        }

        // Wait for this app's first window before launching the next one.
        // Dwindle inserts windows in map order, so launching in parallel
        // shuffles the tiled layout; sequential launches keep the saved order.
        if cfg.cfg.wait_for_window {
            let deadline = Instant::now() + Duration::from_millis(cfg.window_timeout_for(&app.class));
            while Instant::now() < deadline {
                sleep(Duration::from_millis(150));
                place_new(&mut pending, &mut claimed, &monitors, fixup, opts.verbose, &mut rep);
                if !pending.iter().any(|(id, _)| *id == first_id) {
                    break;
                }
            }
        }
        sleep(Duration::from_millis(cfg.delay_for(&app.class)));
    }

    // Final pass: windows from multi-window apps (browsers restoring their own
    // windows) and anything slower than its wait timeout.
    if !opts.dry_run {
        let deadline = Instant::now() + Duration::from_millis(cfg.cfg.fixup_timeout_ms);
        while !pending.is_empty() && Instant::now() < deadline {
            sleep(Duration::from_millis(400));
            place_new(&mut pending, &mut claimed, &monitors, fixup, opts.verbose, &mut rep);
        }
    }
    rep.unplaced = pending.len();
    Ok(rep)
}

/// Match newly mapped windows to pending saved windows (same class, exact
/// title preferred) and fix their placement. Matched windows leave `pending`.
fn place_new(
    pending: &mut Vec<(usize, Window)>,
    claimed: &mut HashSet<String>,
    monitors: &[hypr::Monitor],
    fixup: bool,
    verbose: bool,
    rep: &mut Report,
) {
    if pending.is_empty() {
        return;
    }
    let Ok(now) = hypr::clients() else { return };
    let fresh: Vec<&Client> = now.iter().filter(|c| c.mapped && !claimed.contains(&c.address)).collect();
    if fresh.is_empty() {
        return;
    }
    let mut still = Vec::new();
    for (id, w) in pending.drain(..) {
        let cands: Vec<&&Client> = fresh.iter().filter(|c| same_class(&w.class, c) && !claimed.contains(&c.address)).collect();
        let Some(c) = cands.iter().find(|c| c.title == w.title).or_else(|| cands.first()).copied() else {
            still.push((id, w));
            continue;
        };
        claimed.insert(c.address.clone());
        if fixup {
            // Give the app a moment to finish its own initial resize.
            sleep(Duration::from_millis(100));
            match fix(c, &w, monitors, verbose) {
                Ok(true) => rep.fixed += 1,
                Ok(false) => {}
                Err(e) => rep.errors.push(format!("fixup {}: {e:#}", w.class)),
            }
        }
    }
    *pending = still;
}

/// Returns Ok(true) if any correction was dispatched.
fn fix(c: &Client, w: &Window, monitors: &[hypr::Monitor], verbose: bool) -> Result<bool> {
    let sel = lua_str(&format!("address:{}", c.address));
    let mut cmds: Vec<String> = Vec::new();

    let want_ws = w.workspace_selector();
    let ws_ok = if want_ws.starts_with("special:") || want_ws.starts_with("name:") {
        c.workspace.name == w.workspace_name
    } else {
        c.workspace.id == w.workspace_id
    };
    if !ws_ok {
        cmds.push(format!("hl.dsp.window.move({{ workspace = {}, follow = false, window = {sel} }})", lua_str(&want_ws)));
    }
    let want_float = w.floating || w.pinned;
    if c.floating != want_float {
        let action = if want_float { "enable" } else { "disable" };
        cmds.push(format!("hl.dsp.window.float({{ action = \"{action}\", window = {sel} }})"));
    }
    if want_float {
        // Restore to the saved monitor if it still exists, else the window's current one.
        let (mx, my) = monitors
            .iter()
            .find(|m| m.name == w.monitor)
            .or_else(|| monitors.iter().find(|m| m.id == c.monitor))
            .map(|m| (m.x, m.y))
            .unwrap_or((0, 0));
        let (x, y) = (w.at[0] + mx, w.at[1] + my);
        // Resize first: resize keeps the window centred, which would undo a prior move.
        if c.size != w.size || c.floating != want_float {
            cmds.push(format!("hl.dsp.window.resize({{ x = {}, y = {}, relative = false, window = {sel} }})", w.size[0], w.size[1]));
        }
        if c.at != [x, y] || !cmds.is_empty() {
            cmds.push(format!("hl.dsp.window.move({{ x = {x}, y = {y}, relative = false, window = {sel} }})"));
        }
    }
    if w.pinned && !c.pinned {
        cmds.push(format!("hl.dsp.window.pin({{ action = \"enable\", window = {sel} }})"));
    }
    for cmd in &cmds {
        if verbose {
            eprintln!("  fixup [{}] {cmd}", w.class);
        }
        hypr::dispatch(cmd)?;
    }
    Ok(!cmds.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(class: &str, command: &str, source: &str, process: Option<&str>) -> App {
        App {
            class: class.into(),
            command: command.into(),
            source: source.into(),
            cwd: None,
            terminal: false,
            process: process.map(String::from),
            inner: None,
            windows: vec![],
        }
    }

    fn proc_(pid: i32, exe: &str, argv: &[&str], flatpak: Option<&str>) -> Proc {
        Proc {
            pid,
            exe_name: exe.into(),
            comm: exe.chars().take(15).collect(),
            argv: argv.iter().map(|s| s.to_string()).collect(),
            flatpak: flatpak.map(String::from),
        }
    }

    #[test]
    fn program_of_command() {
        assert_eq!(command_program("'/opt/zen browser/zen-bin' --x").as_deref(), Some("zen-bin"));
        assert_eq!(command_program("/usr/bin/thunar").as_deref(), Some("thunar"));
        assert_eq!(command_program("").as_deref(), None);
        assert_eq!(command_program(&crate::snapshot::shell_quote("/opt/it's/app")).as_deref(), Some("app"));
    }

    #[test]
    fn background_detection() {
        let procs = vec![
            proc_(10, "thunar", &["thunar", "--daemon"], None),
            proc_(11, "python3.13", &["python3", "/opt/tool.py"], None),
            proc_(12, "bwrap", &["bwrap"], Some("org.telegram.desktop")),
        ];
        assert_eq!(background_pid(&app("thunar", "thunar", "desktop", Some("thunar")), &procs), Some(10));
        // Old snapshot without `process`: falls back to the command's program.
        assert_eq!(background_pid(&app("thunar", "thunar", "desktop", None), &procs), Some(10));
        // Interpreters only match on the exact command line.
        assert_eq!(background_pid(&app("tool", "python3 /opt/tool.py", "cmdline", Some("python3.13")), &procs), Some(11));
        assert_eq!(background_pid(&app("other", "python3 /opt/other.py", "cmdline", Some("python3.13")), &procs), None);
        assert_eq!(
            background_pid(&app("telegram", "flatpak run org.telegram.desktop", "flatpak", None), &procs),
            Some(12)
        );
        // Terminals and Steam games are never "in the background".
        let mut term = app("kitty", "kitty", "cmdline", Some("thunar"));
        term.terminal = true;
        assert_eq!(background_pid(&term, &procs), None);
        assert_eq!(background_pid(&app("steam_app_1", "steam steam://rungameid/1", "steam", Some("thunar")), &procs), None);
    }

    #[test]
    fn terminal_command_runs_program_in_shell() {
        let cfg = Loaded::load_default();
        let mut a = app("kitty", "kitty --class kitty", "cmdline", None);
        a.terminal = true;
        a.cwd = Some("/".into());
        a.inner = Some(crate::snapshot::Inner {
            name: "claude".into(),
            command: "claude --resume abc".into(),
            shell: "/usr/bin/zsh".into(),
        });
        assert_eq!(
            full_command(&cfg, &a),
            "cd / && exec kitty --class kitty /usr/bin/zsh -ic 'claude --resume abc; exec /usr/bin/zsh'"
        );
        a.class = "Alacritty".into();
        a.command = "alacritty".into();
        assert!(full_command(&cfg, &a).contains("alacritty -e /usr/bin/zsh -ic"));
    }
}
