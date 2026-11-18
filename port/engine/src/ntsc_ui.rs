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
            // Nobody choosing a look knows or cares what Butterworth and
            // constant-k filters are.
            "filter_type" => "Signal quality".into(),
            _ => s.label,
        };
        if s.name == "filter_type" {
            s.description = Some("How the signal's filters treat detail: Sharper keeps more of it; Softer blurs the picture more.".into());
            if let NtscKind::Enumeration { options } = &s.kind {
                // The app's names, in this order (ntsc-rs's indices, so values
                // and preset JSON are unchanged).
                let named: Vec<(String, u32)> = [("Sharper", 1u32), ("Softer", 0)]
                    .iter()
                    .filter(|(_, i)| options.iter().any(|o| o.1 == *i))
                    .map(|(l, i)| (l.to_string(), *i))
                    .collect();
                s.kind = NtscKind::Enumeration { options: named };
            }
        }
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

/// Signal-path details that read as doing nothing in the panel (the noise
/// seed only reshuffles the same noise, the phase shifts only move the
/// dot-crawl pattern, the filters change fine color detail too subtly to
/// judge by eye). Not shown in the panel; looks, keyframes, the command line
/// and the MCP server still read and apply them. Mac: hiddenFromPanel.
pub const HIDDEN_FROM_PANEL: [&str; 8] = [
    "random_seed", "input_luma_filter", "chroma_lowpass_in", "video_scanline_phase_shift",
    "video_scanline_phase_shift_offset", "chroma_demodulation", "vhs_chroma_vert_blend", "chroma_lowpass_out",
];

/// ntsc-rs's names for choices the app renames, still accepted from the
/// command line and AI tools.
pub fn legacy_option(setting: &str, label: &str) -> Option<u32> {
    if setting != "filter_type" {
        return None;
    }
    [("Butterworth (sharper)", 1), ("Butterworth", 1), ("Constant K (blurry)", 0), ("Constant K", 0)]
        .iter()
        .find(|(l, _)| l.eq_ignore_ascii_case(label))
        .map(|(_, i)| *i)
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
    // (2026-11-17: Finn's "new defaults", which leave ntsc-rs's own VHS,
    // head switching and tracking noise to the VCR stage.)
    let house = json!({
        "filter_type": 1,
        "composite_preemphasis": 0,
        "composite_noise_intensity": 0.1591702707237563,
        "composite_noise_frequency": 0.28247526709401705,
        "composite_noise_detail": 1,
        "vhs_settings": false,
        "head_switching": false,
        "tracking_noise": false,
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
        "chroma_phase_noise_intensity": 0.06609468482905982,
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
