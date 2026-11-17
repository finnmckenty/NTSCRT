//! `ntscrt mcp`: a Model Context Protocol server on stdin/stdout (the Mac's
//! `MCPServer.swift`), so an AI app (Claude Desktop, Claude Code, …) can make
//! looks and render with NTSCRT. Every tool runs this same executable's
//! `render`/`describe`/`looks` as a child process: a render that fails takes
//! nothing down, and the server itself never touches the GPU.
//!
//! The instructions and guide text come from the Mac's file word for word
//! (mcp_text.rs, made by port/scripts/sync-mcp-text.py).

use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use ntscrt_engine::serde_json::{self, json, Map, Value};

use super::describe::STAGES;
use super::mcp_text::{GUIDE, INSTRUCTIONS};
use super::settings::{bool_of, number};
use super::{decimal, log, pretty, write_result, CliError, CliResult};

pub const SUPPORTED_PROTOCOLS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];

fn server_version() -> String {
    crate::update::current_version()
}

pub fn run(_args: &[String]) -> i32 {
    log(&format!("NTSCRT MCP server {} ready on stdio.", server_version()));
    let stdin = std::io::stdin();
    let mut handlers: Vec<std::thread::JoinHandle<()>> = Vec::new();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let line = line.trim_start_matches('\u{feff}');
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Value>(line) {
            Ok(Value::Object(message)) => {
                handlers.retain(|h| !h.is_finished());
                handlers.push(std::thread::spawn(move || handle(message)));
            }
            _ => send(&json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error"}})),
        }
    }
    // The client closed stdin: stop the renders, then let replies already
    // under way go out (a client may close right after its last request).
    jobs().cancel_all();
    let deadline = Instant::now() + Duration::from_secs(10);
    while handlers.iter().any(|h| !h.is_finished()) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    0
}

// MARK: JSON-RPC

fn send(message: &Value) {
    let mut line = serde_json::to_string(message).unwrap_or_default();
    line.push('\n');
    write_result(line.as_bytes());
}

fn handle(message: Map<String, Value>) {
    let id = message.get("id").cloned();
    let Some(method) = message.get("method").and_then(Value::as_str) else { return }; // a response: none expected
    let params = message.get("params").and_then(Value::as_object).cloned().unwrap_or_default();
    let reply = |result: Value| {
        if let Some(id) = &id {
            send(&json!({"jsonrpc": "2.0", "id": id, "result": result}));
        }
    };
    let fail = |code: i64, text: &str| {
        if let Some(id) = &id {
            send(&json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": text}}));
        }
    };
    match method {
        "initialize" => {
            let asked = params.get("protocolVersion").and_then(Value::as_str).unwrap_or(SUPPORTED_PROTOCOLS[0]);
            let version = if SUPPORTED_PROTOCOLS.contains(&asked) { asked } else { SUPPORTED_PROTOCOLS[0] };
            reply(json!({
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "ntscrt", "title": "NTSCRT", "version": server_version()},
                "instructions": INSTRUCTIONS,
            }));
        }
        "ping" => reply(json!({})),
        "tools/list" => reply(json!({"tools": tool_list()})),
        "tools/call" => {
            let Some(name) = params.get("name").and_then(Value::as_str) else { return fail(-32602, "tools/call needs a name") };
            let arguments = params.get("arguments").and_then(Value::as_object).cloned().unwrap_or_default();
            reply(call(name, &arguments));
        }
        m if m.starts_with("notifications/") => {}
        _ => fail(-32601, &format!("Method not found: {method}")),
    }
}

// MARK: tools

