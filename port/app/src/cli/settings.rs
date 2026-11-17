//! A look as JSON, applied to the app (the Mac's `LookSettings.swift`): the
//! shape `--settings` takes and the MCP tools pass. Every key is optional;
//! what's left out stays as the chosen look (or the app's defaults) has it.
//!
//! ```text
//! {"look": "90s VHS bootleg",
//!  "crop": "9:16",
//!  "digital": {"format": "minidv", "values": {"data_loss": 0.2}},
//!  "ntsc": {"enabled": true, "settings": {"luma_smear": 0.4}},
//!  "downscale": {"width": 320, "method": "chunky"},
//!  "glitch": {"values": {"vertical_hold": 0.3}},
//!  "vcr": {"tape": "Moldy", "deck": "Dirty heads", "values": {"tape_speed": "EP"}},
//!  "crt": {"preset": "royale", "params": {"…": 1.0}},
//!  "timeline": {"duration": 4, "fps": 30, "loop": true},
//!  "keyframes": [{"time": 0}, {"time": 2, "glitch": {"values": {…}}}]}
//! ```
//!
//! A stage can also be just "on", "off", or (for digital and crt) a format
//! or preset id. Setting any VCR value switches the VCR on; the other stages
//! keep their switch unless "enabled" says otherwise.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use ntscrt_engine::codec::{DigitalFormat, DigitalParam, DigitalParamKind};
use ntscrt_engine::crop::{Crop, Ratio};
use ntscrt_engine::glitch::params::{self as gp, Group, Kind, VcrCondition, DECKS, DECK_KEYS, TAPES, TAPE_KEYS};
use ntscrt_engine::serde_json::{Map, Value};
use ntscrt_engine::timeline::{Easing, Keyframe};
use ntscrt_engine::{DownscaleMethod, NtscKind, NtscSetting, CRT_SHADERS};

use super::{CliError, CliResult, CLI_NAME};
use crate::App;

/// ntsc-rs's old VHS emulation, retired for the VCR stage (hidden, but still
/// applied for old looks).
pub const RETIRED_VHS: [&str; 3] = ["head_switching", "tracking_noise", "vhs_settings"];

pub const STAGE_ORDER: [&str; 11] = ["look", "crop", "downscale", "digital", "ntsc", "glitch", "vcr", "crt", "timeline", "keyframes", "description"];
pub const KEY_STAGES: [&str; 5] = ["glitch", "vcr", "digital", "ntsc", "crt"];

// MARK: the session (the app, with a source loaded)

/// Open an image or video in the headless app, as the Source panel does.
pub fn load_source(app: &mut App, path: &str) -> CliResult<()> {
    let p = super::expand_path(path);
    if !p.is_file() {
        return Err(CliError::usage(format!("No such file: {}", p.display())));
    }
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    app.error = None;
    app.open(&p);
    if matches!(ext.as_str(), "mp4" | "mov" | "m4v") {
        // In the window the worker opens it and reports its size (Event::Opened).
        let info = ntscrt_media::VideoReader::open(&p)
            .map(|r| r.info())
            .map_err(|e| CliError::usage(format!("Couldn't open {name}: {e:#}")))?;
        app.video = Some(info);
        app.original_size = Some((info.width, info.height));
        if let Some(src) = &mut app.source {
            (src.1, src.2) = (info.width, info.height);
        }
        app.video_frame = 0;
    }
    if let Some(e) = app.error.take() {
        return Err(CliError::usage(e));
    }
    if app.original_size.is_none() {
        return Err(CliError::usage(format!("Couldn't open {name}.")));
    }
    Ok(())
}

/// The bundled looks, by name (the Preset menu's list).
pub fn built_in_looks() -> Vec<(String, PathBuf)> {
    let Some(dir) = ntscrt_engine::find_presets() else { return Vec::new() };
    let mut out: Vec<(String, PathBuf)> = std::fs::read_dir(&dir)
        .map(|r| {
            r.flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|x| x == "json"))
                .filter_map(|p| Some((p.file_stem()?.to_string_lossy().into_owned(), p)))
                .collect()
        })
        .unwrap_or_default();
    out.sort_by_key(|(n, _)| n.to_lowercase());
    out
}

