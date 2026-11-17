//! `ntscrt render <source> -o <file> [options]`: the Export button, from the
//! command line (the Mac's `RenderCommand.swift`). It builds the app without
//! a window, loads the source, applies the look and runs the Export window's
//! own job (`App::export_job` → `export::run`), so a command-line render is
//! what the button would have written.

use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use ntscrt_engine::glitch::params::{self as gp, Group, Kind, VcrCondition, DECKS, DECK_KEYS, TAPES, TAPE_KEYS};
use ntscrt_engine::serde_json::{self, json, Map, Value};
use ntscrt_engine::CRT_SHADERS;
use ntscrt_media::Codec;

use super::settings::{self as ls, is_off, is_on, LookSettings};
use super::{decimal, emit_json, log, CliError, CliResult, CLI_NAME};
use crate::{export, App};

#[derive(Default)]
pub struct Request {
    pub source: Option<String>,
    pub output: Option<String>,
    pub settings: Map<String, Value>,
    pub format: Option<String>,
    pub long_edge: Option<u32>,
    pub gif_width: Option<u32>,
    pub gif_fps: Option<u32>,
    pub quality: Option<String>,
    pub snap: bool,
    pub loops: Option<u32>,
    /// PNG: the frames to take, in seconds.
    pub times: Vec<f64>,
    pub save_look: Option<String>,
    pub dry_run: bool,
    /// PNG: magnify like the preview zoomed in (1–12×), at this point.
    pub zoom: f64,
    pub zoom_at: (f64, f64),
}

pub fn run(args: &[String]) -> i32 {
    let started = Instant::now();
    match parse(args).and_then(|r| render(&r)) {
        Ok(mut out) => {
            out.insert("ok".into(), Value::Bool(true));
            out.insert("elapsed".into(), decimal(started.elapsed().as_secs_f64(), 1));
            emit_json(&Value::Object(out));
            0
        }
        Err(e) => {
            emit_json(&json!({"ok": false, "error": e.message}));
            log(&format!("NTSCRT: {}", e.message));
            e.code
        }
    }
}

// MARK: parsing

