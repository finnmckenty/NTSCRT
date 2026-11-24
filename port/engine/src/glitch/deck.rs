//! The deck's two video heads over time: a port of the Mac's `Deck.swift`.
//! A head touches the tape only while it plays its own field; then it picks
//! up what the tape sheds there, a chunk now and then lodges in it, and now
//! and then debris knocks loose. A Vaseline film transfers fast and wipes
//! off slowly. Every random event is a hash of its field, so any moment can
//! be reproduced by playing from the start.

use super::receiver::{posmod, timing as T};
use super::tape::{noise1, noise2, tape_at, uni, TapeFormat, TapeGeometry, TapeParams};
use super::GlitchSettings;

/// The heads, from the Deck knobs. Head 0 plays even fields, head 1 odd.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DeckParams {
    pub wear: f32,
    pub dirt: f32,
    pub buildup: f32,
    pub mismatch: f32,
}

impl DeckParams {
    pub fn new(s: &GlitchSettings) -> Self {
        let u = |k: &str| s.get(k).clamp(0.0, 1.0) as f32;
        Self {
            // (The slider's taper: wear's effects grow faster than the wear,
            // so the lower half of the travel gets a little more of it.)
            wear: u("head_wear").powf(0.85),
            // (Tapered a little, so three quarters of the knob gives a third
            // of its full effect: the picture breaks up late, where the dirt
            // reaches the FM threshold.)
            dirt: u("head_dirt").powf(0.88),
            buildup: u("dirt_buildup"),
            mismatch: u("head_mismatch"),
        }
    }

