//! Minimal .desktop lookup, used only as a fallback when a process's cmdline
//! won't survive a reboot (AppImage mounts etc.).

use std::env;
use std::fs;
use std::path::PathBuf;

fn app_dirs() -> Vec<PathBuf> {
    let home = env::var("HOME").unwrap_or_default();
    let data_home = env::var("XDG_DATA_HOME").unwrap_or_else(|_| format!("{home}/.local/share"));
    let data_dirs = env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
    std::iter::once(data_home)
        .chain(data_dirs.split(':').map(String::from))
        .chain([
            format!("{home}/.local/share/flatpak/exports/share"),
            "/var/lib/flatpak/exports/share".into(),
        ])
        .map(|d| PathBuf::from(d).join("applications"))
        .collect()
}

struct Entry {
    stem: String,
    name: String,
    wm_class: String,
    exec: String,
}

fn parse(path: &PathBuf) -> Option<Entry> {
    let text = fs::read_to_string(path).ok()?;
    let mut in_main = false;
    let (mut name, mut wm_class, mut exec) = (String::new(), String::new(), String::new());
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_main = line == "[Desktop Entry]";
            continue;
        }
        if !in_main {
            continue;
        }
        if let Some(v) = line.strip_prefix("Name=") {
            name = v.into();
        } else if let Some(v) = line.strip_prefix("StartupWMClass=") {
            wm_class = v.into();
        } else if let Some(v) = line.strip_prefix("Exec=") {
            exec = v.into();
        }
    }
    (!exec.is_empty()).then(|| Entry {
        stem: path.file_stem().unwrap_or_default().to_string_lossy().into(),
        name,
        wm_class,
        exec,
    })
}

/// Strip desktop-entry field codes (%U, %f, ...) so the Exec line is runnable as-is.
fn clean_exec(exec: &str) -> String {
    let mut out = String::new();
    let mut chars = exec.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '%' {
            match chars.next() {
                Some('%') => out.push('%'),
                _ => {} // drop the field code
            }
        } else {
            out.push(c);
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Find an Exec line for a window class. Priority: StartupWMClass, file stem, Name.
pub fn exec_for_class(class: &str) -> Option<String> {
    let cls = class.to_lowercase();
    let mut best: Option<(u8, String)> = None;
    for dir in app_dirs() {
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for f in rd.flatten() {
            let p = f.path();
            if p.extension().is_none_or(|e| e != "desktop") {
                continue;
            }
            let Some(e) = parse(&p) else { continue };
            let score = if e.wm_class.to_lowercase() == cls {
                3
            } else if e.stem.to_lowercase() == cls {
                2
            } else if e.name.to_lowercase() == cls {
                1
            } else {
                continue;
            };
            if best.as_ref().is_none_or(|(s, _)| score > *s) {
                best = Some((score, clean_exec(&e.exec)));
            }
        }
    }
    best.map(|(_, e)| e)
}