pub fn parse(args: &[String]) -> CliResult<Request> {
    let mut r = Request { zoom: 1.0, zoom_at: (0.5, 0.5), ..Default::default() };
    let mut flags: Map<String, Value> = Map::new();
    fn stage<'a>(flags: &'a mut Map<String, Value>, key: &str) -> &'a mut Map<String, Value> {
        let e = flags.entry(key.to_string()).or_insert_with(|| Value::Object(Map::new()));
        if !e.is_object() {
            *e = Value::Object(Map::new());
        }
        e.as_object_mut().expect("object")
    }
    fn set(flags: &mut Map<String, Value>, key: &str, field: &str, v: Value) {
        stage(flags, key).insert(field.to_string(), v);
    }
    fn merge(flags: &mut Map<String, Value>, key: &str, field: &str, pairs: &str) -> CliResult<()> {
        let kv = key_values(pairs)?;
        let d = stage(flags, key);
        let e = d.entry(field.to_string()).or_insert_with(|| Value::Object(Map::new()));
        if let Some(m) = e.as_object_mut() {
            for (k, v) in kv {
                m.insert(k, v);
            }
        }
        Ok(())
    }
    /// "on" / "off" for a stage's switch, else (for digital and crt) a format or preset.
    fn switch_or_name(flags: &mut Map<String, Value>, key: &str, raw: &str, name_field: Option<&str>) -> CliResult<()> {
        if is_on(raw) || is_off(raw) {
            set(flags, key, "enabled", Value::Bool(is_on(raw)));
        } else if let Some(f) = name_field {
            set(flags, key, f, Value::from(raw));
        } else {
            return Err(CliError::usage(format!("--{key} takes on or off.")));
        }
        Ok(())
    }
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        let mut value = || -> CliResult<String> {
            i += 1;
            args.get(i).cloned().ok_or_else(|| CliError::usage(format!("{a} needs a value.")))
        };
        match a {
            "-o" | "--out" | "--output" => r.output = Some(value()?),
            "--settings" => r.settings = parse_settings_json(&value()?)?,
            "--look" => {
                flags.insert("look".into(), Value::from(value()?));
            }
            "--crop" => {
                flags.insert("crop".into(), Value::from(value()?));
            }
            "--downscale" => {
                let v = value()?;
                if is_off(&v) || is_on(&v) {
                    set(&mut flags, "downscale", "enabled", Value::Bool(is_on(&v)));
                } else if let Ok(w) = v.parse::<f64>() {
                    set(&mut flags, "downscale", "width", Value::from(w));
                } else {
                    return Err(CliError::usage("--downscale takes a width in pixels, or off."));
                }
            }
            "--downscale-method" => set(&mut flags, "downscale", "method", Value::from(value()?)),
            "--digital" => switch_or_name(&mut flags, "digital", &value()?, Some("format"))?,
            "--digital-set" => merge(&mut flags, "digital", "values", &value()?)?,
            "--ntsc" => switch_or_name(&mut flags, "ntsc", &value()?, None)?,
            "--ntsc-set" => merge(&mut flags, "ntsc", "settings", &value()?)?,
            "--glitch" => switch_or_name(&mut flags, "glitch", &value()?, None)?,
            "--glitch-set" => merge(&mut flags, "glitch", "values", &value()?)?,
            "--vcr" => switch_or_name(&mut flags, "vcr", &value()?, None)?,
            "--vcr-set" => merge(&mut flags, "vcr", "values", &value()?)?,
            "--tape" => set(&mut flags, "vcr", "tape", Value::from(value()?)),
            "--deck" => set(&mut flags, "vcr", "deck", Value::from(value()?)),
            "--crt" => switch_or_name(&mut flags, "crt", &value()?, Some("preset"))?,
            "--crt-set" => merge(&mut flags, "crt", "params", &value()?)?,
            "--duration" => {
                let d: f64 = value()?.parse().map_err(|_| CliError::usage("--duration takes seconds."))?;
                set(&mut flags, "timeline", "duration", Value::from(d));
            }
            "--fps" => {
                let f: f64 = value()?.parse().map_err(|_| CliError::usage("--fps takes a number."))?;
                set(&mut flags, "timeline", "fps", Value::from(f));
            }
            "--format" => r.format = Some(value()?.to_lowercase()),
            "--long-edge" | "--size" => r.long_edge = Some(whole(&value()?, a)?),
            "--gif-width" => r.gif_width = Some(whole(&value()?, a)?),
            "--gif-fps" => r.gif_fps = Some(whole(&value()?, a)?),
            "--quality" => r.quality = Some(value()?.to_lowercase()),
            "--snap" => r.snap = true,
            "--loops" => r.loops = Some(whole(&value()?, a)?),
            "--time" | "--times" | "--at" => {
                r.times = value()?
                    .split(',')
                    .map(|t| t.trim().parse::<f64>().ok().filter(|t| *t >= 0.0).ok_or_else(|| CliError::usage("--time takes seconds, e.g. 0,1.5,3.")))
                    .collect::<CliResult<_>>()?;
            }
            "--save-look" => r.save_look = Some(value()?),
            "--zoom" => {
                let z = value()?.parse::<f64>().ok().filter(|z| *z >= 1.0).ok_or_else(|| CliError::usage("--zoom takes a magnification from 1 to 12."))?;
                r.zoom = z.min(12.0);
            }
            "--zoom-at" => {
                let xy: Vec<f64> = value()?.split(',').filter_map(|x| x.trim().parse().ok()).collect();
                if xy.len() != 2 {
                    return Err(CliError::usage("--zoom-at takes x,y from 0 to 1 (0.5,0.5 is the center)."));
                }
                r.zoom_at = (xy[0].clamp(0.0, 1.0), xy[1].clamp(0.0, 1.0));
            }
            "--dry-run" => r.dry_run = true,
            _ => {
                if a.starts_with('-') {
                    return Err(CliError::usage(format!("Unknown option {a}. Run `{CLI_NAME} help`.")));
                }
                if let Some(s) = &r.source {
                    return Err(CliError::usage(format!("One source at a time (got {s} and {a}).")));
                }
                r.source = Some(a.to_string());
            }
        }
        i += 1;
    }
    // Flags win over --settings, stage by stage.
    for (k, v) in flags {
        match (r.settings.get_mut(&k).and_then(Value::as_object_mut), v.as_object()) {
            (Some(base), Some(add)) => {
                for (field, fv) in add {
                    match (base.get_mut(field).and_then(Value::as_object_mut), fv.as_object()) {
                        (Some(inner), Some(add_inner)) => {
                            for (ik, iv) in add_inner {
                                inner.insert(ik.clone(), iv.clone());
                            }
                        }
                        _ => {
                            base.insert(field.clone(), fv.clone());
                        }
                    }
                }
            }
            _ => {
                r.settings.insert(k, v);
            }
        }
    }
    if r.output.is_none() && r.save_look.is_none() && !r.dry_run {
        return Err(CliError::usage("Say where to write it: -o <file> (.mp4, .gif or .png), or --save-look <file.json>."));
    }
    if r.source.is_none() && (r.output.is_some() || r.dry_run) {
        return Err(CliError::usage(format!("Give a source image or video: {CLI_NAME} render <file> -o <out>.")));
    }
    Ok(r)
}