fn settings_schema() -> Value {
    json!({
        "type": "object",
        "description": "The look, keyed by stage, applied in this order: look (a built-in look name or a .json look path), crop, downscale, digital, ntsc, glitch, vcr, crt, timeline ({duration, fps} for a still), keyframes. Each stage takes \"on\"/\"off\" or an object — e.g. {\"vcr\": {\"tape\": \"Moldy\", \"deck\": \"Dirty heads\", \"values\": {\"tape_speed\": \"EP\"}}, \"crt\": {\"preset\": \"royale\", \"params\": {}}, \"digital\": {\"format\": \"minidv\"}, \"downscale\": {\"width\": 320, \"method\": \"chunky\"}, \"crop\": \"9:16\"}. To animate, add \"keyframes\": [{\"time\": 0}, {\"time\": 2, \"easing\": \"ease-in\", \"glitch\": {\"values\": {\"vertical_hold\": 0.5}}}, {\"time\": 4, \"vcr\": {\"tape\": \"Chewed\"}}] — each key is the look with those values changed at that many seconds, blending between keys (glitch, vcr, digital, ntsc and crt values only). See ntscrt_describe for every control and the keyframe rules.",
        "additionalProperties": true,
    })
}

const SNAP: &str = "Round the output size to a whole number of pixels per scanline, as the app's \"Snap size to scanline grid\": even, crisp scanlines. Use for pixel art.";

pub fn tool_list() -> Value {
    let topics: Vec<&str> = GUIDE.iter().map(|g| g.0).collect();
    json!([
        {
            "name": "ntscrt_list_looks",
            "title": "List looks",
            "description": "Named starting points: NTSCRT's built-in looks (each with a description of what it looks like and the stages it uses), the VCR's Tape and Deck conditions, Digital video formats and CRT presets.",
            "inputSchema": {"type": "object", "properties": {}},
            "annotations": {"readOnlyHint": true},
        },
        {
            "name": "ntscrt_guide",
            "title": "How to make looks",
            "description": "Read this first, once per conversation, before choosing any settings: the craft rules for NTSCRT — which stage fits which words, how strong to go, resolution and scanlines (bold scanlines need a LOW resolution), sampling and pixel art, CRT close-ups, Digital video, glitch timing, and animating still images (loops, variations). Optional topics narrow it.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "topics": {"type": "array", "items": {"type": "string", "enum": topics}, "description": "Sections to read (default: all)."},
                },
            },
            "annotations": {"readOnlyHint": true},
        },
        {
            "name": "ntscrt_describe",
            "title": "Describe controls",
            "description": "Every control of the stages asked for: id, kind (slider, toggle, choice, seed, integer), range, default, and what it does. Stages: crop, downscale, digital, ntsc, glitch, vcr, crt, output. CRT parameters depend on the preset; pass crt_preset for one other than the default (glow_gauss).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "stages": {"type": "array", "items": {"type": "string", "enum": STAGES}, "description": "Stages to describe (default: all)."},
                    "crt_preset": {"type": "string", "description": "A CRT preset id, or \"all\"."},
                },
            },
            "annotations": {"readOnlyHint": true},
        },
        {
            "name": "ntscrt_preview",
            "title": "Preview a look",
            "description": "Render a few frames of the source with the settings and return them as images, to check a look before rendering the whole video. Times are seconds into the clip (or into the video a still becomes); the VCR and Glitch stages change over time, so ask for several.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "source": {"type": "string", "description": "Absolute path of an image (PNG, JPEG, HEIC) or video (MP4, MOV)."},
                    "settings": settings_schema(),
                    "times": {"type": "array", "items": {"type": "number"}, "description": "Seconds (default [0.5, 2, 4])."},
                    "long_edge": {"type": "integer", "description": "Preview size in pixels (default 640)."},
                    "snap": {"type": "boolean", "description": SNAP},
                    "zoom": {"type": "number", "description": "Magnify like the app's preview zoomed in (1–12): a close-up of the CRT's scanlines and phosphor mask. Pair with a low downscale width."},
                    "zoom_at": {"type": "array", "items": {"type": "number"}, "description": "Where to zoom, [x, y] from 0 to 1 (default the center)."},
                },
                "required": ["source"],
            },
            "annotations": {"readOnlyHint": true},
        },
        {
            "name": "ntscrt_render",
            "title": "Render a video",
            "description": "Render the source with the settings to a file: a clip in full, or a still as a video of `duration` seconds. Waits up to wait_seconds (default 45) and returns the result, or a job id to poll with ntscrt_render_status. Renders run one at a time.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "source": {"type": "string", "description": "Absolute path of an image or video."},
                    "settings": settings_schema(),
                    "output": {"type": "string", "description": "Where to write it (.mp4, .gif or .png). Default: Videos\\NTSCRT\\<source name> <time>.mp4 in the user's folder."},
                    "format": {"type": "string", "enum": ["h264", "hevc", "gif", "png"], "description": "Default: from the output's extension, else h264. png writes full-size stills at `times`. (No ProRes on Windows.)"},
                    "zoom": {"type": "number", "description": "For png: magnify like the app's preview zoomed in (1–12), for CRT close-ups."},
                    "zoom_at": {"type": "array", "items": {"type": "number"}, "description": "For png: where to zoom, [x, y] from 0 to 1."},
                    "times": {"type": "array", "items": {"type": "number"}, "description": "For png: seconds to take a frame at, one file each (named <output> <time>s.png). Use with a varied keyframed timeline to make many alternate stills."},
                    "duration": {"type": "number", "description": "A still's video length in seconds (default 5, or the look's)."},
                    "fps": {"type": "integer", "description": "A still's frame rate (default 30)."},
                    "long_edge": {"type": "integer", "description": "Output long edge in pixels (default 1920)."},
                    "snap": {"type": "boolean", "description": SNAP},
                    "quality": {"type": "string", "enum": ["standard", "high", "very-high", "maximum"]},
                    "loops": {"type": "integer", "description": "Repeat the content this many times in the file."},
                    "gif_width": {"type": "integer"},
                    "gif_fps": {"type": "integer"},
                    "wait_seconds": {"type": "number", "description": "How long to wait for it to finish (0–100, default 45)."},
                },
                "required": ["source"],
            },
        },
        {
            "name": "ntscrt_render_status",
            "title": "Render status",
            "description": "A render's progress, time left, and — when done — its output file. Waits up to wait_seconds (default 30) for it to finish.",
            "inputSchema": {
                "type": "object",
                "properties": {"job_id": {"type": "string"}, "wait_seconds": {"type": "number"}},
                "required": ["job_id"],
            },
            "annotations": {"readOnlyHint": true},
        },
        {
            "name": "ntscrt_save_look",
            "title": "Save a look",
            "description": "Save the settings as an NTSCRT look file, which the app opens with Preset > Load….",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "settings": settings_schema(),
                    "path": {"type": "string", "description": "Where to save it (.json). Default: Videos\\NTSCRT\\Looks\\<name>.json in the user's folder."},
                    "name": {"type": "string", "description": "The look's name, for the default path."},
                    "description": {"type": "string", "description": "One line on what it looks like, kept in the file (shown as the look's tooltip in the app)."},
                },
                "required": ["settings"],
            },
        },
    ])
}

