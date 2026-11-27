//! `ntscrt describe [stage…] [--crt <preset>|all]` and `ntscrt looks`: the
//! controls and named starting points, as JSON, for scripts and AI tools (the
//! Mac's `DescribeCommand.swift`), generated from this version's own
//! definitions.

use ntscrt_engine::codec::{DigitalFormat, DigitalParam, DigitalParamKind};
use ntscrt_engine::crop::Crop;
use ntscrt_engine::glitch::params::{self as gp, GlitchParam, Group, Kind, VcrCondition, DECKS, DECK_KEYS, TAPES, TAPE_KEYS};
use ntscrt_engine::serde_json::{json, Map, Value};
use ntscrt_engine::{app_shader_defaults, find_shaders, ntsc_default_values, ntsc_settings, preset_parameters, NtscKind, NtscSetting, CRT_SHADERS};

use super::settings::{built_in_looks, fmt, RETIRED_VHS};
use super::{emit_json, emit_text, pretty, CliError, CliResult};
use crate::shader_panel::{presentation, Kind as PKind};

pub const STAGES: [&str; 8] = ["crop", "downscale", "digital", "ntsc", "glitch", "vcr", "crt", "output"];

pub fn run(args: &[String]) -> i32 {
    match describe(args) {
        Ok(v) => {
            emit_text(&pretty(&v));
            0
        }
        Err(e) => {
            emit_json(&json!({"ok": false, "error": e.message}));
            e.code
        }
    }
}

pub fn run_looks(_args: &[String]) -> i32 {
    emit_text(&pretty(&looks()));
    0
}

pub fn describe(args: &[String]) -> CliResult<Value> {
    let mut wanted: Vec<&str> = Vec::new();
    let mut crt_presets: Option<Vec<String>> = None;
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--crt" {
            i += 1;
            let a = args.get(i).ok_or_else(|| CliError::usage("--crt needs a preset id, or all."))?;
            crt_presets = Some(if a == "all" { CRT_SHADERS.iter().map(|s| s.0.to_string()).collect() } else { a.split(',').map(str::to_string).collect() });
        } else if let Some(s) = STAGES.iter().find(|s| **s == args[i]) {
            wanted.push(s);
        } else {
            return Err(CliError::usage(format!("describe takes stages ({}) and --crt <preset|all>.", STAGES.join(", "))));
        }
        i += 1;
    }
    if wanted.is_empty() {
        wanted = STAGES.to_vec();
    }
    let mut out = json!({
        "about": "NTSCRT renders images and video through simulated analog video gear. The picture passes through the stages in `order`; each stage's controls are set with `NTSCRT render` flags or a --settings JSON object keyed by stage (see `settingsExample`). Values are what the setting stores: a slider described as percent stores 0–1 (or −1–1), shown in the app as 0–100%.",
        "order": ["source", "crop", "digital", "ntsc", "downscale", "vcr", "glitch", "crt"],
        "settingsExample": {
            "look": "90s VHS bootleg",
            "vcr": {"tape": "Moldy", "deck": "Dirty heads", "values": {"tape_speed": "EP", "tracking_offset": 0.3}},
            "glitch": {"values": {"vertical_hold": 0.2}},
            "crt": {"preset": "royale"},
        },
        "keyframes": {
            "about": "Animate a look: \"keyframes\" in the settings is a list of moments, each the look above it with some values changed. Between keys values blend (on/off, choices and the cassette step instead); before the first key and after the last they hold. Times are seconds into the clip, or into the video a still becomes (a still's video stretches to the last key unless timeline.duration is set). A key at 0 holding the plain look is added when there isn't one. Keys can change glitch values, vcr (tape, deck, values, enabled), digital values, ntsc settings and crt params — not crop, downscale or the CRT preset. They replace any keyframes the look had. For a seamless loop, set \"timeline\": {\"duration\": 2, \"loop\": true}: it adds a closing key that copies the first.",
            "easing": "per key, shaping the move to the next key: linear (default), ease-in, ease-out, ease-in-out, hold (jump at the next key)",
            "example": [
                {"time": 0},
                {"time": 2, "easing": "ease-in", "glitch": {"values": {"vertical_hold": 0.5}}},
                {"time": 3},
                {"time": 5, "vcr": {"tape": "Chewed"}},
            ],
        },
    });
    let o = out.as_object_mut().expect("object");
    let version = crate::update::current_version();
    if crate::update::parse_version(&version).is_some() {
        o.insert("version".into(), Value::from(version));
    }
    let default_crt = ["glow_gauss".to_string()];
    let mut stages = Map::new();
    for s in wanted {
        let v = match s {
            "crop" => crop(),
            "downscale" => downscale(),
            "digital" => digital(),
            "ntsc" => ntsc(),
            "glitch" => glitch(),
            "vcr" => vcr(),
            "crt" => crt(crt_presets.as_deref().unwrap_or(&default_crt))?,
            _ => output(),
        };
        stages.insert(s.to_string(), v);
    }
    o.insert("stages".into(), Value::Object(stages));
    Ok(out)
}

