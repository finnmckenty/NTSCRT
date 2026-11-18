//! VHS tape geometry and the tape's surface: a port of the Mac's
//! `Tape.swift`. The surface map must agree with `vcr.wgsl`'s `tape_at`.
//!
//! Coordinates on the tape are millimeters: x along the tape, y across it
//! from the bottom (reference) edge. A track starts at the bottom and rises
//! at 5.97°, so height across the tape is height in the picture.

use super::receiver::timing as T;

pub struct TapeGeometry;

impl TapeGeometry {
    pub const WIDTH: f64 = 12.65;
    /// Video writing speed, µm per µs.
    pub const WRITING_SPEED: f64 = 5.8;
    pub const TRACK_START: f64 = 1.0;

    pub fn advance_per_field() -> f64 {
        33.35 / T::FIELD_RATE
    }
    pub fn angle() -> f64 {
        5.97 * std::f64::consts::PI / 180.0
    }
    pub fn track_length() -> f64 {
        Self::WRITING_SPEED * 1000.0 / T::FIELD_RATE
    }
    pub fn track_pitch() -> f64 {
        Self::advance_per_field() * Self::angle().sin()
    }
    pub fn line_length() -> f64 {
        Self::track_length() / T::LINES_PER_FIELD
    }

    /// Where along its track (mm) signal line `field_line` of a raster with
    /// `lines_per_field` lines is at `u` µs. Lines are spaced by the raster's
    /// share of the track; each runs the real length of an NTSC line.
    pub fn along_track(field_line: f64, u: f64, lines_per_field: usize) -> f64 {
        field_line / lines_per_field as f64 * Self::track_length() + u / T::LINE * Self::line_length()
    }

    /// The track of field `field` starts this far along the tape (mm).
    pub fn track_origin(field: i64, format: TapeFormat) -> f64 {
        field as f64 * format.advance_per_field()
    }

    /// The tape point `along` mm up the track of field `field`, offset
    /// `across` mm sideways (toward the top edge).
    pub fn point(field: i64, along: f64, across: f64, format: TapeFormat) -> TapePosition {
        let a = Self::angle();
        let x = Self::track_origin(field, format) + along * a.cos() - across * a.sin();
        let y = Self::TRACK_START + along * a.sin() + across * a.cos();
        TapePosition::new(x, y)
    }
}

/// The speed a tape was recorded at. The drum turns at the same rate in all
/// three, so the tracks are as long and the signal on them the same; the
/// tape just moves on less between fields, so the tracks are narrower and
/// lie closer — a deck records LP and EP with narrower heads, which in EP
/// are wider than the track and overwrite part of the one before.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TapeFormat {
    /// 0 SP (standard play), 1 LP (long play, ½ speed), 2 EP (extended, ⅓).
    pub speed: usize,
}