pub fn call(name: &str, a: &Map<String, Value>) -> Value {
    let r: CliResult<Value> = (|| match name {
        "ntscrt_list_looks" => Ok(text(&ChildRun::run(&["looks".into()])?.stdout)),
        "ntscrt_guide" => {
            let wanted: Option<Vec<&str>> = a.get("topics").and_then(Value::as_array).map(|l| l.iter().filter_map(Value::as_str).collect());
            let body: Vec<String> = GUIDE
                .iter()
                .filter(|g| wanted.as_ref().is_none_or(|w| w.contains(&g.0)))
                .map(|g| format!("## {}\n\n{}", g.1, g.2))
                .collect();
            Ok(text(&if body.is_empty() {
                format!("No such topic. Topics: {}.", GUIDE.iter().map(|g| g.0).collect::<Vec<_>>().join(", "))
            } else {
                body.join("\n\n")
            }))
        }
        "ntscrt_describe" => {
            let mut args = vec!["describe".to_string()];
            if let Some(l) = a.get("stages").and_then(Value::as_array) {
                args.extend(l.iter().filter_map(Value::as_str).map(str::to_string));
            }
            if let Some(p) = a.get("crt_preset").and_then(Value::as_str) {
                args.extend(["--crt".into(), p.into()]);
            }
            let r = ChildRun::run(&args)?;
            Ok(if r.status == 0 { text(&r.stdout) } else { error(&r.error_text()) })
        }
        "ntscrt_preview" => preview(a),
        "ntscrt_render" => render(a),
        "ntscrt_render_status" => {
            let Some(id) = a.get("job_id").and_then(Value::as_str) else { return Ok(error("No render with that job_id.")) };
            match jobs().status_after_wait(id, wait(a, 30.0)) {
                Some(s) => Ok(json_result(s)),
                None => Ok(error("No render with that job_id.")),
            }
        }
        "ntscrt_save_look" => save_look(a),
        _ => Ok(error(&format!("Unknown tool {name}."))),
    })();
    r.unwrap_or_else(|e| error(&e.message))
}