// MARK: stages

fn crop() -> Value {
    json!({
        "panel": "Crop",
        "about": "Cut the source to an aspect ratio before anything else runs.",
        "flag": "--crop 9:16[@x,y][*zoom] | off",
        "settings": "\"crop\": \"9:16\" | \"off\" | {\"ratio\": \"9:16\", \"x\": 0.5, \"y\": 0.5, \"zoom\": 1}",
        "values": {"ratio": "w:h, e.g. 1:1, 4:3, 9:16, 16:9", "x": "0–1, where the cut sits across", "y": "0–1, where it sits down", "zoom": format!("1–{}, zoomed in", fmt(Crop::MAX_SCALE))},
    })
}

fn downscale() -> Value {
    json!({
        "panel": "Downscale",
        "about": "The resolution the picture is carried at: everything after it — NTSC, VCR, Glitch, CRT — works on lines this wide. 320 is a 240-line TV picture; 640 a sharper one.",
        "flag": "--downscale <width>|off  --downscale-method chunky|smooth",
        "settings": "\"downscale\": 320 | \"off\" | {\"width\": 320, \"method\": \"chunky\"}",
        "widths": {"SNES/NES": 256, "VGA": 320, "Arcade": 384, "VGA²": 640},
        "methods": {"chunky": "nearest-neighbor: hard pixels", "smooth": "area average"},
    })
}

fn digital() -> Value {
    let controls: Vec<Value> = DigitalParam::all()
        .iter()
        .map(|p| {
            let mut c = Map::new();
            c.insert("id".into(), Value::from(p.id));
            c.insert("label".into(), Value::from(p.label));
            c.insert("group".into(), Value::from(p.group.label()));
            c.insert("default".into(), Value::from(p.default_value));
            c.insert("help".into(), Value::from(p.help));
            match p.kind {
                DigitalParamKind::Slider { min, max, percent, unit } => {
                    c.insert("kind".into(), Value::from("slider"));
                    c.insert("min".into(), Value::from(min));
                    c.insert("max".into(), Value::from(max));
                    if percent {
                        c.insert("display".into(), Value::from("percent"));
                    }
                    if !unit.is_empty() {
                        c.insert("unit".into(), Value::from(unit));
                    }
                    if let Some(s) = p.step {
                        c.insert("step".into(), Value::from(s));
                    }
                }
                DigitalParamKind::Choice(options) => {
                    c.insert("kind".into(), Value::from("choice"));
                    c.insert("options".into(), json!(options));
                }
            }
            Value::Object(c)
        })
        .collect();
    json!({
        "panel": "Digital video",
        "about": "A camera and a video codec ahead of the TV signal: real 8×8 DCT blocks, quantization, motion-compensated frames, lost data. Off by default. A format sets the controls and the Downscale width.",
        "flag": "--digital <format>|on|off  --digital-set key=value,…",
        "settings": "\"digital\": \"minidv\" | \"off\" | {\"format\": \"minidv\", \"values\": {…}}",
        "formats": DigitalFormat::all().iter().map(|f| json!({"id": f.id, "name": f.name, "width": f.width, "about": f.blurb})).collect::<Vec<_>>(),
        "controls": controls,
    })
}