pub fn look_path(name: &str) -> CliResult<PathBuf> {
    if name.to_lowercase().ends_with(".json") || name.contains('/') || name.contains('\\') {
        let p = super::expand_path(name);
        if !p.is_file() {
            return Err(CliError::usage(format!("No such look file: {}", p.display())));
        }
        return Ok(p);
    }
    let looks = built_in_looks();
    if let Some((_, p)) = looks.iter().find(|(n, _)| n.eq_ignore_ascii_case(name) || n.to_lowercase() == name.to_lowercase()) {
        return Ok(p.clone());
    }
    let names: Vec<&str> = looks.iter().map(|(n, _)| n.as_str()).collect();
    Err(CliError::usage(format!("No built-in look named \"{name}\". Run `{CLI_NAME} looks` for the list ({}).", names.join(", "))))
}

// MARK: applying

#[derive(Default)]
pub struct LookSettings {
    pub warnings: Vec<String>,
}

impl LookSettings {
    pub fn apply(&mut self, settings: &Map<String, Value>, app: &mut App) -> CliResult<()> {
        let mut unknown: Vec<&str> = settings.keys().map(String::as_str).filter(|k| !STAGE_ORDER.contains(k)).collect();
        if !unknown.is_empty() {
            unknown.sort();
            return Err(CliError::usage(format!("Unknown setting {}. Known: {}.", unknown.join(", "), STAGE_ORDER.join(", "))));
        }
        if let Some(v) = settings.get("look") {
            apply_look(v, app)?;
        }
        // A look's description no longer fits once it's been changed.
        if settings.keys().any(|k| !["look", "description", "timeline"].contains(&k.as_str())) {
            if let Some(raw) = app.look_raw.as_mut() {
                raw.remove("description");
            }
        }
        if let Some(d) = settings.get("description").and_then(Value::as_str) {
            app.look_raw.get_or_insert_with(Map::new).insert("description".into(), Value::from(d));
        }
        if let Some(v) = settings.get("crop") {
            apply_crop(v, app)?;
        }
        if let Some(v) = settings.get("downscale") {
            apply_downscale(v, app)?;
        }
        if let Some(v) = settings.get("digital") {
            self.apply_digital(v, app)?;
        }
        if let Some(v) = settings.get("ntsc") {
            self.apply_ntsc(v, app)?;
        }
        if let Some(v) = settings.get("glitch") {
            self.apply_glitch(v, app)?;
        }
        if let Some(v) = settings.get("vcr") {
            self.apply_vcr(v, app)?;
        }
        if let Some(v) = settings.get("crt") {
            self.apply_crt(v, app)?;
        }
        if let Some(v) = settings.get("timeline") {
            apply_timeline(v, app)?;
        }
        if app.crt {
            shader_ready(app)?;
        }
        if let Some(v) = settings.get("keyframes") {
            let explicit = settings.get("timeline").and_then(|t| t.get("duration")).is_some();
            self.apply_keyframes(v, explicit, app)?;
        }
        if settings.get("timeline").and_then(|t| t.get("loop")).and_then(bool_of) == Some(true) {
            close_loop(app);
        }
        Ok(())
    }

    // MARK: digital video

    fn apply_digital(&mut self, v: &Value, app: &mut App) -> CliResult<()> {
        let dict = match v {
            Value::String(s) if is_off(s) => {
                app.digital_enabled = false;
                return Ok(());
            }
            Value::String(s) if is_on(s) => {
                app.digital_enabled = true;
                return Ok(());
            }
            Value::String(s) => Map::from_iter([("format".to_string(), Value::from(s.as_str()))]),
            Value::Object(d) => d.clone(),
            _ => return Err(CliError::usage("\"digital\" takes \"on\", \"off\", a format id, or {format, values, enabled}.")),
        };
        if let Some(f) = dict.get("format").and_then(Value::as_str) {
            let Some(format) = digital_format(f) else {
                let ids: Vec<&str> = DigitalFormat::all().iter().map(|f| f.id).collect();
                return Err(CliError::usage(format!("No Digital video format \"{f}\". Formats: {}.", ids.join(", "))));
            };
            app.apply_digital_format(format);
        }
        self.set_digital_values(dict.get("values"), app)?;
        app.digital_enabled = dict.get("enabled").and_then(Value::as_bool).unwrap_or(true);
        Ok(())
    }

    fn set_digital_values(&mut self, raw: Option<&Value>, app: &mut App) -> CliResult<()> {
        let Some(raw) = raw else { return Ok(()) };
        let Some(values) = raw.as_object() else { return Err(CliError::usage("Digital video \"values\" is an object of control: value.")) };
        for (key, raw) in values {
            let Some(p) = DigitalParam::by_id(key) else {
                let ids: Vec<&str> = DigitalParam::all().iter().map(|p| p.id).collect();
                return Err(CliError::usage(format!("No Digital video control \"{key}\". Controls: {}.", ids.join(", "))));
            };
            let value = match p.kind {
                DigitalParamKind::Choice(options) => choice_index(raw, options, &format!("digital {key}"))?,
                DigitalParamKind::Slider { min, max, .. } => self.clamped(raw, min, max, &format!("digital {key}"))?,
            };
            app.digital_values.insert(key.clone(), value);
            app.auto_key();
        }
        Ok(())
    }