// MARK: tool bodies

fn preview(a: &Map<String, Value>) -> CliResult<Value> {
    let source = path(a.get("source"), "source")?;
    let times: Vec<f64> = a.get("times").and_then(Value::as_array).map(|l| l.iter().filter_map(number).collect()).unwrap_or_else(|| vec![0.5, 2.0, 4.0]);
    let long_edge = a.get("long_edge").and_then(number).unwrap_or(640.0) as i64;
    let dir = Scratch::new()?;
    let mut args = vec![
        "render".to_string(),
        source,
        "-o".into(),
        dir.path.join("preview.png").display().to_string(),
        "--time".into(),
        times.iter().map(|t| t.to_string()).collect::<Vec<_>>().join(","),
        "--long-edge".into(),
        long_edge.clamp(128, 1600).to_string(),
    ];
    args.extend(zoom_args(a));
    args.extend(settings_args(a.get("settings"), &dir.path)?);
    let r = ChildRun::run(&args)?;
    let (Some(mut result), 0) = (r.result(), r.status) else { return Ok(error(&r.error_text())) };
    let Some(outputs) = result.get("outputs").and_then(Value::as_array).cloned() else { return Ok(error(&r.error_text())) };
    let mut content = Vec::new();
    for o in outputs {
        let Some(jpeg) = o.get("path").and_then(Value::as_str).and_then(|p| jpeg_data(Path::new(p))) else { continue };
        content.push(json!({"type": "text", "text": format!("t = {} s", o.get("time").cloned().unwrap_or(Value::from(0)))}));
        content.push(json!({"type": "image", "data": base64(&jpeg), "mimeType": "image/jpeg"}));
    }
    for k in ["outputs", "plan", "elapsed"] {
        result.remove(k);
    }
    content.insert(0, json!({"type": "text", "text": pretty(&Value::Object(result))}));
    Ok(json!({"content": content}))
}

fn render(a: &Map<String, Value>) -> CliResult<Value> {
    let source = path(a.get("source"), "source")?;
    let format = a.get("format").and_then(Value::as_str).map(str::to_string);
    let output = match a.get("output").and_then(Value::as_str) {
        Some(o) => super::expand_path(o),
        None => {
            let ext = match format.as_deref() {
                Some("gif") => "gif",
                Some("png") => "png",
                _ => "mp4",
            };
            let stem = Path::new(&source).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "NTSCRT".into());
            videos_folder().join(format!("{stem} {}.{ext}", timestamp()))
        }
    };
    if !output.is_absolute() {
        return Ok(error("output must be an absolute path."));
    }
    let dir = Scratch::new()?;
    let mut args = vec!["render".to_string(), source, "-o".into(), output.display().to_string()];
    if let Some(f) = &format {
        args.extend(["--format".into(), f.clone()]);
    }
    for (key, flag) in [("long_edge", "--long-edge"), ("fps", "--fps"), ("loops", "--loops"), ("gif_width", "--gif-width"), ("gif_fps", "--gif-fps")] {
        if let Some(n) = a.get(key).and_then(number) {
            args.extend([flag.into(), (n as i64).to_string()]);
        }
    }
    if let Some(d) = a.get("duration").and_then(number) {
        args.extend(["--duration".into(), d.to_string()]);
    }
    if let Some(q) = a.get("quality").and_then(Value::as_str) {
        args.extend(["--quality".into(), q.into()]);
    }
    if let Some(times) = a.get("times").and_then(Value::as_array).map(|l| l.iter().filter_map(number).collect::<Vec<_>>()).filter(|t| !t.is_empty()) {
        args.extend(["--time".into(), times.iter().map(|t| t.to_string()).collect::<Vec<_>>().join(",")]);
    }
    args.extend(zoom_args(a));
    args.extend(settings_args(a.get("settings"), &dir.path)?);

    // Check it first (bad settings, the size and length) without the wait.
    let mut dry_args = args.clone();
    dry_args.push("--dry-run".into());
    let dry = ChildRun::run(&dry_args)?;
    if dry.status != 0 {
        return Ok(error(&dry.error_text()));
    }
    let plan = dry.result().and_then(|r| r.get("plan").cloned());
    let id = jobs().start(args, output.display().to_string(), plan, dir.keep());
    Ok(json_result(jobs().status_after_wait(&id, wait(a, 45.0)).unwrap_or_default()))
}