    /// Spacing a worn head's lost tip penetration adds on average, µm, at
    /// full wear — most of what wear costs. A new tip stands 0.12–0.16 mm
    /// proud of the drum and presses a dent into the tape; worn to a third
    /// of that it no longer holds the tape against itself.
    pub const WEAR_SPACING_UM: f32 = 0.33;
    /// The rest: output lost whatever the wavelength (a shallower core, less
    /// inductance), dB at full wear.
    pub const WEAR_LOSS_DB: f32 = 5.0;
    /// And the gap's edges chip: 0.3 µm new, this much longer at full wear.
    pub const WEAR_GAP_UM: f32 = 0.3;
    const CONTACT_DEPTH: f32 = 0.7;
    /// Each head's wear: mismatch moves them apart, mostly by ageing head 1.
    pub fn head_wear(&self, h: usize) -> f32 {
        if h == 0 {
            self.wear * (1.0 - 0.4 * self.mismatch)
        } else {
            (self.wear * (1.0 + 0.4 * self.mismatch) + 0.25 * self.mismatch).min(1.0)
        }
    }
    /// The worn tip's spacing on average, µm.
    pub fn wear_spacing(&self, h: usize) -> f32 {
        Self::WEAR_SPACING_UM * self.head_wear(h)
    }
    /// The worn tip's spacing at one moment, µm: where the head is along its
    /// sweep of track `field` (`along` mm) on cassette `seed`.
    pub fn wear_spacing_at(&self, h: usize, field: i64, along: f64, seed: u32) -> f32 {
        let w = self.wear_spacing(h);
        if w > 0.0 { w * Self::contact(field, along, seed) } else { 0.0 }
    }
    /// How far a worn tip stands off the tape at one moment, against its
    /// average (1). A tip that no longer dents the tape rides on whatever
    /// the tape is doing: it meets the tape late and leaves it early (the
    /// top and bottom of the picture), ripples in the tape's wrap pass under
    /// it (bands that drift through the picture), and the tension holding
    /// the tape on wanders (the whole picture comes and goes over a second
    /// or so). Both heads sweep the same tape, so they share it. A hash of
    /// the cassette's seed and the time, so any moment plays the same again.
    /// How fast and how far it moves is a choice, not a measurement. Mac:
    /// DeckParams.contact.
    pub fn contact(field: i64, along: f64, seed: u32) -> f32 {
        let x = (along / TapeGeometry::track_length()).clamp(0.0, 1.0);
        let t = field as f64 + x; // time, in fields
        // Smooth noise (−1…1) over a place along the sweep and the time.
        let noise = |k: u32, a: f64, per: f64| -> f32 {
            let b = t / per;
            let (ai, bi) = (a.floor(), b.floor());
            2.0 * noise2(seed, k, ai as i64 as i32, (a - ai) as f32, bi as i64 as i32, (b - bi) as f32) - 1.0
        };
        let ends = ((-x / 0.07).exp() + 0.7 * (-(1.0 - x) / 0.05).exp()) as f32;
        let tension = noise(95, 0.0, 45.0);
        let ripple = noise(96, 3.0 * x + 0.013 * t, 25.0);
        let flutter = noise(97, 11.0 * x - 0.031 * t, 9.0);
        (1.0 + Self::CONTACT_DEPTH * (0.5 * ends + 0.35 * tension + 0.6 * ripple + 0.25 * flutter)).max(0.15)
    }
    /// Read efficiency (a worn core, and the weaker of a mismatched pair).
    pub fn efficiency(&self, h: usize) -> f32 {
        10f32.powf(-(self.head_wear(h) * Self::WEAR_LOSS_DB + if h == 1 { self.mismatch * 3.0 } else { 0.0 }) / 20.0)
    }
    /// Gap length, µm: 0.3 new, eroding longer with wear.
    pub fn gap(&self, h: usize) -> f32 {
        0.3 + Self::WEAR_GAP_UM * self.head_wear(h)
    }
    /// How much the deck's color path raises the color-under so tape wear
    /// and head wear don't fade the color: it undoes exactly what they take
    /// from the 629 kHz carrier (the tape's lost remanence and roughness,
    /// the worn head's efficiency, tip spacing and gap). The picture keeps
    /// its worn signal; flaws still take the color where they are. A
    /// mismatched pair's extra wear on head 1 isn't undone. Mac:
    /// DeckParams.colorBoost.
    pub fn color_boost(&self, h: usize, tape: &TapeParams) -> f32 {
        use super::vcr::{channel_gain, color_under_mhz};
        let mhz = color_under_mhz();
        let rough = channel_gain(mhz, (0.1 * tape.wear) as f64, 0.3);
        let new = channel_gain(mhz, 0.0, 0.3);
        let lost = tape.remanence() * (rough / new) as f32;
        self.color_noise(h) / lost.max(1e-3)
    }
    /// The head's own share of that boost, which the head's noise rides up
    /// with — as it does when a deck's color control (ACC) turns up a weak
    /// color signal: a worn head's color keeps its strength and gets
    /// noisier. (The tape's share is raised against the same head noise, as
    /// if the tape were new.) Mac: DeckParams.colorNoise.
    pub fn color_noise(&self, h: usize) -> f32 {
        use super::vcr::{channel_gain, color_under_mhz};
        let w = self.head_wear(h).min(self.wear);
        let mhz = color_under_mhz();
        let worn = channel_gain(mhz, (Self::WEAR_SPACING_UM * w) as f64, (0.3 + Self::WEAR_GAP_UM * w) as f64);
        let new = channel_gain(mhz, 0.0, 0.3);
        1.0 / (10f32.powf(-w * Self::WEAR_LOSS_DB / 20.0) * (worn / new) as f32).max(1e-3)
    }
    /// Dirt baked onto each head (µm of spacing), there until cleaned.
    pub fn baseline_dirt(&self, h: usize, seed: u32) -> f32 {
        let share = if h == 0 { 1.2 } else { 0.5 + 0.8 * uni(seed, 90, 1, 0) };
        self.dirt * 0.5 * share
    }
    /// That dirt as the head carries it through field `field`: the layer
    /// shifts as the tape drags over it — packs down, lifts at an edge — so
    /// it holds the head off a little more or less from second to second.
    /// Each head's shifts on its own, so the two drift apart and back;
    /// within a sweep it is one thing, since it rides on the head. How far
    /// and how fast is a choice.
    pub fn baseline_dirt_at(&self, h: usize, seed: u32, field: i64) -> f32 {
        let d = self.baseline_dirt(h, seed);
        if d > 0.0 { d * Self::dirt_shift(h, field, seed) } else { 0.0 }
    }
    pub fn dirt_shift(h: usize, field: i64, seed: u32) -> f32 {
        let noise = |k: u32, per: f64| -> f32 {
            let b = field as f64 / per;
            let bi = b.floor();
            2.0 * noise1(seed, k + h as u32, bi as i64 as i32, (b - bi) as f32) - 1.0
        };
        1.0 + 0.15 * noise(98, 90.0) + 0.06 * noise(100, 16.0)
    }
    /// µm of debris head `h` collects per second per unit of shedding: next
    /// to nothing on a deck just cleaned, rising evenly along the knob (half
    /// way, about a third of full). A worn head collects more: its chipped
    /// gap and flattened tip hold what a new one sheds — twice as much when
    /// fully worn.
    fn pickup(&self, h: usize) -> f32 {
        (0.02 + 1.2 * self.buildup.powf(1.5)) * (1.0 + self.head_wear(h))
    }
}