pub fn parse_settings_json(raw: &str) -> CliResult<Map<String, Value>> {
    let mut text = raw.to_string();
    if raw.starts_with('@') || !raw.trim_start().starts_with('{') {
        let path = super::expand_path(raw.strip_prefix('@').unwrap_or(raw));
        text = std::fs::read_to_string(&path).map_err(|_| CliError::usage(format!("--settings: no such file {}.", path.display())))?;
    }
    // A file saved by Notepad may start with a byte-order mark.
    let text = text.trim_start_matches('\u{feff}');
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(m)) => Ok(m),
        _ => Err(CliError::usage("--settings isn't a JSON object.")),
    }
}

/// "a=1,b=on,tape_speed=EP" → typed values.
pub fn key_values(s: &str) -> CliResult<Vec<(String, Value)>> {
    s.split(',')
        .map(|pair| {
            let (k, raw) = pair.split_once('=').map(|(k, v)| (k.trim(), v.trim())).ok_or_else(|| CliError::usage(format!("Expected key=value, got \"{pair}\".")))?;
            if k.is_empty() {
                return Err(CliError::usage(format!("Expected key=value, got \"{pair}\".")));
            }
            let v = if let Ok(d) = raw.parse::<f64>() {
                Value::from(d)
            } else if raw.eq_ignore_ascii_case("true") || raw.eq_ignore_ascii_case("on") {
                Value::Bool(true)
            } else if raw.eq_ignore_ascii_case("false") || raw.eq_ignore_ascii_case("off") {
                Value::Bool(false)
            } else {
                Value::from(raw)
            };
            Ok((k.to_string(), v))
        })
        .collect()
}

fn whole(s: &str, flag: &str) -> CliResult<u32> {
    s.parse::<u32>().ok().filter(|n| *n > 0).ok_or_else(|| CliError::usage(format!("{flag} takes a whole number.")))
}

// MARK: rendering

pub const QUALITIES: [(&str, usize); 5] = [("standard", 0), ("high", 1), ("very-high", 2), ("veryhigh", 2), ("maximum", 3)];

fn format_of(key: &str) -> CliResult<Option<export::Format>> {
    Ok(Some(match key {
        "h264" | "mp4" => export::Format::Mp4(Codec::H264),
        "hevc" | "h265" => export::Format::Mp4(Codec::Hevc),
        "gif" => export::Format::Gif,
        "png" => export::Format::Png,
        "prores" | "prores422" | "prores-hq" | "prores422hq" | "mov" => {
            return Err(CliError::usage("ProRes isn't available on Windows: write an .mp4 (H.264, or --format hevc), a .gif or .png."));
        }
        _ => return Ok(None),
    }))
}

