//! Looks: the Mac app's preset JSON (`AppState.lookDictionary` / `loadLook`),
//! read and written in the same format so a look moves between the two apps.
//! Anything the Windows version doesn't know (Screen Loop's settings, keys
//! from later versions) is kept as it was, so saving a look here never
//! drops it.

use std::collections::HashMap;

use anyhow::{bail, Context, Result};
use serde_json::{Map, Value};

use crate::timeline::{Easing, Keyframe};
use crate::crop::{Crop, Ratio};
use crate::DownscaleMethod;

#[derive(Clone, Debug, Default)]
pub struct Look {
    /// The whole file, for writing back what this version doesn't use.
    pub raw: Map<String, Value>,
    pub version: i64,
    pub downscale_enabled: Option<bool>,
    pub downscale_width: Option<u32>,
    pub downscale_preset: Option<String>,
    /// None when the file names a method this version doesn't know.
    pub downscale_method: Option<DownscaleMethod>,
    pub ntsc_enabled: Option<bool>,
    pub ntsc_settings: Option<Map<String, Value>>,
    pub shader_enabled: Option<bool>,
    pub shader_preset: Option<String>,
    pub shader_params: HashMap<String, f32>,
    pub keys: Vec<Keyframe>,
    /// The Glitch stage: on/off and knobs (missing knobs are healthy).
    /// Looks from before the stage load it on and healthy, which renders
    /// exactly as they always looked.
    pub glitch_enabled: bool,
    pub glitch_values: crate::glitch::GlitchSettings,
    /// The Digital video stage (looks from before it existed leave it off;
    /// version-1 values are migrated as on the Mac).
    pub digital: Option<(bool, std::collections::BTreeMap<String, f64>)>,
    pub timeline_enabled: Option<bool>,
    /// A still's animation length and frame rate.
    pub timeline_duration: Option<f64>,
    pub timeline_fps: Option<u32>,
    /// Only a crop that's on travels with a look (the Mac's rule); a look
    /// without one leaves the current crop alone.
    pub crop: Option<Crop>,
}

fn floats(v: Option<&Value>) -> HashMap<String, f32> {
    v.and_then(Value::as_object)
        .map(|m| m.iter().filter_map(|(k, v)| v.as_f64().map(|f| (k.clone(), f as f32))).collect())
        .unwrap_or_default()
}

fn object(v: Option<&Value>) -> Map<String, Value> {
    v.and_then(Value::as_object).cloned().unwrap_or_default()
}

