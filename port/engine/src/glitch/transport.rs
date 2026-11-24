//! The deck's transport: a port of the Mac's `Transport.swift`. How the
//! tape is moved past the drum decides where the heads' sweep falls on the
//! recorded tracks and when the signal on them arrives.
//!
//! The servo: the control head reads a pulse recorded at the bottom edge
//! once a frame; the capstan's speed is corrected (a type-2 loop, ~1.4 Hz)
//! to keep the pulse at the drum's phase plus the tracking control's delay.
//! A pulse lost to a damaged edge leaves the capstan running at its last
//! speed; a crinkle can fake one. A sticky tape (binder gone gummy: sticky
//! shed, and mold a little) grabs and lets go (`sticky`): the tape runs
//! clean, then at a gummy patch it sticks on the guides and drum, the
//! capstan drags it on, the tension climbs, and it tears loose and springs
//! back. Picture search runs the tape n× as fast with the servo off.
//!
//! Like the rest of the simulation it depends only on the knobs over time
//! and the seed, so any moment can be reproduced by playing from the start.

use std::collections::VecDeque;

use super::receiver::{floordiv, posmod, timing as T, uniform, value};
use super::tape::{smoothstep, tape_at, uni, TapeFormat, TapeGeometry, TapeParams, TapePosition};
use super::GlitchSettings;

/// The transport knobs.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransportParams {
    /// Back tension against the recording deck's: the knob (−1…1) as it is
    /// up to half, then on a straight line to ±(1 + TENSION_TOP_END) at its
    /// ends (tape::top_end). Half a knob is a band brake out of adjustment;
    /// the ends are a tape stretched by a deck that chewed it, or a supply
    /// reel hardly braked at all.
    pub tension: f64,
    /// Worn drum motor, belts and pinch roller, 0…1.
    pub flutter: f64,
    /// The tracking control: where the servo puts the tape, in track
    /// pitches (±1 is a whole track).
    pub tracking: f64,
    /// Picture search multiple (1 = normal play).
    pub search: f64,
    pub format: TapeFormat,
}

impl TransportParams {
    /// (At ±1 — the old full knob — the top of the picture barely hooked on
    /// a TV with the default AFC, which rides out all but 4% of the jump
    /// before the picture starts.)
    pub const TENSION_TOP_END: f64 = 3.0;

    pub fn new(s: &GlitchSettings) -> Self {
        // The knob on a curve: its first half moves the heads three quarters
        // of the way off their tracks; the rest is where noise bands break
        // out and take over.
        let k = s.get("tracking_offset").clamp(-1.0, 1.0);
        let bt = s.get("back_tension").clamp(-1.0, 1.0);
        Self {
            tension: if bt < 0.0 { -1.0 } else { 1.0 } * super::tape::top_end(bt.abs() as f32, Self::TENSION_TOP_END as f32) as f64,
            // On the damage knobs' curve (tape::top_end): realistic up to half,
            // then up to 5x (at its realistic most the TV's AFC rode out
            // nearly all of it).
            flutter: super::tape::amount("transport_flutter", s.get("transport_flutter").clamp(0.0, 1.0) as f32) as f64,
            tracking: if k < 0.0 { -1.0 } else { 1.0 } * (1.0 - (1.0 - k.abs()) * (1.0 - k.abs())),
            search: s.get("search_speed").clamp(1.0, 9.0),
            format: TapeFormat::new(s),
        }
    }

    /// How much longer the tape is stretched than when it was recorded: a
    /// 13 µs jump at the head switch at tension 1; 53 µs at the knob's end
    /// (0.3% longer: a tape a deck has stretched). The steady part: the
    /// tension arm hunts around it (Simulator::strain).
    pub fn strain(&self) -> f64 {
        8e-4 * self.tension
    }

    pub fn searching(&self) -> bool {
        self.search > 1.02
    }
}

