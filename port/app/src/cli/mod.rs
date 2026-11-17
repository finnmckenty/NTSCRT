//! The command line: `ntscrt render|describe|looks|mcp|help` runs without a
//! window (the Mac's `CLI/Launch.swift`). stdout carries only the result (one
//! JSON line, or for `mcp` the protocol); everything else, the pipeline's
//! own prints included, goes to stderr. Exit 0 ok, 1 render failed, 2 bad
//! command.
//!
//! On Windows `ntscrt.exe` is a GUI-subsystem program (no console window
//! when it's double-clicked, or when Claude starts `ntscrt.exe mcp`), so its
//! output reaches whatever its standard handles are: pipes work as they are.
//! In a terminal, use `ntscrt-cli.exe` (src/bin/ntscrt-cli.rs), a console
//! program that runs `ntscrt.exe` with its own console and waits for it.

pub mod describe;
pub mod help;
pub mod mcp;
mod mcp_text;
pub mod render;
pub mod settings;

use std::io::Write;
use std::sync::{Mutex, OnceLock};

use ntscrt_engine::serde_json::{self, Value};

pub const COMMANDS: [&str; 7] = ["render", "describe", "looks", "mcp", "help", "--help", "-h"];

/// The name to type, in messages (the console launcher on Windows).
#[cfg(windows)]
pub const CLI_NAME: &str = "ntscrt-cli";
#[cfg(not(windows))]
pub const CLI_NAME: &str = "ntscrt";

/// A mistake in the command (exit 2) or a failed render (exit 1).
#[derive(Debug)]
pub struct CliError {
    pub message: String,
    pub code: i32,
}

impl CliError {
    pub fn usage(message: impl Into<String>) -> Self {
        Self { message: message.into(), code: 2 }
    }
    pub fn failed(message: impl Into<String>) -> Self {
        Self { message: message.into(), code: 1 }
    }
}

impl std::fmt::Display for CliError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

pub type CliResult<T> = Result<T, CliError>;

/// The real stdout, kept for results once fd 1 / STD_OUTPUT_HANDLE points at stderr.
static RESULT_OUT: OnceLock<Mutex<Box<dyn Write + Send>>> = OnceLock::new();

pub fn start(command: &str, args: &[String]) -> ! {
    redirect_stdout();
    let code = match command {
        "render" => render::run(args),
        "describe" => describe::run(args),
        "looks" => describe::run_looks(args),
        "mcp" => mcp::run(args),
        _ => {
            emit_text(&help::text());
            0
        }
    };
    let _ = std::io::stderr().flush();
    std::process::exit(code)
}

/// One line on the result stream.
pub fn emit_text(text: &str) {
    let mut line = text.to_string();
    if !line.ends_with('\n') {
        line.push('\n');
    }
    write_result(line.as_bytes());
}

/// Compact, sorted keys (serde_json's map is ordered), as the Mac's emitJSON.
pub fn emit_json(v: &Value) {
    emit_text(&serde_json::to_string(v).unwrap_or_else(|_| "{}".into()));
}

pub fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

pub fn write_result(bytes: &[u8]) {
    match RESULT_OUT.get() {
        Some(out) => {
            let mut out = out.lock().unwrap_or_else(|e| e.into_inner());
            let _ = out.write_all(bytes);
            let _ = out.flush();
        }
        None => {
            let mut out = std::io::stdout();
            let _ = out.write_all(bytes);
            let _ = out.flush();
        }
    }
}

pub fn log(text: &str) {
    eprintln!("{text}");
}

/// A number rounded for reading (as the Mac's CLI.decimal).
pub fn decimal(x: f64, places: i32) -> Value {
    let f = 10f64.powi(places);
    let r = (x * f).round() / f;
    if r == r.trunc() && r.abs() < 1e15 {
        Value::from(r as i64)
    } else {
        Value::from(r)
    }
}