impl TapeFormat {
    pub const SP: TapeFormat = TapeFormat { speed: 0 };
    pub const NAMES: [&'static str; 3] = ["SP", "LP", "EP"];

    pub fn with_speed(speed: i64) -> Self {
        Self { speed: speed.clamp(0, 2) as usize }
    }
    pub fn new(s: &super::GlitchSettings) -> Self {
        Self::with_speed(s.get("tape_speed").round() as i64)
    }

    /// Tape transport per field, mm.
    pub fn advance_per_field(&self) -> f64 {
        TapeGeometry::advance_per_field() / (self.speed + 1) as f64
    }
    /// Neighboring tracks' spacing across the tape, mm (58, 29, 19.3 µm).
    pub fn track_pitch(&self) -> f64 {
        self.advance_per_field() * TapeGeometry::angle().sin()
    }
    /// The video heads' width, mm: full-width SP heads, and the narrow
    /// heads of a four-head deck for LP and EP.
    pub fn head_width(&self) -> f64 {
        if self.speed == 0 { 0.058 } else { 0.026 }
    }
    /// What's left of each recorded track once the next has been written
    /// over its edge, mm.
    pub fn track_width(&self) -> f64 {
        self.head_width().min(self.track_pitch())
    }
    /// How far a track's lines sit along from the neighboring track's, in
    /// lines (1.5 SP, 0.75 LP, 0.5 EP).
    pub fn track_offset_lines(&self) -> f64 {
        self.advance_per_field() * TapeGeometry::angle().cos() / TapeGeometry::line_length()
    }
    /// The noise a head picks up, against an SP head's: decks make most of
    /// a narrow track's loss back with their narrow heads (spec sheets give
    /// much the same video S/N in every speed), leaving LP about 1.5 dB and
    /// EP 2.5 dB of carrier-to-noise behind SP.
    pub fn noise_scale(&self) -> f64 {
        [1.0, 0.53, 0.445][self.speed]
    }

    /// What a head `delta` track pitches off its own track's center reads
    /// of the three tracks nearest it (`center` − 1, `center`, `center` + 1):
    /// each one's share of a full SP track's output for the FM carrier and
    /// for the color-under. Tracks an odd number from its own were written
    /// at the other azimuth, so short wavelengths cancel (azimuth loss).
    pub fn read(&self, delta: f64) -> (i64, [f64; 3], [f64; 3]) {
        let (p, w, tw) = (self.track_pitch() * 1000.0, self.head_width() * 1000.0, self.track_width() * 1000.0);
        let center = delta.round() as i64;
        let (lo, hi) = (delta * p - w / 2.0, delta * p + w / 2.0);
        let (mut fm, mut color) = ([0.0; 3], [0.0; 3]);
        for t in 0..3 {
            let k = center - 1 + t as i64;
            let o = (hi.min(k as f64 * p + tw / 2.0) - lo.max(k as f64 * p - tw / 2.0)).max(0.0);
            let share = o / 58.0;
            if k % 2 == 0 {
                fm[t] = share;
                color[t] = share;
            } else {
                fm[t] = share * Self::azimuth_loss(o, Self::FM_MHZ);
                color[t] = share * Self::azimuth_loss(o, super::vcr::color_under_mhz());
            }
        }
        (center, fm, color)
    }

    /// The FM carrier's frequency for azimuth loss (mid-band).
    pub const FM_MHZ: f64 = 4.0;
    /// tan of the 12° between the two heads' azimuths.
    pub fn azimuth_tan() -> f64 {
        (12.0 * std::f64::consts::PI / 180.0).tan()
    }

    /// Amplitude (signed) a head reads of a track recorded at the other
    /// azimuth across `width` µm, at `mhz`.
    pub fn azimuth_loss(width: f64, mhz: f64) -> f64 {
        let lambda = TapeGeometry::WRITING_SPEED / mhz;
        let x = std::f64::consts::PI * width * Self::azimuth_tan() / lambda;
        if x < 1e-6 { 1.0 } else { x.sin() / x }
    }
}

/// A point on the tape, split for 32-bit floats: `base` whole tenths of a
/// millimeter along the tape plus `offset` more (in tenths).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TapePosition {
    pub base: i32,
    pub offset: f32,
    pub y: f32,
}

impl TapePosition {
    pub fn new(x: f64, y: f64) -> Self {
        let tenths = x * 10.0;
        let b = tenths.floor();
        Self { base: b.clamp(i32::MIN as f64, i32::MAX as f64) as i32, offset: (tenths - b) as f32, y: y as f32 }
    }
}

/// The tape's condition, from the Tape knobs.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TapeParams {
    pub seed: u32,
    pub wear: f32,
    pub dropouts: f32,
    pub scratches: f32,
    pub creases: f32,
    pub edge: f32,
    pub mold: f32,
    pub vaseline: f32,
    /// Binder breaking down (sticky shed): the tape drags and sheds.
    pub sticky: f32,
}