impl Look {
    pub fn parse(json: &str) -> Result<Look> {
        let raw: Map<String, Value> = serde_json::from_str(json).context("not a look file (JSON object expected)")?;
        if raw.get("kind").and_then(Value::as_str) == Some("ntscrt-video-feedback") {
            bail!("This is a Screen Loop preset, not a look.");
        }
        let mut look = Look { version: raw.get("version").and_then(Value::as_i64).unwrap_or(1), ..Default::default() };
        if let Some(d) = raw.get("downscale").and_then(Value::as_object) {
            look.downscale_enabled = d.get("enabled").and_then(Value::as_bool);
            look.downscale_width = d.get("width").and_then(Value::as_u64).map(|w| w as u32);
            look.downscale_preset = Some(d.get("preset").and_then(Value::as_str).unwrap_or("Custom").to_string());
            look.downscale_method = d.get("method").and_then(Value::as_str).and_then(DownscaleMethod::from_raw);
        }
        if let Some(n) = raw.get("ntsc").and_then(Value::as_object) {
            look.ntsc_enabled = n.get("enabled").and_then(Value::as_bool);
            look.ntsc_settings = n.get("settings").and_then(Value::as_object).cloned();
        }
        if let Some(s) = raw.get("shader").and_then(Value::as_object) {
            look.shader_enabled = s.get("enabled").and_then(Value::as_bool);
            look.shader_preset = s.get("preset").and_then(Value::as_str).map(str::to_string);
            look.shader_params = floats(s.get("params"));
        }
        look.glitch_enabled = true;
        if let Some(g) = raw.get("glitch").and_then(Value::as_object) {
            let values = object(g.get("values"));
            look.glitch_values = crate::glitch::GlitchSettings::from_values(values.iter().filter_map(|(k, v)| v.as_f64().map(|f| (k, f))));
            look.glitch_enabled = g.get("enabled").and_then(Value::as_bool).unwrap_or(true);
        }
        if let Some(d) = raw.get("digital").and_then(Value::as_object) {
            let values: std::collections::BTreeMap<String, f64> =
                object(d.get("values")).iter().filter_map(|(k, v)| v.as_f64().map(|f| (k.clone(), f))).collect();
            look.digital = Some((
                d.get("enabled").and_then(Value::as_bool).unwrap_or(false),
                ntscrt_codec::DigitalSettings::migrated(&values, look.version),
            ));
        }
        if let Some(t) = raw.get("timeline").and_then(Value::as_object) {
            look.timeline_enabled = t.get("enabled").and_then(Value::as_bool);
            look.timeline_duration = t.get("duration").and_then(Value::as_f64);
            look.timeline_fps = t.get("fps").and_then(Value::as_u64).map(|f| f as u32);
        }
        if let Some(keys) = raw.get("timeline").and_then(|t| t.get("keys")).and_then(Value::as_array) {
            look.keys = keys
                .iter()
                .filter_map(|k| {
                    Some(Keyframe {
                        t: k.get("t")?.as_f64()?,
                        easing: k.get("easing").and_then(Value::as_str).and_then(Easing::from_raw).unwrap_or_default(),
                        shader: floats(k.get("shader")),
                        ntsc: object(k.get("ntsc")),
                        glitch: object(k.get("glitch")),
                        digital: {
                            let d = object(k.get("digital"));
                            let floats: std::collections::BTreeMap<String, f64> = d.iter().filter_map(|(k, v)| v.as_f64().map(|f| (k.clone(), f))).collect();
                            ntscrt_codec::DigitalSettings::migrated(&floats, look.version).into_iter().map(|(k, v)| (k, Value::from(v))).collect()
                        },
                    })
                })
                .collect();
            look.keys.sort_by(|a, b| a.t.total_cmp(&b.t));
        }
        if let Some(c) = raw.get("crop").and_then(Value::as_object) {
            if let Some(ratio) = c.get("ratio").and_then(Value::as_str).and_then(Ratio::from_label) {
                // Looks from before the crop could zoom have one position.
                let position = c.get("position").and_then(Value::as_f64).unwrap_or(0.5);
                let unit = |k: &str| c.get(k).and_then(Value::as_f64).unwrap_or(position).clamp(0.0, 1.0);
                look.crop = Some(Crop {
                    ratio,
                    x: unit("x"),
                    y: unit("y"),
                    scale: c.get("scale").and_then(Value::as_f64).unwrap_or(1.0).clamp(1.0, Crop::MAX_SCALE),
                });
            }
        }
        look.raw = raw;
        Ok(look)
    }

    /// What this look uses that the Windows version can't show yet.
    pub fn unported(&self) -> Vec<&'static str> {
        let mut out = Vec::new();
        if self.raw.get("downscale").and_then(|d| d.get("method")).is_some() && self.downscale_method.is_none() {
            out.push("its downscale method");
        }
        out
    }
}

impl Look {
    /// What the Windows pipeline renders for this look on a picture of
    /// `source` size, as the Mac app shows it right after loading: the
    /// shader's starting values (preset plus the Mac's tweaks) under the
    /// look's, and with keyframes, the first key's values on top.
    pub fn render_settings(&self, source: (u32, u32), shaders: &std::path::Path, frame: usize) -> Result<crate::Settings> {
        let digital = self.digital.as_ref().filter(|d| d.0).map(|d| ntscrt_codec::DigitalSettings::new(d.1.clone()));
        let downscale = match (self.downscale_enabled.unwrap_or(true), self.downscale_width) {
            (true, Some(w)) => {
                let d = crate::DownscaleSpec::for_width(w, source, self.downscale_method.unwrap_or(DownscaleMethod::Nearest));
                Some(if digital.as_ref().is_some_and(|s| s.get("fields") >= 0.5) { d.one_field() } else { d })
            }
            _ => None,
        };
        let mut ntsc = self.ntsc_settings.clone().unwrap_or_else(crate::ntsc_default_values);
        let first = self.keys.first();
        if let Some(k) = first.filter(|k| !k.ntsc.is_empty()) {
            ntsc = k.ntsc.clone();
        }
        let shader = if self.shader_enabled.unwrap_or(true) {
            let id = self.shader_preset.as_deref().unwrap_or("glow_gauss");
            let (_, _, rel) = crate::CRT_SHADERS.iter().find(|s| s.0 == id).context("unknown shader")?;
            let preset = shaders.join(rel);
            let mut values: HashMap<String, f32> = crate::preset_parameters(&preset)?.into_iter().map(|p| (p.name, p.initial)).collect();
            values.extend(crate::app_shader_defaults(id));
            values.extend(self.shader_params.iter().map(|(k, v)| (k.clone(), *v)));
            if let Some(k) = first {
                values.extend(k.shader.iter().map(|(k, v)| (k.clone(), *v)));
            }
            let mut params: Vec<(String, f32)> = values.into_iter().collect();
            params.sort_by(|a, b| a.0.cmp(&b.0));
            Some(crate::ShaderSpec { preset, params })
        } else {
            None
        };
        Ok(crate::Settings {
            ntsc: self.ntsc_enabled.unwrap_or(true).then(|| crate::NtscSettings::Json(crate::ntsc_values_json(&ntsc))),
            downscale,
            shader,
            frame,
            // The receiver at time zero (a look's first moment).
            glitch: self.glitch_enabled.then(|| crate::glitch::GlitchFrame { settings: self.glitch_values.clone(), time: 0.0, history: None }),
            // Frame 0 of a still at the timeline's rate.
            digital: digital.map(|settings| crate::DigitalFrame {
                settings,
                frame: frame as i64,
                source_fps: self.timeline_fps.unwrap_or(30).max(1) as f64,
                capture: crate::DigitalFrame::capture_size(source, downscale.map(|d| (d.width, d.picture_height()))),
                history: None,
            }),
        })
    }
}