/// Where a sticky tape grabs: a port of the Mac's `StickyTape`.
///
/// Binder that has taken up moisture is gummy in patches along the tape.
/// Sources describe what that does as squeal, the tape dragging and jerking
/// through the path, and residue on the heads — not a jitter on every line.
/// So: the tape plays clean until a patch reaches the guides and drum. There
/// it holds; the capstan keeps pulling, so the tape between stretches
/// (tension climbs: the picture skews, more each field), the capstan slips
/// (the tracking sags) and the tape squeals (a tone, swelling). Then it
/// tears loose: the tension is gone in a millisecond, the picture below that
/// line lurches sideways, and the tape rings like the spring it is for a
/// couple of fields.
///
/// A function of the place on the tape alone, so it is there again on every
/// play, somewhere else on another cassette, and three times as long at EP's
/// tape speed. How often, how long and how hard are choices: nothing here is
/// measured from a tape.
pub mod sticky {
    use super::{uniform, TapeParams};
    use std::f64::consts::PI;

    #[derive(Clone, Copy, Debug, Default, PartialEq)]
    pub struct Grab {
        /// The tape's extra stretch (strain).
        pub strain: f64,
        /// How hard it is held, 0…1 (what the capstan slips against).
        pub hold: f64,
        /// The squeal: amplitude (µs) and pitch (Hz).
        pub squeal: f64,
        pub pitch: f64,
    }

    /// Patches are dealt one to a stretch of tape this long, mm (0.3 s at SP).
    pub const STRETCH: f64 = 10.0;
    /// The stretch a full-strength patch puts on the tape before it lets
    /// go: 36 µs of skew over a field.
    pub const STRAIN: f64 = 2.2e-3;
    /// The capstan's slip against a full-strength hold, track pitches a field.
    pub const SLIP: f64 = 0.4;
    /// The squeal's size at full strength, µs.
    pub const SQUEAL: f64 = 0.3;
    /// Letting go takes this much tape, mm (0.75 ms at SP).
    pub const RELEASE: f64 = 0.025;

    /// How sticky the tape is overall, 0…1: Sticky shed, and a little from
    /// mold (its colonies are tacky too).
    pub fn stickiness(t: &TapeParams) -> f64 {
        (t.sticky as f64 + 0.25 * t.mold as f64).min(1.0)
    }

    /// The patch in stretch `c`, if it has one: where it starts and ends
    /// (mm), how hard it holds, and its squeal's pitch.
    pub fn patch(c: i64, t: &TapeParams) -> Option<(f64, f64, f64, f64)> {
        let st = stickiness(t);
        if st <= 0.0 {
            return None;
        }
        let seed = t.seed as u64;
        // A few at a low setting (one every three seconds at a quarter, one
        // a second at half), one in every stretch at full: three a second,
        // the tape held two thirds of the time.
        if uniform(seed, 101, c, 0) >= st.powf(1.6).min(1.0) {
            return None;
        }
        let length = (2.0 + 7.0 * uniform(seed, 102, c, 0)) * (0.5 + 0.5 * st);
        let start = (c as f64 + 0.9 * uniform(seed, 103, c, 0)) * STRETCH;
        // (How hard a patch holds grows less with the knob than how many
        // there are: a slightly sticky tape grabs rarely, but it does grab.)
        let grip = (0.35 + 0.65 * st) * (0.5 + 0.5 * uniform(seed, 104, c, 0));
        Some((start, start + length, grip, 950.0 + 800.0 * uniform(seed, 105, c, 0)))
    }

    pub fn at(x: f64, t: &TapeParams) -> Grab {
        let mut g = Grab::default();
        if !(t.sticky > 0.0 || t.mold > 0.0) {
            return g;
        }
        let c = (x / STRETCH).floor() as i64;
        // This stretch's patch and the one before's (still ringing, or
        // running over the boundary).
        for k in [c - 1, c] {
            let Some((start, end, grip, pitch)) = patch(k, t) else { continue };
            if x < start {
                continue;
            }
            if x < end {
                // Held: the tension climbs, slowly at first.
                let q = (x - start) / (end - start);
                g.strain += STRAIN * grip * q * q;
                g.hold = g.hold.max(grip * (q * 4.0).min(1.0));
                g.squeal = SQUEAL * grip * q;
                g.pitch = pitch;
            } else {
                // Let go: the tension falls away and the tape rings.
                let d = x - end;
                if d >= 4.0 {
                    continue;
                }
                let fall = 1.0 - (d / RELEASE).min(1.0);
                let ring = -0.35 * (1.0 - fall) * (-d / 0.5).exp() * (2.0 * PI * d / 0.8).cos();
                g.strain += STRAIN * grip * (fall * fall * (3.0 - 2.0 * fall) + ring);
            }
        }
        g
    }
}