pub fn render(r: &Request) -> CliResult<Map<String, Value>> {
    let mut app = App::headless();
    if let Some(source) = &r.source {
        ls::load_source(&mut app, source)?;
    }
    let mut looks = LookSettings::default();
    looks.apply(&r.settings, &mut app)?;
    for w in &looks.warnings {
        log(&format!("warning: {w}"));
    }
    let mut result = Map::new();
    result.insert("look".into(), summary(&mut app));
    if !looks.warnings.is_empty() {
        result.insert("warnings".into(), json!(looks.warnings));
    }

    if let Some(path) = &r.save_look {
        let path = super::expand_path(path);
        if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
            let _ = std::fs::create_dir_all(dir);
        }
        app.error = None;
        app.save_look(&path);
        if let Some(e) = app.error.take() {
            return Err(CliError::failed(format!("Couldn't save the look: {e}")));
        }
        result.insert("savedLook".into(), Value::from(absolute(&path).display().to_string()));
    }
    let out_path = match (&r.output, r.dry_run) {
        (Some(o), _) => absolute(&super::expand_path(o)),
        (None, true) => std::env::temp_dir().join("ntscrt-dry-run.mp4"),
        (None, false) => return Ok(result),
    };
    let ext = out_path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    let format = match &r.format {
        Some(f) => format_of(f)?.ok_or_else(|| CliError::usage(format!("--format is h264, hevc, gif or png (got {f}).")))?,
        None => format_of(&ext)?.ok_or_else(|| {
            CliError::usage(format!(
                "Can't tell the format from \"{}\": use .mp4, .gif or .png, or --format h264|hevc|gif|png.",
                out_path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
            ))
        })?,
    };
    app.export_format = format;
    if let Some(n) = r.long_edge {
        app.export_long_edge = n.clamp(64, 8192);
    }
    if let Some(n) = r.gif_width {
        app.gif_width = n.clamp(64, 2048);
    }
    if let Some(n) = r.gif_fps {
        app.gif_fps = n.clamp(1, 50);
    }
    if let Some(q) = &r.quality {
        let Some((_, i)) = QUALITIES.iter().find(|(n, _)| n == q) else {
            return Err(CliError::usage("--quality is standard, high, very-high or maximum."));
        };
        app.export_quality = *i;
    }
    app.export_snap = r.snap;
    if let Some(n) = r.loops {
        app.export_loops = n.min(100) as usize;
    }
    if format == export::Format::Png {
        let times = if r.times.is_empty() { vec![0.0] } else { r.times.clone() };
        return render_pngs(&mut app, &out_path, &times, r.zoom, r.zoom_at, r.dry_run, result);
    }

    let size = app.export_size().ok_or_else(|| CliError::failed("The source isn't loaded."))?;
    let (frames, fps) = movie_frames(&app);
    let vcr = app.glitch_values.vcr();
    let passes = 1 + app.glitch_values.get("tape_generation").round() as i64;
    let route = match (format, app.video.is_some()) {
        (export::Format::Gif, _) => "gif",
        (_, true) => "clip",
        _ => "still",
    };
    result.insert(
        "plan".into(),
        json!({
            "route": route,
            "format": match format { export::Format::Mp4(Codec::Hevc) => "HEVC", export::Format::Gif => "GIF", _ => "H.264" },
            "width": size.0, "height": size.1, "frames": frames, "fps": decimal(fps, 3),
            "seconds": decimal(frames as f64 / fps.max(1.0), 2),
            "vcrPasses": if vcr { passes } else { 0 },
        }),
    );
    if r.dry_run {
        return Ok(result);
    }
    if let Some(dir) = out_path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let job = app.export_job(format, out_path.clone(), size).ok_or_else(|| CliError::failed("The source isn't loaded."))?;
    run_job(job, true)?;
    result.insert("outputs".into(), json!([output(&out_path, size, Some((frames, fps)), None)]));
    Ok(result)
}

/// Frames and frame rate the export writes (as `export::run` counts them).
fn movie_frames(app: &App) -> (usize, f64) {
    match (app.export_format, app.video) {
        (export::Format::Gif, Some(v)) => ((((v.total_frames as f64 / v.timescale()) * app.gif_fps as f64).round() as usize).max(1), app.gif_fps as f64),
        (export::Format::Gif, None) => (((app.timeline_seconds * app.gif_fps as f64).round() as usize).max(1), app.gif_fps as f64),
        (_, Some(v)) => (v.total_frames * app.export_loops.max(1), v.fps_rational.0 as f64 / v.fps_rational.1.max(1) as f64),
        (_, None) => (((app.timeline_seconds * app.timeline_fps as f64).round() as usize).max(1), app.timeline_fps as f64),
    }
}

/// Run an export job on its own thread, reporting progress on stderr.
fn run_job(job: export::Job, report: bool) -> CliResult<String> {
    let progress = Arc::new(export::Progress::default());
    let p = progress.clone();
    let worker = std::thread::spawn(move || export::run(job, p).map_err(|e| format!("{e:#}")));
    let mut reporter = ProgressReporter::new();
    while !worker.is_finished() {
        std::thread::sleep(Duration::from_millis(100));
        if report {
            reporter.report(progress.done.load(Ordering::Relaxed) as f64 / 1000.0);
        }
    }
    let r = worker.join().map_err(|_| CliError::failed("The render crashed."))?;
    if report {
        reporter.report(1.0);
    }
    r.map_err(|e| CliError::failed(format!("The render failed: {e}")))
}

