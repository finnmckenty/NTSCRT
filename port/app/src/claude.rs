//! "Connect to Claude…" (the Mac's `ClaudeConnection.swift`): registers this
//! program's MCP server (`ntscrt.exe mcp`) with Claude Desktop (its JSON
//! config) and Claude Code (its `claude mcp` command), or removes it. Other
//! servers and settings in those configs are left alone.
//!
//! Claude Desktop on Windows keeps its config in `%APPDATA%\Claude`; the
//! Microsoft Store (MSIX) build reads a copy virtualized under
//! `%LOCALAPPDATA%\Packages\Claude_<id>\LocalCache\Roaming\Claude`. NTSCRT
//! writes every one of those that exists.
//!
//! `NTSCRT_CLAUDE_HOME` stands in for the user's folder (with AppData under
//! it) in the self-check (`NTSCRT_CONNECT_SELFTEST`), so it never touches the
//! real settings.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use ntscrt_engine::serde_json::{self, json, Map, Value};

pub const SERVER_NAME: &str = "ntscrt";
const CONFIG: &str = "claude_desktop_config.json";
const BACKUP: &str = "claude_desktop_config.json.before-ntscrt";

#[derive(Clone, Debug, PartialEq)]
pub enum Status {
    NotInstalled,
    NotConnected,
    Connected,
    /// Connected, but to an NTSCRT somewhere else.
    ConnectedElsewhere(String),
    Unreadable(String),
}

/// This program, as the command Claude runs (ntscrt.exe, not the console launcher).
pub fn executable() -> String {
    std::env::current_exe().map(|p| p.display().to_string()).unwrap_or_default()
}

fn scratch_home() -> Option<PathBuf> {
    std::env::var_os("NTSCRT_CLAUDE_HOME").map(PathBuf::from)
}

pub fn home() -> PathBuf {
    scratch_home().or_else(crate::cli::home_dir).unwrap_or_default()
}

/// %APPDATA% and %LOCALAPPDATA% (under the scratch home in the self-check).
fn roaming() -> PathBuf {
    match (scratch_home(), std::env::var_os("APPDATA")) {
        (None, Some(a)) => PathBuf::from(a),
        _ => home().join("AppData").join("Roaming"),
    }
}

fn local() -> PathBuf {
    match (scratch_home(), std::env::var_os("LOCALAPPDATA")) {
        (None, Some(a)) => PathBuf::from(a),
        _ => home().join("AppData").join("Local"),
    }
}

/// Why the app can't be connected from where it is, if it can't: a path that
/// won't last (a zip opened in Explorer runs from a temporary copy).
pub fn location_problem() -> Option<String> {
    location_problem_for(&executable())
}

pub fn location_problem_for(exe: &str) -> Option<String> {
    let lower = exe.to_lowercase().replace('/', "\\");
    let temp = std::env::temp_dir().display().to_string().to_lowercase().replace('/', "\\");
    let in_temp = (!temp.is_empty() && lower.starts_with(temp.trim_end_matches('\\'))) || lower.contains("\\appdata\\local\\temp\\");
    if in_temp || lower.contains("\\temp1_") || lower.contains(".zip\\") {
        return Some("NTSCRT is running from inside the zip file, which Windows unpacks to a temporary folder. Extract the NTSCRT folder somewhere it can stay (Documents, say), open ntscrt.exe from there, and connect again.".into());
    }
    None
}

/// Where this copy is, for the Claude Desktop extension's launcher
/// (mcpb/server/launch.cmd), which can't know where the zip was unpacked:
/// HKCU\Software\NTSCRT, Path and Version. Written each time the window
/// opens, unless this copy is in a temporary folder.
pub fn remember_location() {
    if location_problem().is_some() || scratch_home().is_some() {
        return;
    }
    #[cfg(windows)]
    unsafe {
        use windows::core::{w, PCWSTR};
        use windows::Win32::System::Registry::{RegSetKeyValueW, HKEY_CURRENT_USER, REG_SZ};
        for (name, value) in [(w!("Path"), executable()), (w!("Version"), crate::update::current_version())] {
            let wide: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
            let _ = RegSetKeyValueW(HKEY_CURRENT_USER, w!("Software\\NTSCRT"), PCWSTR(name.0), REG_SZ.0, Some(wide.as_ptr() as _), (wide.len() * 2) as u32);
        }
    }
}

