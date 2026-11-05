//! Reading process info from /proc. Everything here is best-effort: processes
//! can exit between `hyprctl clients` and our read, so errors become `None`.

use std::fs;
use std::path::{Path, PathBuf};

const SHELLS: &[&str] = &[
    "bash", "zsh", "fish", "sh", "dash", "nu", "ksh", "mksh", "tcsh", "xonsh", "elvish", "oil", "ion",
];

pub fn cmdline(pid: i32) -> Option<Vec<String>> {
    let raw = fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let args: Vec<String> = raw
        .split(|b| *b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect();
    // Electron/Chromium apps often rewrite argv into one space-joined string
    // (setproctitle). If argv[0] isn't a real path but its first word is, split it.
    if args.len() == 1 && args[0].contains(' ') && !Path::new(&args[0]).exists() {
        let parts: Vec<String> = args[0].split_whitespace().map(String::from).collect();
        return Some(parts);
    }
    (!args.is_empty()).then_some(args)
}

pub fn cwd(pid: i32) -> Option<PathBuf> {
    fs::read_link(format!("/proc/{pid}/cwd")).ok()
}

pub fn exe(pid: i32) -> Option<PathBuf> {
    fs::read_link(format!("/proc/{pid}/exe")).ok()
}

pub fn comm(pid: i32) -> Option<String> {
    fs::read_to_string(format!("/proc/{pid}/comm")).ok().map(|s| s.trim().to_string())
}

pub fn environ_var(pid: i32, key: &str) -> Option<String> {
    let raw = fs::read(format!("/proc/{pid}/environ")).ok()?;
    let prefix = format!("{key}=");
    raw.split(|b| *b == 0)
        .map(String::from_utf8_lossy)
        .find_map(|kv| kv.strip_prefix(&prefix).map(str::to_string))
}

/// Direct children, collected from every thread's `children` file
/// (a child is listed under the thread that forked it, not always the main one).
pub fn children(pid: i32) -> Vec<i32> {
    let mut out = Vec::new();
    if let Ok(tasks) = fs::read_dir(format!("/proc/{pid}/task")) {
        for t in tasks.flatten() {
            if let Ok(s) = fs::read_to_string(t.path().join("children")) {
                out.extend(s.split_whitespace().filter_map(|p| p.parse::<i32>().ok()));
            }
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

/// For terminals: the cwd of the first shell found under the terminal (BFS, depth ≤ 3).
/// Lowest PID wins, which is usually the first tab.
pub fn shell_child_cwd(pid: i32) -> Option<PathBuf> {
    cwd(shell_child(pid)?)
}

/// `/proc/<pid>/stat` fields after the `(comm)` part (comm may contain spaces/parens).
fn stat_fields(pid: i32) -> Option<Vec<String>> {
    parse_stat(&fs::read_to_string(format!("/proc/{pid}/stat")).ok()?)
}

fn parse_stat(s: &str) -> Option<Vec<String>> {
    let rest = s.get(s.rfind(')')? + 2..)?;
    Some(rest.split_whitespace().map(String::from).collect())
}

/// The process running in the foreground of a shell's terminal, if it isn't
/// the shell itself: the leader of the terminal's foreground process group.
pub fn foreground_of(shell: i32) -> Option<i32> {
    let f = stat_fields(shell)?;
    // After comm: state(0) ppid(1) pgrp(2) session(3) tty_nr(4) tpgid(5)
    let pgrp: i32 = f.get(2)?.parse().ok()?;
    let tpgid: i32 = f.get(5)?.parse().ok()?;
    if tpgid <= 0 || tpgid == pgrp {
        return None;
    }
    // The group leader may have exited while the group lives on.
    Path::new(&format!("/proc/{tpgid}")).exists().then_some(tpgid)
}

/// PID of the first shell found under `pid` (BFS, depth ≤ 3, lowest PID first).
pub fn shell_child(pid: i32) -> Option<i32> {
    let mut frontier = vec![pid];
    for _ in 0..3 {
        let mut next = Vec::new();
        for p in frontier {
            for c in children(p) {
                let is_shell = comm(c)
                    .map(|n| SHELLS.contains(&n.trim_start_matches('-')))
                    .unwrap_or(false);
                if is_shell {
                    return Some(c);
                }
                next.push(c);
            }
        }
        frontier = next;
    }
    None
}

/// Flatpak sandboxes expose their metadata at /proc/<pid>/root/.flatpak-info.
pub fn flatpak_app_id(pid: i32) -> Option<String> {
    let info = fs::read_to_string(format!("/proc/{pid}/root/.flatpak-info")).ok()?;
    let mut in_app = false;
    for line in info.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_app = line == "[Application]";
        } else if in_app
            && let Some(v) = line.strip_prefix("name=") {
                return Some(v.to_string());
            }
    }
    None
}

/// True if the binary lives somewhere that won't exist after a reboot
/// (AppImage FUSE mounts, deleted executables, tmp dirs).
pub fn exe_is_ephemeral(pid: i32) -> bool {
    match exe(pid) {
        Some(p) => {
            let s = p.to_string_lossy();
            s.starts_with("/tmp/") || s.contains("/.mount_") || s.ends_with(" (deleted)") || !Path::new(&*s).exists()
        }
        None => true,
    }
}

/// Executables that run someone else's code: their name says nothing about
/// which app it is, so such processes are matched on the full command line.
pub fn is_interpreter(name: &str) -> bool {
    const GENERIC: &[&str] = &["sh", "bash", "zsh", "dash", "env", "bwrap", "java", "node", "electron", "perl", "ruby", "gjs", "wine", "wine64"];
    GENERIC.contains(&name)
        || ["python", "electron", "wine", "java", "ld-linux"].iter().any(|p| name.starts_with(p))
}

/// Name an app's processes are recognised by: the executable's file name,
/// without the " (deleted)" suffix an updated binary gets.
pub fn exe_name(pid: i32) -> Option<String> {
    let p = exe(pid)?;
    let n = p.file_name()?.to_string_lossy().into_owned();
    Some(n.trim_end_matches(" (deleted)").to_string())
}

pub struct Proc {
    pub pid: i32,
    pub exe_name: String,
    pub comm: String,
    pub argv: Vec<String>,
    pub flatpak: Option<String>,
}

/// Every live process of the current user. Zombies and kernel threads (no
/// readable exe) are left out. `with_flatpak` also reads each process's
/// Flatpak app id (an extra file read per process, so only when needed).
pub fn processes(with_flatpak: bool) -> Vec<Proc> {
    use std::os::unix::fs::MetadataExt;
    let uid = fs::metadata("/proc/self").map(|m| m.uid()).ok();
    let mut out = Vec::new();
    let Ok(rd) = fs::read_dir("/proc") else { return out };
    for e in rd.flatten() {
        let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else { continue };
        if e.metadata().map(|m| Some(m.uid()) != uid).unwrap_or(true) {
            continue;
        }
        let Some(exe_name) = exe_name(pid) else { continue };
        let Some(argv) = cmdline(pid) else { continue };
        out.push(Proc { pid, comm: comm(pid).unwrap_or_default(), flatpak: if with_flatpak { flatpak_app_id(pid) } else { None }, exe_name, argv });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stat_with_tricky_comm() {
        // comm "(a) b)" contains spaces and parens; fields start after the last ')'.
        let f = parse_stat("123 ((a) b)) S 1 123 123 34817 4567 4194304").unwrap();
        assert_eq!(f[0], "S");
        assert_eq!(f[2], "123"); // pgrp
        assert_eq!(f[5], "4567"); // tpgid
        assert!(parse_stat("garbage").is_none());
    }

    #[test]
    fn interpreters() {
        for n in ["python3.13", "node", "electron36", "java", "bwrap"] {
            assert!(is_interpreter(n), "{n}");
        }
        for n in ["thunar", "zen-bin", "Discord", "kitty"] {
            assert!(!is_interpreter(n), "{n}");
        }
    }
}
