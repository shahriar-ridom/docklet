//! Session file format and capturing the current session.

use crate::config::Loaded;
use crate::hypr::{self, Client};
use crate::{desktop, procinfo};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;

pub const FORMAT_VERSION: u32 = 1;

#[derive(Debug, Serialize, Deserialize)]
pub struct Session {
    pub version: u32,
    pub name: String,
    /// Unix seconds.
    pub created: i64,
    pub hyprland: String,
    pub apps: Vec<App>,
}

/// One launch = one App. Windows sharing a PID (browsers, Electron) are grouped
/// so the app is started once and restores its own extra windows.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct App {
    pub class: String,
    /// Shell command passed to hl.exec_cmd.
    pub command: String,
    /// Where `command` came from: override | flatpak | appimage | desktop | steam | cmdline.
    pub source: String,
    pub cwd: Option<String>,
    pub terminal: bool,
    pub windows: Vec<Window>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Window {
    pub class: String,
    pub title: String,
    pub workspace_id: i64,
    pub workspace_name: String,
    pub monitor: String,
    /// Position relative to the monitor's top-left corner.
    pub at: [i32; 2],
    pub size: [i32; 2],
    pub floating: bool,
    /// 0 = none, 1 = maximized, 2 = fullscreen (Hyprland's numbering).
    pub fullscreen: i32,
    pub pinned: bool,
    pub pid: i32,
}

impl Window {
    /// Workspace selector as Hyprland rules want it.
    pub fn workspace_selector(&self) -> String {
        if self.workspace_name.starts_with("special:") {
            self.workspace_name.clone()
        } else if self.workspace_id > 0 && self.workspace_name == self.workspace_id.to_string() {
            self.workspace_id.to_string()
        } else {
            format!("name:{}", self.workspace_name)
        }
    }
}

pub fn data_dir() -> PathBuf {
    let base = std::env::var("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/share"));
    base.join("hyprsess")
}

pub fn validate_name(name: &str) -> Result<()> {
    let ok = !name.is_empty()
        && name.len() <= 64
        && !name.starts_with('.')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c));
    if !ok {
        bail!("invalid session name '{name}' (use letters, digits, - _ . ; max 64 chars)");
    }
    Ok(())
}

pub fn path_for(name: &str) -> Result<PathBuf> {
    validate_name(name)?;
    Ok(data_dir().join(format!("{name}.json")))
}

/// POSIX shell single-quote escaping.
pub fn shell_quote(s: &str) -> String {
    if !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:,+@%".contains(c)) {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', r"'\''"))
    }
}

fn resolve_command(cfg: &Loaded, class: &str, pid: i32) -> Option<(String, &'static str)> {
    if let Some(cmd) = cfg.app(class).and_then(|a| a.command.clone()) {
        return Some((cmd, "override"));
    }
    if let Some(id) = procinfo::flatpak_app_id(pid) {
        return Some((format!("flatpak run {}", shell_quote(&id)), "flatpak"));
    }
    if let Some(n) = class.strip_prefix("steam_app_").filter(|n| n.chars().all(|c| c.is_ascii_digit())) {
        return Some((format!("steam steam://rungameid/{n}"), "steam"));
    }
    if procinfo::exe_is_ephemeral(pid) {
        if let Some(img) = procinfo::environ_var(pid, "APPIMAGE") {
            return Some((shell_quote(&img), "appimage"));
        }
        if let Some(exec) = desktop::exec_for_class(class) {
            return Some((exec, "desktop"));
        }
    }
    let argv = procinfo::cmdline(pid)?;
    Some((argv.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" "), "cmdline"))
}

pub fn capture(cfg: &Loaded, name: &str) -> Result<(Session, Vec<String>)> {
    let monitors = hypr::monitors()?;
    let mut clients: Vec<Client> = hypr::clients()?;
    let mut warnings = Vec::new();
    let self_pid = std::process::id() as i32;

    // Stable order: workspace, then position. Makes restore order predictable.
    clients.sort_by_key(|c| (c.workspace.id, c.at[0], c.at[1]));

    // Group key: PID, or class for single_instance apps.
    let mut groups: BTreeMap<String, App> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();

    for c in clients {
        let class = if c.class.is_empty() { c.initial_class.clone() } else { c.class.clone() };
        if !c.mapped || c.pid <= 0 || c.pid == self_pid || cfg.is_ignored(&class) {
            continue;
        }
        let mon = monitors.iter().find(|m| m.id == c.monitor);
        let (mx, my) = mon.map(|m| (m.x, m.y)).unwrap_or((0, 0));
        let win = Window {
            class: class.clone(),
            title: c.title.clone(),
            workspace_id: c.workspace.id,
            workspace_name: c.workspace.name.clone(),
            monitor: mon.map(|m| m.name.clone()).unwrap_or_default(),
            at: [c.at[0] - mx, c.at[1] - my],
            size: c.size,
            floating: c.floating,
            fullscreen: c.fullscreen,
            pinned: c.pinned,
            pid: c.pid,
        };

        let single = cfg.app(&class).is_some_and(|a| a.single_instance);
        let key = if single { format!("class:{}", class.to_lowercase()) } else { format!("pid:{}", c.pid) };

        if let Some(app) = groups.get_mut(&key) {
            app.windows.push(win);
            continue;
        }

        let Some((command, source)) = resolve_command(cfg, &class, c.pid) else {
            warnings.push(format!("skipped {class} (pid {}): no cmdline (process gone?)", c.pid));
            continue;
        };
        let terminal = cfg.is_terminal(&class);
        let cwd = if terminal { procinfo::shell_child_cwd(c.pid).or_else(|| procinfo::cwd(c.pid)) } else { procinfo::cwd(c.pid) };

        order.push(key.clone());
        groups.insert(
            key,
            App {
                class,
                command,
                source: source.into(),
                cwd: cwd.map(|p| p.to_string_lossy().into_owned()),
                terminal,
                windows: vec![win],
            },
        );
    }

    let apps = order.into_iter().filter_map(|k| groups.remove(&k)).collect();
    let session = Session {
        version: FORMAT_VERSION,
        name: name.into(),
        created: chrono::Utc::now().timestamp(),
        hyprland: hypr::version(),
        apps,
    };
    Ok((session, warnings))
}

pub fn write(session: &Session) -> Result<PathBuf> {
    let path = path_for(&session.name)?;
    std::fs::create_dir_all(data_dir())?;
    // Write to a temp file then rename, so a reader (the bar, a concurrent
    // autosave) never sees a half-written file.
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(session)?)?;
    std::fs::rename(&tmp, &path)?;
    Ok(path)
}

pub fn read(name: &str) -> Result<Session> {
    let path = path_for(name)?;
    let text = std::fs::read_to_string(&path).with_context(|| format!("no session '{name}' ({})", path.display()))?;
    serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))
}

pub fn list() -> Result<Vec<Session>> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(data_dir()) else { return Ok(out) };
    for e in rd.flatten() {
        let p = e.path();
        if p.extension().is_some_and(|x| x == "json") {
            if let Ok(s) = std::fs::read_to_string(&p).map_err(anyhow::Error::from).and_then(|t| Ok(serde_json::from_str::<Session>(&t)?)) {
                out.push(s);
            }
        }
    }
    out.sort_by_key(|s| std::cmp::Reverse(s.created));
    Ok(out)
}

pub fn delete(name: &str) -> Result<()> {
    let path = path_for(name)?;
    std::fs::remove_file(&path).with_context(|| format!("no session '{name}'"))
}
