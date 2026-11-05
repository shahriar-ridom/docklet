//! Thin wrapper around `hyprctl`. Hyprland 0.56+ uses Lua for dispatch/exec:
//!   hyprctl eval     'hl.exec_cmd("cmd", { workspace = "3 silent", float = true })'
//!   hyprctl dispatch 'hl.dsp.window.move({ x = 1, y = 2, window = "address:0x…" })'

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use std::process::Command;

#[derive(Debug, Deserialize, Clone)]
pub struct WsRef {
    pub id: i64,
    pub name: String,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Client {
    pub address: String,
    pub class: String,
    #[serde(default)]
    pub initial_class: String,
    pub title: String,
    pub workspace: WsRef,
    pub monitor: i64,
    pub at: [i32; 2],
    pub size: [i32; 2],
    pub floating: bool,
    pub fullscreen: i32,
    pub pinned: bool,
    pub pid: i32,
    #[serde(default = "yes")]
    pub mapped: bool,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Deserialize, Clone)]
pub struct Monitor {
    pub id: i64,
    pub name: String,
    pub x: i32,
    pub y: i32,
}

/// systemd user units don't inherit HYPRLAND_INSTANCE_SIGNATURE unless it was
/// imported, so fall back to the newest instance socket in $XDG_RUNTIME_DIR/hypr.
fn instance_signature() -> Option<String> {
    if let Ok(s) = std::env::var("HYPRLAND_INSTANCE_SIGNATURE") {
        return Some(s);
    }
    let rt = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| format!("/run/user/{}", current_uid()));
    let mut best: Option<(std::time::SystemTime, String)> = None;
    for e in std::fs::read_dir(format!("{rt}/hypr")).ok()?.flatten() {
        let p = e.path();
        if !p.join(".socket.sock").exists() {
            continue;
        }
        let t = e.metadata().and_then(|m| m.modified()).ok()?;
        if best.as_ref().is_none_or(|(bt, _)| t > *bt) {
            best = Some((t, e.file_name().to_string_lossy().into()));
        }
    }
    best.map(|(_, s)| s)
}

fn current_uid() -> u32 {
    // Read our uid from /proc to avoid a libc dependency.
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("Uid:"))?.split_whitespace().nth(1)?.parse().ok())
        .unwrap_or(1000)
}

fn hyprctl(args: &[&str]) -> Result<String> {
    let mut cmd = Command::new("hyprctl");
    if let Some(sig) = instance_signature() {
        cmd.env("HYPRLAND_INSTANCE_SIGNATURE", sig);
    }
    let out = cmd.args(args).output().context("running hyprctl (is Hyprland running?)")?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    // hyprctl often exits 0 even on failure; errors show up in stdout.
    if !out.status.success() || stdout.trim_start().starts_with("error") {
        bail!("hyprctl {}: {}{}", args.first().unwrap_or(&""), stdout.trim(), String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(stdout)
}

pub fn clients() -> Result<Vec<Client>> {
    let s = hyprctl(&["-j", "clients"])?;
    serde_json::from_str(&s).context("parsing hyprctl clients -j")
}

pub fn active_workspace() -> Result<WsRef> {
    let s = hyprctl(&["-j", "activeworkspace"])?;
    serde_json::from_str(&s).context("parsing hyprctl activeworkspace -j")
}

pub fn workspaces() -> Result<Vec<WsRef>> {
    let s = hyprctl(&["-j", "workspaces"])?;
    serde_json::from_str(&s).context("parsing hyprctl workspaces -j")
}

pub fn monitors() -> Result<Vec<Monitor>> {
    let s = hyprctl(&["-j", "monitors"])?;
    serde_json::from_str(&s).context("parsing hyprctl monitors -j")
}

pub fn version() -> String {
    hyprctl(&["version"])
        .ok().map(|s| s.split_whitespace().take(2).collect::<Vec<_>>().join(" "))
        .unwrap_or_default()
}

pub fn eval(lua: &str) -> Result<()> {
    hyprctl(&["eval", lua]).map(|_| ())
}

pub fn dispatch(lua: &str) -> Result<()> {
    hyprctl(&["dispatch", lua]).map(|_| ())
}

/// Quote a string as a Lua string literal.
pub fn lua_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\{}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// A Lua table literal from (key, already-rendered value) pairs.
pub fn lua_table(pairs: &[(&str, String)]) -> String {
    let body: Vec<String> = pairs.iter().map(|(k, v)| format!("{k} = {v}")).collect();
    format!("{{ {} }}", body.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lua_strings() {
        assert_eq!(lua_str(r#"cd "/a b" && x"#), r#""cd \"/a b\" && x""#);
        assert_eq!(lua_str("a\\b\nc"), r#""a\\b\nc""#);
        assert_eq!(lua_table(&[("float", "true".into()), ("workspace", lua_str("2 silent"))]),
                   r#"{ float = true, workspace = "2 silent" }"#);
    }
}