impl TapeParams {
    pub fn new(s: &super::GlitchSettings) -> Self {
        let u = |k: &str| s.get(k).clamp(0.0, 1.0) as f32;
        Self {
            seed: (s.get("tape_seed").round() as i64).wrapping_mul(7919).wrapping_add(17) as u32,
            wear: amount("tape_wear", u("tape_wear")),
            dropouts: amount("tape_dropouts", u("tape_dropouts")),
            scratches: amount("tape_scratches", u("tape_scratches")),
            creases: amount("tape_creases", u("tape_creases")),
            edge: amount("tape_edge_damage", u("tape_edge_damage")),
            mold: u("tape_mold"),
            vaseline: u("tape_vaseline"),
            sticky: u("tape_sticky"),
        }
    }
    pub fn remanence(&self) -> f32 {
        10f32.powf(-self.wear * 10.0 / 20.0)
    }
    pub fn roughness(&self) -> f32 {
        0.015 + 0.1 * self.wear
    }
    pub fn pinhole_chance(&self) -> f32 {
        (0.05 + 6.0 * self.dropouts + 2.0 * self.wear) * 0.01
    }
    pub fn flake_chance(&self) -> f32 {
        0.001 + 0.6 * self.dropouts * self.dropouts + 0.06 * self.wear + 0.06 * self.mold
    }
}

/// How far past a realistic worst case a damage knob goes at full: up to
/// half as calibrated, then a straight line to 1 + gain (Creases; and the
/// deck's Flutter, whose realistic most the TV's AFC rode out). Mac:
/// TapeParams.topEndGains.
pub fn top_end_gain(key: &str) -> f32 {
    match key {
        "tape_creases" | "transport_flutter" => 4.0,
        _ => 0.0,
    }
}

/// Measured slider curves: each knob's amount (1 = the realistic worst) at
/// the slider's tenths, so the picture's change grows as the slider to the
/// power 1.5 (Mac: TapeParams.curves — keep identical). Wear goes to 1.85,
/// with its color spared (DeckParams::color_boost).
pub fn curve(key: &str) -> Option<&'static [f32; 11]> {
    match key {
        "tape_wear" => Some(&[0.0, 0.259, 0.648, 0.955, 1.202, 1.391, 1.540, 1.640, 1.724, 1.785, 1.850]),
        "tape_dropouts" => Some(&[0.0, 0.195, 0.473, 0.754, 0.931, 1.120, 1.322, 1.607, 2.124, 2.480, 3.0]),
        "tape_scratches" => Some(&[0.0, 0.759, 1.281, 1.822, 2.073, 2.289, 2.516, 2.777, 3.069, 3.430, 4.0]),
        "tape_edge_damage" => Some(&[0.0, 0.703, 0.743, 0.800, 0.888, 0.934, 0.987, 1.056, 1.190, 1.329, 1.45]),
        _ => None,
    }
}

/// The keys with measured curves.
pub const CURVE_KEYS: [&str; 4] = ["tape_wear", "tape_dropouts", "tape_scratches", "tape_edge_damage"];

pub fn top_end(k: f32, gain: f32) -> f32 {
    if k <= 0.5 { k } else { k + gain * (k - 0.5) / 0.5 }
}

/// The knob setting that gives `amount` on a top end (its inverse).
pub fn knob_for_amount_gain(amount: f64, gain: f64) -> f64 {
    if amount <= 0.5 { amount } else { (amount + gain) / (1.0 + 2.0 * gain) }
}

/// A damage knob's amount for its slider position: its measured curve, or
/// its top end, or the knob itself.
pub fn amount(key: &str, k: f32) -> f32 {
    let k = k.clamp(0.0, 1.0);
    let Some(c) = curve(key) else { return top_end(k, top_end_gain(key)) };
    let x = k * 10.0;
    let i = (x as usize).min(9);
    c[i] + (c[i + 1] - c[i]) * (x - i as f32)
}

/// The slider position that gives `amount` (the inverse of `amount`).
pub fn knob(key: &str, amount: f64) -> f64 {
    let Some(c) = curve(key) else { return knob_for_amount_gain(amount, top_end_gain(key) as f64) };
    let a = amount.clamp(0.0, c[10] as f64) as f32;
    for i in 0..10 {
        if a <= c[i + 1] {
            let span = c[i + 1] - c[i];
            return ((i as f32 + if span > 0.0 { (a - c[i]) / span } else { 0.0 }) / 10.0) as f64;
        }
    }
    1.0
}

/// A knob's amount as 0.27.0 read it (straight lines above half), for looks
/// saved then and before (version < 3).
pub fn amount_in_027(key: &str, k: f64) -> f64 {
    let g = match key {
        "tape_wear" => 0.85,
        "tape_dropouts" => 2.0,
        "tape_scratches" => 3.0,
        "tape_edge_damage" => 0.45,
        _ => 0.0,
    };
    if k <= 0.5 { k } else { k + g * (k - 0.5) / 0.5 }
}