    // MARK: NTSC (ntsc-rs)

    fn apply_ntsc(&mut self, v: &Value, app: &mut App) -> CliResult<()> {
        const USAGE: &str = "\"ntsc\" takes \"on\", \"off\", or {enabled, settings}.";
        match v {
            Value::String(s) if is_on(s) || is_off(s) => {
                app.ntsc = is_on(s);
                Ok(())
            }
            Value::Object(d) => {
                self.set_ntsc_settings(d.get("settings"), app)?;
                if let Some(e) = d.get("enabled").and_then(Value::as_bool) {
                    app.ntsc = e;
                }
                Ok(())
            }
            _ => Err(CliError::usage(USAGE)),
        }
    }

    fn set_ntsc_settings(&mut self, raw: Option<&Value>, app: &mut App) -> CliResult<()> {
        let Some(raw) = raw else { return Ok(()) };
        let Some(settings) = raw.as_object() else { return Err(CliError::usage("NTSC \"settings\" is an object of setting: value.")) };
        let list = app.ntsc_settings.clone();
        let known = ntsc_by_key(&list);
        let retired = retired_ntsc_keys(&list);
        for (key, raw) in settings {
            let Some(s) = known.get(key.as_str()) else {
                return Err(CliError::usage(if retired.contains(key.as_str()) {
                    format!("NTSC \"{key}\" is ntsc-rs's old VHS filter, retired for the VCR stage: use \"vcr\" instead.")
                } else {
                    format!("No NTSC setting \"{key}\". Run `{CLI_NAME} describe ntsc` for the list.")
                }));
            };
            let value = self.ntsc_value(raw, s)?;
            app.ntsc_values.insert(key.clone(), value);
            app.auto_key();
        }
        Ok(())
    }

    fn ntsc_value(&mut self, raw: &Value, s: &NtscSetting) -> CliResult<Value> {
        let name = &s.name;
        Ok(match &s.kind {
            NtscKind::Boolean | NtscKind::Group { .. } => Value::from(bool_of(raw).ok_or_else(|| CliError::usage(format!("NTSC {name} is on/off.")))?),
            NtscKind::Percentage { .. } => Value::from(self.clamped(raw, 0.0, 1.0, &format!("ntsc {name}"))?),
            NtscKind::Float { min, max, .. } => Value::from(self.clamped(raw, *min as f64, *max as f64, &format!("ntsc {name}"))?),
            NtscKind::Int { min, max } => Value::from(self.clamped(raw, *min as f64, *max as f64, &format!("ntsc {name}"))?.round() as i64),
            NtscKind::Enumeration { options } => {
                if let Some(label) = raw.as_str() {
                    if let Some((_, i)) = options.iter().find(|(l, _)| l.eq_ignore_ascii_case(label)) {
                        return Ok(Value::from(*i));
                    }
                }
                if let Some(n) = number(raw) {
                    if options.iter().any(|(_, i)| *i as f64 == n) {
                        return Ok(Value::from(n as i64));
                    }
                }
                let labels: Vec<&str> = options.iter().map(|(l, _)| l.as_str()).collect();
                return Err(CliError::usage(format!("NTSC {name} is one of: {}.", labels.join(", "))));
            }
            NtscKind::Section { .. } => return Err(CliError::usage(format!("NTSC {name} is a heading, not a setting."))),
        })
    }

    // MARK: glitch and VCR (one stage, two panels)

    fn apply_glitch(&mut self, v: &Value, app: &mut App) -> CliResult<()> {
        const USAGE: &str = "\"glitch\" takes \"on\", \"off\", or {enabled, values}.";
        match v {
            Value::String(s) if is_on(s) || is_off(s) => {
                app.glitch_enabled = is_on(s);
                Ok(())
            }
            Value::Object(d) => {
                self.set_glitch_values(d.get("values"), &[Group::Reception], "Glitch", app)?;
                app.glitch_enabled = d.get("enabled").and_then(Value::as_bool).unwrap_or(true);
                Ok(())
            }
            _ => Err(CliError::usage(USAGE)),
        }
    }

