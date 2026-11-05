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
    let mut frontier = vec![pid];
    for _ in 0..3 {
        let mut next = Vec::new();
        for p in frontier {
            for c in children(p) {
                let is_shell = comm(c)
                    .map(|n| SHELLS.contains(&n.trim_start_matches('-')))
                    .unwrap_or(false);
                if is_shell {
                    return cwd(c);
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
        } else if in_app {
            if let Some(v) = line.strip_prefix("name=") {
                return Some(v.to_string());
            }
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