/// The knob setting that damages a tape as `amount` did before the curves
/// (for the tape choices, the dub decks and migrated old looks). Mac: asBefore.
pub fn as_before(key: &str, amount: f64) -> f64 {
    knob(key, amount)
}

/// What the head finds at one point of the tape.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TapePoint {
    /// Tape held off the head, µm (roughness, creases, edges, mold).
    pub lift: f32,
    /// A film on the tape (Vaseline), µm.
    pub film: f32,
    /// Magnetization relative to a new tape.
    pub output: f32,
    /// How much the tape sheds there.
    pub shed: f32,
}

#[inline(always)]
pub fn hash(a: u32, b: u32, c: u32, d: u32) -> u32 {
    let mut h = a.wrapping_mul(0x8DA6_B343) ^ b.wrapping_mul(0xD816_3841) ^ c.wrapping_mul(0xCB1A_B31F) ^ d.wrapping_mul(0x1656_67B1);
    h ^= h >> 15;
    h = h.wrapping_mul(0x2C1B_3C6D);
    h ^= h >> 12;
    h = h.wrapping_mul(0x297A_2D39);
    h ^= h >> 15;
    h
}

#[inline(always)]
pub fn uni(a: u32, b: u32, c: i32, d: i32) -> f32 {
    ((hash(a, b, c as u32, d as u32) >> 8) as f32 + 0.5) * (1.0 / 16_777_216.0)
}

#[inline(always)]
fn smooth(t: f32) -> f32 {
    t * t * (3.0 - 2.0 * t)
}

#[inline(always)]
pub(crate) fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// The cell of size `q` tenths of a mm holding x, and how far into it.
#[inline(always)]
fn cell(p: TapePosition, q: i32) -> (i32, f32) {
    let whole = p.offset.floor();
    let t = p.base.wrapping_add(whole as i32);
    let mut c = t / q;
    if t % q != 0 && t < 0 {
        c -= 1;
    }
    ((c), ((t.wrapping_sub(c.wrapping_mul(q))) as f32 + (p.offset - whole)) / q as f32)
}

#[inline(always)]
fn dx(p: TapePosition, c: i32, q: i32, frac: f32) -> f32 {
    (c.wrapping_mul(q).wrapping_sub(p.base)) as f32 + frac * q as f32 - p.offset
}

fn noise1(s: u32, k: u32, i: i32, f: f32) -> f32 {
    let a = uni(s, k, i, 0);
    let b = uni(s, k, i.wrapping_add(1), 0);
    a + (b - a) * smooth(f)
}

fn noise2(s: u32, k: u32, i: i32, fi: f32, j: i32, fj: f32) -> f32 {
    let a = uni(s, k, i, j);
    let b = uni(s, k, i.wrapping_add(1), j);
    let c = uni(s, k, i, j.wrapping_add(1));
    let d = uni(s, k, i.wrapping_add(1), j.wrapping_add(1));
    let (u, v) = (smooth(fi), smooth(fj));
    let lo = a + (b - a) * u;
    let hi = c + (d - c) * u;
    lo + (hi - lo) * v
}

const W: f32 = TapeGeometry::WIDTH as f32;

/// The tape at `p`. `detail` includes flaws much smaller than a track
/// (pinholes, scratches), which only matter to the picture.
pub fn tape_at(p: TapePosition, t: &TapeParams, detail: bool) -> TapePoint {
    tape_at_with(p, t, detail, true)
}