fn ntsc() -> Value {
    let defaults = ntsc_default_values();
    fn control(s: &NtscSetting, defaults: &Map<String, Value>) -> Option<Value> {
        if RETIRED_VHS.contains(&s.name.as_str()) {
            return None;
        }
        let mut c = Map::new();
        c.insert("id".into(), Value::from(s.name.as_str()));
        c.insert("label".into(), Value::from(s.label.as_str()));
        if let Some(d) = s.description.as_deref().filter(|d| !d.is_empty()) {
            c.insert("help".into(), Value::from(d));
        }
        if let Some(def) = defaults.get(&s.name) {
            c.insert("default".into(), def.clone());
        }
        let kind = match &s.kind {
            NtscKind::Boolean => "toggle",
            NtscKind::Percentage { .. } => {
                c.insert("min".into(), Value::from(0));
                c.insert("max".into(), Value::from(1));
                c.insert("display".into(), Value::from("percent"));
                "slider"
            }
            NtscKind::Float { min, max, .. } => {
                c.insert("min".into(), Value::from(*min as f64));
                c.insert("max".into(), Value::from(*max as f64));
                "slider"
            }
            NtscKind::Int { min, max } => {
                c.insert("min".into(), Value::from(*min));
                c.insert("max".into(), Value::from(*max));
                "integer"
            }
            NtscKind::Enumeration { options } => {
                c.insert("options".into(), json!(options.iter().map(|o| o.0.as_str()).collect::<Vec<_>>()));
                // By name: the options are listed in the panel's order, not
                // ntsc-rs's numbering.
                if let Some(o) = defaults.get(&s.name).and_then(Value::as_u64).and_then(|d| options.iter().find(|o| o.1 as u64 == d)) {
                    c.insert("default".into(), Value::from(o.0.as_str()));
                }
                "choice"
            }
            NtscKind::Group { children } => {
                c.insert("about".into(), Value::from("A switch for the settings under it."));
                c.insert("children".into(), Value::Array(children.iter().filter_map(|k| control(k, defaults)).collect()));
                "group"
            }
            NtscKind::Section { children } => {
                c.insert("children".into(), Value::Array(children.iter().filter_map(|k| control(k, defaults)).collect()));
                c.remove("default");
                "section"
            }
        };
        c.insert("kind".into(), Value::from(kind));
        Some(Value::Object(c))
    }
    json!({
        "panel": "NTSC (TV)",
        "about": "ntsc-rs's model of a composite NTSC signal: the picture encoded as luma and a color subcarrier, filtered, noised and decoded again — smear, ringing, color bleed and noise. On by default with the app's house settings. Its old VHS emulation (head switching, tracking noise, tape settings) is retired and hidden: use the VCR stage for tape.",
        "flag": "--ntsc on|off  --ntsc-set key=value,…",
        "settings": "\"ntsc\": \"off\" | {\"enabled\": true, \"settings\": {…}}",
        "controls": ntsc_settings().iter().filter_map(|s| control(s, &defaults)).collect::<Vec<_>>(),
    })
}