    fn apply_vcr(&mut self, v: &Value, app: &mut App) -> CliResult<()> {
        const USAGE: &str = "\"vcr\" takes \"on\", \"off\", or {enabled, tape, deck, values}.";
        match v {
            Value::String(s) if is_on(s) || is_off(s) => {
                set_vcr(app, is_on(s));
                Ok(())
            }
            Value::Object(d) => {
                apply_conditions(d, app, true)?;
                self.set_glitch_values(d.get("values"), &[Group::Tape, Group::Deck], "VCR", app)?;
                set_vcr(app, d.get("enabled").and_then(Value::as_bool).unwrap_or(true));
                Ok(())
            }
            _ => Err(CliError::usage(USAGE)),
        }
    }

    fn set_glitch_values(&mut self, raw: Option<&Value>, groups: &[Group], panel: &str, app: &mut App) -> CliResult<()> {
        let Some(raw) = raw else { return Ok(()) };
        let Some(values) = raw.as_object() else { return Err(CliError::usage(format!("{panel} \"values\" is an object of control: value."))) };
        let allowed: Vec<&gp::GlitchParam> = gp::PARAMS.iter().filter(|p| groups.contains(&p.group) && p.id != gp::VCR_ID).collect();
        for (key, value) in values {
            let Some(p) = allowed.iter().find(|p| p.id == key) else {
                let other = gp::param(key).map(|p| if p.group == Group::Reception { "glitch" } else { "vcr" });
                return Err(CliError::usage(match other {
                    Some(o) => format!("\"{key}\" belongs to \"{o}\", not {panel}."),
                    None => format!("No {panel} control \"{key}\". Controls: {}.", allowed.iter().map(|p| p.id).collect::<Vec<_>>().join(", ")),
                }));
            };
            let v = match p.kind {
                Kind::Slider { min, max, .. } => self.clamped(value, min, max, key)?,
                Kind::Toggle => {
                    if bool_of(value).ok_or_else(|| CliError::usage(format!("{key} is on/off.")))? {
                        1.0
                    } else {
                        0.0
                    }
                }
                Kind::Seed => match number(value) {
                    Some(n) if n >= 0.0 => n.round(),
                    _ => return Err(CliError::usage(format!("{key} is a whole number (which cassette)."))),
                },
                Kind::Choice(options) => choice_index(value, options, key)?,
            };
            set_glitch(app, key, v);
        }
        Ok(())
    }

    // MARK: CRT shader

    fn apply_crt(&mut self, v: &Value, app: &mut App) -> CliResult<()> {
        let dict = match v {
            Value::String(s) if is_off(s) => {
                app.crt = false;
                return Ok(());
            }
            Value::String(s) if is_on(s) => {
                app.crt = true;
                return Ok(());
            }
            Value::String(s) => Map::from_iter([("preset".to_string(), Value::from(s.as_str()))]),
            Value::Object(d) => d.clone(),
            _ => return Err(CliError::usage("\"crt\" takes \"on\", \"off\", a preset id, or {preset, params, enabled}.")),
        };
        if let Some(id) = dict.get("preset").and_then(Value::as_str) {
            let Some(i) = CRT_SHADERS.iter().position(|s| s.0 == id.to_lowercase() || s.1.eq_ignore_ascii_case(id)) else {
                let ids: Vec<&str> = CRT_SHADERS.iter().map(|s| s.0).collect();
                return Err(CliError::usage(format!("No CRT preset \"{id}\". Presets: {}.", ids.join(", "))));
            };
            app.shader = i;
            app.ensure_shader();
        }
        self.set_crt_params(dict.get("params"), app)?;
        app.crt = dict.get("enabled").and_then(Value::as_bool).unwrap_or(true);
        Ok(())
    }

    fn set_crt_params(&mut self, raw: Option<&Value>, app: &mut App) -> CliResult<()> {
        let Some(raw) = raw else { return Ok(()) };
        let Some(params) = raw.as_object() else { return Err(CliError::usage("CRT \"params\" is an object of parameter: value.")) };
        if params.is_empty() {
            return Ok(());
        }
        let descriptors = shader_ready(app)?;
        let id = CRT_SHADERS[app.shader].0;
        for (key, raw) in params {
            let Some(p) = descriptors.iter().find(|p| &p.name == key) else {
                return Err(CliError::usage(format!(
                    "CRT preset {id} has no parameter \"{key}\". Run `{CLI_NAME} describe crt --crt {id}` for its list."
                )));
            };
            let value = match raw {
                Value::Bool(b) => f64::from(u8::from(*b)),
                Value::String(s) if s.parse::<f64>().is_err() && bool_of(raw).is_some() => f64::from(u8::from(bool_of(raw) == Some(true))),
                _ => self.clamped(raw, p.minimum as f64, p.maximum as f64, &format!("crt {key}"))?,
            };
            if let Some(values) = app.shader_values.get_mut(&app.shader) {
                values.insert(key.clone(), value as f32);
            }
            app.auto_key();
        }
        Ok(())
    }

