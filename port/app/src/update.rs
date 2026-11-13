//! Checking for a newer release: GitHub's latest release against this
//! build's version, at most once a day at launch (unless turned off) and
//! whenever asked. A newer one is offered with its notes and a link to the
//! release page; nothing is downloaded or installed here.
//!
//! The version is stamped at build time (`NTSCRT_VERSION`, from the git tag
//! in CI); a build without one ("dev") doesn't check on its own.
//!
//! Test hooks: `NTSCRT_UPDATE_URL` (another feed: a URL or a JSON file in
//! GitHub's release format), `NTSCRT_UPDATE_VERSION` (pretend to be this
//! version), `NTSCRT_UPDATE_CHECK=0` (never check at launch).

use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use ntscrt_engine::serde_json::{self, json, Value};

const FEED: &str = "https://api.github.com/repos/finnmckenty/NTSCRT/releases/latest";
/// How long after a check the next one at launch waits.
const CHECK_EVERY: Duration = Duration::from_secs(24 * 60 * 60);

/// This build's version: the release's ("0.23.0"), a git describe string
/// for builds between releases ("0.22.1-3-gf1f92f1"), or "dev".
pub fn current_version() -> String {
    std::env::var("NTSCRT_UPDATE_VERSION").ok().or(option_env!("NTSCRT_VERSION").map(str::to_owned)).unwrap_or_else(|| "dev".into())
}

/// The release a version string belongs to: "v0.22.1", "0.22.1" and
/// "0.22.1-3-gf1f92f1" are all (0, 22, 1); "dev" is none.
pub fn parse_version(s: &str) -> Option<(u32, u32, u32)> {
    let s = s.trim().trim_start_matches('v');
    let core = s.split(['-', '+', ' ']).next()?;
    let mut parts = core.split('.').map(|p| p.parse::<u32>().ok());
    let v = (parts.next()??, parts.next().flatten().unwrap_or(0), parts.next().flatten().unwrap_or(0));
    Some(v)
}

#[derive(Clone, Debug, PartialEq)]
pub struct Release {
    /// As tagged, without the "v": "0.23.0".
    pub version: String,
    /// The release's page, where the downloads are.
    pub page: String,
    /// Its notes (GitHub's Markdown, lightly tidied for plain text).
    pub notes: String,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Newer(Release),
    UpToDate { latest: String },
    Failed(String),
}

/// Ask the feed for the latest release and compare it with `current`.
pub fn check(current: &str) -> Outcome {
    match fetch().and_then(|v| release_from(&v)) {
        Ok(r) => compare(current, r),
        Err(e) => Outcome::Failed(format!("{e:#}")),
    }
}

fn compare(current: &str, latest: Release) -> Outcome {
    match (parse_version(&latest.version), parse_version(current)) {
        (Some(l), Some(c)) if l > c => Outcome::Newer(latest),
        (Some(_), Some(_)) => Outcome::UpToDate { latest: latest.version },
        // A build without a version: anything released is worth knowing about.
        (Some(_), None) => Outcome::Newer(latest),
        (None, _) => Outcome::Failed(format!("the latest release's version ({}) isn't one this can read", latest.version)),
    }
}

fn fetch() -> Result<Value> {
    let feed = std::env::var("NTSCRT_UPDATE_URL").unwrap_or_else(|_| FEED.into());
    if !feed.starts_with("http") {
        let text = std::fs::read_to_string(&feed).with_context(|| format!("reading {feed}"))?;
        return Ok(serde_json::from_str(&text)?);
    }
    let tls = native_tls::TlsConnector::new().context("setting up a secure connection")?;
    let agent = ureq::AgentBuilder::new().tls_connector(std::sync::Arc::new(tls)).timeout(Duration::from_secs(15)).build();
    let body = agent
        .get(&feed)
        .set("Accept", "application/vnd.github+json")
        .set("User-Agent", &format!("NTSCRT/{} (Windows)", current_version()))
        .call()
        .map_err(|e| match e {
            ureq::Error::Status(code, _) => anyhow!("GitHub answered {code}"),
            e => anyhow!("couldn't reach GitHub ({e})"),
        })?
        .into_string()?;
    Ok(serde_json::from_str(&body)?)
}

fn release_from(v: &Value) -> Result<Release> {
    let tag = v["tag_name"].as_str().context("no version in GitHub's answer")?;
    Ok(Release {
        version: tag.trim_start_matches('v').to_owned(),
        page: v["html_url"].as_str().unwrap_or("https://github.com/finnmckenty/NTSCRT/releases/latest").to_owned(),
        notes: plain_notes(v["body"].as_str().unwrap_or("")),
    })
}