fn glitch_control(p: &GlitchParam) -> Value {
    let mut c = Map::new();
    c.insert("id".into(), Value::from(p.id));
    c.insert("label".into(), Value::from(p.label));
    c.insert("default".into(), Value::from(p.default));
    c.insert("help".into(), Value::from(p.help));
    if p.group != Group::Reception {
        c.insert("group".into(), Value::from(p.group.label()));
    }
    if let Some(s) = p.section {
        c.insert("section".into(), Value::from(s));
    }
    match p.kind {
        Kind::Slider { min, max, percent, unit } => {
            c.insert("kind".into(), Value::from("slider"));
            c.insert("min".into(), Value::from(min));
            c.insert("max".into(), Value::from(max));
            if percent {
                c.insert("display".into(), Value::from("percent"));
            }
            if !unit.is_empty() {
                c.insert("unit".into(), Value::from(unit));
            }
        }
        Kind::Toggle => {
            c.insert("kind".into(), Value::from("toggle"));
        }
        Kind::Seed => {
            c.insert("kind".into(), Value::from("seed"));
            c.insert("note".into(), Value::from("A whole number that picks which cassette (1, 2, 3…), not an amount. Only matters when the tape has flaws."));
        }
        Kind::Choice(options) => {
            c.insert("kind".into(), Value::from("choice"));
            c.insert("options".into(), json!(options));
            c.insert("note".into(), Value::from("Takes an option's name or its number (0 = first)."));
        }
    }
    let note = match p.id {
        "tracking_offset" => Some("Signed: ±1 is a whole track either way. Runs on a curve, so the picture holds over most of the travel and breaks up near the ends (|value| ≳ 0.6)."),
        "back_tension" => Some("Signed: positive is tighter than the recording deck (skew, the top of the picture hooks sideways), negative is slacker (the top of the picture waves from side to side and gets noisy). 0 matches it. Up to ±0.5 is a deck out of adjustment; beyond, the effect grows four times as fast (a stretched tape: strong hooking, noise bars on LP and EP)."),
        "search_speed" => Some("1 is normal play; 2–9 is fast-forward picture search."),
        "rf" => Some("On: the picture reaches the TV as a game console's signal on channel 3 through the antenna socket — colored fringes on hard edges that crawl, fine detail softened, the tuner's noise; signal_strength and ghost_level act on that signal. Best on a low Downscale (256 or 320 wide). A typical console-on-RF look: rf on, signal_strength 0.82, ghost_level 0.14, ghost_delay 0.4, hum 0.04, rf_crawl 0.25, rf_color 1.75. Rough: signal_strength 0.72, ghost_level 0.24, ghost_delay 0.5, hum 0.1, rf_crawl 0.55, rf_color 2.65."),
        "rf_crawl" => Some("Needs rf on. Dots crawling beside changes of color, harder outlines, somewhat stronger fringes, a crisper and grainier picture; little added color, and the picture's own color is not changed (that is rf_color). 0.25 typical, 0.55 rough, 1 extreme."),
        "rf_smear" => Some("Needs rf on. The color trails to the right of what it colors and is thin inside left edges; brightness stays put. 0.25 slight, 0.5 typical RF, 1 heavy (about 4 pixels late at 256 wide)."),
        "rf_soft" => Some("Needs rf on. Blurs the brightness's detail (small text merges); color and levels untouched. 0.2 typical RF."),
        "rf_offset" => Some("Needs rf on. The set tuned off the channel: detail loses contrast with a halo round shapes, color weakens and gets noisy and unsteady, then drops to black and white from about 0.85. 0.3 is a set not quite on the channel."),
        "rf_color" => Some("Needs rf on. The picture's own color: 0 black and white, 1 as sent, up to 4 (garish). 1.3 to 1.75 is how RF usually looked; fringes and noise are rf_crawl's."),
        _ => None,
    };
    if let Some(n) = note {
        c.insert("note".into(), Value::from(n));
    }
    Value::Object(c)
}

fn glitch() -> Value {
    json!({
        "panel": "Glitch",
        "about": "The TV set and the broadcast reaching it: weak signal, hold controls, ghosts, hum. A simulation of the receiver's circuits; every knob is one a real set had. On by default with every knob healthy, which changes nothing.",
        "flag": "--glitch on|off  --glitch-set key=value,…",
        "settings": "\"glitch\": \"off\" | {\"values\": {\"signal_strength\": 0.4}}",
        "controls": gp::controls(Group::Reception).map(glitch_control).collect::<Vec<_>>(),
    })
}

pub fn condition(c: &VcrCondition) -> Value {
    let values: Map<String, Value> = c.values.iter().map(|(k, _)| (k.to_string(), Value::from(c.value(k)))).collect();
    json!({"name": c.name, "about": c.help, "values": values})
}

fn vcr() -> Value {
    json!({
        "panel": "VCR",
        "about": "Plays the picture off a simulated VHS tape: recorded as FM on slanted tracks, read back by two spinning heads, through the tape's condition and the deck's. Off by default. History matters — clogs build up as it plays, the tracking servo hunts, creases sweep through over seconds — so look at more than the first frame. The Tape and Deck pickers set a whole condition at once; set `values` after them to adjust.",
        "flag": "--vcr on|off  --tape <name>  --deck <name>  --vcr-set key=value,…   (any of these but --vcr off switches it on)",
        "settings": "\"vcr\": \"on\" | \"off\" | {\"tape\": \"Moldy\", \"deck\": \"Dirty heads\", \"values\": {\"tape_speed\": \"LP\"}}",
        "tapes": TAPES.iter().map(condition).collect::<Vec<_>>(),
        "decks": DECKS.iter().map(condition).collect::<Vec<_>>(),
        "cost": "Each Generation (copy) is a full extra playback: a Third copy takes about four times as long as an Original.",
        "controls": gp::controls(Group::Tape).chain(gp::controls(Group::Deck)).map(glitch_control).collect::<Vec<_>>(),
    })
}