// MARK: Claude Desktop

/// Claude Desktop's config folders that exist (the Store build's first).
pub fn desktop_folders() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(entries) = std::fs::read_dir(local().join("Packages")) {
        let mut packages: Vec<PathBuf> = entries
            .flatten()
            .filter(|e| {
                let n = e.file_name().to_string_lossy().to_lowercase();
                n.starts_with("claude_") || n.starts_with("anthropic.claude")
            })
            .map(|e| e.path().join("LocalCache").join("Roaming").join("Claude"))
            .filter(|p| p.is_dir())
            .collect();
        packages.sort();
        out.extend(packages);
    }
    let classic = roaming().join("Claude");
    if classic.is_dir() {
        out.push(classic);
    }
    out
}

pub fn desktop_installed() -> bool {
    if !desktop_folders().is_empty() {
        return true;
    }
    if scratch_home().is_some() {
        return false;
    }
    // Installed but never opened: no config folder yet.
    local().join("AnthropicClaude").is_dir()
        || std::fs::read_dir(local().join("Packages")).is_ok_and(|r| r.flatten().any(|e| e.file_name().to_string_lossy().to_lowercase().starts_with("claude_")))
}

/// Where to write: every config folder that exists, else the classic one.
fn desktop_targets() -> Vec<PathBuf> {
    let found = desktop_folders();
    if found.is_empty() {
        vec![roaming().join("Claude")]
    } else {
        found
    }
}

/// The config the app reads (the Store build's copy when it has one).
pub fn desktop_config() -> PathBuf {
    desktop_targets()[0].join(CONFIG)
}

/// The config as an object; empty if the file doesn't exist yet.
pub fn read_config(path: &Path) -> Result<Map<String, Value>, String> {
    let Ok(bytes) = std::fs::read(path) else { return Ok(Map::new()) };
    let text = String::from_utf8_lossy(&bytes);
    let text = text.trim_start_matches('\u{feff}');
    if text.trim().is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(m)) => Ok(m),
        _ => Err(format!("Claude Desktop's settings file isn't valid JSON, so NTSCRT left it alone: {}", path.display())),
    }
}

fn entry_status(config: &Map<String, Value>) -> Status {
    match config.get("mcpServers").and_then(|s| s.get(SERVER_NAME)).and_then(Value::as_object) {
        None => Status::NotConnected,
        Some(e) => {
            let command = e.get("command").and_then(Value::as_str).unwrap_or_default();
            if same_path(command, &executable()) {
                Status::Connected
            } else {
                Status::ConnectedElsewhere(command.to_string())
            }
        }
    }
}

fn same_path(a: &str, b: &str) -> bool {
    if cfg!(windows) {
        a.replace('/', "\\").eq_ignore_ascii_case(&b.replace('/', "\\"))
    } else {
        a == b
    }
}

pub fn desktop_status() -> Status {
    if !desktop_installed() {
        return Status::NotInstalled;
    }
    match read_config(&desktop_config()) {
        Ok(c) => entry_status(&c),
        Err(e) => Status::Unreadable(e),
    }
}

pub fn connect_desktop() -> Result<(), String> {
    if let Some(p) = location_problem() {
        return Err(p);
    }
    edit_desktop(|servers| {
        servers.insert(SERVER_NAME.into(), json!({"command": executable(), "args": ["mcp"]}));
        true
    })
}

pub fn disconnect_desktop() -> Result<(), String> {
    edit_desktop(|servers| servers.remove(SERVER_NAME).is_some())
}

