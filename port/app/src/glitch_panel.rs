//! The Glitch panel: the Mac's GlitchPanel — a simulated TV and VCR whose
//! knobs come in two groups, Reception and Tape. Healthy defaults change
//! nothing until a knob is turned.

use eframe::egui;
use ntscrt_engine::glitch::{GlitchSettings, Group, Kind, PARAMS};

use crate::ntsc_panel::edited;

/// Returns true when a knob changed.
pub fn controls(ui: &mut egui::Ui, values: &mut GlitchSettings) -> bool {
    let mut changed = false;
    for group in Group::ALL {
        egui::CollapsingHeader::new(egui::RichText::new(group.label()).strong()).id_salt(("glitch", group.label())).default_open(true).show(ui, |ui| {
            for p in PARAMS.iter().filter(|p| p.group == group) {
                let v = values.get(p.id);
                match p.kind {
                    Kind::Toggle => {
                        let mut on = v >= 0.5;
                        let r = ui.checkbox(&mut on, p.label).on_hover_text(p.help);
                        if r.clicked() {
                            values.values.insert(p.id.to_string(), if on { 1.0 } else { 0.0 });
                            changed = true;
                        }
                    }
                    Kind::Slider { min, max, percent, unit } => {
                        ui.label(p.label).on_hover_text(p.help);
                        let (scale, suffix) = if percent { (100.0, "%".to_string()) } else { (1.0, format!(" {unit}")) };
                        let mut shown = v * scale;
                        let r = ui
                            .add(egui::Slider::new(&mut shown, min * scale..=max * scale).suffix(suffix).max_decimals(if percent { 0 } else { 2 }))
                            .on_hover_text(p.help);
                        if edited(&r) {
                            values.values.insert(p.id.to_string(), shown / scale);
                            changed = true;
                        }
                    }
                }
            }
        });
    }
    changed
}