fn crt(ids: &[String]) -> CliResult<Value> {
    let root = find_shaders().ok_or_else(|| CliError::failed("The CRT shaders weren't found (the shaders folder next to ntscrt.exe, or NTSCRT_SHADERS)."))?;
    let mut presets = Vec::new();
    for id in ids {
        let id = id.as_str();
        let Some((id, name, rel)) = CRT_SHADERS.iter().find(|s| s.0 == id) else {
            let all: Vec<&str> = CRT_SHADERS.iter().map(|s| s.0).collect();
            return Err(CliError::usage(format!("No CRT preset \"{id}\". Presets: {}.", all.join(", "))));
        };
        let params = preset_parameters(&root.join(rel)).map_err(|_| CliError::failed(format!("CRT preset {id} failed to compile.")))?;
        let defaults = app_shader_defaults(id);
        let mut seen = std::collections::HashSet::new();
        let mut list = Vec::new();
        for p in &params {
            if !seen.insert(p.name.clone()) {
                continue;
            }
            let pres = presentation(p);
            if pres.kind == PKind::Header {
                continue;
            }
            let default = defaults.iter().find(|(n, _)| *n == p.name).map_or(p.initial, |(_, v)| *v);
            let mut c = Map::new();
            c.insert("id".into(), Value::from(p.name.as_str()));
            c.insert("label".into(), Value::from(pres.title.as_str()));
            c.insert("min".into(), Value::from(p.minimum as f64));
            c.insert("max".into(), Value::from(p.maximum as f64));
            c.insert("default".into(), Value::from(default as f64));
            if p.step > 0.0 {
                c.insert("step".into(), Value::from(p.step as f64));
            }
            let kind = match &pres.kind {
                PKind::Toggle => "toggle",
                PKind::Picker { values, labels, .. } => {
                    c.insert("values".into(), json!(values.iter().map(|v| *v as f64).collect::<Vec<_>>()));
                    if let Some(l) = labels {
                        c.insert("options".into(), json!(l));
                    }
                    "choice"
                }
                PKind::Stepper { .. } => "integer",
                _ => "slider",
            };
            c.insert("kind".into(), Value::from(kind));
            if let Some(cap) = &pres.caption {
                c.insert("note".into(), Value::from(cap.as_str()));
            }
            list.push(Value::Object(c));
        }
        presets.push(json!({"id": id, "name": name, "params": list}));
    }
    Ok(json!({
        "panel": "CRT",
        "about": "A CRT shader (libretro slang presets via librashader): scanlines, the shadow mask, glow, curvature. On by default with CRT Glow (Gaussian). Each preset has its own parameters; describe one with --crt <id>.",
        "flag": "--crt <preset>|on|off  --crt-set param=value,…",
        "settings": "\"crt\": \"royale\" | \"off\" | {\"preset\": \"royale\", \"params\": {…}}",
        "presetIDs": CRT_SHADERS.iter().map(|s| json!({"id": s.0, "name": s.1})).collect::<Vec<_>>(),
        "default": "glow_gauss",
        "presets": presets,
    }))
}

fn output() -> Value {
    json!({
        "about": "What `render` writes, chosen by the -o extension or --format.",
        "formats": {
            "mp4": "H.264 (or --format hevc)",
            "gif": "GIF at its own width (--gif-width, default 480) and frame rate (--gif-fps, default 12)",
            "png": "one frame; --time 0,1.5,3 writes one per time",
            "mov": "ProRes: not available on Windows",
        },
        "size": "--long-edge N (default 1920) at the source's aspect; --snap rounds to the scanline grid",
        "length": "a clip renders whole; a still becomes a video of --duration seconds (default 5) at --fps (default 30), or its look's timeline",
        "other": "--quality standard|high|very-high|maximum, --loops N, --save-look file.json, --dry-run",
    })
}

