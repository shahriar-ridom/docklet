//! ~/.config/hyprsess/config.toml (all fields optional).

use anyhow::{Context, Result};
use regex::Regex;
use serde::Deserialize;
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Pause between launches, ms.
    pub launch_delay_ms: u64,
    /// After launching, poll clients and fix workspace/float/size/position.
    pub fixup: bool,
    /// How long to keep polling for windows after the last launch, ms.
    pub fixup_timeout_ms: u64,
    /// Classes treated as terminals (cwd taken from the shell child).
    pub terminals: Vec<String>,
    /// Extra ignore patterns (regex, case-insensitive, matched against the full class).
    pub ignore: Vec<String>,
    /// Per-class settings, keyed by window class (case-insensitive).
    pub apps: HashMap<String, AppOverride>,
}

#[derive(Debug, Default, Deserialize, Clone)]
#[serde(default)]
pub struct AppOverride {
    /// Shell command used on restore instead of the detected cmdline.
    pub command: Option<String>,
    /// Delay after launching this app, ms (replaces launch_delay_ms).
    pub delay_ms: Option<u64>,
    /// Never save this class.
    pub ignore: bool,
    /// Launch once per class even if windows had different PIDs.
    pub single_instance: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            launch_delay_ms: 400,
            fixup: true,
            fixup_timeout_ms: 20_000,
            terminals: ["kitty", "foot", "footclient", "alacritty", "org.wezfurlong.wezterm", "wezterm", "ghostty", "com.mitchellh.ghostty"]
                .map(String::from)
                .to_vec(),
            ignore: Vec::new(),
            apps: HashMap::new(),
        }
    }
}

/// Built-in ignore list: shells, portals, auth agents. Anchored, case-insensitive.
const BUILTIN_IGNORE: &[&str] = &[
    "",
    "quickshell",
    "org\\.quickshell.*",
    "noctalia.*",
    "hyprland-share-picker",
    "hyprpolkitagent",
    "xdg-desktop-portal.*",
    "org\\.kde\\.polkit-kde-authentication-agent-1",
    "polkit-gnome-authentication-agent-1",
    "fcitx.*",
];

pub fn config_path() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".config"));
    base.join("hyprsess/config.toml")
}

pub struct Loaded {
    pub cfg: Config,
    ignore: Vec<Regex>,
    apps_lc: HashMap<String, AppOverride>,
}

impl Loaded {
    pub fn load() -> Result<Self> {
        let path = config_path();
        let cfg: Config = if path.exists() {
            let text = std::fs::read_to_string(&path)?;
            toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))?
        } else {
            Config::default()
        };
        let ignore = BUILTIN_IGNORE
            .iter()
            .map(|s| s.to_string())
            .chain(cfg.ignore.iter().cloned())
            .map(|p| Regex::new(&format!("(?i)^(?:{p})$")).with_context(|| format!("bad ignore regex: {p}")))
            .collect::<Result<Vec<_>>>()?;
        let apps_lc = cfg.apps.iter().map(|(k, v)| (k.to_lowercase(), v.clone())).collect();
        Ok(Self { cfg, ignore, apps_lc })
    }

    pub fn app(&self, class: &str) -> Option<&AppOverride> {
        self.apps_lc.get(&class.to_lowercase())
    }

    pub fn is_ignored(&self, class: &str) -> bool {
        self.app(class).is_some_and(|a| a.ignore) || self.ignore.iter().any(|r| r.is_match(class))
    }

    pub fn is_terminal(&self, class: &str) -> bool {
        self.cfg.terminals.iter().any(|t| t.eq_ignore_ascii_case(class))
    }

    pub fn delay_for(&self, class: &str) -> u64 {
        self.app(class).and_then(|a| a.delay_ms).unwrap_or(self.cfg.launch_delay_ms)
    }
}