    // MARK: keyframes (animation)

    /// `"keyframes": [{"time": 0, "glitch": {"values": {…}}}, {"time": 2.5,
    /// "easing": "ease-in-out", "vcr": {"tape": "Chewed"}}, …]`. Each key is
    /// the look above it with these values changed; between keys values blend
    /// (whole-number controls step), as the timeline does. They replace any
    /// keyframes the look brought. A key at 0 holding the look itself is
    /// added when there isn't one.
    fn apply_keyframes(&mut self, v: &Value, explicit_duration: bool, app: &mut App) -> CliResult<()> {
        let Some(list) = v.as_array().filter(|l| l.iter().all(Value::is_object)) else {
            return Err(CliError::usage("\"keyframes\" is a list of {time, easing, glitch, vcr, digital, ntsc, crt}."));
        };
        // Capture with the timeline off, so no edit lands in an old key.
        app.timeline_open = false;
        app.keys.clear();
        app.selected_key = None;
        if list.is_empty() {
            return Ok(());
        }
        let mut timed: Vec<(f64, &Map<String, Value>)> = Vec::new();
        for key in list {
            let key = key.as_object().expect("checked");
            let Some(time) = key.get("time").and_then(number).filter(|t| *t >= 0.0) else {
                return Err(CliError::usage("Each keyframe needs a \"time\" in seconds (0 or more)."));
            };
            let mut extra: Vec<&str> = key.keys().map(String::as_str).filter(|k| !["time", "easing"].contains(k) && !KEY_STAGES.contains(k)).collect();
            if !extra.is_empty() {
                extra.sort();
                return Err(CliError::usage(format!(
                    "A keyframe can change {} (not {}): crop, downscale and the CRT preset hold for the whole video.",
                    KEY_STAGES.join(", "),
                    extra.join(", ")
                )));
            }
            timed.push((time, key));
        }
        timed.sort_by(|a, b| a.0.total_cmp(&b.0));

        // Times are seconds; the timeline stores them as 0…1 of its length.
        let last = timed.last().expect("non-empty").0;
        let mut duration = effective_duration(app);
        if app.video.is_none() && !explicit_duration && last > duration {
            app.timeline_seconds = last;
            duration = last;
        }
        if last > duration + 1e-6 {
            self.warnings.push(format!("Keyframes after {} s are past the end of the video; they land at the end.", fmt(duration)));
        }

        app.ensure_shader();
        let base_params = app.shader_values.get(&app.shader).cloned();
        let base_ntsc = app.ntsc_values.clone();
        let base_glitch = app.glitch_values.clone();
        let base_digital = app.digital_values.clone();
        let restore = |app: &mut App| {
            if let Some(p) = &base_params {
                app.shader_values.insert(app.shader, p.clone());
            }
            app.ntsc_values = base_ntsc.clone();
            app.glitch_values = base_glitch.clone();
            app.digital_values = base_digital.clone();
        };

        let mut keys: Vec<Keyframe> = Vec::new();
        let mut touched: HashSet<&str> = HashSet::new();
        if timed[0].0 > 1e-6 {
            keys.push(app.snapshot(0.0));
        }
        for (time, key) in &timed {
            restore(app);
            let mut easing = Easing::Linear;
            if let Some(e) = key.get("easing").and_then(Value::as_str) {
                easing = parse_easing(e).ok_or_else(|| CliError::usage(format!("Easing \"{e}\": use linear, ease-in, ease-out, ease-in-out or hold.")))?;
            }
            for stage in KEY_STAGES {
                let Some(sv) = key.get(stage) else { continue };
                touched.insert(stage);
                let Some(d) = sv.as_object() else {
                    if let (true, Some(s)) = (stage == "vcr", sv.as_str()) {
                        if is_on(s) || is_off(s) {
                            set_vcr(app, is_on(s));
                            continue;
                        }
                    }
                    return Err(CliError::usage(format!("In a keyframe, \"{stage}\" is an object, as in the look (e.g. {{\"values\": {{…}}}}).")));
                };
                match stage {
                    "glitch" => self.set_glitch_values(d.get("values"), &[Group::Reception], "Glitch", app)?,
                    "vcr" => {
                        apply_conditions(d, app, false)?;
                        self.set_glitch_values(d.get("values"), &[Group::Tape, Group::Deck], "VCR", app)?;
                        if let Some(on) = d.get("enabled").and_then(bool_of) {
                            set_vcr(app, on);
                        }
                    }
                    "digital" => self.set_digital_values(d.get("values"), app)?,
                    "ntsc" => self.set_ntsc_settings(d.get("settings"), app)?,
                    "crt" => self.set_crt_params(d.get("params"), app)?,
                    _ => {}
                }
            }
            let mut k = app.snapshot(if duration > 0.0 { (time / duration).min(1.0) } else { 0.0 });
            k.easing = easing;
            keys.push(k);
        }
        restore(app);

        // A stage a keyframe animates has to be running to show it.
        if touched.contains("glitch") {
            app.glitch_enabled = true;
        }
        if touched.contains("digital") {
            app.digital_enabled = true;
        }
        if touched.contains("ntsc") {
            app.ntsc = true;
        }
        if touched.contains("crt") {
            app.crt = true;
        }
        app.keys = keys;
        app.timeline_open = true;
        app.glitch_off_key_edit = None;
        app.scrub(0.0);
        Ok(())
    }

