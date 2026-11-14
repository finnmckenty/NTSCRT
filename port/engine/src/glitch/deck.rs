//! The deck's two video heads over time: a port of the Mac's `Deck.swift`.
//! A head touches the tape only while it plays its own field; then it picks
//! up what the tape sheds there, a chunk now and then lodges in it, and now
//! and then debris knocks loose. A Vaseline film transfers fast and wipes
//! off slowly. Every random event is a hash of its field, so any moment can
//! be reproduced by playing from the start.

use super::receiver::{posmod, timing as T};
use super::tape::{tape_at, uni, TapeGeometry, TapeParams};
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
        Self { wear: u("head_wear"), dirt: u("head_dirt"), buildup: u("dirt_buildup"), mismatch: u("head_mismatch") }
    }
    /// Each head's wear: mismatch moves them apart, mostly by ageing head 1.
    pub fn head_wear(&self, h: usize) -> f32 {
        if h == 0 {
            self.wear * (1.0 - 0.4 * self.mismatch)
        } else {
            (self.wear * (1.0 + 0.4 * self.mismatch) + 0.25 * self.mismatch).min(1.0)
        }
    }
    /// Spacing a worn head's lost tip penetration adds, µm.
    pub fn wear_spacing(&self, h: usize) -> f32 {
        0.3 * self.head_wear(h)
    }
    /// Read efficiency (a worn core, and the weaker of a mismatched pair).
    pub fn efficiency(&self, h: usize) -> f32 {
        10f32.powf(-(self.head_wear(h) * 10.0 + if h == 1 { self.mismatch * 3.0 } else { 0.0 }) / 20.0)
    }
    /// Gap length, µm: 0.3 new, eroding longer with wear.
    pub fn gap(&self, h: usize) -> f32 {
        0.3 + 0.35 * self.head_wear(h)
    }
    /// Dirt baked onto each head (µm of spacing), there until cleaned.
    pub fn baseline_dirt(&self, h: usize, seed: u32) -> f32 {
        let share = if h == 0 { 1.2 } else { 0.5 + 0.8 * uni(seed, 90, 1, 0) };
        self.dirt * 0.5 * share
    }
    fn pickup(&self) -> f32 {
        0.02 + 1.2 * self.buildup * self.buildup
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
    /// The last field stepped through.
    field: i64,
    heads: Option<[HeadState; 2]>,
    history: Vec<(i64, [HeadState; 2])>,
}

impl DeckSimulator {
    const HISTORY: usize = 12;

    pub fn new(s: &GlitchSettings) -> Self {
        Self { tape: TapeParams::new(s), deck: DeckParams::new(s), field: 0, heads: None, history: Vec::new() }
    }

    pub fn update(&mut self, s: &GlitchSettings) {
        self.tape = TapeParams::new(s);
        self.deck = DeckParams::new(s);
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
            let p = tape_at(TapeGeometry::point(f, along, 0.0), &self.tape, false);
            shed += p.shed;
            film += p.film;
        }
        shed /= n as f32;
        film /= n as f32;
        let heads = self.heads.as_mut().expect("heads");
        let mut s = heads[h];
        let seed = self.tape.seed;
        let (field, era) = (f as i32, (f >> 31) as i32);
        let pickup = self.deck.pickup();
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
