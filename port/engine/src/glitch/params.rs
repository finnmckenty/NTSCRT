//! The Glitch stage's knobs: a port of the Mac's `GlitchParams.swift`. The
//! stage simulates a TV receiver and a VCR transport, so every control is a
//! knob that existed on one of them (or a physical condition of the signal).
//! Defaults describe a healthy set on a clean signal: enabling the stage
//! changes nothing until a knob is turned.

use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Group {
    Reception,
    Tape,
}

impl Group {
    pub const ALL: [Group; 2] = [Group::Reception, Group::Tape];
    pub fn label(self) -> &'static str {
        match self {
            Group::Reception => "Reception",
            Group::Tape => "Tape",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    /// `percent` controls show 0–100 (or ±100); `unit` labels the rest.
    Slider { min: f64, max: f64, percent: bool, unit: &'static str },
    Toggle,
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
}

const fn slider(min: f64, max: f64, percent: bool, unit: &'static str) -> Kind {
    Kind::Slider { min, max, percent, unit }
}

pub const PARAMS: [GlitchParam; 17] = [
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
    GlitchParam { id: "head_switch", label: "Head switching", group: Group::Tape, kind: slider(0.0, 8.0, false, "µs"), default: 0.0,
        help: "Timing jump when the VCR changes heads, just before vertical sync. The bottom lines jump sideways and the TV's AFC chases the jump into the top of the next field — the bend called flagging." },
    GlitchParam { id: "timebase_jitter", label: "Time-base jitter", group: Group::Tape, kind: slider(0.0, 3.0, false, "µs"), default: 0.0,
        help: "Tape stretch and transport flutter. The TV's AFC follows the slow wander; the fast jitter shows as ragged lines." },
    GlitchParam { id: "crinkle", label: "Tape crinkle", group: Group::Tape, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Creased tape passing the heads: bands of signal loss and violent timing errors, enough to knock the TV out of lock for a moment." },
    GlitchParam { id: "head_clog", label: "Head clog", group: Group::Tape, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Debris on the video heads, lifting them off the tape: whole fields drop out to noise and lose their sync, more often as the clog worsens." },
    GlitchParam { id: "tracking", label: "Tracking error", group: Group::Tape, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "The heads drifting off the recorded tracks. Well tracked, the noise band where they cross to the next track rests in the vertical interval, out of sight; as the error grows it climbs into the picture and widens." },
    GlitchParam { id: "search_speed", label: "Search", group: Group::Tape, kind: slider(1.0, 9.0, false, "×"), default: 1.0,
        help: "Fast-forward picture search. The spinning heads cross from track to track, reading noise between them: one fewer noise bar than the speed, drifting as the tracking phase slides, with the picture jumping at each crossing." },
    GlitchParam { id: "dropouts", label: "Dropouts", group: Group::Tape, kind: slider(0.0, 1.0, true, ""), default: 0.0,
        help: "Oxide missing from the tape: brief losses of signal, often a few lines tall. How they look depends on Dropout compensation." },
    GlitchParam { id: "dropout_compensation", label: "Dropout compensation", group: Group::Tape, kind: Kind::Toggle, default: 1.0,
        help: "The VCR's fix for dropouts: replay the lost stretch from the line before. On, dropouts shrink to brief white ticks and short smears where one line repeats down a tall flaw; off, they show as long white streaks." },
];

pub fn param(id: &str) -> Option<&'static GlitchParam> {
    PARAMS.iter().find(|p| p.id == id)
}

/// Knobs that change the receiver's evolving state (sync, timing, signal
/// level). The rest — ghost, brightness, captions, dropouts — apply when the
/// field is drawn, so changing them never needs the history re-run.
pub const TIMING_IDS: [&str; 11] = [
    "signal_strength", "vertical_hold", "horizontal_hold", "afc_speed", "hum", "head_switch", "timebase_jitter", "crinkle", "head_clog",
    "search_speed", "tracking",
];

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
        TIMING_IDS.iter().map(|id| (id.to_string(), self.get(id))).collect()
    }
}