fn output(path: &Path, size: (u32, u32), frames: Option<(usize, f64)>, time: Option<f64>) -> Value {
    let mut o = Map::new();
    o.insert("path".into(), Value::from(path.display().to_string()));
    o.insert("width".into(), Value::from(size.0));
    o.insert("height".into(), Value::from(size.1));
    o.insert("bytes".into(), Value::from(std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)));
    if let Some((n, fps)) = frames {
        o.insert("frames".into(), Value::from(n));
        o.insert("seconds".into(), decimal(n as f64 / fps.max(1.0), 2));
        o.insert("fps".into(), decimal(fps, 3));
    }
    if let Some(t) = time {
        o.insert("time".into(), decimal(t, 3));
    }
    Value::Object(o)
}

fn absolute(p: &Path) -> PathBuf {
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        std::env::current_dir().map(|d| d.join(p)).unwrap_or_else(|_| p.to_path_buf())
    }
}

/// Stills of the look at the given times. History counts — clogs build up,
/// the tracking hunts, creases pass — so each is the frame the export would
/// have at that time, simulated up to it.
fn render_pngs(app: &mut App, url: &Path, times: &[f64], zoom: f64, zoom_at: (f64, f64), dry_run: bool, mut result: Map<String, Value>) -> CliResult<Map<String, Value>> {
    let size = app.export_size().ok_or_else(|| CliError::failed("The source isn't loaded."))?;
    result.insert("plan".into(), json!({"route": "png", "width": size.0, "height": size.1, "times": times.iter().map(|t| decimal(*t, 3)).collect::<Vec<_>>()}));
    if dry_run {
        return Ok(result);
    }
    if let Some(dir) = url.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let stem = url.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "frame".into());
    let mut outputs = Vec::new();
    for (n, &t) in times.iter().enumerate() {
        let file = if times.len() == 1 { url.to_path_buf() } else { url.with_file_name(format!("{stem} {t:.2}s.png")) };
        let at = seek(app, t);
        let job = app.export_job(export::Format::Png, file.clone(), size).ok_or_else(|| CliError::failed("The source isn't loaded."))?;
        run_job(job, false).map_err(|e| CliError::failed(format!("Rendering the frame at {t} s failed: {}", e.message)))?;
        if zoom > 1.001 {
            magnify(&file, zoom, zoom_at)?;
        }
        outputs.push(output(&file, size, None, Some(at)));
        ProgressReporter::line((n + 1) as f64 / times.len() as f64, None);
    }
    result.insert("outputs".into(), Value::Array(outputs));
    Ok(result)
}

/// Put the playhead at `t` seconds; returns the time it landed on.
fn seek(app: &mut App, t: f64) -> f64 {
    if let Some(v) = app.video {
        let fps = v.fps.max(1.0);
        let frame = ((t * fps).round().max(0.0) as usize).min(v.total_frames.saturating_sub(1));
        if app.timeline_open {
            let last = v.total_frames.saturating_sub(1);
            app.scrub(if last > 0 { frame as f64 / last as f64 } else { 0.0 });
        } else {
            app.video_frame = frame;
        }
        return frame as f64 / fps;
    }
    // A still: its time runs on the timeline (keyframes, if the look has
    // any, are spread over the timeline's length).
    if app.keys.is_empty() && t > app.timeline_seconds {
        app.timeline_seconds = t;
    }
    app.timeline_open = true;
    let total = app.timeline_frames();
    let fps = app.timeline_fps.max(1) as f64;
    let frame = ((t * fps).round().max(0.0) as usize).min(total.saturating_sub(1));
    app.scrub(if total > 1 { frame as f64 / (total - 1) as f64 } else { 0.0 });
    app.frame = frame + 1;
    frame as f64 / fps
}

/// The preview zoomed in, as Export viewport saves it: the CRT render cut to
/// 1/zoom around the point and enlarged pixel for pixel.
fn magnify(file: &Path, zoom: f64, at: (f64, f64)) -> CliResult<()> {
    let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let img = image::open(file).map_err(|_| CliError::failed(format!("Couldn't reopen {name} to zoom it.")))?.to_rgba8();
    let (w, h) = img.dimensions();
    let cw = ((w as f64 / zoom).round() as u32).max(1);
    let ch = ((h as f64 / zoom).round() as u32).max(1);
    let x0 = ((at.0 * w as f64) as i64 - cw as i64 / 2).clamp(0, (w - cw) as i64) as u32;
    let y0 = ((at.1 * h as f64) as i64 - ch as i64 / 2).clamp(0, (h - ch) as i64) as u32;
    let cut = image::imageops::crop_imm(&img, x0, y0, cw, ch).to_image();
    let out = image::imageops::resize(&cut, w, h, image::imageops::FilterType::Nearest);
    out.save(file).map_err(|e| CliError::failed(format!("Couldn't zoom {name}: {e}")))
}