    // MARK: value parsing

    fn clamped(&mut self, v: &Value, lo: f64, hi: f64, name: &str) -> CliResult<f64> {
        let Some(n) = number(v).filter(|n| n.is_finite()) else {
            return Err(CliError::usage(format!("{name} takes a number from {} to {}.", fmt(lo), fmt(hi))));
        };
        let c = n.clamp(lo, hi);
        if c != n {
            self.warnings.push(format!("{name} {} is outside {}…{}; used {}.", fmt(n), fmt(lo), fmt(hi), fmt(c)));
        }
        Ok(c)
    }
}

fn apply_look(v: &Value, app: &mut App) -> CliResult<()> {
    let Some(name) = v.as_str() else { return Err(CliError::usage("\"look\" takes a look name or a .json path.")) };
    let path = look_path(name)?;
    app.error = None;
    app.load_look(&path);
    if let Some(e) = app.error.take() {
        return Err(CliError::usage(format!("Couldn't load the look {name}: {e}")));
    }
    Ok(())
}

fn apply_crop(v: &Value, app: &mut App) -> CliResult<()> {
    match v {
        Value::String(s) => {
            if is_off(s) {
                app.crop_enabled = false;
                return Ok(());
            }
            // "9:16", "9:16@0.2,0.7", each optionally "*1.5" (zoomed in).
            let (placed, zoom) = s.split_once('*').map_or((s.as_str(), None), |(a, b)| (a, Some(b)));
            let (label, at) = placed.split_once('@').map_or((placed, None), |(a, b)| (a, Some(b)));
            let Some(ratio) = Ratio::from_label(label) else {
                return Err(CliError::usage(format!("Crop \"{s}\": expected a ratio like 9:16, optionally @x,y and *zoom.")));
            };
            let at: Vec<f64> = at.map(|a| a.split(',').filter_map(|x| x.trim().parse().ok()).collect()).unwrap_or_default();
            let zoom = zoom.and_then(|z| z.trim().parse().ok()).unwrap_or(1.0);
            set_crop(app, ratio, at.first().copied().unwrap_or(0.5), at.last().copied().unwrap_or(0.5), zoom);
            Ok(())
        }
        Value::Object(d) => {
            if d.get("enabled").and_then(Value::as_bool) == Some(false) {
                app.crop_enabled = false;
                return Ok(());
            }
            let Some(ratio) = d.get("ratio").and_then(Value::as_str).and_then(Ratio::from_label) else {
                return Err(CliError::usage("Crop needs a \"ratio\" like \"9:16\"."));
            };
            let n = |k: &str, def: f64| d.get(k).and_then(number).unwrap_or(def);
            set_crop(app, ratio, n("x", 0.5), n("y", 0.5), n("zoom", 1.0));
            Ok(())
        }
        _ => Err(CliError::usage("\"crop\" takes \"off\", a ratio like \"9:16\", or {ratio, x, y, zoom}.")),
    }
}

fn set_crop(app: &mut App, ratio: Ratio, x: f64, y: f64, zoom: f64) {
    app.crop = Crop { x: x.clamp(0.0, 1.0), y: y.clamp(0.0, 1.0), scale: zoom.clamp(1.0, Crop::MAX_SCALE), ..Crop::new(ratio) };
    app.crop_enabled = true;
}

