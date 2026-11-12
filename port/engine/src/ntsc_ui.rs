//! The NTSC panel's schema and starting values, as the Mac app builds them
//! (`NtscSettingsModel.swift`, `AppState.appNtscDefaults`): ntsc-rs's own
//! settings list, relabeled and regrouped for legibility. Values are the flat
//! JSON ntsc-rs reads and writes, so presets still paste both ways with the
//! ntsc-rs app.

use ntsc_rs::settings::standard::NtscEffectFullSettings;
use ntsc_rs::settings::{SettingDescriptor, SettingKind, SettingsList};
use serde_json::{json, Map, Value};

#[derive(Clone, Debug)]
pub enum NtscKind {
    Boolean,
    Percentage { logarithmic: bool },
    Int { min: i32, max: i32 },
    Float { min: f32, max: f32, logarithmic: bool },
    Enumeration { options: Vec<(String, u32)> },
    /// A setting with an on/off switch of its own, and children.
    Group { children: Vec<NtscSetting> },
    /// A heading we add for readability; no setting of its own.
    Section { children: Vec<NtscSetting> },
}

#[derive(Clone, Debug)]
pub struct NtscSetting {
    /// The JSON key.
    pub name: String,
    pub label: String,
    pub description: Option<String>,
    pub kind: NtscKind,
}

fn convert(d: &SettingDescriptor<NtscEffectFullSettings>) -> Option<NtscSetting> {
    let kind = match &d.kind {
        SettingKind::Boolean => NtscKind::Boolean,
        SettingKind::Percentage { logarithmic } => NtscKind::Percentage { logarithmic: *logarithmic },
        SettingKind::IntRange { range } => NtscKind::Int { min: *range.start(), max: *range.end() },
        SettingKind::FloatRange { range, logarithmic } => {
            NtscKind::Float { min: *range.start(), max: *range.end(), logarithmic: *logarithmic }
        }
        SettingKind::Enumeration { options } => {
            NtscKind::Enumeration { options: options.iter().map(|o| (o.label.to_string(), o.index)).collect() }
        }
        SettingKind::Group { children } => NtscKind::Group { children: children.iter().filter_map(convert).collect() },
    };
    Some(NtscSetting {
        name: d.id.name.to_string(),
        label: d.label.to_string(),
        description: d.description.map(str::to_string),
        kind,
    })
}

/// The Mac's house layout (`NtscSetting.houseLayout`): "Scale" reads as the
/// master intensity, the two scales' sliders spend their travel where the
/// useful values are, four loose chroma controls share a heading, and
/// Intensity comes first.
fn house_layout(settings: Vec<NtscSetting>) -> Vec<NtscSetting> {
    fn relabel(mut s: NtscSetting) -> NtscSetting {
        s.label = match s.name.as_str() {
            "scale_settings" => "Intensity".into(),
            "bandwidth_scale" => "Horizontal intensity".into(),
            "vertical_scale" => "Vertical intensity".into(),
            _ => s.label,
        };
        if let NtscKind::Float { logarithmic, .. } = s.kind {
            if s.name == "bandwidth_scale" || s.name == "vertical_scale" {
                s.kind = NtscKind::Float { min: 0.125, max: 3.0, logarithmic };
            }
        }
        if let NtscKind::Group { children } = s.kind {
            s.kind = NtscKind::Group { children: children.into_iter().map(relabel).collect() };
        }
        s
    }
    let mut out: Vec<NtscSetting> = settings.into_iter().map(relabel).collect();

    let chroma = ["chroma_phase_error", "chroma_phase_noise_intensity", "chroma_delay_horizontal", "chroma_delay_vertical"];
    if chroma.iter().all(|n| out.iter().any(|s| s.name == *n)) {
        let anchor = out.iter().position(|s| s.name == chroma[0]).unwrap_or(0);
        let members: Vec<NtscSetting> =
            chroma.iter().map(|n| out.iter().find(|s| s.name == *n).cloned().expect("present")).collect();
        out.retain(|s| !chroma.contains(&s.name.as_str()));
        out.insert(
            anchor.min(out.len()),
            NtscSetting {
                name: "chroma_distortion".into(),
                label: "Chroma distortion".into(),
                description: Some("Phase and delay errors in the color subcarrier.".into()),
                kind: NtscKind::Section { children: members },
            },
        );
    }
    if let Some(i) = out.iter().position(|s| s.name == "scale_settings") {
        let s = out.remove(i);
        out.insert(0, s);
    }
    out
}

/// The NTSC panel's settings, in the Mac app's order.
pub fn ntsc_settings() -> Vec<NtscSetting> {
    let list = SettingsList::<NtscEffectFullSettings>::new();
    house_layout(list.setting_descriptors.iter().filter_map(convert).collect())
}

/// The Mac app's house VHS look (`AppState.appNtscDefaults`, values exact),
/// laid over ntsc-rs's defaults. Reset returns here.
pub fn ntsc_default_values() -> Map<String, Value> {
    let list = SettingsList::<NtscEffectFullSettings>::new();
    let json = list.to_json_string(&NtscEffectFullSettings::default()).expect("ntsc-rs defaults as JSON");
    let mut values: Map<String, Value> = serde_json::from_str(&json).expect("ntsc-rs JSON");
    let house = json!({
        "filter_type": 0,
        "composite_preemphasis": 0.2753769054878048,
        "composite_noise_intensity": 0.1391983173076923,
        "composite_noise_frequency": 0.8576,
        "composite_noise_detail": 2,
        "snow_intensity": 0,
        "video_scanline_phase_shift_offset": 3,
        "luma_smear": 0.6692,
        "head_switching_height": 8,
        "head_switching_offset": 3,
        "head_switching_horizontal_shift": 41.57,
        "head_switching_mid_line_jitter": 0.181,
        "tracking_noise_height": 63,
        "ringing_power": 5.674,
        "ringing_scale": 4.935,
        "luma_noise_intensity": 0.153,
        "chroma_noise_intensity": 0.13054193376068376,
        "chroma_noise_frequency": 0.0777,
        "chroma_phase_error": 0.016,
        "chroma_phase_noise_intensity": 0.029,
        "chroma_delay_horizontal": 1.7279639582876793,
        "chroma_delay_vertical": 2,
        "vhs_chroma_loss": 0.003639155982905983,
        "vhs_edge_wave": 0.34226190476190477,
        "vhs_tape_speed": 3,
        "scale_with_video_size": true,
        "bandwidth_scale": 0.3,
        "vertical_scale": 0.3,
    });
    for (k, v) in house.as_object().expect("object") {
        values.insert(k.clone(), v.clone());
    }
    values
}

/// Values as the settings JSON the engine (and ntsc-rs) reads.
pub fn ntsc_values_json(values: &Map<String, Value>) -> String {
    Value::Object(values.clone()).to_string()
}
