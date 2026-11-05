//! Relaunch apps with exec rules, then optionally poll and fix placement.

use crate::config::Loaded;
use crate::hypr::{self, Client, lua_str, lua_table};
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
    pub fixed: usize,
    pub unplaced: usize,
    pub errors: Vec<String>,
}

pub struct Opts {
    pub dry_run: bool,
    pub force: bool,
    pub no_fixup: bool,
    pub verbose: bool,
}

/// `cd <dir> && exec <cmd>`: `exec` keeps the PID Hyprland is watching, so
/// the exec rules still apply to the real app process.
fn full_command(app: &App) -> String {
    match &app.cwd {
        Some(d) if std::path::Path::new(d).is_dir() => format!("cd {} && exec {}", shell_quote(d), app.command),
        _ => app.command.clone(),
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

fn same_class(a: &str, c: &Client) -> bool {
    a.eq_ignore_ascii_case(&c.class) || a.eq_ignore_ascii_case(&c.initial_class)
}

pub fn run(cfg: &Loaded, session: &Session, opts: &Opts) -> Result<Report> {
    let mut rep = Report::default();
    let before = hypr::clients()?;
    let monitors = hypr::monitors().unwrap_or_default();
    // Addresses already matched (or pre-existing); never matched again.
    let mut claimed: HashSet<String> = before.iter().map(|c| c.address.clone()).collect();
    // Saved windows still waiting for a live window to appear, with a unique id.
    let mut pending: Vec<(usize, Window)> = Vec::new();
    let mut next_id = 0usize;
    let fixup = cfg.cfg.fixup && !opts.no_fixup;

    for app in &session.apps {
        // Avoid duplicating apps that are already open (terminals are exempt:
        // having several is normal). --force launches everything.
        let running = before.iter().any(|c| same_class(&app.class, c));
        if running && !app.terminal && !opts.force {
            rep.skipped.push(format!("{} (already running)", app.class));
            continue;
        }
        // A config override applies on restore too, so you can fix old snapshots.
        let mut app = app.clone();
        if let Some(cmd) = cfg.app(&app.class).and_then(|a| a.command.clone()) {
            app.command = cmd;
        }
        let cmd = full_command(&app);
        let lua = format!("hl.exec_cmd({}, {})", lua_str(&cmd), rules(&app.windows[0]));
        if opts.dry_run || opts.verbose {
            eprintln!("[{}] {}", app.class, lua);
        }
        if opts.dry_run {
            rep.launched.push(app.class.clone());
            continue;
        }
        if let Err(e) = hypr::eval(&lua) {
            rep.errors.push(format!("{}: {e:#}", app.class));
            continue;
        }
        rep.launched.push(app.class.clone());
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