/// `tape_at`; `flakes: false` leaves out the flakes too, for the deck's
/// color loops, which hold through a dropout.
pub fn tape_at_with(p: TapePosition, t: &TapeParams, detail: bool, flakes: bool) -> TapePoint {
    let s = t.seed;
    let y = p.y;
    let mut lift = t.roughness();
    let mut out = t.remanence();
    let mut film = 0.0f32;
    // Worn coating sheds a little everywhere; a hydrolyzed binder sheds
    // gummy oxide all along the tape.
    let mut shed = 0.02 * t.wear + 0.9 * t.sticky * t.sticky;

    {
        let (cx, fx) = cell(p, 5);
        let yy = y * 10.0;
        let cy = yy.floor() as i32;
        out *= 1.0 + (0.04 + 0.1 * t.wear) * (2.0 * noise2(s, 1, cx, fx, cy, yy - cy as f32) - 1.0);
    }

    let pin = t.pinhole_chance();
    if detail && pin > 0.0 {
        let (cx, _) = cell(p, 1);
        let cy = (y * 10.0).floor() as i32;
        for j in -1..=1 {
            for i in -1..=1 {
                let (ci, cj) = (cx.wrapping_add(i), cy.wrapping_add(j));
                if uni(s, 11, ci, cj) >= pin {
                    continue;
                }
                let ddx = dx(p, ci, 1, uni(s, 12, ci, cj)) * 0.1;
                let ddy = (cj as f32 + uni(s, 13, ci, cj)) * 0.1 - y;
                let u = uni(s, 14, ci, cj);
                let r = 0.003 * 15f32.powf(u * u);
                let d = (ddx * ddx + ddy * ddy).sqrt();
                if d < r {
                    out *= smoothstep(r * 0.6, r, d);
                }
            }
        }
    }

    let flake = t.flake_chance();
    if flakes && flake > 0.0 {
        let (cx, _) = cell(p, 10);
        let cy = y.floor() as i32;
        for j in -1..=1 {
            for i in -1..=1 {
                let (ci, cj) = (cx.wrapping_add(i), cy.wrapping_add(j));
                if uni(s, 21, ci, cj) >= flake {
                    continue;
                }
                let ddx = dx(p, ci, 10, uni(s, 22, ci, cj)) * 0.1;
                let ddy = cj as f32 + uni(s, 23, ci, cj) - y;
                let u = uni(s, 24, ci, cj);
                // Past the realistic range (dropouts over 1: the top of the
                // knob) the flakes grow, since a square holds one.
                let r = 0.04 * 8f32.powf(u * u) * (1.0 + 0.6 * (t.dropouts - 1.0).max(0.0));
                let e = 0.6 + 0.8 * uni(s, 25, ci, cj);
                let d = ((ddx / e) * (ddx / e) + (ddy * e) * (ddy * e)).sqrt();
                if d < r * 1.5 {
                    out *= smoothstep(r * 0.8, r, d);
                    shed += 0.5 * (1.0 - smoothstep(r, r * 1.5, d));
                }
            }
        }
    }

    // Lengthwise scratches from worn guides, along a stretch of tape. Most
    // are narrower than a track (6–80 µm); the debris thrown up either side
    // holds the head off a little. A scratch weaves sideways (tens of µm),
    // and its depth and width vary, with skips.
    if detail && t.scratches > 0.0 {
        let lane = (y * 4.0).floor() as i32;
        let (sx, fx) = cell(p, 3000);
        let ((c80, f80), (c15, f15)) = (cell(p, 80), cell(p, 15));
        let ((c200, f200), (c120, f120)) = (cell(p, 200), cell(p, 120));
        for l in -1..=1 {
            let li = lane.wrapping_add(l);
            if uni(s, 31, li, sx) >= t.scratches * 0.3 {
                continue;
            }
            let (a, b) = (uni(s, 32, li, sx), uni(s, 33, li, sx));
            if fx < a.min(b) * 0.6 || fx > 0.4 + a.max(b) * 0.6 {
                continue;
            }
            // This scratch's own variation along the tape.
            let ss = s ^ (li as u32).wrapping_mul(0x9E37_79B9) ^ (sx as u32).wrapping_mul(0x85EB_CA6B);
            let weave = 0.03 * (2.0 * noise1(ss, 37, c80, f80) - 1.0) + 0.012 * (2.0 * noise1(ss, 38, c15, f15) - 1.0);
            let yc = (li as f32 + 0.15 + 0.7 * uni(s, 34, li, sx)) * 0.25 + weave;
            let u = uni(s, 35, li, sx);
            let w = (0.006 + 0.074 * u * u * u) * (0.6 + 0.4 * t.scratches) * (0.5 + noise1(ss, 39, c200, f200));
            let depth = smoothstep(0.3, 0.55, noise1(ss, 40, c120, f120));
            if depth <= 0.0 {
                continue;
            }
            let dy = (y - yc).abs();
            if dy < w * 0.5 {
                out *= 1.0 - 0.95 * depth;
                lift += 0.15 * depth * t.scratches;
            } else if dy < w * 1.5 {
                lift += 0.35 * depth * t.scratches * (1.0 - (dy - w * 0.5) / w);
            }
        }
    }

    if t.creases > 0.0 {
        let (sx, _) = cell(p, 400);
        for k in -1..=1 {
            let ci = sx.wrapping_add(k);
            if uni(s, 41, ci, 0) >= t.creases * 0.9 {
                continue;
            }
            let off = dx(p, ci, 400, uni(s, 42, ci, 0)) * 0.1;
            let slant = ((uni(s, 43, ci, 0) - 0.5) * 0.7).tan();
            let from_bottom = uni(s, 44, ci, 0) < 0.5;
            let extent = W * (0.25 + 0.75 * uni(s, 45, ci, 0));
            let yy = if from_bottom { y } else { W - y };
            if yy >= extent {
                continue;
            }
            let reach = smoothstep(extent, extent * 0.8, yy);
            let w = 0.3 + 2.7 * uni(s, 46, ci, 0).powf(1.5);
            let peak = (0.5 + 3.5 * uni(s, 47, ci, 0).powf(1.5)) * (0.4 + 0.6 * t.creases);
            let dd = (off + yy * slant) / w;
            if dd.abs() >= 4.0 {
                continue;
            }
            let profile = (-dd * dd).exp() * (0.75 + 0.25 * (dd * 9.0).cos());
            lift += peak * profile * reach;
            out *= 1.0 - 0.3 * profile * reach;
        }
    }

    if t.edge > 0.0 {
        for side in 0..2u32 {
            let k = 51 + side * 4;
            let yy = if side == 0 { y } else { W - y };
            let (c60, f60) = cell(p, 600);
            let stretch = noise1(s, k, c60, f60);
            let damaged = smoothstep(t.edge * 0.85, t.edge * 0.85 - 0.1, stretch);
            if damaged <= 0.0 {
                continue;
            }
            let (c20, f20) = cell(p, 200);
            let reach = 0.3 + 1.9 * t.edge * (0.5 + 0.5 * noise1(s, k + 1, c20, f20));
            if yy >= reach {
                continue;
            }
            let (c1, f1) = cell(p, 12);
            let crinkle = noise1(s, k + 2, c1, f1);
            lift += damaged * t.edge * (1.0 + 2.5 * crinkle * crinkle) * (1.0 - yy / reach).powf(0.7);
        }
    }

    if t.mold > 0.0 {
        let (cx, _) = cell(p, 40);
        let cy = (y / 4.0).floor() as i32;
        for j in -1..=1 {
            for i in -1..=1 {
                let (ci, cj) = (cx.wrapping_add(i), cy.wrapping_add(j));
                let ycen = (cj as f32 + uni(s, 63, ci, cj)) * 4.0;
                if ycen <= -1.0 || ycen >= W + 1.0 {
                    continue;
                }
                let edge_near = 1.0 - (ycen.abs().min((W - ycen).abs()) / 6.3).min(1.0);
                if uni(s, 61, ci, cj) >= (t.mold * (0.3 + 1.3 * edge_near)).min(0.95) {
                    continue;
                }
                let ddx = dx(p, ci, 40, uni(s, 62, ci, cj)) * 0.1;
                let ddy = ycen - y;
                let d = (ddx * ddx + ddy * ddy).sqrt();
                let big = (0.35 + 2.0 * uni(s, 64, ci, cj).powf(1.3)) * (0.6 + 0.4 * t.mold);
                if d >= big * 1.4 {
                    continue;
                }
                let turn = (ddy.atan2(ddx) / std::f32::consts::TAU + 0.5) * 6.0;
                let ti = turn.floor() as i32;
                let a0 = uni(s, 65, ci.wrapping_mul(7).wrapping_add(ti % 6), cj);
                let a1 = uni(s, 65, ci.wrapping_mul(7).wrapping_add((ti + 1) % 6), cj);
                let rr = big * (0.7 + 0.6 * (a0 + (a1 - a0) * smooth(turn - ti as f32)));
                let mut dens = 1.0 - smoothstep(rr * 0.35, rr, d);
                if dens <= 0.0 {
                    continue;
                }
                let (f3, ff3) = cell(p, 3);
                let fy3 = y * 0.33 * 10.0;
                let gy = fy3.floor() as i32;
                dens *= 0.55 + 0.45 * noise2(s, 66, f3, ff3, gy, fy3 - gy as f32);
                lift += dens * (0.5 + 2.5 * t.mold);
                out *= 1.0 - 0.55 * dens;
                shed += dens * 2.0;
            }
        }
    }

    if t.vaseline > 0.0 {
        let (sx, fx) = cell(p, 600);
        if uni(s, 71, sx, 0) < 0.2 + 0.8 * t.vaseline {
            let a = 0.4 * uni(s, 72, sx, 0);
            let b = 0.6 + 0.4 * uni(s, 73, sx, 0);
            let taper = smoothstep(a, a + 0.05, fx) * smoothstep(b, b - 0.05, fx);
            if taper > 0.0 {
                let (c8, f8) = cell(p, 80);
                let yy = y * 5.0;
                let cy = yy.floor() as i32;
                let streak = noise2(s, 74, c8, f8, cy, yy - cy as f32).powf(1.5);
                film = t.vaseline * 1.8 * (0.25 + 0.75 * streak) * taper;
            }
        }
    }

    TapePoint { lift, film, output: out.max(0.0), shed }
}