/// x wrapped to (−1, 1]: the offset from the nearest track two pitches
/// apart (the nearest of the head's own azimuth).
#[inline(always)]
pub fn wrap2(x: f64) -> f64 {
    let mut r = x % 2.0;
    if r > 1.0 {
        r -= 2.0;
    } else if r <= -1.0 {
        r += 2.0;
    }
    r
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Line {
    /// Where the tape is along its length against where the heads expect
    /// it, in track pitches.
    pub delta: f64,
    /// The time-base error that puts on the signal, µs.
    pub tbe: f64,
    /// How much a sticky patch is stretching the tape here (strain, on top
    /// of the back tension's).
    pub strain: f64,
}

#[derive(Clone, Copy, Debug)]
struct FieldEntry {
    field: i64,
    phase: f64,
    rate: f64,
}

#[derive(Clone, Debug)]
struct State {
    line: i64,
    delta: f64,
    speed: f64,
    kick: f64,
    integ: f64,
    phase: f64,
    rate: f64,
    lines: VecDeque<Line>,
    fields: VecDeque<FieldEntry>,
}

impl Default for State {
    fn default() -> Self {
        Self {
            line: -1,
            delta: 0.0,
            speed: 0.0,
            kick: 0.0,
            integ: 0.0,
            phase: 0.0,
            rate: 0.0,
            lines: VecDeque::new(),
            fields: VecDeque::new(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct TransportSnapshot(State);

#[derive(Clone, Debug)]
pub struct TransportSimulator {
    lines_per_field: usize,
    seed: u64,
    pub params: TransportParams,
    pub tape: TapeParams,
    s: State,
    cap: usize,
}

impl TransportSimulator {
    /// The control track's pulse is ~79 mm along the tape from its track's
    /// start (the VHS X-distance), at the bottom edge.
    const CONTROL_OFFSET: f64 = 79.244;
    const CONTROL_Y: f64 = 0.35;

    pub fn new(lines_per_field: usize, seed: u64, s: &GlitchSettings) -> Self {
        Self { lines_per_field, seed, params: TransportParams::new(s), tape: TapeParams::new(s), s: State::default(), cap: 4 * lines_per_field + 64 }
    }

    pub fn update(&mut self, s: &GlitchSettings) {
        self.params = TransportParams::new(s);
        self.tape = TapeParams::new(s);
    }

    /// Back to the start of play: tape in place, servo locked.
    pub fn reset(&mut self) {
        self.s = State::default();
        self.s.lines.reserve(self.cap);
    }

    pub fn snapshot(&self) -> TransportSnapshot {
        TransportSnapshot(self.s.clone())
    }

    pub fn restore(&mut self, snap: &TransportSnapshot) {
        self.s = snap.0.clone();
    }

    /// Tape position error and its time-base error at signal line j (as of
    /// the last line stepped, for lines not reached yet).
    pub fn line(&self, j: i64) -> Line {
        let back = (self.s.line - j).max(0);
        if self.s.lines.is_empty() {
            return Line::default();
        }
        let n = self.s.lines.len() as i64;
        let i = if back >= n { 0 } else { n - 1 - back };
        self.s.lines[i as usize]
    }

    /// Picture search: how far off its own track a head starts sweeping
    /// field f (pitches), and how many it crosses in the sweep.
    pub fn search(&self, f: i64) -> (f64, f64) {
        if let Some(e) = self.s.fields.iter().rev().find(|e| e.field == f) {
            return (e.phase, e.rate);
        }
        if let Some(last) = self.s.fields.back() {
            if f > last.field {
                return (wrap2(last.phase + last.rate * (f - last.field) as f64), last.rate);
            }
        }
        self.s.fields.front().map(|e| (e.phase, e.rate)).unwrap_or((0.0, 0.0))
    }

    /// Play on through signal line j.
    pub fn advance(&mut self, j: i64) {
        if self.s.lines.is_empty() {
            self.s.line = j - 1;
        }
        while self.s.line < j {
            self.step(self.s.line + 1);
        }
    }

    fn step(&mut self, j: i64) {
        let p = self.params;
        let seed = self.seed;
        let l = self.lines_per_field as i64;
        let (f, jf) = (floordiv(j, l), posmod(j, l));
        let advance = p.format.advance_per_field();
        if jf == 0 || self.s.fields.is_empty() {
            self.field_step(f);
        }

        // The capstan moves the tape on; its speed error — the motor's own,
        // wandering with load, less the servo's correction — carries the
        // tape off its place (pitches per frame, two fields).
        let t = j as f64 * T::LINE * 1e-6;
        let motor = 0.004 * (2.0 * uniform(seed, 69, 0, 0) - 1.0) + 0.006 * value(seed, 60, t / 3.0);
        let s = &mut self.s;
        s.delta += (motor + s.speed + s.kick) / (2 * l) as f64;
        // A sticky patch under the guides: the tape is held back.
        let x = f as f64 * advance + jf as f64 / l as f64 * advance; // tape position, mm
        let grab = sticky::at(x, &self.tape);
        // The capstan slips against the held tape, so the tape falls behind
        // its place (the servo sees that, and pulls it back over the next
        // half second: the tracking sags and recovers).
        if grab.hold > 0.0 {
            s.delta -= sticky::SLIP * grab.hold / l as f64;
        }

        // The pinch roller's wobble, too fast for the servo (residual).
        let wobble = p.flutter * 0.03 * value(seed, 65, t * 3.5);
        let delta = s.delta + wobble;
        let alpha = p.format.track_offset_lines();
        // Soft-limited to under half a line, measured from the nearest track
        // of the heads' own azimuth.
        let mut tbe = T::LINE * 0.45 * (alpha * wrap2(delta) / 0.45).tanh();
        // Held, the tape sings: the squeal, a steady tone that swells until
        // it lets go. (Its pitch wavers: a stick-slip tone, not a tuning fork.)
        if grab.squeal > 0.0 {
            tbe += grab.squeal * (2.0 * std::f64::consts::PI * grab.pitch * t + 1.5 * value(seed, 106, t * 40.0)).sin();
        }
        if s.lines.len() >= self.cap {
            let drop = s.lines.len() - self.cap + 1;
            s.lines.drain(..drop);
        }
        s.lines.push_back(Line { delta, tbe, strain: grab.strain });
        s.line = j;
    }

    fn field_step(&mut self, f: i64) {
        let p = self.params;
        if p.searching() {
            // Picture search: the capstan runs n×, the servo is off, and each
            // sweep starts n−1 tracks on from the last.
            let prev = self.s.fields.back().copied();
            self.s.phase = prev.map(|e| wrap2(e.phase + e.rate)).unwrap_or(0.0);
            self.s.rate = p.search - 1.0;
            self.s.kick = 0.0;
        } else {
            if self.s.rate != 0.0 || self.s.phase != 0.0 {
                // Back to play: the servo has to pull the tape back in.
                self.s.delta += wrap2(self.s.phase + self.s.rate);
                self.s.phase = 0.0;
                self.s.rate = 0.0;
            }
            if posmod(f, 2) == 0 {
                self.servo(f);
            }
        }
        let (phase, rate) = (self.s.phase, self.s.rate);
        self.s.fields.push_back(FieldEntry { field: f, phase, rate });
        if self.s.fields.len() > 16 {
            self.s.fields.pop_front();
        }
    }

    /// One control-track pulse (once a frame).
    fn servo(&mut self, f: i64) {
        let p = self.params;
        let seed = self.seed;
        let pitch = p.format.track_pitch() * 1000.0;
        // Where the tape should be: the tracking control's offset, plus the
        // recording deck's own (its control head sat a few µm elsewhere).
        let recorded = 1.5 * (2.0 * uni(self.tape.seed, 95, 0, 0) as f64 - 1.0) / pitch;
        let target = p.tracking + recorded;
        // The pulse, as the control head reads it off the bottom edge: a
        // weaker tape overall still reads, but missing coating or the tape
        // held off the head loses it.
        let at = TapePosition::new(TapeGeometry::track_origin(f, p.format) + Self::CONTROL_OFFSET, Self::CONTROL_Y);
        let edge = tape_at(at, &self.tape, false);
        let amplitude = (edge.output / self.tape.remanence()) as f64 * (-2.0 * std::f64::consts::PI * edge.lift as f64 / 12.0).exp();
        let u = uniform(seed, 66, f, 0);
        // The phase detector reads the error to the nearest frame.
        let mut measured = (amplitude * (0.85 + 0.3 * u) > 0.5).then(|| wrap2(self.s.delta - target));
        // A crinkle passing the head can fake a pulse.
        let fake = 0.5 * smoothstep(0.8, 2.5, edge.lift) as f64;
        if uniform(seed, 67, f, 0) < fake {
            measured = Some(uniform(seed, 68, f, 0) - 0.5);
        }
        // No pulse: the capstan holds the speed it had settled on; the phase
        // correction is a one-frame nudge, not a speed held until the next
        // pulse (held over a run of missing pulses it would build into an
        // ever wider swing).
        self.s.kick = 0.0;
        let Some(e) = measured else { return };
        self.s.speed = -self.s.integ;
        self.s.kick = -0.377 * e;
        self.s.integ = (self.s.integ + 0.0986 * e).clamp(-0.15, 0.15);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::glitch::receiver::{Raster, Simulator};

    fn settings(values: &[(&str, f64)]) -> GlitchSettings {
        let mut s = GlitchSettings::default();
        s.values.insert("vcr".into(), 1.0);
        for (k, v) in values {
            s.values.insert(k.to_string(), *v);
        }
        s
    }

    #[test]
    fn a_worn_tape_keeps_its_tracking() {
        // Worn oxide reads weaker everywhere, but the control amplifier has
        // gain to spare: the servo holds (the Mac's 0.25.1 fix).
        let l = Raster::new(320, 240).total_lines();
        // (The second: a realistic worn tape, as amounts on the knobs' curves.)
        use crate::glitch::tape::as_before;
        let worn = [("tape_wear", as_before("tape_wear", 0.7)), ("tape_dropouts", as_before("tape_dropouts", 0.45)),
                    ("tape_scratches", as_before("tape_scratches", 0.5)), ("tape_edge_damage", as_before("tape_edge_damage", 0.35))];
        for extra in [&[("tape_wear", 1.0)][..], &worn[..]] {
            let mut t = TransportSimulator::new(l, Simulator::DEFAULT_SEED, &settings(extra));
            t.reset();
            let mut worst: f64 = 0.0;
            for f in 1..=30 * 60i64 {
                t.advance(f * l as i64);
                worst = worst.max(t.line(f * l as i64).delta.abs());
            }
            assert!(worst < 0.1, "{extra:?}: {worst}");
        }
    }

    #[test]
    fn a_lost_control_track_drifts_but_never_runs_away() {
        let l = Raster::new(320, 240).total_lines();
        let mut t = TransportSimulator::new(l, Simulator::DEFAULT_SEED, &settings(&[("tape_edge_damage", 1.0), ("tape_mold", 1.0), ("tape_wear", 1.0)]));
        t.reset();
        let mut worst: f64 = 0.0;
        for f in 1..=60 * 60i64 {
            t.advance(f * l as i64);
            let line = t.line(f * l as i64);
            worst = worst.max(line.delta.abs());
            assert!(line.tbe.abs() < T::LINE / 2.0);
        }
        assert!(worst < 60.0 * 0.15 * 30.0 + 2.0, "bounded by the capstan's range: {worst}");
    }
}