/// Progress lines on stderr: {"progress":0.42,"eta":12.5}, a few a second.
struct ProgressReporter {
    start: Instant,
    last: Option<Instant>,
    finished: bool,
}

impl ProgressReporter {
    fn new() -> Self {
        Self { start: Instant::now(), last: None, finished: false }
    }

    fn report(&mut self, p: f64) {
        let now = Instant::now();
        if self.finished || !(self.last.is_none_or(|l| now - l > Duration::from_millis(250)) || p >= 1.0) {
            return;
        }
        self.last = Some(now);
        self.finished = p >= 1.0;
        let elapsed = (now - self.start).as_secs_f64();
        Self::line(p, (p > 0.02).then(|| elapsed / p * (1.0 - p)));
    }

    fn line(p: f64, eta: Option<f64>) {
        let mut m = Map::new();
        m.insert("progress".into(), decimal(p, 3));
        if let Some(e) = eta {
            m.insert("eta".into(), decimal(e, 1));
        }
        eprintln!("{}", Value::Object(m));
    }
}

// MARK: the look summary

/// What a look does, in the panels' words — so a caller can check it got
/// what it asked for.
pub fn summary(app: &mut App) -> Value {
    let mut out = Map::new();
    out.insert("crop".into(), Value::from(if app.crop_enabled { app.crop.ratio.label() } else { "off".into() }));
    let digital = if app.digital_enabled {
        ntscrt_engine::codec::DigitalFormat::matching(&app.digital_values, app.downscale_width as usize).map_or("custom", |f| f.name)
    } else {
        "off"
    };
    out.insert("digital".into(), Value::from(digital));
    out.insert("ntsc".into(), Value::from(if app.ntsc { "on" } else { "off" }));
    if let Some((w, h)) = app.original_size {
        out.insert("source".into(), Value::from(format!("{w}×{h}")));
    }
    // Lines only with a source (save_look has none).
    let lines = app.chain_input().map(|((_, h), _)| h);
    let method = ls::DOWNSCALE_METHODS.iter().find(|(_, m)| *m == app.method).map_or(app.method.raw(), |(n, _)| *n);
    let downscale = match (app.downscale, lines) {
        (true, Some(l)) => format!("{} wide, {method}, {l} lines", app.downscale_width),
        (true, None) => format!("{} wide, {method}", app.downscale_width),
        (false, Some(l)) => format!("off ({l} lines)"),
        (false, None) => "off".into(),
    };
    out.insert("downscale".into(), Value::from(downscale));
    let g = &app.glitch_values;
    let glitch = if app.glitch_enabled {
        if gp::controls(Group::Reception).all(|p| (g.get(p.id) - p.default).abs() < 1e-9) {
            "on (healthy)"
        } else {
            "on"
        }
    } else {
        "off"
    };
    out.insert("glitch".into(), Value::from(glitch));
    if g.vcr() {
        let name = |id: &str| -> String {
            match gp::param(id).map(|p| p.kind) {
                Some(Kind::Choice(o)) => o[(g.get(id).round().max(0.0) as usize).min(o.len() - 1)].to_string(),
                _ => String::new(),
            }
        };
        let tape = VcrCondition::matching(&TAPES, &TAPE_KEYS, g).map_or("custom", |c| c.name);
        let deck = VcrCondition::matching(&DECKS, &DECK_KEYS, g).map_or("custom", |c| c.name);
        out.insert("vcr".into(), json!({"tape": tape, "deck": deck, "recordedAt": name("tape_speed"), "generation": name("tape_generation")}));
    } else {
        out.insert("vcr".into(), Value::from("off"));
    }
    out.insert("crt".into(), Value::from(if app.crt { CRT_SHADERS[app.shader].0 } else { "off" }));
    if app.timeline_open && !app.keys.is_empty() {
        out.insert("keyframes".into(), Value::from(app.keys.len()));
    }
    Value::Object(out)
}
