//! RF input: the picture reaching the TV on channel 3 through its antenna
//! socket, the way a game console or a VCR sent it — as a composite video
//! signal, through the tuner — instead of arriving already separated into
//! brightness and color. A port of the Mac's `CompositeSignal.swift`; the
//! reasoning and the history are there and in DEVELOPMENT.md ("RF input").
//!
//! The picture is really made into the signal, at its own pixel scale
//! (after Downscale), six samples a subcarrier cycle, and decoded as a set
//! would (glitch.wgsl, `decodeComposite`): hard edges get colored fringes
//! that differ from line to line and move every field. The snow and the
//! ghost are in the signal. Every number here is a choice, not a
//! measurement.

use std::f64::consts::PI;

use super::params::GlitchSettings;
use super::receiver::timing as T;

/// Samples in a subcarrier cycle.
pub const SAMPLES_PER_CYCLE: usize = 6;
/// A sample's length, µs.
pub const SAMPLE_US: f64 = 1.0 / (SAMPLES_PER_CYCLE as f64 * T::SUBCARRIER_MHZ);
/// The tuner's own noise on a strong signal, IRE in the video band.
pub const TUNER_NOISE_IRE: f64 = 1.5;
/// The decode filters' reach either side, samples (1.1 µs).
pub const REACH: usize = 24;
/// Edge crawl's emphasis compares the signal with itself half a subcarrier
/// cycle either side.
const EMPHASIS_STEP: usize = SAMPLES_PER_CYCLE / 2;
/// The reach of the filters with the emphasis folded in.
pub const TAP_RADIUS: usize = REACH + EMPHASIS_STEP;
/// Edge crawl at the top: the brightness's edges emphasized by 0.75, what
/// the set takes for color by 0.3 (2.2 times).
const EDGE_MOST: f64 = 0.75;
const FRINGE_MOST: f64 = 0.3;
/// Color's range: four times the color as sent.
pub const MOST_COLOR: f64 = 4.0;
/// Tuner offset: the loss at the subcarrier, the tilt toward the picture's
/// broad strokes, and the share of the picture's color it takes besides.
const OFFSET_LOSS: f64 = 0.85;
const OFFSET_TILT: f64 = 2.0;
const OFFSET_FADE: f64 = 0.5;
/// Tuner smear: how many whole subcarrier cycles back the color comes from,
/// and the weights' ratio at the top of the knob.
const SMEAR_STEPS: usize = 8;
const SMEAR_MOST: f64 = 0.9;
const SMEAR_REACH: usize = SMEAR_STEPS * SAMPLES_PER_CYCLE;
/// The filter table: from `TAP_LEFT` samples before the pixel to
/// `TAP_RADIUS` after it.
pub const TAP_LEFT: usize = TAP_RADIUS + SMEAR_REACH;
pub const TAP_SPAN: usize = TAP_LEFT + TAP_RADIUS + 1;