/// The part of a look this version owns.
pub struct LookState<'a> {
    pub downscale_enabled: bool,
    pub downscale_width: u32,
    pub downscale_preset: &'a str,
    pub downscale_method: DownscaleMethod,
    pub ntsc_enabled: bool,
    pub ntsc_settings: &'a Map<String, Value>,
    pub shader_enabled: bool,
    pub shader_preset: &'a str,
    pub shader_params: &'a HashMap<String, f32>,
    pub crop: Option<Crop>,
    pub timeline: Option<TimelineState<'a>>,
    pub glitch: Option<(bool, &'a crate::glitch::GlitchSettings)>,
    pub digital: Option<(bool, &'a std::collections::BTreeMap<String, f64>)>,
}

pub struct TimelineState<'a> {
    pub enabled: bool,
    pub duration: f64,
    pub fps: u32,
    pub keys: &'a [Keyframe],
}

/// A look file: `base` (the look last loaded, if any) with this version's
/// sections replaced. Pretty-printed with sorted keys, as the Mac writes.
pub fn write_look(base: Option<&Map<String, Value>>, s: &LookState) -> String {
    let mut look = base.cloned().unwrap_or_default();
    // A look without a timeline section loads fine on the Mac; with one from
    // the base, its keys are kept.
    look.insert("version".into(), Value::from(2));
    look.insert(
        "downscale".into(),
        serde_json::json!({
            "enabled": s.downscale_enabled,
            "width": s.downscale_width,
            "preset": s.downscale_preset,
            "method": s.downscale_method.raw(),
        }),
    );
    look.insert("ntsc".into(), serde_json::json!({ "enabled": s.ntsc_enabled, "settings": s.ntsc_settings }));
    let params: Map<String, Value> = s.shader_params.iter().map(|(k, v)| (k.clone(), Value::from(*v as f64))).collect();
    look.insert("shader".into(), serde_json::json!({ "enabled": s.shader_enabled, "preset": s.shader_preset, "params": params }));
    if let Some((enabled, d)) = s.digital {
        look.insert("digital".into(), serde_json::json!({ "enabled": enabled, "values": d }));
    }
    if let Some((enabled, g)) = s.glitch {
        look.insert("glitch".into(), serde_json::json!({ "enabled": enabled, "values": g.values }));
    }
    if let Some(t) = &s.timeline {
        let keys: Vec<Value> = t
            .keys
            .iter()
            .map(|k| {
                let shader: Map<String, Value> = k.shader.iter().map(|(n, v)| (n.clone(), Value::from(*v as f64))).collect();
                serde_json::json!({ "t": k.t, "easing": k.easing.raw(), "shader": shader, "ntsc": k.ntsc, "glitch": k.glitch, "digital": k.digital })
            })
            .collect();
        look.insert("timeline".into(), serde_json::json!({ "enabled": t.enabled, "duration": t.duration, "fps": t.fps, "keys": keys }));
    }
    match s.crop {
        Some(c) => {
            look.insert("crop".into(), serde_json::json!({ "ratio": c.ratio.label(), "x": c.x, "y": c.y, "scale": c.scale }));
        }
        None => {
            look.remove("crop");
        }
    }
    // serde_json's Map is a BTreeMap (sorted) without the preserve_order feature.
    serde_json::to_string_pretty(&Value::Object(look)).expect("JSON")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_every_bundled_preset() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../presets");
        let mut n = 0;
        for e in std::fs::read_dir(&dir).unwrap() {
            let p = e.unwrap().path();
            if p.extension().is_some_and(|x| x == "json") {
                let look = Look::parse(&std::fs::read_to_string(&p).unwrap()).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
                assert!(look.downscale_width.is_some(), "{}", p.display());
                n += 1;
            }
        }
        assert!(n >= 20, "found {n} presets");
    }

    #[test]
    fn round_trips_what_it_does_not_use() {
        let json = r#"{"version":1,"glitch":{"enabled":true,"values":{"tracking":0.5}},"digital":{"enabled":true,"values":{}},
            "crop":{"ratio":"1:1","x":0.5,"y":0.5,"scale":1},"timeline":{"keys":[{"t":0,"shader":{},"ntsc":{}}]},
            "downscale":{"enabled":true,"width":256,"method":"lanczos"},"ntsc":{"enabled":false,"settings":{"luma_smear":0.5}},
            "shader":{"enabled":true,"preset":"royale","params":{"x":1}}}"#;
        let look = Look::parse(json).unwrap();
        assert!(look.unported().is_empty());
        assert_eq!(look.digital.as_ref().map(|d| d.0), Some(true));
        assert_eq!(look.crop, Some(Crop::new(Ratio::SQUARE)));
        assert_eq!(look.downscale_method, Some(DownscaleMethod::Lanczos));
        let ntsc = look.ntsc_settings.clone().unwrap();
        let params = HashMap::from([("x".to_string(), 2.0f32)]);
        let out = write_look(
            Some(&look.raw),
            &LookState {
                downscale_enabled: true,
                downscale_width: 320,
                downscale_preset: "Custom",
                downscale_method: DownscaleMethod::Area,
                ntsc_enabled: true,
                ntsc_settings: &ntsc,
                shader_enabled: true,
                shader_preset: "royale",
                shader_params: &params,
                crop: Some(Crop { x: 0.25, ..Crop::new(Ratio::new(9, 16)) }),
                timeline: None,
                glitch: None,
                digital: None,
            },
        );
        let back = Look::parse(&out).unwrap();
        assert_eq!(back.crop.map(|c| (c.ratio, c.x)), Some((Ratio::new(9, 16), 0.25)));
        assert_eq!(back.version, 2);
        assert_eq!(back.downscale_width, Some(320));
        assert_eq!(back.shader_params["x"], 2.0);
        assert_eq!(back.raw["glitch"], look.raw["glitch"], "kept");
        assert_eq!(back.keys.len(), 1, "keys kept");
        assert!(Look::parse(r#"{"kind":"ntscrt-video-feedback"}"#).is_err());
    }
}