/// The Downscale's names for its two methods (chunky = nearest, smooth = area).
pub const DOWNSCALE_METHODS: [(&str, DownscaleMethod); 2] = [("chunky", DownscaleMethod::Nearest), ("smooth", DownscaleMethod::Area)];

fn apply_downscale(v: &Value, app: &mut App) -> CliResult<()> {
    if let Some(s) = v.as_str() {
        if is_off(s) {
            app.downscale = false;
            return Ok(());
        }
        if is_on(s) {
            app.downscale = true;
            return Ok(());
        }
    }
    if let Some(w) = number(v).filter(|_| !v.is_object()) {
        set_downscale_width(app, w);
        return Ok(());
    }
    let Some(d) = v.as_object() else { return Err(CliError::usage("\"downscale\" takes \"off\", a width in pixels, or {width, method}.")) };
    if let Some(w) = d.get("width").and_then(number) {
        set_downscale_width(app, w);
    }
    if let Some(m) = d.get("method").and_then(Value::as_str) {
        let method = DOWNSCALE_METHODS.iter().find(|(n, _)| *n == m.to_lowercase()).map(|(_, x)| *x).or_else(|| DownscaleMethod::from_raw(m));
        let Some(method) = method else { return Err(CliError::usage(format!("Downscale method \"{m}\": use chunky or smooth."))) };
        app.method = method;
    }
    if let Some(e) = d.get("enabled").and_then(Value::as_bool) {
        app.downscale = e;
    }
    Ok(())
}

fn set_downscale_width(app: &mut App, w: f64) {
    app.downscale_width = w.round().clamp(16.0, 4096.0) as u32;
    app.downscale_preset = "Custom".into();
    app.downscale = true;
}

fn apply_timeline(v: &Value, app: &mut App) -> CliResult<()> {
    let Some(d) = v.as_object() else { return Err(CliError::usage("\"timeline\" takes {duration, fps, loop}.")) };
    if let Some(s) = d.get("duration").and_then(number) {
        app.timeline_seconds = s.clamp(0.1, 600.0);
    }
    if let Some(f) = d.get("fps").and_then(number) {
        app.timeline_fps = f.round().clamp(1.0, 120.0) as u32;
    }
    Ok(())
}

/// `"timeline": {"loop": true}`: end the animation where it began, with a key
/// at the end copying the first, so a GIF or looped video has no jump.
fn close_loop(app: &mut App) {
    if app.keys.len() < 2 {
        return;
    }
    if let Some(i) = app.keys.iter().position(|k| k.t > 1.0 - 1e-6) {
        app.keys.remove(i);
    }
    let mut end = app.keys[0].clone();
    end.t = 1.0;
    app.keys.push(end);
    app.scrub(0.0);
}

/// The Tape and Deck pickers.
fn apply_conditions(d: &Map<String, Value>, app: &mut App, list_names: bool) -> CliResult<()> {
    for (field, list, keys, what) in [("tape", &TAPES[..], &TAPE_KEYS[..], "tape"), ("deck", &DECKS[..], &DECK_KEYS[..], "deck")] {
        let Some(name) = d.get(field).and_then(Value::as_str) else { continue };
        let Some(c) = vcr_condition(name, list) else {
            let names: Vec<&str> = list.iter().map(|c| c.name).collect();
            return Err(CliError::usage(if list_names {
                format!("No {what} \"{name}\". {}s: {}.", capitalized(what), names.join(", "))
            } else {
                format!("No {what} \"{name}\".")
            }));
        };
        c.apply(keys, &mut app.glitch_values);
        glitch_edited(app);
    }
    Ok(())
}

fn capitalized(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}

pub fn vcr_condition(name: &str, list: &'static [VcrCondition]) -> Option<&'static VcrCondition> {
    list.iter().find(|c| c.name.to_lowercase() == name.to_lowercase())
}

pub fn digital_format(s: &str) -> Option<&'static DigitalFormat> {
    DigitalFormat::by_id(&s.to_lowercase()).or_else(|| DigitalFormat::all().iter().find(|f| f.name.to_lowercase() == s.to_lowercase()))
}

fn set_vcr(app: &mut App, on: bool) {
    set_glitch(app, gp::VCR_ID, if on { 1.0 } else { 0.0 });
}

fn set_glitch(app: &mut App, id: &str, v: f64) {
    app.glitch_values.values.insert(id.to_string(), v);
    glitch_edited(app);
}

