//! The Digital video panel: the Mac's DigitalVideoPanel — a camera and a
//! real block codec ahead of the NTSC stage, in four groups. Only the
//! controls the chosen codec has are shown; a control that does nothing
//! until another is turned up is dimmed, with the reason as its tooltip.

use std::collections::BTreeMap;

use eframe::egui;
use ntscrt_engine::codec::{ChromaSubsampling, DigitalGroup, DigitalParam, DigitalParamKind, DigitalSettings};

use crate::ntsc_panel::edited;

/// Returns true when a control changed. `bitrate` is the Bitrate limit as a
/// real rate for the picture on screen ("≈ 163 kbps at 320 × 240, 15 fps"),
/// shown under its slider.
pub fn controls(ui: &mut egui::Ui, values: &mut BTreeMap<String, f64>, bitrate: Option<&str>) -> bool {
    let mut changed = false;
    let settings = DigitalSettings::new(values.iter().map(|(k, v)| (k.clone(), *v)));
    let codec = settings.codec();
    for group in DigitalGroup::ALL {
        egui::CollapsingHeader::new(egui::RichText::new(group.label()).strong()).id_salt(("digital", group.label())).default_open(true).show(ui, |ui| {
            for p in DigitalParam::all().iter().filter(|p| p.group == group && p.applies(codec)) {
                let v = settings.get(p.id);
                let reason = idle_reason(p.id, &settings);
                let help = reason.unwrap_or(p.help);
                ui.add_enabled_ui(reason.is_none(), |ui| match p.kind {
                    DigitalParamKind::Choice(names) => {
                        let mut i = (v.round() as usize).min(names.len().saturating_sub(1));
                        ui.horizontal(|ui| {
                            ui.label(p.label).on_hover_text(help);
                            let before = i;
                            egui::ComboBox::from_id_salt(("digital-choice", p.id)).selected_text(names.get(i).copied().unwrap_or("")).show_ui(ui, |ui| {
                                for (n, name) in names.iter().enumerate() {
                                    ui.selectable_value(&mut i, n, *name);
                                }
                            });
                            if i != before {
                                values.insert(p.id.to_string(), i as f64);
                                changed = true;
                            }
                        });
                    }
                    DigitalParamKind::Slider { min, max, percent, unit } => {
                        ui.label(p.label).on_hover_text(help);
                        let (scale, suffix) = if percent { (100.0, "%".to_string()) } else { (1.0, format!(" {unit}")) };
                        let mut shown = v * scale;
                        let mut slider = egui::Slider::new(&mut shown, min * scale..=max * scale).suffix(suffix);
                        slider = match p.step {
                            Some(s) => slider.step_by(s * scale).max_decimals(0),
                            None => slider.max_decimals(if percent { 0 } else { 2 }),
                        };
                        let r = ui.add(slider).on_hover_text(help);
                        if r.double_clicked() {
                            // As on the Mac: double-click returns to the control's default.
                            values.insert(p.id.to_string(), p.default_value);
                            changed = true;
                        } else if edited(&r) {
                            let v = shown / scale;
                            values.insert(p.id.to_string(), p.step.map_or(v, |s| (v / s).round() * s));
                            changed = true;
                        }
                        if p.id == "bitrate_limit" && reason.is_none() {
                            if let Some(label) = bitrate {
                                ui.weak(label);
                            }
                        }
                    }
                });
            }
        });
    }
    changed
}

/// Why a control does nothing right now: it works on another that's at 0.
fn idle_reason(id: &str, s: &DigitalSettings) -> Option<&'static str> {
    match id {
        "datamosh" if s.get("keyframe_interval") <= 0.0 => Some("Set a keyframe interval above 0 first — datamoshing throws keyframes away."),
        "low_light_noise" if s.get("sensor_noise") <= 0.0 => Some("Turn up Sensor noise first — this sets how much it grows in the dark."),
        "sharpening_width" if s.get("sharpening") <= 0.0 => Some("Turn up Sharpening first — this sets how wide its halos reach."),
        "chroma_upsampling" if s.chroma() == ChromaSubsampling::Full => Some("Set Color below 4:4:4 first — at full resolution there is nothing to scale back up."),
        "loss_pattern" if s.get("data_loss") <= 0.0 => Some("Turn up Data loss first — this sets where it falls."),
        "concealment" if s.get("data_loss") <= 0.0 => Some("Turn up Data loss first — this sets what shows where data was lost."),
        "rate_buffer" if s.get("bitrate_limit") <= 0.0 => Some("Turn up Bitrate limit first — this sets how many bits it lets the codec borrow."),
        "rate_buffer" if s.get("keyframe_interval") <= 0.0 => {
            Some("Set a keyframe interval above 0 first — with every frame compressed on its own, each gets the same bits and there is nothing to borrow.")
        }
        "mosh_motion" if s.get("keyframe_interval") <= 0.0 => {
            Some("Set a keyframe interval above 0 first — added motion acts on the frames between keyframes.")
        }
        "mosh_speed" if s.get("keyframe_interval") <= 0.0 || s.get("mosh_motion") < 0.5 => {
            Some("Choose an Added motion first (and a keyframe interval above 0) — this sets its speed.")
        }
        _ => None,
    }
}
