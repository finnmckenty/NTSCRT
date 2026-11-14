//! The Glitch stage's knobs: a port of the Mac's `GlitchParams.swift`. The
//! stage simulates a TV receiver and a VCR transport, so every control is a
//! knob that existed on one of them (or a physical condition of the signal).
//! Defaults describe a healthy set on a clean signal: enabling the stage
//! changes nothing until a knob is turned.

use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Group {
    /// The TV and the signal reaching it (the Glitch panel).
    Reception,
    /// The cassette's condition (the VCR panel).
    Tape,
    /// The deck: its heads and transport (the VCR panel).
    Deck,
}

impl Group {
    pub const ALL: [Group; 3] = [Group::Reception, Group::Tape, Group::Deck];
    pub fn label(self) -> &'static str {
        match self {
            Group::Reception => "Reception",
            Group::Tape => "Tape",
            Group::Deck => "Deck",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    /// `percent` controls show 0–100 (or ±100); `unit` labels the rest.
    Slider { min: f64, max: f64, percent: bool, unit: &'static str },
    Toggle,
    /// A whole number picking one of endlessly many variations (which
    /// cassette): a "next one" button, never interpolated.
    Seed,
}

#[derive(Clone, Copy, Debug)]
pub struct GlitchParam {
    pub id: &'static str,
    pub label: &'static str,
    pub group: Group,
    pub kind: Kind,
    pub default: f64,
    pub help: &'static str,
}

impl GlitchParam {
    pub fn is_toggle(&self) -> bool {
        self.kind == Kind::Toggle
    }
    /// Stepped, not blended, between keyframes.
    pub fn is_discrete(&self) -> bool {
        matches!(self.kind, Kind::Toggle | Kind::Seed)
    }
}

/// The VCR panel's on/off switch, kept with the knobs so it is saved,
/// keyframed and exported along with them.
pub const VCR_ID: &str = "vcr";

const fn slider(min: f64, max: f64, percent: bool, unit: &'static str) -> Kind {
    Kind::Slider { min, max, percent, unit }
}

pub const PARAMS: [GlitchParam; 27] = [
    GlitchParam { id: "signal_strength", label: "Signal strength", group: Group::Reception, kind: slider(0.0, 1.0, true, ""), default: 1.0,
        help: "Antenna signal level. Lowering it brings snow first, then flickering and lost color as the color burst drowns, then broken sync as the sync pulses do — the order a real set fails in." },
    GlitchParam { id: "vertical_hold", label: "Vertical hold", group: Group::Reception, kind: slider(-1.0, 1.0, true, ""), default: 0.0,
        help: "The vertical oscillator's free-running speed. Near the center the sync pulses pull it into lock; past the lock range the picture rolls, with the blanking bar crossing the screen." },
    GlitchParam { id: "horizontal_hold", label: "Horizontal hold", group: Group::Reception, kind: slider(-1.0, 1.0, true, ""), default: 0.0,
        help: "The horizontal oscillator's free-running speed. Off center the picture slides sideways as the AFC strains to hold it; further and lock breaks — the picture tears into diagonal bands and the color goes wild." },
    GlitchParam { id: "afc_speed", label: "AFC response", group: Group::Reception, kind: slider(0.0, 1.0, true, ""), default: 0.5,
        help: "How quickly the TV's horizontal AFC follows timing changes. Slow sets ride out noise but bend at the top of the picture on VCR playback (flagging); fast ones track tape timing but jitter in noise." },
    GlitchParam { id: "brightness", label: "Brightness", group: Group::Reception, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Raises the picture tube's black level, as turning up a TV's brightness did. The blanking intervals and sync pulses become visible when the picture rolls or tears." },
    GlitchParam { id: "ghost_level", label: "Ghost", group: Group::Reception, kind: slider(-1.0, 1.0, true, ""), default: 0.0,
        help: "A reflected copy of the signal arriving late (multipath). Negative values invert it, as reflections often did. Its color shifts with the delay, because the delayed color carrier arrives at a different phase." },
    GlitchParam { id: "ghost_delay", label: "Ghost delay", group: Group::Reception, kind: slider(0.2, 12.0, false, "µs"), default: 2.0,
        help: "How late the reflection arrives. 1 µs is about 2% of the picture width — a reflection path roughly 300 m longer than the direct one." },
    GlitchParam { id: "hum", label: "Hum", group: Group::Reception, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Mains hum leaking into the video: light and dark bars that drift slowly up the picture (60 Hz hum against the 59.94 Hz color field rate), bending the picture where the sync separator is pulled off." },
    GlitchParam { id: "closed_captions", label: "Caption data", group: Group::Reception, kind: Kind::Toggle, default: 1.0,
        help: "Line 21 carries closed-caption data — the row of dashes visible in the blanking bar when the picture rolls." },
    GlitchParam { id: "vcr", label: "VCR", group: Group::Deck, kind: Kind::Toggle, default: 0.0,
        help: "Play the picture from a simulated VHS tape: it is recorded as an FM signal on the tape's slanted tracks and read back by the deck's two spinning heads, through everything the tape and heads are doing to it." },
    GlitchParam { id: "tape_seed", label: "Cassette", group: Group::Tape, kind: Kind::Seed, default: 1.0,
        help: "Which cassette: another one has the same condition but its own flaws in its own places." },
    GlitchParam { id: "tape_wear", label: "Wear", group: Group::Tape, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Age and plays. The magnetic coating weakens and roughens, so the heads read a weaker signal over a slightly larger gap — noisier pictures, then sparkles where the signal sinks to the FM threshold — and pinholes appear in the oxide." },
    GlitchParam { id: "tape_dropouts", label: "Oxide flaws", group: Group::Tape, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Pinholes and flakes missing from the magnetic coating. A flaw wider than one 58 µm track shows in the same place for a few fields in a row; one smaller than a track only weakens the signal, and is seen only when the signal is weak already." },
    GlitchParam { id: "tape_scratches", label: "Scratches", group: Group::Tape, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Scratches along the tape from worn guides. Height across the tape is height in the picture, so a lengthwise scratch is a streak at the same height in every field." },
    GlitchParam { id: "tape_creases", label: "Creases", group: Group::Tape, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Folds across the tape. The heads cross each one a little earlier every field, so it sweeps up through the picture as a band of noise over a few seconds; the fold also shortens the track, a timing jump the TV has to chase." },
    GlitchParam { id: "tape_edge_damage", label: "Edge damage", group: Group::Tape, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Crinkled tape edges, from a deck that chewed it. The tracks start at the bottom edge and end at the top, so the damage lifts the tape off the heads at the top and bottom of the picture." },
    GlitchParam { id: "tape_mold", label: "Mold", group: Group::Tape, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Fungus colonies, thickest near the edges where it grows in the wound pack. Each one lifts the tape off the heads and eats into the coating, and it sheds — what it sheds collects on the heads." },
    GlitchParam { id: "tape_vaseline", label: "Vaseline", group: Group::Tape, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "A film smeared on the tape, holding the heads off it. Spacing costs the short-wavelength picture signal far more than the long-wavelength color, so the picture breaks into noise while color survives and smears. It rubs off onto the heads, too." },
    GlitchParam { id: "head_wear", label: "Head wear", group: Group::Deck, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Worn heads stand less proud of the drum, so they press into the tape less, and their gaps erode wider. Both lose the top of the signal first: black streaks trail bright edges, then the picture gets noisy." },
    GlitchParam { id: "head_dirt", label: "Head dirt", group: Group::Deck, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Debris already on the heads when play starts. It holds them off the tape; each head carries its own, so one can be clogged while the other is clear — every other field fails." },
    GlitchParam { id: "dirt_buildup", label: "Dirt buildup", group: Group::Deck, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "How readily the heads collect what the tape sheds — low for a deck that's had a head-cleaning tape, high for one that never has. Shedding tapes (mold, wear, flaws) clog it as they play; clogs sometimes knock loose." },
    GlitchParam { id: "head_mismatch", label: "Head mismatch", group: Group::Deck, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "How unevenly the two heads have aged: one reads a weaker signal than the other, and since they take turns, field by field, the picture flickers between them." },
    GlitchParam { id: "head_switch", label: "Head switching", group: Group::Deck, kind: slider(0.0, 8.0, false, "µs"), default: 0.0,
        help: "How far the two heads are from exactly opposite on the drum, as a timing jump when the deck changes heads just before vertical sync. The bottom lines jump sideways and the TV's AFC chases the jump into the top of the next field — the bend called flagging." },
    GlitchParam { id: "dropout_compensation", label: "Dropout compensation", group: Group::Deck, kind: Kind::Toggle, default: 1.0,
        help: "The deck watches the signal coming off the heads and, where it drops out, repeats the picture from the line before. On, dropouts become short smears of the line above; off, they show as the demodulator's streaks." },
    GlitchParam { id: "timebase_jitter", label: "Time-base jitter", group: Group::Deck, kind: slider(0.0, 3.0, false, "µs"), default: 0.0,
        help: "Tape stretch and transport flutter. The TV's AFC follows the slow wander; the fast jitter shows as ragged lines." },
    GlitchParam { id: "tracking", label: "Tracking error", group: Group::Deck, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "The heads drifting off the recorded tracks. Well tracked, the stretch where they cross to the next track rests in the vertical interval, out of sight; as the error grows the heads read less and less of their track there, and the noise band climbs into the picture." },
    GlitchParam { id: "search_speed", label: "Search", group: Group::Deck, kind: slider(1.0, 9.0, false, "×"), default: 1.0,
        help: "Fast-forward picture search. The spinning heads cross from track to track, reading noise between them: one fewer noise bar than the speed, drifting as the tracking phase slides, with the picture jumping at each crossing." },
];

pub fn param(id: &str) -> Option<&'static GlitchParam> {
    PARAMS.iter().find(|p| p.id == id)
}

/// The controls a panel shows for a group (the VCR switch lives in the VCR
/// panel's header instead).
pub fn controls(group: Group) -> impl Iterator<Item = &'static GlitchParam> {
    PARAMS.iter().filter(move |p| p.group == group && p.id != VCR_ID)
}

/// Knobs that change the simulation's evolving state: anything touching
/// sync, timing or signal level, and everything about the tape and deck (the
/// tape decides where sync is lost; the heads collect dirt as it plays).
/// The rest — ghost, brightness, captions, dropout compensation — apply when
/// the field is drawn, so changing them never needs the history re-run.
pub fn is_timing(id: &str) -> bool {
    matches!(id, "signal_strength" | "vertical_hold" | "horizontal_hold" | "afc_speed" | "hum")
        || param(id).is_some_and(|p| p.group != Group::Reception && p.id != "dropout_compensation")
}

/// A named condition for the VCR panel's Tape and Deck pickers.
#[derive(Clone, Copy, Debug)]
pub struct VcrCondition {
    pub name: &'static str,
    pub help: &'static str,
    pub values: &'static [(&'static str, f64)],
}

pub const TAPE_KEYS: [&str; 7] = ["tape_wear", "tape_dropouts", "tape_scratches", "tape_creases", "tape_edge_damage", "tape_mold", "tape_vaseline"];
pub const DECK_KEYS: [&str; 4] = ["head_wear", "head_dirt", "dirt_buildup", "head_mismatch"];

pub const TAPES: [VcrCondition; 6] = [
    VcrCondition { name: "Brand new", help: "Fresh out of the shrink-wrap.", values: &[] },
    VcrCondition { name: "Used", help: "A rental: played a few dozen times.", values: &[("tape_wear", 0.3), ("tape_dropouts", 0.15), ("tape_scratches", 0.1)] },
    VcrCondition {
        name: "Worn out",
        help: "Played to death in a garage for twenty years.",
        values: &[("tape_wear", 0.75), ("tape_dropouts", 0.5), ("tape_scratches", 0.45), ("tape_creases", 0.15), ("tape_edge_damage", 0.2)],
    },
    VcrCondition { name: "Moldy", help: "Stored somewhere damp.", values: &[("tape_wear", 0.5), ("tape_dropouts", 0.35), ("tape_mold", 0.7), ("tape_edge_damage", 0.1)] },
    VcrCondition { name: "Vaselined", help: "Smeared on purpose.", values: &[("tape_wear", 0.2), ("tape_vaseline", 0.6)] },
    VcrCondition {
        name: "Chewed",
        help: "Eaten by a deck and wound back by hand.",
        values: &[("tape_wear", 0.4), ("tape_dropouts", 0.3), ("tape_scratches", 0.4), ("tape_creases", 0.7), ("tape_edge_damage", 0.7)],
    },
];

pub const DECKS: [VcrCondition; 4] = [
    VcrCondition { name: "Clean heads", help: "Freshly cleaned with a head-cleaning tape.", values: &[] },
    VcrCondition {
        name: "Dirty heads",
        help: "Never cleaned: carries some debris, and picks up more.",
        values: &[("head_wear", 0.15), ("head_dirt", 0.4), ("dirt_buildup", 0.55), ("head_mismatch", 0.3)],
    },
    VcrCondition {
        name: "Worn heads",
        help: "Thousands of hours on the drum.",
        values: &[("head_wear", 0.7), ("head_dirt", 0.05), ("dirt_buildup", 0.2), ("head_mismatch", 0.35)],
    },
    VcrCondition {
        name: "Neglected",
        help: "Worn, filthy, and still in use.",
        values: &[("head_wear", 0.5), ("head_dirt", 0.55), ("dirt_buildup", 0.8), ("head_mismatch", 0.5)],
    },
];

impl VcrCondition {
    fn value(&self, key: &str) -> f64 {
        self.values.iter().find(|(k, _)| *k == key).map(|(_, v)| *v).or_else(|| param(key).map(|p| p.default)).unwrap_or(0.0)
    }

    /// The condition among `list` whose values `s` matches exactly, if any.
    pub fn matching(list: &'static [VcrCondition], keys: &[&str], s: &GlitchSettings) -> Option<&'static VcrCondition> {
        list.iter().find(|c| keys.iter().all(|k| (s.get(k) - c.value(k)).abs() < 1e-6))
    }

    /// Apply this condition's values for `keys` to `s`.
    pub fn apply(&self, keys: &[&str], s: &mut GlitchSettings) {
        for k in keys {
            s.values.insert(k.to_string(), self.value(k));
        }
    }
}

/// Every knob's value at one moment (the flat form looks and keyframes store).
#[derive(Clone, Debug, PartialEq)]
pub struct GlitchSettings {
    pub values: BTreeMap<String, f64>,
}

impl Default for GlitchSettings {
    fn default() -> Self {
        Self { values: PARAMS.iter().map(|p| (p.id.to_string(), p.default)).collect() }
    }
}

impl GlitchSettings {
    /// Missing keys (older looks) fall back to the healthy defaults.
    pub fn from_values<'a>(values: impl IntoIterator<Item = (&'a String, f64)>) -> Self {
        let mut s = Self::default();
        for (k, v) in values {
            s.values.insert(k.clone(), v);
        }
        s
    }

    pub fn get(&self, id: &str) -> f64 {
        self.values.get(id).copied().or_else(|| param(id).map(|p| p.default)).unwrap_or(0.0)
    }

    pub fn flag(&self, id: &str) -> bool {
        self.get(id) >= 0.5
    }

    pub fn timing(&self) -> Vec<(String, f64)> {
        PARAMS.iter().filter(|p| is_timing(p.id)).map(|p| (p.id.to_string(), self.get(p.id))).collect()
    }

    /// Whether the VCR plays the picture (its panel is switched on).
    pub fn vcr(&self) -> bool {
        self.flag(VCR_ID)
    }

    /// What the stage runs with, or None when it doesn't run: the Glitch
    /// panel's knobs only while it is on (off, the TV is healthy and only the
    /// VCR acts, if it is playing).
    pub fn for_stage(reception_on: bool, values: &GlitchSettings) -> Option<GlitchSettings> {
        if reception_on {
            Some(values.clone())
        } else if values.vcr() {
            Some(values.reception_healthy())
        } else {
            None
        }
    }

    /// These settings with every Reception knob back to healthy — the
    /// stage's input when only the VCR panel is on.
    pub fn reception_healthy(&self) -> Self {
        let mut s = self.clone();
        for p in controls(Group::Reception) {
            s.values.insert(p.id.to_string(), p.default);
        }
        s
    }

    /// Values saved before the VCR panel existed, in today's terms: the old
    /// Tape knobs were effects drawn on the signal; their nearest physical
    /// causes are a flawed or creased tape and dirty heads. A look that used
    /// any of them gets the VCR switched on. Values that already have the
    /// VCR key come back unchanged.
    pub fn migrated(values: &BTreeMap<String, f64>) -> BTreeMap<String, f64> {
        if values.contains_key(VCR_ID) {
            return values.clone();
        }
        let mut v = values.clone();
        let mut used = false;
        if let Some(c) = v.remove("head_clog").filter(|c| *c > 0.0) {
            v.insert("head_dirt".into(), (c * 0.9).min(1.0));
            used = true;
        }
        if let Some(c) = v.remove("crinkle").filter(|c| *c > 0.0) {
            v.insert("tape_creases".into(), c.min(1.0));
            used = true;
        }
        if let Some(d) = v.remove("dropouts").filter(|d| *d > 0.0) {
            v.insert("tape_dropouts".into(), d.min(1.0));
            used = true;
        }
        for k in ["head_clog", "crinkle", "dropouts"] {
            v.remove(k);
        }
        for k in ["head_switch", "timebase_jitter", "tracking", "search_speed"] {
            if let (Some(x), Some(p)) = (v.get(k), param(k)) {
                if (x - p.default).abs() > 1e-9 {
                    used = true;
                }
            }
        }
        v.insert(VCR_ID.into(), if used { 1.0 } else { 0.0 });
        v
    }
}