/// As the panels' edits: off a key, the preview runs on the knobs as set;
/// parked on one, it's updated (the Mac's glitchEdited).
fn glitch_edited(app: &mut App) {
    if app.timeline_open && !app.keys.is_empty() && app.parked_key().is_none() {
        app.glitch_off_key_edit = Some(app.glitch_values.clone());
    }
    app.auto_key();
}

/// The CRT preset's parameters, compiled (parsed) — or why not.
pub fn shader_ready(app: &mut App) -> CliResult<Vec<ntscrt_engine::ShaderParam>> {
    if app.shaders.is_none() {
        return Err(CliError::failed("The CRT shaders weren't found (the shaders folder next to ntscrt.exe, or NTSCRT_SHADERS)."));
    }
    app.ensure_shader();
    match app.shader_params.get(&app.shader) {
        Some(Ok(ps)) => Ok(ps.clone()),
        Some(Err(e)) => Err(CliError::failed(format!("The CRT shader failed: {e}"))),
        None => Err(CliError::failed("The CRT shader failed to load.")),
    }
}

/// The clip's length, or a still's timeline.
pub fn effective_duration(app: &App) -> f64 {
    app.video.map_or(app.timeline_seconds, |v| v.duration)
}

fn parse_easing(name: &str) -> Option<Easing> {
    let squash = |s: &str| s.to_lowercase().chars().filter(|c| c.is_alphabetic()).collect::<String>();
    let n = squash(name);
    Easing::ALL.into_iter().find(|e| squash(e.raw()) == n)
}

/// Every NTSC setting by key, groups' switches included — retired ones left out.
pub fn ntsc_by_key(list: &[NtscSetting]) -> HashMap<&str, &NtscSetting> {
    fn walk<'a>(list: &'a [NtscSetting], out: &mut HashMap<&'a str, &'a NtscSetting>) {
        for s in list {
            match &s.kind {
                NtscKind::Section { children } => walk(children, out),
                NtscKind::Group { children } => {
                    if !RETIRED_VHS.contains(&s.name.as_str()) {
                        out.insert(&s.name, s);
                        walk(children, out);
                    }
                }
                _ => {
                    out.insert(&s.name, s);
                }
            }
        }
    }
    let mut out = HashMap::new();
    walk(list, &mut out);
    out
}

pub fn retired_ntsc_keys(list: &[NtscSetting]) -> HashSet<&str> {
    fn walk<'a>(list: &'a [NtscSetting], inside: bool, out: &mut HashSet<&'a str>) {
        for s in list {
            let retired = inside || RETIRED_VHS.contains(&s.name.as_str());
            if retired {
                out.insert(&s.name);
            }
            if let NtscKind::Section { children } | NtscKind::Group { children } = &s.kind {
                walk(children, retired, out);
            }
        }
    }
    let mut out = HashSet::new();
    walk(list, false, &mut out);
    out
}

pub fn is_on(s: &str) -> bool {
    ["on", "true", "yes", "1"].contains(&s.to_lowercase().as_str())
}

pub fn is_off(s: &str) -> bool {
    ["off", "false", "no", "0", "none"].contains(&s.to_lowercase().as_str())
}

pub fn number(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

pub fn bool_of(v: &Value) -> Option<bool> {
    match v {
        Value::Bool(b) => Some(*b),
        Value::Number(n) => n.as_f64().map(|x| x >= 0.5),
        Value::String(s) if is_on(s) => Some(true),
        Value::String(s) if is_off(s) => Some(false),
        _ => None,
    }
}

pub fn choice_index(v: &Value, options: &[&str], name: &str) -> CliResult<f64> {
    if let Some(s) = v.as_str() {
        if let Some(i) = options.iter().position(|o| o.eq_ignore_ascii_case(s) || o.to_lowercase() == s.to_lowercase()) {
            return Ok(i as f64);
        }
    }
    if let Some(n) = number(v) {
        if n.round() == n && n >= 0.0 && (n as usize) < options.len() {
            return Ok(n);
        }
    }
    Err(CliError::usage(format!("{name} is one of: {} (or its number, 0–{}).", options.join(", "), options.len().saturating_sub(1))))
}

pub fn fmt(d: f64) -> String {
    if d == d.round() && d.abs() < 1e9 {
        format!("{}", d as i64)
    } else {
        // %g
        let s = format!("{d:.6}");
        let s = s.trim_end_matches('0').trim_end_matches('.');
        s.to_string()
    }
}
