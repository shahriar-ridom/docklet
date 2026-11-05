mod config;
mod desktop;
mod hypr;
mod procinfo;
mod restore;
mod snapshot;

use anyhow::Result;
use clap::{Parser, Subcommand};
use serde_json::json;

#[derive(Parser)]
#[command(name = "hyprsess", version, about = "Save and restore Hyprland window sessions")]
struct Cli {
    /// Machine-readable JSON output (used by the Quickshell bar).
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Snapshot open windows to ~/.local/share/hyprsess/<name>.json
    Save {
        #[arg(default_value = "last")]
        name: String,
        /// Allow overwriting an existing session with an empty one
        #[arg(long)]
        allow_empty: bool,
        /// Only save one desktop: "current", a workspace id, or a name.
        /// Default: all desktops.
        #[arg(long, short)]
        workspace: Option<String>,
    },
    /// Relaunch apps from a snapshot
    Restore {
        #[arg(default_value = "last")]
        name: String,
        /// Print the hyprctl calls without launching anything
        #[arg(long, short = 'n')]
        dry_run: bool,
        /// Don't launch apps whose class already has open windows
        /// (by default everything in the session is launched)
        #[arg(long, short)]
        skip_running: bool,
        /// Also launch apps that are running in the background (tray/daemon),
        /// which usually opens their main window
        #[arg(long, short)]
        force: bool,
        /// Skip polling/fixing window placement after launch
        #[arg(long)]
        no_fixup: bool,
        #[arg(long, short)]
        verbose: bool,
    },
    /// List saved sessions (newest first)
    List,
    /// Show what a session contains
    Show {
        #[arg(default_value = "last")]
        name: String,
    },
    /// Delete a saved session
    Delete { name: String },
}

fn fmt_time(ts: i64) -> String {
    chrono::DateTime::from_timestamp(ts, 0)
        .map(|t| t.with_timezone(&chrono::Local).format("%Y-%m-%d %H:%M").to_string())
        .unwrap_or_default()
}

fn window_count(s: &snapshot::Session) -> usize {
    s.apps.iter().map(|a| a.windows.len()).sum()
}

