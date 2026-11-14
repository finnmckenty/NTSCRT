//! The VCR panel: the Mac's VcrPanel. Two pickers set the tape's and the
//! deck's condition — a cassette off the shelf, a deck to play it in — and
//! the knobs under each adjust it.

use eframe::egui;
use ntscrt_engine::glitch::{controls as group_controls, GlitchSettings, Group, Kind, VcrCondition, DECKS, DECK_KEYS, TAPES, TAPE_KEYS};

use crate::glitch_panel::control;

/// Returns true when a knob changed.
pub fn controls(ui: &mut egui::Ui, values: &mut GlitchSettings) -> bool {
    let mut changed = false;
    for (group, list, keys) in [(Group::Tape, &TAPES[..], &TAPE_KEYS[..]), (Group::Deck, &DECKS[..], &DECK_KEYS[..])] {
        let label = group.label();
        egui::CollapsingHeader::new(egui::RichText::new(label).strong()).id_salt(("vcr", label)).default_open(true).show(ui, |ui| {
            let current = VcrCondition::matching(list, keys, values).map_or("Custom", |c| c.name);
            egui::ComboBox::from_id_salt(("vcr picker", label))
                .selected_text(current)
                .show_ui(ui, |ui| {
                    for c in list {
                        if ui.selectable_label(c.name == current, c.name).on_hover_text(c.help).clicked() {
                            c.apply(keys, values);
                            changed = true;
                        }
                    }
                })
                .response
                .on_hover_text(format!("Start from a typical {} condition, then adjust it below", label.to_lowercase()));
            for p in group_controls(group) {
                changed |= control(ui, p, values);
            }
        });
    }
    changed
}

/// A new tape in a clean deck (the switch and cassette left as they are).
pub fn reset(values: &mut GlitchSettings) {
    for g in [Group::Tape, Group::Deck] {
        for p in group_controls(g).filter(|p| p.kind != Kind::Seed) {
            values.values.insert(p.id.to_string(), p.default);
        }
    }
}