/// Move stdout to stderr, keeping the real stdout for results.
#[cfg(windows)]
fn redirect_stdout() {
    use std::os::windows::io::FromRawHandle;
    use windows::Win32::System::Console::{AttachConsole, GetStdHandle, SetStdHandle, ATTACH_PARENT_PROCESS, STD_ERROR_HANDLE, STD_OUTPUT_HANDLE};
    unsafe {
        // Run from a terminal without the console launcher, a GUI program has
        // no standard handles: borrow the terminal's console, so the output
        // at least shows (after the prompt; ntscrt-cli waits properly).
        let missing = GetStdHandle(STD_OUTPUT_HANDLE).map_or(true, |h| h.is_invalid() || h.0.is_null());
        if missing && AttachConsole(ATTACH_PARENT_PROCESS).is_ok() {
            reopen_console();
        }
        let out = GetStdHandle(STD_OUTPUT_HANDLE).ok().filter(|h| !h.is_invalid() && !h.0.is_null());
        let err = GetStdHandle(STD_ERROR_HANDLE).ok().filter(|h| !h.is_invalid() && !h.0.is_null());
        if let Some(out) = out {
            // A File over the handle, never closed (it's the process's stdout).
            let file = std::mem::ManuallyDrop::new(std::fs::File::from_raw_handle(out.0 as _));
            let writer: Box<dyn Write + Send> = Box::new(HandleWriter(file));
            let _ = RESULT_OUT.set(Mutex::new(writer));
            if let Some(err) = err {
                let _ = SetStdHandle(STD_OUTPUT_HANDLE, err);
            }
        }
    }
}

#[cfg(windows)]
struct HandleWriter(std::mem::ManuallyDrop<std::fs::File>);

#[cfg(windows)]
impl Write for HandleWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let mut f: &std::fs::File = &self.0;
        f.write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// After AttachConsole: standard handles onto the console, where none were given.
#[cfg(windows)]
unsafe fn reopen_console() {
    use windows::core::w;
    use windows::Win32::Foundation::{GENERIC_READ, GENERIC_WRITE};
    use windows::Win32::Storage::FileSystem::{CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING};
    use windows::Win32::System::Console::{GetStdHandle, SetStdHandle, STD_ERROR_HANDLE, STD_OUTPUT_HANDLE};
    let open = || CreateFileW(w!("CONOUT$"), (GENERIC_READ | GENERIC_WRITE).0, FILE_SHARE_READ | FILE_SHARE_WRITE, None, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, None).ok();
    for which in [STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
        let missing = GetStdHandle(which).map_or(true, |h| h.is_invalid() || h.0.is_null());
        if missing {
            if let Some(h) = open() {
                let _ = SetStdHandle(which, h);
            }
        }
    }
}

#[cfg(unix)]
fn redirect_stdout() {
    use std::os::unix::io::FromRawFd;
    unsafe {
        let real = libc::dup(1);
        if real >= 0 {
            libc::dup2(2, 1);
            let file = std::fs::File::from_raw_fd(real);
            let writer: Box<dyn Write + Send> = Box::new(file);
            let _ = RESULT_OUT.set(Mutex::new(writer));
        }
    }
}

#[cfg(not(any(windows, unix)))]
fn redirect_stdout() {}

/// A path as typed: `~` expanded, and the quotes File Explorer's "Copy as
/// path" puts around it removed.
pub fn expand_path(s: &str) -> std::path::PathBuf {
    let s = s.trim();
    let s = s.strip_prefix('"').and_then(|x| x.strip_suffix('"')).unwrap_or(s);
    if let Some(rest) = s.strip_prefix("~/").or_else(|| s.strip_prefix("~\\")) {
        if let Some(home) = home_dir() {
            return home.join(rest);
        }
    }
    if s == "~" {
        if let Some(home) = home_dir() {
            return home;
        }
    }
    std::path::PathBuf::from(s)
}

pub fn home_dir() -> Option<std::path::PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(std::path::PathBuf::from)
}

/// A short random id (render jobs, scratch folders).
pub fn random_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
    h.write_u32(std::process::id());
    format!("{:016x}", h.finish())
}