fn run(cli: &Cli) -> Result<()> {
    match &cli.cmd {
        Cmd::Save { name, allow_empty, workspace } => {
            snapshot::validate_name(name)?;
            let cfg = config::Loaded::load()?;
            let scope = match workspace.as_deref() {
                None | Some("all") => snapshot::Scope::All,
                Some("current") => snapshot::Scope::Workspace(hypr::active_workspace()?),
                Some(w) => {
                    let found = hypr::workspaces()?.into_iter().find(|ws| ws.id.to_string() == w || ws.name == w);
                    snapshot::Scope::Workspace(found.ok_or_else(|| anyhow::anyhow!("no workspace '{w}'"))?)
                }
            };
            let (session, warnings) = snapshot::capture(&cfg, name, &scope)?;
            // Don't clobber a good snapshot with an empty one (e.g. an autosave
            // firing right after login, or during logout teardown).
            if session.apps.is_empty() && !allow_empty && snapshot::path_for(name)?.exists() {
                anyhow::bail!("no windows to save; keeping existing '{name}' (use --allow-empty to overwrite)");
            }
            let path = snapshot::write(&session)?;
            if cli.json {
                println!("{}", json!({"ok": true, "name": name, "path": path, "apps": session.apps.len(),
                    "windows": window_count(&session), "scope": session.scope, "warnings": warnings}));
            } else {
                for w in &warnings {
                    eprintln!("warning: {w}");
                }
                let what = session.scope.as_ref().map(|w| format!(" (desktop {w})")).unwrap_or_default();
                println!("saved '{name}'{what}: {} apps, {} windows → {}", session.apps.len(), window_count(&session), path.display());
            }
        }
        Cmd::Restore { name, dry_run, skip_running, force, no_fixup, verbose } => {
            let cfg = config::Loaded::load()?;
            let session = snapshot::read(name)?;
            let opts = restore::Opts { dry_run: *dry_run, skip_running: *skip_running, wake_background: *force, no_fixup: *no_fixup, verbose: *verbose };
            let rep = restore::run(&cfg, &session, &opts)?;
            if cli.json {
                println!("{}", json!({"ok": rep.errors.is_empty(), "name": name, "report": rep}));
            } else {
                let verb = if *dry_run { "would launch" } else { "launched" };
                println!("{verb} {} app(s): {}", rep.launched.len(), rep.launched.join(", "));
                for s in &rep.skipped {
                    println!("skipped {s}");
                }
                if !dry_run {
                    println!("fixed placement of {} window(s); {} never appeared", rep.fixed, rep.unplaced);
                }
                for e in &rep.errors {
                    eprintln!("error: {e}");
                }
            }
            if !rep.errors.is_empty() {
                std::process::exit(2);
            }
        }
        Cmd::List => {
            let sessions = snapshot::list()?;
            if cli.json {
                let v: Vec<_> = sessions
                    .iter()
                    .map(|s| {
                        // Distinct app classes in launch order, for the bar's icon stack.
                        let mut classes: Vec<&str> = Vec::new();
                        for a in &s.apps {
                            if !classes.iter().any(|c| c.eq_ignore_ascii_case(&a.class)) {
                                classes.push(&a.class);
                            }
                        }
                        json!({"name": s.name, "created": s.created, "apps": s.apps.len(), "windows": window_count(s),
                               "scope": s.scope, "classes": classes})
                    })
                    .collect();
                println!("{}", serde_json::to_string(&v)?);
            } else if sessions.is_empty() {
                println!("no saved sessions");
            } else {
                for s in &sessions {
                    let scope = s.scope.as_ref().map(|w| format!("desktop {w}")).unwrap_or_else(|| "all desktops".into());
                    println!("{:<20} {}  {:>3} windows  {:>3} apps  {scope}", s.name, fmt_time(s.created), window_count(s), s.apps.len());
                }
            }
        }
        Cmd::Show { name } => {
            let s = snapshot::read(name)?;
            if cli.json {
                println!("{}", serde_json::to_string_pretty(&s)?);
            } else {
                let scope = s.scope.as_ref().map(|w| format!("desktop {w}")).unwrap_or_else(|| "all desktops".into());
                println!("{} — saved {} — {scope} — {}", s.name, fmt_time(s.created), s.hyprland);
                for a in &s.apps {
                    println!("\n{} [{}]{}", a.class, a.source, if a.terminal { " (terminal)" } else { "" });
                    println!("  cmd: {}", a.command);
                    if let Some(i) = &a.inner {
                        println!("  runs: {}  (in {})", i.command, i.shell);
                    }
                    if let Some(c) = &a.cwd {
                        println!("  cwd: {c}");
                    }
                    for w in &a.windows {
                        let mode = if w.pinned { "pinned" } else if w.floating { "float" } else { "tiled" };
                        let geo = if w.floating { format!(" {}x{}+{}+{}", w.size[0], w.size[1], w.at[0], w.at[1]) } else { String::new() };
                        let t: String = w.title.chars().take(50).collect();
                        println!("  - ws {:<10} {mode}{geo}  {t}", w.workspace_selector());
                    }
                }
            }
        }
        Cmd::Delete { name } => {
            snapshot::delete(name)?;
            if cli.json {
                println!("{}", json!({"ok": true, "name": name}));
            } else {
                println!("deleted '{name}'");
            }
        }
    }
    Ok(())
}

fn main() {
    let cli = Cli::parse();
    if let Err(e) = run(&cli) {
        if cli.json {
            println!("{}", json!({"ok": false, "error": format!("{e:#}")}));
        } else {
            eprintln!("error: {e:#}");
        }
        std::process::exit(1);
    }
}