/// The receiver's noise figure is IRE in the 4.2 MHz video band; a sample
/// here carries the band to half the sampling rate.
pub fn noise_per_sample() -> f64 {
    (0.5 / SAMPLE_US / 4.2).sqrt()
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CompositeSignal {
    /// The picture comes in through the antenna socket. Off: brightness and
    /// color arrive apart, and nothing here acts.
    pub on: bool,
    /// Edge crawl, 0…1.
    pub crawl: f64,
    /// Color: the picture's own color, 0 through 1 (as sent) to MOST_COLOR.
    pub color: f64,
    /// Tuner smear, 0…1: the color arriving late and drawn out.
    pub smear: f64,
    /// Softness, 0…1: the brightness filter's cutoff brought down.
    pub soft: f64,
    /// Tuner offset, 0…1: the set tuned off the channel.
    pub offset: f64,
}

impl CompositeSignal {
    pub fn new(s: &GlitchSettings) -> Self {
        let on = s.flag("rf");
        let knob = |id: &str| if on { s.get(id).clamp(0.0, 1.0) } else { 0.0 };
        Self {
            on,
            crawl: knob("rf_crawl"),
            color: if on { s.get("rf_color").clamp(0.0, MOST_COLOR) } else { 1.0 },
            smear: knob("rf_smear"),
            soft: knob("rf_soft"),
            offset: knob("rf_offset"),
        }
    }

    /// Tuner offset: what is left of everything around the subcarrier — the
    /// color, and the burst the set's color circuits lock to.
    pub fn burst_gain(&self) -> f64 {
        1.0 - OFFSET_LOSS * self.offset
    }

    /// Softness: the brightness filter's half-gain frequency, MHz.
    pub fn luma_cutoff_mhz(&self) -> f64 {
        2.1 - 1.3 * self.soft
    }

    fn edge_emphasis(&self) -> f64 {
        EDGE_MOST * self.crawl
    }
    fn fringe_emphasis(&self) -> f64 {
        FRINGE_MOST * self.crawl
    }

    /// The color as it goes into the signal: the Color knob's, less what
    /// Edge crawl's emphasis will add to it and what Tuner offset takes.
    pub fn color_in_signal(&self) -> f64 {
        self.color * (1.0 - OFFSET_FADE * self.offset) / (1.0 + 4.0 * self.fringe_emphasis())
    }

    /// The set's two filters with the knobs in them, each `2·TAP_RADIUS + 1`
    /// long, brightness then color (the Mac's `taps`).
    pub fn taps(&self) -> (Vec<f32>, Vec<f32>) {
        let (r, n, d) = (TAP_RADIUS as i64, REACH as i64, EMPHASIS_STEP as i64);
        let (el, ec) = (self.edge_emphasis(), self.fringe_emphasis());
        let luma = luma_filter();
        let low = if self.soft > 0.0 { lowpass(self.luma_cutoff_mhz() * SAMPLE_US, true) } else { luma };
        let notch = notch_filter();
        let broad = broad_filter();
        let chroma_f = chroma_filter();
        let tilt = OFFSET_TILT * self.offset;
        let base: Vec<f64> = (0..=2 * REACH)
            .map(|i| {
                let plain = low[i] + self.crawl * (notch[i] - low[i]);
                (plain + tilt * broad[i]) / (1.0 + tilt)
            })
            .collect();
        let at = |f: &[f64], k: i64| if k.abs() <= n { f[(k + n) as usize] } else { 0.0 };
        let mut luma_taps = Vec::with_capacity(2 * TAP_RADIUS + 1);
        let mut chroma_taps = Vec::with_capacity(2 * TAP_RADIUS + 1);
        for k in -r..=r {
            luma_taps.push(((1.0 + 2.0 * el) * at(&base, k) - el * (at(&base, k - d) + at(&base, k + d))) as f32);
            chroma_taps.push(((1.0 + 2.0 * ec) * at(&chroma_f, k) + ec * (at(&chroma_f, k - d) + at(&chroma_f, k + d))) as f32);
        }
        (luma_taps, chroma_taps)
    }

    /// Tuner smear's weights: the color as it was 0, 1, … whole subcarrier
    /// cycles back.
    pub fn smear_kernel(&self) -> Vec<f64> {
        let a = SMEAR_MOST * self.smear.sqrt();
        let w: Vec<f64> = (0..=SMEAR_STEPS).map(|k| a.powi(k as i32)).collect();
        let sum: f64 = w.iter().sum();
        w.iter().map(|x| x / sum).collect()
    }

    /// The stage's filter table (the Mac's `signalTaps`): for each sample
    /// from TAP_LEFT before the pixel to TAP_RADIUS after it, what its
    /// brightness adds to the pixel's brightness and to its color, and what
    /// its color adds to each (those two with the smear in them).
    pub fn signal_taps(&self) -> Vec<f32> {
        let (luma, chroma) = self.taps();
        let r = TAP_RADIUS as i64;
        let w = self.smear_kernel();
        let at = |f: &[f32], k: i64| if k.abs() <= r { f[(k + r) as usize] as f64 } else { 0.0 };
        let mut table = vec![0f32; 4 * TAP_SPAN];
        for m in -(TAP_LEFT as i64)..=r {
            let i = (m + TAP_LEFT as i64) as usize;
            table[i] = at(&luma, m) as f32;
            table[i + TAP_SPAN] = at(&chroma, m) as f32;
            let (mut l, mut c) = (0.0, 0.0);
            for (j, wj) in w.iter().enumerate() {
                if *wj != 0.0 {
                    l += wj * at(&luma, m + (j * SAMPLES_PER_CYCLE) as i64);
                    c += wj * at(&chroma, m + (j * SAMPLES_PER_CYCLE) as i64);
                }
            }
            table[i + 2 * TAP_SPAN] = l as f32;
            table[i + 3 * TAP_SPAN] = c as f32;
        }
        table
    }

    /// How far before the pixel the table is in use: the smear's reach only
    /// when there is smear.
    pub fn taps_before(&self) -> usize {
        if self.smear > 0.0 {
            TAP_LEFT
        } else {
            TAP_RADIUS
        }
    }
}

/// A low-pass filter of `2·REACH + 1` taps, half its gain at `cutoff` cycles
/// a sample, unit gain at rest. `blackman` trades a wider skirt for a deeper
/// stop band.
fn lowpass(cutoff: f64, blackman: bool) -> Vec<f64> {
    let n = REACH as i64;
    let h: Vec<f64> = (-n..=n)
        .map(|k| {
            let x = k as f64;
            let sinc = if k == 0 { 2.0 * cutoff } else { (2.0 * PI * cutoff * x).sin() / (PI * x) };
            let a = PI * (x + n as f64) / n as f64;
            let w = if blackman { 0.42 - 0.5 * a.cos() + 0.08 * (2.0 * a).cos() } else { 0.54 - 0.46 * a.cos() };
            sinc * w
        })
        .collect();
    let sum: f64 = h.iter().sum();
    h.iter().map(|x| x / sum).collect()
}

/// Brightness: half gain at 2.1 MHz, nothing left at the subcarrier.
fn luma_filter() -> Vec<f64> {
    lowpass(2.1 * SAMPLE_US, true)
}
/// The picture's broadest strokes only: what a tuner off its channel favors.
fn broad_filter() -> Vec<f64> {
    lowpass(0.5 * SAMPLE_US, false)
}
/// Color: half gain at 0.85 MHz, nothing left at 1.8.
fn chroma_filter() -> Vec<f64> {
    lowpass(0.85 * SAMPLE_US, false)
}
/// The brightness filter of a set with a notch: everything to 4.6 MHz except
/// a band a megahertz wide around the subcarrier.
fn notch_filter() -> Vec<f64> {
    let wide = lowpass(4.6 * SAMPLE_US, true);
    let band = lowpass(0.5 * SAMPLE_US, false);
    let n = REACH as i64;
    let h: Vec<f64> = (-n..=n).map(|k| wide[(k + n) as usize] - 2.0 * (2.0 * PI * k as f64 / SAMPLES_PER_CYCLE as f64).cos() * band[(k + n) as usize]).collect();
    let sum: f64 = h.iter().sum();
    h.iter().map(|x| x / sum).collect()
}

/// A filter's gain at `f` cycles a sample (the taps are symmetric).
pub fn gain(taps: &[f32], f: f64) -> f64 {
    let r = (taps.len() / 2) as i64;
    (-r..=r).map(|k| taps[(k + r) as usize] as f64 * (2.0 * PI * f * k as f64).cos()).sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signal(values: &[(&str, f64)]) -> CompositeSignal {
        let mut s = GlitchSettings::default();
        for (k, v) in values {
            s.values.insert(k.to_string(), *v);
        }
        CompositeSignal::new(&s)
    }
    fn mhz(f: f64) -> f64 {
        f * SAMPLE_US
    }
    const CARRIER: f64 = 1.0 / SAMPLES_PER_CYCLE as f64;

    /// The shader's copies of the table's sizes are these.
    #[test]
    fn the_shader_has_the_tables_sizes() {
        let wgsl = include_str!("glitch.wgsl");
        for (name, value) in [("SIG_AFTER", TAP_RADIUS), ("SIG_LEFT", TAP_LEFT), ("SIG_SPAN", TAP_SPAN), ("SIG_CYCLE", SAMPLES_PER_CYCLE)] {
            assert!(wgsl.contains(&format!("const {name}: i32 = {value};")), "{name} = {value}");
        }
    }

    /// Off by default, and off the knobs do nothing.
    #[test]
    fn the_switch() {
        assert!(!signal(&[]).on);
        let off = signal(&[("rf_crawl", 0.8), ("rf_color", 3.0), ("rf_smear", 1.0), ("rf_soft", 1.0), ("rf_offset", 1.0)]);
        assert_eq!((off.crawl, off.color, off.smear, off.soft, off.offset), (0.0, 1.0, 0.0, 0.0, 0.0));
        assert_eq!((off.burst_gain(), off.color_in_signal()), (1.0, 1.0));
        let on = signal(&[("rf", 1.0)]);
        assert!(on.on && on.crawl == 0.0 && on.color == 1.0);
        assert!(crate::glitch::params::is_timing("rf") && crate::glitch::params::is_timing("rf_offset"));
    }

    /// The brightness filter passes the picture and keeps the subcarrier
    /// out; the color filter passes the color's band and no more.
    #[test]
    fn the_decode_filters() {
        let (luma, chroma) = signal(&[("rf", 1.0)]).taps();
        assert_eq!((luma.len(), chroma.len()), (2 * TAP_RADIUS + 1, 2 * TAP_RADIUS + 1));
        assert!((gain(&luma, 0.0) - 1.0).abs() < 1e-5);
        assert!(gain(&luma, mhz(1.0)) > 0.85);
        assert!((gain(&luma, mhz(2.1)) - 0.5).abs() < 0.06);
        for f in [3.58, 4.2, 5.4, 7.16, 10.0] {
            assert!(gain(&luma, mhz(f)).abs() < 0.01, "luma at {f} MHz");
        }
        assert!((gain(&chroma, mhz(0.85)) - 0.5).abs() < 0.06);
        for f in [1.8, 2.5, 3.58, 5.0, 7.16] {
            assert!(gain(&chroma, mhz(f)).abs() < 0.02, "chroma at {f} MHz");
        }
    }

    /// Edge crawl: harder edges and stronger fringes (2.2 times at the top,
    /// not four), levels holding, a steady color still out of the
    /// brightness, the picture's own color unchanged.
    #[test]
    fn edge_crawl_leaves_the_color() {
        let mut last_fringe = 1.0;
        let mut last_edge = gain(&signal(&[("rf", 1.0)]).taps().0, CARRIER / 2.0);
        for k in [0.25, 0.5, 0.75, 1.0] {
            let sig = signal(&[("rf", 1.0), ("rf_crawl", k)]);
            let (luma, chroma) = sig.taps();
            assert!((gain(&luma, 0.0) - 1.0).abs() < 1e-5);
            assert!(gain(&luma, CARRIER).abs() < 0.02);
            let (fringe, edge) = (gain(&chroma, 0.0), gain(&luma, CARRIER / 2.0));
            assert!(fringe > last_fringe + 0.2 && edge > last_edge * 1.15, "{k}");
            assert!((sig.color_in_signal() * fringe - 1.0).abs() < 1e-5, "{k}");
            (last_fringe, last_edge) = (fringe, edge);
        }
        assert!((last_fringe - 2.2).abs() < 0.01);
    }

    /// Tuner smear: the lateness grows evenly to about 0.9 µs; the table's
    /// brightness columns never change and its color columns match them
    /// without smear.
    #[test]
    fn tuner_smear_makes_the_color_late() {
        let late = |k: f64| {
            let w = signal(&[("rf", 1.0), ("rf_smear", k)]).smear_kernel();
            assert!((w.iter().sum::<f64>() - 1.0).abs() < 1e-9);
            w.iter().enumerate().map(|(i, x)| i as f64 * x).sum::<f64>() / T::SUBCARRIER_MHZ
        };
        assert_eq!(late(0.0), 0.0);
        let mut last = 0.0;
        for k in [0.25, 0.5, 0.75, 1.0] {
            let v = late(k);
            assert!(v > last + 0.12, "{k}");
            last = v;
        }
        assert!((last - 0.92).abs() < 0.05);
        let plain = signal(&[("rf", 1.0)]);
        let smeared = signal(&[("rf", 1.0), ("rf_smear", 1.0)]);
        let (p, q) = (plain.signal_taps(), smeared.signal_taps());
        assert_eq!(p.len(), 4 * TAP_SPAN);
        assert_eq!(p[..2 * TAP_SPAN], q[..2 * TAP_SPAN]);
        assert_eq!(p[2 * TAP_SPAN..], p[..2 * TAP_SPAN]);
        assert_eq!((plain.taps_before(), smeared.taps_before()), (TAP_RADIUS, TAP_LEFT));
        let (a, b): (f32, f32) = (q[3 * TAP_SPAN..].iter().sum(), p[TAP_SPAN..2 * TAP_SPAN].iter().sum());
        assert!((a - b).abs() < 1e-4);
    }

    /// Softness takes the brightness's detail only; Tuner offset starves
    /// everything at the subcarrier and lowers detail's contrast.
    #[test]
    fn softness_and_tuner_offset() {
        let plain = signal(&[("rf", 1.0)]).taps();
        let mut last = gain(&plain.0, mhz(1.5));
        for k in [0.25, 0.5, 0.75, 1.0] {
            let t = signal(&[("rf", 1.0), ("rf_soft", k)]).taps();
            assert!((gain(&t.0, 0.0) - 1.0).abs() < 1e-5);
            let g = gain(&t.0, mhz(1.5));
            assert!(g < last - 0.1, "{k}");
            assert_eq!(t.1, plain.1);
            last = g;
        }
        assert!(last < 0.05);
        let (mut burst, mut color, mut detail) = (1.0, 1.0, gain(&plain.0, mhz(1.5)));
        for k in [0.25, 0.5, 0.75, 1.0] {
            let sig = signal(&[("rf", 1.0), ("rf_offset", k)]);
            let d = gain(&sig.taps().0, mhz(1.5));
            assert!(sig.burst_gain() < burst - 0.15 && sig.color_in_signal() < color - 0.08 && d < detail - 0.05, "{k}");
            assert!((gain(&sig.taps().0, 0.0) - 1.0).abs() < 1e-5);
            (burst, color, detail) = (sig.burst_gain(), sig.color_in_signal(), d);
        }
        assert!((burst - 0.15).abs() < 1e-9 && detail > 0.2);
    }
}