/// Read every config first (refusing all of them if one is broken), then
/// back each up and write it.
fn edit_desktop(change: impl Fn(&mut Map<String, Value>) -> bool) -> Result<(), String> {
    let mut edits = Vec::new();
    for dir in desktop_targets() {
        let file = dir.join(CONFIG);
        let mut config = read_config(&file)?;
        let mut servers = config.get("mcpServers").and_then(Value::as_object).cloned().unwrap_or_default();
        if change(&mut servers) {
            config.insert("mcpServers".into(), Value::Object(servers));
            edits.push((dir, file, config));
        }
    }
    for (dir, file, config) in edits {
        std::fs::create_dir_all(&dir).map_err(|e| format!("Couldn't make {}: {e}", dir.display()))?;
        if file.exists() {
            let _ = std::fs::copy(&file, dir.join(BACKUP)).map_err(|e| format!("Couldn't back up {}: {e}", file.display()))?;
        }
        let text = serde_json::to_string_pretty(&Value::Object(config)).unwrap_or_default();
        // Atomically: a temporary file beside it, then a rename over it.
        let tmp = dir.join(format!("{CONFIG}.ntscrt-tmp"));
        std::fs::write(&tmp, text).map_err(|e| format!("Couldn't write {}: {e}", file.display()))?;
        std::fs::rename(&tmp, &file).map_err(|e| format!("Couldn't write {}: {e}", file.display()))?;
    }
    Ok(())
}

// MARK: Claude Code

/// The `claude` command, where its installers put it (an app opened from
/// Explorer may not have the terminal's PATH).
pub fn claude_cli() -> Option<PathBuf> {
    let user = crate::cli::home_dir().unwrap_or_default();
    let mut candidates = vec![user.join(".local").join("bin").join(if cfg!(windows) { "claude.exe" } else { "claude" })];
    if cfg!(windows) {
        if let Some(a) = std::env::var_os("APPDATA") {
            candidates.push(PathBuf::from(a).join("npm").join("claude.cmd"));
        }
    } else {
        candidates.extend([user.join(".claude/local/claude"), "/opt/homebrew/bin/claude".into(), "/usr/local/bin/claude".into()]);
    }
    if let Some(found) = candidates.into_iter().find(|p| p.is_file()) {
        return Some(found);
    }
    let path = std::env::var_os("PATH")?;
    let names: &[&str] = if cfg!(windows) { &["claude.exe", "claude.cmd"] } else { &["claude"] };
    std::env::split_paths(&path).flat_map(|d| names.iter().map(move |n| d.join(n))).find(|p| p.is_file())
}

/// What to type by hand.
pub fn code_command() -> String {
    format!("claude mcp add --scope user {SERVER_NAME} -- {} mcp", shell_quoted(&executable()))
}

