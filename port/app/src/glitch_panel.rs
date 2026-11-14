//! The Glitch panel: the Mac's GlitchPanel — a simulated TV whose knobs
//! start healthy and change nothing until turned. Its controls are shared
//! with the VCR panel (vcr_panel.rs).

use eframe::egui;
use ntscrt_engine::glitch::{controls as group_controls, GlitchParam, GlitchSettings, Group, Kind};

use crate::ntsc_panel::edited;

/// Returns true when a knob changed.
pub fn controls(ui: &mut egui::Ui, values: &mut GlitchSettings) -> bool {
    let mut changed = false;
    for p in group_controls(Group::Reception) {
        changed |= control(ui, p, values);
    }
    changed
}

/// One knob. Returns true when it changed.
pub fn control(ui: &mut egui::Ui, p: &GlitchParam, values: &mut GlitchSettings) -> bool {
    let v = values.get(p.id);
    match p.kind {
        Kind::Toggle => {
            let mut on = v >= 0.5;
            let r = ui.checkbox(&mut on, p.label).on_hover_text(p.help);
            if r.clicked() {
                values.values.insert(p.id.to_string(), if on { 1.0 } else { 0.0 });
                return true;
            }
        }
        Kind::Seed => {
            let mut changed = false;
            ui.horizontal(|ui| {
                ui.label(format!("{} #{}", p.label, v.round() as i64)).on_hover_text(p.help);
                if ui.small_button("Another").on_hover_text(p.help).clicked() {
                    values.values.insert(p.id.to_string(), v.round() + 1.0);
                    changed = true;
                }
            });
            return changed;
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
                return true;
            }
        }
    }
    false
}