/// What one head carries beyond its baked-on dirt.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct HeadState {
    /// Debris lodged as the tape played, µm of spacing.
    pub debris: f32,
    /// A greasy film from the tape (Vaseline), µm.
    pub grease: f32,
}

#[derive(Clone, Debug)]
pub struct DeckSnapshot {
    field: i64,
    heads: Option<[HeadState; 2]>,
    history: Vec<(i64, [HeadState; 2])>,
}

#[derive(Clone, Debug)]
pub struct DeckSimulator {
    pub tape: TapeParams,
    pub deck: DeckParams,
    pub format: TapeFormat,
    /// The last field stepped through.
    field: i64,
    heads: Option<[HeadState; 2]>,
    history: Vec<(i64, [HeadState; 2])>,
}

impl DeckSimulator {
    const HISTORY: usize = 12;

    pub fn new(s: &GlitchSettings) -> Self {
        Self { tape: TapeParams::new(s), deck: DeckParams::new(s), format: TapeFormat::new(s), field: 0, heads: None, history: Vec::new() }
    }

    pub fn update(&mut self, s: &GlitchSettings) {
        self.tape = TapeParams::new(s);
        self.deck = DeckParams::new(s);
        self.format = TapeFormat::new(s);
    }

    pub fn reset(&mut self, field: i64) {
        self.field = field - 1;
        self.heads = Some([HeadState::default(); 2]);
        self.history.clear();
    }

    pub fn snapshot(&self) -> DeckSnapshot {
        DeckSnapshot { field: self.field, heads: self.heads, history: self.history.clone() }
    }

    pub fn restore(&mut self, s: &DeckSnapshot) {
        self.field = s.field;
        self.heads = s.heads;
        self.history = s.history.clone();
    }

    /// Play on through field `f`.
    pub fn advance(&mut self, f: i64) {
        if self.heads.is_none() {
            self.reset(f);
        }
        while self.field < f {
            let next = self.field + 1;
            self.history.push((next, self.heads.expect("heads")));
            if self.history.len() > Self::HISTORY {
                self.history.remove(0);
            }
            self.step(next);
            self.field = next;
        }
    }

    /// The heads entering field `f`.
    pub fn heads(&self, f: i64) -> [HeadState; 2] {
        let now = self.heads.unwrap_or_default();
        if f > self.field {
            return now;
        }
        if let Some((_, h)) = self.history.iter().rev().find(|(g, _)| *g == f) {
            return *h;
        }
        self.history.first().map(|(_, h)| *h).unwrap_or(now)
    }

    fn step(&mut self, f: i64) {
        let h = posmod(f, 2) as usize;
        let dt = (1.0 / T::FIELD_RATE) as f32;
        let n = 12;
        let (mut shed, mut film) = (0.0f32, 0.0f32);
        for i in 0..n {
            let along = (i as f64 + 0.5) / n as f64 * TapeGeometry::track_length();
            let p = tape_at(TapeGeometry::point(f, along, 0.0, self.format), &self.tape, false);
            shed += p.shed;
            film += p.film;
        }
        shed /= n as f32;
        film /= n as f32;
        let heads = self.heads.as_mut().expect("heads");
        let mut s = heads[h];
        let seed = self.tape.seed;
        let (field, era) = (f as i32, (f >> 31) as i32);
        let pickup = self.deck.pickup(h);
        s.debris += pickup * shed * dt - s.debris * 0.5 * dt;
        if uni(seed, 81, field, era) < (pickup * shed * 0.03).min(0.25) {
            s.debris += 0.15 + 0.65 * uni(seed, 82, field, era);
        }
        if uni(seed, 83, field, era) < 0.0005 + 0.004 * s.debris * s.debris {
            s.debris *= 0.25 * uni(seed, 84, field, era);
        }
        s.debris = s.debris.clamp(0.0, 6.0);
        s.grease += (film - s.grease) * if film > s.grease { 0.2 } else { 0.003 };
        heads[h] = s;
    }
}