fn save_look(a: &Map<String, Value>) -> CliResult<Value> {
    let target = match a.get("path").and_then(Value::as_str) {
        Some(p) => super::expand_path(p),
        None => {
            let name = a.get("name").and_then(Value::as_str).unwrap_or("NTSCRT look");
            let name: String = name.chars().map(|c| if r#"/\:*?"<>|"#.contains(c) { '-' } else { c }).collect();
            videos_folder().join("Looks").join(format!("{name}.json"))
        }
    };
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent).map_err(|e| CliError::failed(format!("Couldn't make {}: {e}", parent.display())))?;
    }
    let dir = Scratch::new()?;
    let mut settings = a.get("settings").and_then(Value::as_object).cloned().unwrap_or_default();
    if let Some(d) = a.get("description").and_then(Value::as_str) {
        settings.insert("description".into(), Value::from(d));
    }
    let mut args = vec!["render".to_string(), "--save-look".into(), target.display().to_string()];
    if !settings.is_empty() {
        args.extend(settings_args(Some(&Value::Object(settings)), &dir.path)?);
    }
    let r = ChildRun::run(&args)?;
    Ok(if r.status == 0 { json_result(r.result().unwrap_or_default()) } else { error(&r.error_text()) })
}

// MARK: helpers

/// Where renders and looks go by default: the user's Videos folder (the Mac's Movies).
pub fn videos_folder() -> PathBuf {
    known_videos().unwrap_or_else(|| super::home_dir().unwrap_or_default().join(if cfg!(target_os = "macos") { "Movies" } else { "Videos" })).join("NTSCRT")
}

#[cfg(windows)]
fn known_videos() -> Option<PathBuf> {
    use windows::Win32::System::Com::CoTaskMemFree;
    use windows::Win32::UI::Shell::{FOLDERID_Videos, SHGetKnownFolderPath, KF_FLAG_DEFAULT};
    unsafe {
        let p = SHGetKnownFolderPath(&FOLDERID_Videos, KF_FLAG_DEFAULT, None).ok()?;
        let s = p.to_string().ok();
        CoTaskMemFree(Some(p.0 as _));
        s.map(PathBuf::from)
    }
}

#[cfg(not(windows))]
fn known_videos() -> Option<PathBuf> {
    None
}

/// "2026-11-16 17.42.05", local time.
fn timestamp() -> String {
    #[cfg(windows)]
    {
        let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
        format!("{:04}-{:02}-{:02} {:02}.{:02}.{:02}", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond)
    }
    #[cfg(unix)]
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&now, &mut tm);
        format!("{:04}-{:02}-{:02} {:02}.{:02}.{:02}", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec)
    }
}

