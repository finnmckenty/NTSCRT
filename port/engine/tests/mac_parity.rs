//! Values the Windows app starts with, checked against the Mac app's own
//! launch look (tests/fixtures/mac-launch-look.json, written by the Mac app's
//! CRT_SAVE_LOOK hook). Regenerate the fixture if the Mac's defaults change.

use ntscrt_engine::serde_json::{self, Value};

fn mac_look() -> Value {
    serde_json::from_str(include_str!("fixtures/mac-launch-look.json")).expect("fixture")
}

#[test]
fn ntsc_defaults_match_the_mac() {
    let look = mac_look();
    let mac = look["ntsc"]["settings"].as_object().expect("ntsc settings");
    let ours = ntscrt_engine::ntsc_default_values();
    let mut diffs = Vec::new();
    for (k, v) in mac {
        match ours.get(k) {
            None => diffs.push(format!("{k}: missing (Mac {v})")),
            Some(o) => {
                let same = match (o.as_f64(), v.as_f64()) {
                    (Some(a), Some(b)) => (a - b).abs() < 1e-9,
                    _ => o == v,
                };
                if !same {
                    diffs.push(format!("{k}: ours {o}, Mac {v}"));
                }
            }
        }
    }
    for k in ours.keys() {
        if !mac.contains_key(k) {
            diffs.push(format!("{k}: only ours"));
        }
    }
    assert!(diffs.is_empty(), "NTSC defaults differ from the Mac:\n{}", diffs.join("\n"));
}

#[test]
fn every_ntsc_setting_has_a_default() {
    let values = ntscrt_engine::ntsc_default_values();
    fn walk(s: &[ntscrt_engine::NtscSetting], values: &serde_json::Map<String, Value>, missing: &mut Vec<String>) {
        for s in s {
            match &s.kind {
                ntscrt_engine::NtscKind::Section { children } => walk(children, values, missing),
                ntscrt_engine::NtscKind::Group { children } => {
                    if !values.contains_key(&s.name) { missing.push(s.name.clone()) }
                    walk(children, values, missing)
                }
                _ => if !values.contains_key(&s.name) { missing.push(s.name.clone()) },
            }
        }
    }
    let mut missing = Vec::new();
    walk(&ntscrt_engine::ntsc_settings(), &values, &mut missing);
    assert!(missing.is_empty(), "no value for: {missing:?}");
    assert_eq!(ntscrt_engine::ntsc_settings()[0].label, "Intensity", "Intensity leads, as on the Mac");
}

#[test]
fn starting_shader_values_match_the_mac() {
    let look = mac_look();
    let preset_id = look["shader"]["preset"].as_str().expect("shader preset id");
    let (_, _, rel) = ntscrt_engine::CRT_SHADERS.iter().find(|s| s.0 == preset_id).expect("known shader");
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Vendor/slang-shaders");
    let mut ours: std::collections::HashMap<String, f32> =
        ntscrt_engine::preset_parameters(&root.join(rel)).expect("params").into_iter().map(|p| (p.name, p.initial)).collect();
    ours.extend(ntscrt_engine::app_shader_defaults(preset_id));
    let mac = look["shader"]["params"].as_object().expect("params");
    let mut diffs = Vec::new();
    for (k, v) in mac {
        let m = v.as_f64().expect("number") as f32;
        match ours.get(k) {
            Some(o) if (o - m).abs() < 1e-6 => {}
            o => diffs.push(format!("{k}: ours {o:?}, Mac {m}")),
        }
    }
    assert!(diffs.is_empty(), "{preset_id} starting values differ:\n{}", diffs.join("\n"));
    assert_eq!(ours.len(), mac.len(), "same parameters");
}
