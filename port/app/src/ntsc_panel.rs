//! The NTSC panel's controls, built from ntsc-rs's settings list (as the
//! Mac's NtscPanel does). Values are ntsc-rs's flat settings JSON.

use eframe::egui;
use ntscrt_engine::serde_json::{Map, Value};
use ntscrt_engine::{NtscKind, NtscSetting};

fn number(values: &Map<String, Value>, name: &str) -> f64 {
    match values.get(name) {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(Value::Bool(b)) => f64::from(u8::from(*b)),
        _ => 0.0,
    }
}

fn boolean(values: &Map<String, Value>, name: &str) -> bool {
    match values.get(name) {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0) != 0.0,
        _ => false,
    }
}

fn hover(r: egui::Response, s: &NtscSetting) -> egui::Response {
    match &s.description {
        Some(d) => r.on_hover_text(d),
        None => r,
    }
}

/// The settings' controls. Returns true when any value changed.
pub fn controls(ui: &mut egui::Ui, settings: &[NtscSetting], values: &mut Map<String, Value>) -> bool {
    let mut changed = false;
    for s in settings {
        changed |= control(ui, s, values);
    }
    changed
}

fn control(ui: &mut egui::Ui, s: &NtscSetting, values: &mut Map<String, Value>) -> bool {
    let mut changed = false;
    match &s.kind {
        NtscKind::Boolean => {
            let mut on = boolean(values, &s.name);
            let r = hover(ui.checkbox(&mut on, &s.label), s);
            if r.changed() {
                values.insert(s.name.clone(), Value::Bool(on));
                changed = true;
            }
        }
        NtscKind::Percentage { logarithmic } => {
            ui.label(&s.label);
            let mut v = number(values, &s.name) * 100.0;
            let r = hover(ui.add(egui::Slider::new(&mut v, 0.0..=100.0).logarithmic(*logarithmic).suffix("%").max_decimals(1)), s);
            if r.changed() {
                values.insert(s.name.clone(), Value::from(v / 100.0));
                changed = true;
            }
        }
        NtscKind::Float { min, max, logarithmic } => {
            ui.label(&s.label);
            let mut v = number(values, &s.name);
            let r = hover(ui.add(egui::Slider::new(&mut v, *min as f64..=*max as f64).logarithmic(*logarithmic).clamping(egui::SliderClamping::Edits)), s);
            if r.changed() {
                values.insert(s.name.clone(), Value::from(v));
                changed = true;
            }
        }
        NtscKind::Int { min, max } => {
            ui.label(&s.label);
            let mut v = number(values, &s.name).round() as i64;
            let r = hover(ui.add(egui::Slider::new(&mut v, *min as i64..=*max as i64)), s);
            if r.changed() {
                values.insert(s.name.clone(), Value::from(v));
                changed = true;
            }
            if s.name == "head_switching_offset" && number(values, "head_switching_offset") >= number(values, "head_switching_height") {
                ui.colored_label(egui::Color32::from_rgb(230, 150, 40), "No effect while Offset ≥ Height");
            }
        }
        NtscKind::Enumeration { options } => {
            ui.label(&s.label);
            let current = number(values, &s.name).round() as u32;
            let selected = options.iter().find(|o| o.1 == current).map_or_else(|| current.to_string(), |o| o.0.clone());
            let r = egui::ComboBox::from_id_salt(&s.name).selected_text(selected).show_ui(ui, |ui| {
                for (label, index) in options {
                    if ui.selectable_label(*index == current, label).clicked() {
                        values.insert(s.name.clone(), Value::from(*index));
                        changed = true;
                    }
                }
            });
            hover(r.response, s);
        }
        NtscKind::Group { children } => {
            let id = ui.make_persistent_id(("ntsc-group", &s.name));
            let state = egui::collapsing_header::CollapsingState::load_with_default_open(ui.ctx(), id, true);
            let mut on = boolean(values, &s.name);
            let (_, header, _) = state
                .show_header(ui, |ui| {
                    let r = hover(ui.checkbox(&mut on, egui::RichText::new(&s.label).strong()), s);
                    if r.changed() {
                        values.insert(s.name.clone(), Value::Bool(on));
                        changed = true;
                    }
                })
                .body(|ui| {
                    if on {
                        changed |= controls(ui, children, values);
                    }
                });
            let _ = header;
        }
        NtscKind::Section { children } => {
            let r = egui::CollapsingHeader::new(egui::RichText::new(&s.label).strong())
                .id_salt(("ntsc-section", &s.name))
                .default_open(true)
                .show(ui, |ui| changed |= controls(ui, children, values));
            hover(r.header_response, s);
        }
    }
    changed
}