fn path(v: Option<&Value>, name: &str) -> CliResult<String> {
    let Some(s) = v.and_then(Value::as_str).filter(|s| !s.trim().is_empty()) else { return Err(CliError::usage(format!("{name} is required."))) };
    let p = super::expand_path(s);
    if !p.is_absolute() {
        return Err(CliError::usage(format!("{name} must be an absolute path (got {s}).")));
    }
    Ok(p.display().to_string())
}

/// A scratch folder for one call, removed when it's done with.
struct Scratch {
    path: PathBuf,
    keep: bool,
}

impl Scratch {
    fn new() -> CliResult<Self> {
        let path = std::env::temp_dir().join("ntscrt-mcp").join(super::random_id());
        std::fs::create_dir_all(&path).map_err(|e| CliError::failed(format!("Couldn't make a scratch folder: {e}")))?;
        Ok(Self { path, keep: false })
    }
    /// Hand the folder to a render job, which removes it when it ends.
    fn keep(mut self) -> PathBuf {
        self.keep = true;
        self.path.clone()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        if !self.keep {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }
}

/// The settings as a file for `--settings @file` (command lines have a
/// length limit; a look's keyframes don't).
fn settings_args(v: Option<&Value>, dir: &Path) -> CliResult<Vec<String>> {
    let settings = match v {
        None | Some(Value::Null) => return Ok(Vec::new()),
        Some(Value::Object(d)) => d.clone(),
        Some(Value::String(s)) => match serde_json::from_str::<Value>(s) {
            Ok(Value::Object(d)) => d,
            _ => return Err(CliError::usage("settings must be a JSON object keyed by stage.")),
        },
        _ => return Err(CliError::usage("settings must be a JSON object keyed by stage.")),
    };
    if settings.is_empty() {
        return Ok(Vec::new());
    }
    let file = dir.join("settings.json");
    std::fs::write(&file, serde_json::to_string(&Value::Object(settings)).unwrap_or_default()).map_err(|e| CliError::failed(format!("Couldn't write the settings: {e}")))?;
    Ok(vec!["--settings".into(), format!("@{}", file.display())])
}

fn zoom_args(a: &Map<String, Value>) -> Vec<String> {
    let mut out = Vec::new();
    if a.get("snap").and_then(bool_of) == Some(true) {
        out.push("--snap".into());
    }
    if let Some(z) = a.get("zoom").and_then(number).filter(|z| *z > 1.0) {
        out.extend(["--zoom".into(), z.to_string()]);
    }
    if let Some(xy) = a.get("zoom_at").and_then(Value::as_array).map(|l| l.iter().filter_map(number).collect::<Vec<_>>()).filter(|xy| xy.len() == 2) {
        out.extend(["--zoom-at".into(), format!("{},{}", xy[0], xy[1])]);
    }
    out
}

fn wait(a: &Map<String, Value>, def: f64) -> f64 {
    a.get("wait_seconds").and_then(number).unwrap_or(def).clamp(0.0, 100.0)
}

fn jpeg_data(path: &Path) -> Option<Vec<u8>> {
    let img = image::open(path).ok()?.to_rgb8();
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 85).encode_image(&img).ok()?;
    Some(out)
}

fn base64(data: &[u8]) -> String {
    const ABC: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (b[0] as u32) << 16 | (b[1] as u32) << 8 | b[2] as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                s.push(ABC[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                s.push('=');
            }
        }
    }
    s
}

fn text(s: &str) -> Value {
    json!({"content": [{"type": "text", "text": s}]})
}

fn json_result(o: Map<String, Value>) -> Value {
    json!({"content": [{"type": "text", "text": pretty(&Value::Object(o.clone()))}], "structuredContent": o})
}

fn error(s: &str) -> Value {
    json!({"content": [{"type": "text", "text": s}], "isError": true})
}

// MARK: child processes

/// This executable, run as a command (`ntscrt.exe`, never the console launcher).
fn command(args: &[String]) -> CliResult<Command> {
    let exe = std::env::current_exe().map_err(|e| CliError::failed(format!("Can't find NTSCRT's program: {e}")))?;
    let mut c = Command::new(exe);
    c.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW: never a console window for a child.
        c.creation_flags(0x0800_0000);
    }
    Ok(c)
}

