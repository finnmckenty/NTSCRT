//! The Glitch panel: the Mac's GlitchPanel — a simulated TV whose knobs
//! start healthy and change nothing until turned. Its controls are shared
//! with the VCR panel (vcr_panel.rs).

use eframe::egui;
use ntscrt_engine::glitch::{controls as group_controls, GlitchParam, GlitchSettings, Group, Kind, VcrCondition, CONNECTIONS, CONNECTION_KEYS};

use crate::ntsc_panel::edited;

/// Returns true when a knob changed.
pub fn controls(ui: &mut egui::Ui, values: &mut GlitchSettings) -> bool {
    let mut changed = false;
    // How the picture reaches the set: directly, or through the antenna
    // socket in some state of repair. A starting point for the knobs below,
    // as the VCR's Tape and Deck (the Mac's Connection picker).
    ui.horizontal(|ui| {
        ui.label(egui::RichText::new("Connection").strong());
        let current = VcrCondition::matching(&CONNECTIONS, &CONNECTION_KEYS, values).map_or("Custom", |c| c.name);
        egui::ComboBox::from_id_salt("connection picker")
            .selected_text(current)
            .show_ui(ui, |ui| {
                for c in &CONNECTIONS {
                    if ui.selectable_label(c.name == current, c.name).on_hover_text(c.help).clicked() {
                        c.apply(&CONNECTION_KEYS, values);
                        changed = true;
                    }
                }
            })
            .response
            .on_hover_text("How the picture reaches the TV: directly, or through its antenna socket (RF) on a good day or a bad one. Sets RF input and its five knobs, Signal strength, Ghost and Hum; adjust them below.");
    });
    let mut section = None;
    for p in group_controls(Group::Reception) {
        // A heading where the controls' section changes.
        if p.section.is_some() && p.section != section {
            ui.add_space(4.0);
            ui.label(egui::RichText::new(p.section.unwrap_or_default()).small().weak());
        }
        section = p.section;
        // The tuner's knobs act only with the picture coming in through it.
        let idle = p.id.starts_with("rf_") && !values.flag("rf");
        changed |= ui.add_enabled_ui(!idle, |ui| control(ui, p, values)).inner;
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
        Kind::Choice(names) => {
            // A row of buttons for a few names (the Mac's segmented
            // control), a menu for more.
            let current = (v.round().max(0.0) as usize).min(names.len() - 1);
            let mut picked = current;
            ui.horizontal(|ui| {
                ui.label(p.label).on_hover_text(p.help);
                if names.len() <= 3 {
                    for (i, name) in names.iter().enumerate() {
                        ui.selectable_value(&mut picked, i, *name).on_hover_text(p.help);
                    }
                } else {
                    egui::ComboBox::from_id_salt(("choice", p.id))
                        .selected_text(names[current])
                        .show_ui(ui, |ui| {
                            for (i, name) in names.iter().enumerate() {
                                ui.selectable_value(&mut picked, i, *name);
                            }
                        })
                        .response
                        .on_hover_text(p.help);
                }
            });
            if picked != current {
                values.values.insert(p.id.to_string(), picked as f64);
                return true;
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
                return true;
            }
        }
    }
    false
}