/// GitHub's Markdown as plain text: headings and emphasis marks dropped,
/// list bullets kept as "•".
fn plain_notes(md: &str) -> String {
    md.replace("\r\n", "\n")
        .lines()
        .map(|line| {
            let indent = line.len() - line.trim_start().len();
            let t = line.trim_start();
            let t = t.trim_start_matches('#').trim_start();
            let (bullet, t) = match t.strip_prefix("- ").or_else(|| t.strip_prefix("* ")) {
                Some(rest) => ("• ", rest),
                None => ("", t),
            };
            format!("{}{bullet}{}", " ".repeat(indent), t.replace("**", "").replace('`', ""))
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_owned()
}

/// What's remembered between runs.
#[derive(Clone, Debug, PartialEq)]
pub struct Prefs {
    pub automatic: bool,
    /// Seconds since 1970 of the last check that got an answer.
    pub last_check: u64,
    /// A version the user chose to skip: it isn't offered again at launch.
    pub skipped: Option<String>,
}

impl Default for Prefs {
    fn default() -> Self {
        Self { automatic: true, last_check: 0, skipped: None }
    }
}

fn prefs_path() -> Option<PathBuf> {
    let base = std::env::var_os("APPDATA").map(PathBuf::from).or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("NTSCRT").join("updates.json"))
}

impl Prefs {
    pub fn load() -> Self {
        let Some(v) = prefs_path().and_then(|p| std::fs::read_to_string(p).ok()).and_then(|t| serde_json::from_str::<Value>(&t).ok()) else {
            return Self::default();
        };
        Self {
            automatic: v["automatic"].as_bool().unwrap_or(true),
            last_check: v["last_check"].as_u64().unwrap_or(0),
            skipped: v["skipped"].as_str().map(str::to_owned),
        }
    }

    pub fn save(&self) {
        let Some(path) = prefs_path() else { return };
        let v = json!({ "automatic": self.automatic, "last_check": self.last_check, "skipped": self.skipped });
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(path, serde_json::to_string_pretty(&v).unwrap_or_default());
    }

    /// Whether a launch now should check.
    pub fn due(&self, now: u64) -> bool {
        self.automatic && now.saturating_sub(self.last_check) >= CHECK_EVERY.as_secs()
    }
}

pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

/// Open the release page in the default browser.
pub fn open_page(url: &str) {
    #[cfg(windows)]
    let _ = std::process::Command::new("rundll32").args(["url.dll,FileProtocolHandler", url]).spawn();
    #[cfg(target_os = "macos")]
    let _ = std::process::Command::new("open").arg(url).spawn();
    #[cfg(not(any(windows, target_os = "macos")))]
    let _ = url;
}

/// The check as the window sees it: what's remembered, a check under way,
/// and what's being shown.
pub struct Updates {
    pub prefs: Prefs,
    current: String,
    pending: Option<(bool, std::sync::mpsc::Receiver<Outcome>)>,
    /// An answer on screen, and whether it was asked for.
    shown: Option<(Outcome, bool)>,
}

impl Updates {
    /// `scripted`: a run driven by test hooks (snapshots, exports), which
    /// mustn't reach the network or pop a window on its own.
    pub fn new(ctx: &eframe::egui::Context, scripted: bool) -> Self {
        let mut u = Self { prefs: Prefs::load(), current: current_version(), pending: None, shown: None };
        let testing = std::env::var_os("NTSCRT_UPDATE_URL").is_some();
        let allowed = std::env::var("NTSCRT_UPDATE_CHECK").as_deref() != Ok("0") && (!scripted || testing);
        if allowed && (testing || parse_version(&u.current).is_some() && u.prefs.due(now())) {
            u.start(ctx, false);
        }
        u
    }

    fn start(&mut self, ctx: &eframe::egui::Context, manual: bool) {
        if self.pending.is_some() {
            return;
        }
        let (tx, rx) = std::sync::mpsc::channel();
        let current = self.current.clone();
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let _ = tx.send(check(&current));
            ctx.request_repaint();
        });
        self.pending = Some((manual, rx));
    }

    /// The Help menu's items.
    pub fn menu(&mut self, ui: &mut eframe::egui::Ui) {
        let checking = self.pending.is_some();
        if ui.add_enabled(!checking, eframe::egui::Button::new(if checking { "Checking for updates…" } else { "Check for Updates…" })).clicked() {
            self.start(ui.ctx(), true);
            ui.close();
        }
        if ui.checkbox(&mut self.prefs.automatic, "Check for updates automatically").on_hover_text("Once a day, when NTSCRT opens. It only asks GitHub for the latest version.").changed() {
            self.prefs.save();
        }
        ui.separator();
        if ui.button(format!("NTSCRT {} on GitHub", self.current)).clicked() {
            open_page("https://github.com/finnmckenty/NTSCRT/releases");
            ui.close();
        }
    }

    /// Take in an answer and show it.
    pub fn show(&mut self, ctx: &eframe::egui::Context) {
        if let Some((manual, rx)) = &self.pending {
            if let Ok(outcome) = rx.try_recv() {
                let manual = *manual;
                self.pending = None;
                if !matches!(outcome, Outcome::Failed(_)) {
                    self.prefs.last_check = now();
                    self.prefs.save();
                }
                let skipped = matches!(&outcome, Outcome::Newer(r) if self.prefs.skipped.as_deref() == Some(r.version.as_str()));
                // At launch, only a newer release not skipped is worth a window.
                if manual || matches!(outcome, Outcome::Newer(_)) && !skipped {
                    self.shown = Some((outcome, manual));
                }
            }
        }
        let Some((outcome, _)) = self.shown.clone() else { return };
        use eframe::egui;
        let mut close = false;
        let title = if matches!(outcome, Outcome::Newer(_)) { "Update available" } else { "Check for updates" };
        egui::Window::new(title).collapsible(false).resizable(false).anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0]).show(ctx, |ui| {
            ui.set_max_width(460.0);
            match &outcome {
                Outcome::Newer(r) => {
                    ui.heading(format!("NTSCRT {} is available", r.version));
                    ui.label(format!("You have {}. Download it from the release page and replace this copy.", self.current));
                    if !r.notes.is_empty() {
                        ui.add_space(6.0);
                        egui::Frame::group(ui.style()).show(ui, |ui| {
                            egui::ScrollArea::vertical().max_height(220.0).show(ui, |ui| {
                                ui.set_min_width(430.0);
                                ui.label(&r.notes);
                            });
                        });
                    }
                    ui.add_space(6.0);
                    ui.horizontal(|ui| {
                        if ui.button("Download…").on_hover_text("Open the release page in your browser").clicked() {
                            open_page(&r.page);
                            close = true;
                        }
                        if ui.button("Skip This Version").clicked() {
                            self.prefs.skipped = Some(r.version.clone());
                            self.prefs.save();
                            close = true;
                        }
                        if ui.button("Later").clicked() {
                            close = true;
                        }
                    });
                }
                Outcome::UpToDate { latest } => {
                    if parse_version(&self.current).is_some_and(|c| Some(c) == parse_version(latest)) && !self.current.contains('-') {
                        ui.label(format!("You're up to date: NTSCRT {} is the latest version.", self.current));
                    } else {
                        ui.label(format!("You're up to date. This build is {}; the latest release is {latest}.", self.current));
                    }
                    if ui.button("OK").clicked() {
                        close = true;
                    }
                }
                Outcome::Failed(e) => {
                    ui.label(format!("Couldn't check for updates: {e}."));
                    ui.label("Check your internet connection, or see the releases on GitHub.");
                    ui.horizontal(|ui| {
                        if ui.button("Open GitHub").clicked() {
                            open_page("https://github.com/finnmckenty/NTSCRT/releases");
                            close = true;
                        }
                        if ui.button("OK").clicked() {
                            close = true;
                        }
                    });
                }
            }
            ui.add_space(4.0);
            if ui.checkbox(&mut self.prefs.automatic, "Check for updates automatically").changed() {
                self.prefs.save();
            }
        });
        if close {
            self.shown = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_read_from_tags_and_describe_strings() {
        assert_eq!(parse_version("v0.22.1"), Some((0, 22, 1)));
        assert_eq!(parse_version("0.22.1-3-gf1f92f1-dirty"), Some((0, 22, 1)));
        assert_eq!(parse_version("1.0"), Some((1, 0, 0)));
        assert_eq!(parse_version("dev"), None);
        assert_eq!(parse_version("f1f92f1"), None);
    }

    fn release(v: &str) -> Release {
        Release { version: v.into(), page: "p".into(), notes: String::new() }
    }

    #[test]
    fn only_a_newer_release_is_offered() {
        assert_eq!(compare("0.22.1", release("0.23.0")), Outcome::Newer(release("0.23.0")));
        assert_eq!(compare("0.22.1", release("0.22.10")), Outcome::Newer(release("0.22.10")));
        assert_eq!(compare("0.22.1", release("0.22.1")), Outcome::UpToDate { latest: "0.22.1".into() });
        // Built after 0.22.1 but not released yet: still 0.22.1.
        assert_eq!(compare("0.22.1-2-gabc", release("0.22.1")), Outcome::UpToDate { latest: "0.22.1".into() });
        assert_eq!(compare("0.23.0", release("0.22.1")), Outcome::UpToDate { latest: "0.22.1".into() });
    }

    #[test]
    fn githubs_answer_becomes_a_release_with_plain_notes() {
        let v = json!({
            "tag_name": "v0.23.0",
            "html_url": "https://github.com/finnmckenty/NTSCRT/releases/tag/v0.23.0",
            "body": "## Windows preview\r\n\r\n- **Smoother playback.** Uses `ntscrt.exe`.\r\n  - nested"
        });
        let r = release_from(&v).unwrap();
        assert_eq!(r.version, "0.23.0");
        assert_eq!(r.notes, "Windows preview\n\n• Smoother playback. Uses ntscrt.exe.\n  • nested");
    }

    #[test]
    fn a_launch_checks_once_a_day_unless_turned_off() {
        let p = Prefs { automatic: true, last_check: 1_000_000, skipped: None };
        assert!(!p.due(1_000_000 + 3600));
        assert!(p.due(1_000_000 + 24 * 3600));
        assert!(!Prefs { automatic: false, ..p }.due(u64::MAX));
    }
}