#[cfg(test)]
mod timeline_tests {
    use super::*;

    #[test]
    fn keyframes_round_trip_in_the_macs_format() {
        let src = std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../presets/5 second glitch.json")).unwrap();
        let look = Look::parse(&src).unwrap();
        assert!(look.keys.len() > 1);
        let ntsc = look.ntsc_settings.clone().unwrap_or_default();
        let params = HashMap::new();
        let out = write_look(
            Some(&look.raw),
            &LookState {
                downscale_enabled: true,
                downscale_width: 384,
                downscale_preset: "Custom",
                downscale_method: DownscaleMethod::Area,
                ntsc_enabled: true,
                ntsc_settings: &ntsc,
                shader_enabled: true,
                shader_preset: "glow_gauss",
                shader_params: &params,
                crop: None,
                timeline: Some(TimelineState { enabled: true, duration: 5.0, fps: 30, keys: &look.keys }),
                glitch: None,
                digital: None,
            },
        );
        let back = Look::parse(&out).unwrap();
        assert_eq!(back.keys.len(), look.keys.len());
        for (a, b) in back.keys.iter().zip(&look.keys) {
            assert_eq!((a.t, a.easing), (b.t, b.easing));
            assert_eq!(a.shader, b.shader, "shader at {}", b.t);
            for (k, v) in &b.ntsc {
                assert_eq!(a.ntsc.get(k), Some(v), "ntsc {k} at {}", b.t);
            }
            assert_eq!(a.glitch, b.glitch, "glitch at {}", b.t);
            assert_eq!(a.digital, b.digital, "digital at {}", b.t);
        }
        assert_eq!((back.timeline_duration, back.timeline_fps), (Some(5.0), Some(30)));
    }
}