fn shell_quoted(s: &str) -> String {
    if s.chars().all(|c| c.is_alphanumeric() || "/\\:._-".contains(c)) {
        s.to_string()
    } else if cfg!(windows) {
        format!("\"{s}\"")
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

/// Claude Code's user-scope servers live in ~/.claude.json.
pub fn code_status() -> Status {
    if claude_cli().is_none() {
        return Status::NotInstalled;
    }
    let file = home().join(".claude.json");
    match std::fs::read_to_string(file).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) {
        Some(Value::Object(o)) => entry_status(&o),
        _ => Status::NotConnected,
    }
}

pub fn connect_code() -> Result<(), String> {
    if let Some(p) = location_problem() {
        return Err(p);
    }
    let cli = claude_cli().ok_or("Claude Code's `claude` command wasn't found.")?;
    let _ = run(&cli, &["mcp", "remove", "--scope", "user", SERVER_NAME]);
    run(&cli, &["mcp", "add", "--scope", "user", SERVER_NAME, "--", &executable(), "mcp"]).map(|_| ())
}

pub fn disconnect_code() -> Result<(), String> {
    let Some(cli) = claude_cli() else { return Ok(()) };
    run(&cli, &["mcp", "remove", "--scope", "user", SERVER_NAME]).map(|_| ())
}

fn run(tool: &Path, args: &[&str]) -> Result<String, String> {
    let mut c = Command::new(tool);
    c.args(args).stdin(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let out = c.output().map_err(|e| format!("Couldn't run {}: {e}", tool.display()))?;
    let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    if !out.status.success() {
        return Err(format!("`claude mcp` failed: {}", text.trim()));
    }
    Ok(text)
}

// MARK: the self-check

/// NTSCRT_CONNECT_SELFTEST: connect and disconnect Claude Desktop in the
/// scratch home (keeping another server there), print PASS/FAIL lines on
/// stderr, and leave it connected for the window's snapshot. Returns the
/// number of failures.
pub fn self_test() -> usize {
    let Some(scratch) = scratch_home() else {
        eprintln!("CONNECT FAIL: set NTSCRT_CLAUDE_HOME to a scratch folder");
        std::process::exit(1);
    };
    let mut failures = 0;
    let mut check = |name: &str, ok: bool, detail: String| {
        eprintln!("CONNECT {} {name} {detail}", if ok { "PASS" } else { "FAIL" });
        if !ok {
            failures += 1;
        }
    };
    let support = roaming().join("Claude");
    let _ = std::fs::create_dir_all(&support);
    let config = support.join(CONFIG);
    let existing = r#"{"mcpServers":{"other":{"command":"C:\\Windows\\System32\\cmd.exe","args":["/c","echo hi"]}},"globalShortcut":"Ctrl+Space"}"#;
    let _ = std::fs::write(&config, existing);
    check("home is the scratch folder", support.starts_with(&scratch), support.display().to_string());
    check("starts not connected", desktop_status() == Status::NotConnected, format!("{:?}", desktop_status()));
    if let Err(e) = connect_desktop() {
        check("connect", false, e);
    }
    check("connected", desktop_status() == Status::Connected, format!("{:?}", desktop_status()));
    let after = read_config(&config).unwrap_or_default();
    check("kept the other server", after.get("mcpServers").and_then(|s| s.get("other")).is_some(), String::new());
    check("kept other settings", after.get("globalShortcut").and_then(Value::as_str) == Some("Ctrl+Space"), String::new());
    check("points at this program", after["mcpServers"][SERVER_NAME]["command"].as_str() == Some(executable().as_str()), executable());
    check("backed up", support.join(BACKUP).is_file(), String::new());
    if let Err(e) = disconnect_desktop() {
        check("disconnect", false, e);
    }
    check("disconnected", desktop_status() == Status::NotConnected, format!("{:?}", desktop_status()));
    check(
        "other server survives disconnect",
        read_config(&config).ok().and_then(|c| c.get("mcpServers").and_then(|s| s.get("other")).cloned()).is_some(),
        String::new(),
    );
    let _ = std::fs::write(&config, "{ not json");
    let refused = connect_desktop().is_err();
    check("leaves a broken file alone", refused && std::fs::read_to_string(&config).ok().as_deref() == Some("{ not json"), String::new());

    // The Store build: its virtualized copy gets written too.
    let store = local().join("Packages").join("Claude_pzs8sxrjxfjjc").join("LocalCache").join("Roaming").join("Claude");
    let _ = std::fs::create_dir_all(&store);
    let _ = std::fs::write(&config, existing);
    let _ = connect_desktop();
    let store_config = read_config(&store.join(CONFIG)).unwrap_or_default();
    check("Store build's config written", store_config.get("mcpServers").and_then(|s| s.get(SERVER_NAME)).is_some(), store.display().to_string());
    check("status reads the Store build's config", desktop_config().starts_with(&store) && desktop_status() == Status::Connected, format!("{:?}", desktop_status()));
    check(
        "classic config written alongside",
        read_config(&config).ok().and_then(|c| c.get("mcpServers").and_then(|s| s.get(SERVER_NAME)).cloned()).is_some(),
        String::new(),
    );
    let _ = std::fs::remove_dir_all(local().join("Packages"));

    let zip = r"C:\Users\someone\AppData\Local\Temp\Temp1_NTSCRT-0.26.4-windows-x64.zip\NTSCRT\ntscrt.exe";
    check("refuses inside a zip", location_problem_for(zip).is_some(), String::new());
    check("accepts a lasting folder", location_problem_for(r"C:\Users\someone\Documents\NTSCRT\ntscrt.exe").is_none(), String::new());
    check("this copy can connect", location_problem().is_none(), executable());

    // Connected again, for the window's snapshot.
    let _ = std::fs::write(&config, existing);
    let _ = connect_desktop();
    eprintln!("{}", if failures == 0 { "CONNECT-ALL-PASS".to_string() } else { format!("CONNECT-FAILURES {failures}") });
    failures
}