struct ChildRun {
    status: i32,
    stdout: String,
    stderr: String,
}

impl ChildRun {
    fn run(args: &[String]) -> CliResult<Self> {
        let out = command(args)?.output().map_err(|e| CliError::failed(format!("Couldn't run NTSCRT: {e}")))?;
        Ok(Self {
            status: out.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        })
    }

    /// The result JSON (the last line of stdout).
    fn result(&self) -> Option<Map<String, Value>> {
        let line = self.stdout.lines().rev().find(|l| !l.trim().is_empty())?;
        serde_json::from_str::<Value>(line).ok()?.as_object().cloned()
    }

    fn error_text(&self) -> String {
        if let Some(e) = self.result().and_then(|r| r.get("error").and_then(Value::as_str).map(str::to_string)) {
            return e;
        }
        let lines: Vec<&str> = self.stderr.lines().collect();
        let tail = lines[lines.len().saturating_sub(5)..].join("\n");
        if tail.trim().is_empty() {
            format!("NTSCRT exited with status {}.", self.status)
        } else {
            tail
        }
    }
}

// MARK: render jobs

struct Job {
    args: Vec<String>,
    output: String,
    plan: Option<Value>,
    cleanup: PathBuf,
    state: &'static str,
    progress: f64,
    eta: Option<f64>,
    result: Option<Map<String, Value>>,
    error: Option<String>,
    child: Option<Arc<Mutex<Child>>>,
}

impl Job {
    fn finished(&self) -> bool {
        self.state == "done" || self.state == "failed"
    }

    fn status(&self, id: &str) -> Map<String, Value> {
        let mut s = Map::new();
        s.insert("job_id".into(), Value::from(id));
        s.insert("state".into(), Value::from(self.state));
        s.insert("output".into(), Value::from(self.output.as_str()));
        if let Some(p) = &self.plan {
            s.insert("plan".into(), p.clone());
        }
        match self.state {
            "running" => {
                s.insert("progress".into(), decimal(self.progress, 2));
                if let Some(e) = self.eta {
                    s.insert("seconds_left".into(), decimal(e, 0));
                }
                s.insert("next".into(), Value::from("Call ntscrt_render_status with this job_id to wait for it."));
            }
            "queued" => {
                s.insert("next".into(), Value::from("Waiting for another render to finish; call ntscrt_render_status to wait."));
            }
            "done" => {
                if let Some(r) = &self.result {
                    for k in ["outputs", "look", "warnings"] {
                        if let Some(v) = r.get(k) {
                            s.insert(k.into(), v.clone());
                        }
                    }
                    if let Some(e) = r.get("elapsed").and_then(number) {
                        s.insert("elapsed".into(), decimal(e, 1));
                    }
                }
            }
            _ => {
                s.insert("error".into(), Value::from(self.error.clone().unwrap_or_else(|| "The render failed.".into())));
            }
        }
        s
    }
}

#[derive(Default)]
struct JobsInner {
    jobs: HashMap<String, Job>,
    /// Renders run one at a time: each uses the GPU flat out.
    queue: VecDeque<String>,
    running: Option<String>,
}

#[derive(Default)]
struct Jobs {
    inner: Mutex<JobsInner>,
    changed: Condvar,
}

fn jobs() -> &'static Arc<Jobs> {
    static JOBS: OnceLock<Arc<Jobs>> = OnceLock::new();
    JOBS.get_or_init(|| Arc::new(Jobs::default()))
}

