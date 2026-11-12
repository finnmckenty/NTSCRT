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

/// Whether the person changed the control. egui's sliders also report a
/// change when they merely round a value to their displayed decimals or
/// step grid, which would silently rewrite the look (0.1305 → 0.131); only
/// a value someone actually set is written back.
pub fn edited(r: &egui::Response) -> bool {
    r.changed() && (r.dragged() || r.drag_stopped() || r.clicked() || r.has_focus() || r.lost_focus())
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
            if edited(&r) {
                values.insert(s.name.clone(), Value::Bool(on));
                changed = true;
            }
        }
        NtscKind::Percentage { logarithmic } => {
            ui.label(&s.label);
            let mut v = number(values, &s.name) * 100.0;
            let r = hover(ui.add(egui::Slider::new(&mut v, 0.0..=100.0).logarithmic(*logarithmic).suffix("%").max_decimals(1)), s);
            if edited(&r) {
                values.insert(s.name.clone(), Value::from(v / 100.0));
                changed = true;
            }
        }
        NtscKind::Float { min, max, logarithmic } => {
            ui.label(&s.label);
            let mut v = number(values, &s.name);
            let r = hover(ui.add(egui::Slider::new(&mut v, *min as f64..=*max as f64).logarithmic(*logarithmic).clamping(egui::SliderClamping::Edits)), s);
            if edited(&r) {
                values.insert(s.name.clone(), Value::from(v));
                changed = true;
            }
        }
        NtscKind::Int { min, max } => {
            ui.label(&s.label);
            let mut v = number(values, &s.name).round() as i64;
            // A huge range (the random seed) is a number field, not a slider.
            let r = if (*max as i64 - *min as i64) > 10_000 {
                hover(ui.add(egui::DragValue::new(&mut v).range(*min as i64..=*max as i64)), s)
            } else {
                hover(ui.add(egui::Slider::new(&mut v, *min as i64..=*max as i64)), s)
            };
            if edited(&r) {
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
                    if edited(&r) {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Drawing the panels must not change a single value (egui's sliders
    /// round and snap what they show; that once rewrote the house look).
    #[test]
    fn drawing_the_panels_changes_nothing() {
        let settings = ntscrt_engine::ntsc_settings();
        let start = ntscrt_engine::ntsc_default_values();
        let mut values = start.clone();
        let ctx = egui::Context::default();
        // Shader parameters too: every preset's starting values.
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Vendor/slang-shaders");
        let mut shaders: Vec<(&str, Vec<ntscrt_engine::ShaderParam>, std::collections::HashMap<String, f32>)> = ntscrt_engine::CRT_SHADERS
            .iter()
            .map(|(id, _, rel)| {
                let params = ntscrt_engine::preset_parameters(&root.join(rel)).expect("params");
                let mut v: std::collections::HashMap<String, f32> = params.iter().map(|p| (p.name.clone(), p.initial)).collect();
                v.extend(ntscrt_engine::app_shader_defaults(id));
                (*id, params, v)
            })
            .collect();
        let shader_start: Vec<_> = shaders.iter().map(|s| s.2.clone()).collect();
        for _ in 0..3 {
            let _ = ctx.run_ui(egui::RawInput::default(), |ui| {
                egui::ScrollArea::vertical().show(ui, |ui| {
                    controls(ui, &settings, &mut values);
                    for (id, params, v) in shaders.iter_mut() {
                        for p in params.iter() {
                            crate::shader_panel::control(ui, id, p, v, Some(240));
                        }
                    }
                });
            });
        }
        assert_eq!(values, start, "the NTSC panel rewrote values just by drawing them");
        for ((id, _, v), before) in shaders.iter().zip(shader_start) {
            assert_eq!(v, &before, "{id}: the CRT panel rewrote values just by drawing them");
        }
    }
}
