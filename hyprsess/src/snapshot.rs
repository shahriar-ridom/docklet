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
    /// Workspace name this session was limited to; None = all desktops.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    pub apps: Vec<App>,
}

/// Which windows `capture` takes.
pub enum Scope {
    All,
    Workspace(hypr::WsRef),
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
    /// Executable name of the window's process at save time (e.g. "thunar",
    /// "Discord"), used on restore to spot the app running in the background.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub process: Option<String>,
    /// Terminals only: the program that was running inside it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inner: Option<Inner>,
    pub windows: Vec<Window>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Inner {
    /// Program name, for display (e.g. "claude", "nvim").
    pub name: String,
    /// Shell command run inside the terminal.
    pub command: String,
    /// The terminal's shell, re-entered when the program exits.
    pub shell: String,
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
    // Windows owned by a background service (thunar --daemon, GApplication
    // services): rerunning that cmdline opens no window, so use the launcher.
    if argv.iter().skip(1).any(|a| a == "--daemon" || a == "--gapplication-service")
        && let Some(exec) = desktop::exec_for_class(class) {
            return Some((exec, "desktop"));
        }
    Some((argv.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" "), "cmdline"))
}

/// Claude Code writes `<config>/sessions/<pid>.json` with its conversation id,
/// so a running `claude` can be brought back with `claude --resume <id>`.
fn claude_resume(pid: i32) -> Option<String> {
    let dir = procinfo::environ_var(pid, "CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".claude"));
    let text = std::fs::read_to_string(dir.join(format!("sessions/{pid}.json"))).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    if v.get("pid").and_then(|p| p.as_i64()) != Some(pid as i64) {
        return None;
    }
    let id = v.get("sessionId")?.as_str()?;
    Some(format!("claude --resume {}", shell_quote(id)))
}

/// What's running in the foreground of a terminal's shell, if anything.
fn terminal_inner(cfg: &Loaded, term_pid: i32) -> Option<(Inner, Option<PathBuf>)> {
    let shell = procinfo::shell_child(term_pid)?;
    let fg = procinfo::foreground_of(shell)?;
    let shell_path = procinfo::exe(shell)?.to_string_lossy().into_owned();
    let argv = procinfo::cmdline(fg)?;
    let name = std::path::Path::new(&argv[0]).file_name()?.to_string_lossy().into_owned();
    let (name, command) = match claude_resume(fg) {
        Some(cmd) => ("claude".to_string(), cmd),
        None => (name, argv.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" ")),
    };
    if cfg.is_program_ignored(&name) {
        return None;
    }
    Some((Inner { name, command, shell: shell_path }, procinfo::cwd(fg)))
}

pub fn capture(cfg: &Loaded, name: &str, scope: &Scope) -> Result<(Session, Vec<String>)> {
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
        if let Scope::Workspace(ws) = scope
            && (c.workspace.id != ws.id || c.workspace.name != ws.name) {
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
        let mut cwd = if terminal { procinfo::shell_child_cwd(c.pid).or_else(|| procinfo::cwd(c.pid)) } else { procinfo::cwd(c.pid) };
        let mut inner = None;
        if terminal && cfg.cfg.terminal_programs
            && let Some((i, icwd)) = terminal_inner(cfg, c.pid) {
                inner = Some(i);
                cwd = icwd.or(cwd);
            }

        order.push(key.clone());
        groups.insert(
            key,
            App {
                class,
                command,
                source: source.into(),
                process: procinfo::exe_name(c.pid),
                cwd: cwd.map(|p| p.to_string_lossy().into_owned()),
                terminal,
                inner,
                windows: vec![win],
            },
        );
    }

    let mut apps: Vec<App> = order.into_iter().filter_map(|k| groups.remove(&k)).collect();
    for a in &mut apps {
        // A single-instance terminal (one PID, many windows): we can't tell
        // which window the program ran in, so don't guess.
        if a.windows.len() > 1 && a.inner.take().is_some() {
            warnings.push(format!("{}: several windows share one process; not saving the programs inside them", a.class));
        }
    }
    let session = Session {
        version: FORMAT_VERSION,
        name: name.into(),
        created: chrono::Utc::now().timestamp(),
        hyprland: hypr::version(),
        scope: match scope {
            Scope::All => None,
            Scope::Workspace(ws) => Some(ws.name.clone()),
        },
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
        if p.extension().is_some_and(|x| x == "json")
            && let Ok(s) = std::fs::read_to_string(&p).map_err(anyhow::Error::from).and_then(|t| Ok(serde_json::from_str::<Session>(&t)?)) {
                out.push(s);
            }
    }
    out.sort_by_key(|s| std::cmp::Reverse(s.created));
    Ok(out)
}

pub fn delete(name: &str) -> Result<()> {
    let path = path_for(name)?;
    std::fs::remove_file(&path).with_context(|| format!("no session '{name}'"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("kitty"), "kitty");
        assert_eq!(shell_quote("/opt/a b"), "'/opt/a b'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(shell_quote(""), "''");
    }

    #[test]
    fn names() {
        assert!(validate_name("desktop-1").is_ok());
        assert!(validate_name("work.v2").is_ok());
        for bad in ["", ".hidden", "a/b", "../x", "with space", &"x".repeat(65)] {
            assert!(validate_name(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn workspace_selectors() {
        let w = |id: i64, name: &str| Window {
            class: String::new(), title: String::new(), workspace_id: id, workspace_name: name.into(),
            monitor: String::new(), at: [0, 0], size: [0, 0], floating: false, fullscreen: 0, pinned: false, pid: 0,
        };
        assert_eq!(w(3, "3").workspace_selector(), "3");
        assert_eq!(w(-98, "special:scratchpad").workspace_selector(), "special:scratchpad");
        assert_eq!(w(7, "code").workspace_selector(), "name:code");
    }

    #[test]
    fn old_session_files_still_parse() {
        // Format before scope/inner/process existed.
        let old = r#"{"version":1,"name":"x","created":1,"hyprland":"h","apps":[
            {"class":"kitty","command":"kitty","source":"cmdline","cwd":null,"terminal":true,"windows":[]}]}"#;
        let s: Session = serde_json::from_str(old).unwrap();
        assert!(s.scope.is_none() && s.apps[0].inner.is_none() && s.apps[0].process.is_none());
    }
}