// MARK: looks

pub fn looks() -> Value {
    let built_in: Vec<Value> = built_in_looks()
        .into_iter()
        .map(|(name, path)| {
            let mut o = Map::new();
            o.insert("name".into(), Value::from(name));
            if let Some(Value::Object(d)) = std::fs::read_to_string(&path).ok().and_then(|t| ntscrt_engine::serde_json::from_str(&t).ok()) {
                if let Some(text) = d.get("description").and_then(Value::as_str) {
                    o.insert("description".into(), Value::from(text));
                }
                o.insert("stages".into(), look_stages(&d));
            }
            Value::Object(o)
        })
        .collect();
    json!({
        "looks": built_in,
        "about": "Whole looks: pass a name to --look (or \"look\" in --settings), then adjust any stage. Tapes and decks are the VCR's pickers; formats are Digital video's; presets are the CRT's.",
        "tapes": TAPES.iter().map(condition).collect::<Vec<_>>(),
        "decks": DECKS.iter().map(condition).collect::<Vec<_>>(),
        "digitalFormats": DigitalFormat::all().iter().map(|f| json!({"id": f.id, "name": f.name, "about": f.blurb})).collect::<Vec<_>>(),
        "crtPresets": CRT_SHADERS.iter().map(|s| json!({"id": s.0, "name": s.1})).collect::<Vec<_>>(),
    })
}

/// A look file's stages in brief, read from the file itself.
fn look_stages(d: &Map<String, Value>) -> Value {
    let on = |key: &str, def: bool| d.get(key).and_then(|s| s.get("enabled")).and_then(Value::as_bool).unwrap_or(def);
    let floats = |v: Option<&Value>| -> std::collections::BTreeMap<String, f64> {
        v.and_then(Value::as_object).map(|m| m.iter().filter_map(|(k, v)| v.as_f64().map(|f| (k.clone(), f))).collect()).unwrap_or_default()
    };
    let mut s = Map::new();
    if let Some(r) = d.get("crop").and_then(|c| c.get("ratio")) {
        s.insert("crop".into(), r.clone());
    }
    if on("digital", false) {
        let values = floats(d.get("digital").and_then(|x| x.get("values")));
        let width = d.get("downscale").and_then(|x| x.get("width")).and_then(Value::as_u64).unwrap_or(0) as usize;
        s.insert("digital".into(), Value::from(DigitalFormat::matching(&values, width).map_or("custom", |f| f.name)));
    }
    s.insert("ntsc".into(), Value::from(on("ntsc", true)));
    if on("downscale", true) {
        if let Some(w) = d.get("downscale").and_then(|x| x.get("width")) {
            s.insert("downscale".into(), w.clone());
        }
    }
    let values = gp::GlitchSettings::migrated(&floats(d.get("glitch").and_then(|g| g.get("values"))));
    let full = gp::GlitchSettings::from_values(values.iter().map(|(k, v)| (k, *v)));
    if values.get(gp::VCR_ID).copied().unwrap_or(0.0) >= 0.5 {
        s.insert(
            "vcr".into(),
            json!({
                "tape": VcrCondition::matching(&TAPES, &TAPE_KEYS, &full).map_or("custom", |c| c.name),
                "deck": VcrCondition::matching(&DECKS, &DECK_KEYS, &full).map_or("custom", |c| c.name),
            }),
        );
    }
    if on("glitch", true) && gp::controls(Group::Reception).any(|p| (values.get(p.id).copied().unwrap_or(p.default) - p.default).abs() > 1e-9) {
        s.insert("glitch".into(), Value::Bool(true));
    }
    let shader = d.get("shader");
    let crt_on = shader.and_then(|x| x.get("enabled")).and_then(Value::as_bool).unwrap_or(true);
    s.insert("crt".into(), Value::from(if crt_on { shader.and_then(|x| x.get("preset")).and_then(Value::as_str).unwrap_or("glow_gauss") } else { "off" }));
    if let Some(keys) = d.get("timeline").and_then(|t| t.get("keys")).and_then(Value::as_array).filter(|k| !k.is_empty()) {
        s.insert("keyframes".into(), Value::from(keys.len()));
    }
    Value::Object(s)
}