/// A crease a track crosses: how far along it (mm), its width, and how much
/// the fold shortens the track (µm).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Fold {
    pub along: f64,
    pub width: f64,
    pub shortening: f64,
}

/// The creases track `field` crosses, in order along it.
pub fn folds(field: i64, t: &TapeParams, format: TapeFormat) -> Vec<Fold> {
    if t.creases <= 0.0 {
        return Vec::new();
    }
    let s = t.seed;
    let start = TapeGeometry::track_origin(field, format);
    let lo = (start * 10.0 / 400.0).floor() as i32 - 1;
    let hi = ((start + TapeGeometry::track_length()) * 10.0 / 400.0).floor() as i32 + 1;
    let (c, sn) = (TapeGeometry::angle().cos(), TapeGeometry::angle().sin());
    let mut out = Vec::new();
    for ci in lo..=hi {
        if uni(s, 41, ci, 0) >= t.creases * 0.9 {
            continue;
        }
        let xc = (ci as f64 + uni(s, 42, ci, 0) as f64) * 40.0;
        let slant = ((uni(s, 43, ci, 0) - 0.5) * 0.7).tan() as f64;
        let from_bottom = uni(s, 44, ci, 0) < 0.5;
        let extent = TapeGeometry::WIDTH * (0.25 + 0.75 * uni(s, 45, ci, 0) as f64);
        let w = 0.3 + 2.7 * (uni(s, 46, ci, 0) as f64).powf(1.5);
        let peak = (0.5 + 3.5 * (uni(s, 47, ci, 0) as f64).powf(1.5)) * (0.4 + 0.6 * t.creases as f64);
        let y0 = TapeGeometry::TRACK_START;
        let a = if from_bottom {
            (xc + y0 * slant - start) / (c - sn * slant)
        } else {
            (xc + (TapeGeometry::WIDTH - y0) * slant - start) / (c + sn * slant)
        };
        if !(0.0..=TapeGeometry::track_length()).contains(&a) {
            continue;
        }
        let y = y0 + a * sn;
        let yy = if from_bottom { y } else { TapeGeometry::WIDTH - y };
        if yy >= extent {
            continue;
        }
        let reach = smoothstep(extent as f32, extent as f32 * 0.8, yy as f32) as f64;
        out.push(Fold { along: a, width: w, shortening: 4.0 * peak * reach });
    }
    out.sort_by(|a, b| a.along.total_cmp(&b.along));
    out
}