impl Jobs {
    fn lock(&self) -> std::sync::MutexGuard<'_, JobsInner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn start(self: &Arc<Self>, args: Vec<String>, output: String, plan: Option<Value>, cleanup: PathBuf) -> String {
        let id = super::random_id()[..8].to_string();
        let mut g = self.lock();
        g.jobs.insert(
            id.clone(),
            Job { args, output, plan, cleanup, state: "queued", progress: 0.0, eta: None, result: None, error: None, child: None },
        );
        g.queue.push_back(id.clone());
        drop(g);
        self.next();
        id
    }

    fn next(self: &Arc<Self>) {
        let mut g = self.lock();
        if g.running.is_some() {
            return;
        }
        let Some(id) = g.queue.pop_front() else { return };
        g.running = Some(id.clone());
        drop(g);
        let me = self.clone();
        std::thread::spawn(move || {
            me.run(&id);
            me.lock().running = None;
            me.next();
        });
    }

    fn run(self: &Arc<Self>, id: &str) {
        let args = {
            let mut g = self.lock();
            let Some(j) = g.jobs.get_mut(id) else { return };
            j.state = "running";
            j.args.clone()
        };
        let spawned = command(&args).and_then(|mut c| c.spawn().map_err(|e| CliError::failed(format!("Couldn't run NTSCRT: {e}"))));
        let mut child = match spawned {
            Ok(c) => c,
            Err(e) => return self.finish(id, -1, String::new(), e.message),
        };
        let mut out = child.stdout.take().expect("piped");
        let err = child.stderr.take().expect("piped");
        let child = Arc::new(Mutex::new(child));
        if let Some(j) = self.lock().jobs.get_mut(id) {
            j.child = Some(child.clone());
        }
        let stdout = std::thread::spawn(move || {
            let mut s = String::new();
            let _ = out.read_to_string(&mut s);
            s
        });
        let me = self.clone();
        let job_id = id.to_string();
        let stderr = std::thread::spawn(move || {
            let mut all = String::new();
            for line in std::io::BufReader::new(err).lines().map_while(Result::ok) {
                if line.starts_with("{\"eta\"") || line.starts_with("{\"progress\"") {
                    if let Ok(Value::Object(o)) = serde_json::from_str::<Value>(&line) {
                        if let Some(j) = me.lock().jobs.get_mut(&job_id) {
                            if let Some(p) = o.get("progress").and_then(number) {
                                j.progress = p;
                            }
                            if let Some(e) = o.get("eta").and_then(number) {
                                j.eta = Some(e);
                            }
                        }
                    }
                }
                all.push_str(&line);
                all.push('\n');
            }
            all
        });
        // Poll, so cancel_all can kill it meanwhile.
        let status = loop {
            if let Ok(Some(s)) = child.lock().unwrap_or_else(|e| e.into_inner()).try_wait() {
                break s.code().unwrap_or(-1);
            }
            std::thread::sleep(Duration::from_millis(100));
        };
        let stdout = stdout.join().unwrap_or_default();
        let stderr = stderr.join().unwrap_or_default();
        self.finish(id, status, stdout, stderr);
    }

    fn finish(&self, id: &str, status: i32, stdout: String, stderr: String) {
        let child = ChildRun { status, stdout, stderr };
        let mut g = self.lock();
        if let Some(j) = g.jobs.get_mut(id) {
            let _ = std::fs::remove_dir_all(&j.cleanup);
            j.child = None;
            match (status, child.result()) {
                (0, Some(r)) => {
                    j.result = Some(r);
                    j.progress = 1.0;
                    j.state = "done";
                }
                _ => {
                    j.error = Some(child.error_text());
                    j.state = "failed";
                }
            }
        }
        drop(g);
        self.changed.notify_all();
    }

    /// The job's status once it finishes, or after `seconds`.
    fn status_after_wait(&self, id: &str, seconds: f64) -> Option<Map<String, Value>> {
        let deadline = Instant::now() + Duration::from_secs_f64(seconds);
        let mut g = self.lock();
        loop {
            let job = g.jobs.get(id)?;
            let now = Instant::now();
            if job.finished() || now >= deadline {
                return Some(job.status(id));
            }
            g = self.changed.wait_timeout(g, deadline - now).unwrap_or_else(|e| e.into_inner()).0;
        }
    }

    fn cancel_all(&self) {
        let g = self.lock();
        for j in g.jobs.values() {
            if let Some(c) = &j.child {
                let _ = c.lock().unwrap_or_else(|e| e.into_inner()).kill();
            }
        }
    }
}
