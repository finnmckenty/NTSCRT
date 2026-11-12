//! Microsoft Video 1 (1992, Video for Windows; "CRAM"), the Digital video
//! stage's second codec (`Video1Codec.swift`): block truncation coding in
//! 15-bit RGB, no transform at all. Every 4×4 block is coded the cheapest way
//! that keeps its error under the quality's threshold:
//!
//! - skip (between keyframes): leave the previous picture's block;
//! - one color: the block's average;
//! - two colors: each pixel picks one of a pair (hard two-tone edges);
//! - eight colors: a pair for each 2×2 quarter (busy detail stays readable).
//!
//! Colors are 5 bits a channel, so gradients step into bands. Coded blocks
//! are absolute, so a decoder that lost data heals wherever a block is coded
//! again; skipped and lost blocks keep whatever it last had. Apple Video
//! (QuickTime's "road pizza") is the same family; starved, it collapses to
//! one-color mosaic — this codec's low end.

use std::ops::{Add, AddAssign, Div, Mul, Sub};
use std::sync::Arc;

use rayon::prelude::*;

use crate::codec::{CodecFrameKind, CodecGeometry, CodecPicture, CodecState, DigitalCodec, FrameSettings, MotionVector};
use crate::params::{swift_max, swift_min};

/// Swift's `SIMD3<Float>`, with its element-wise arithmetic.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct V3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl V3 {
    pub const ZERO: V3 = V3 { x: 0.0, y: 0.0, z: 0.0 };
    pub const fn new(x: f32, y: f32, z: f32) -> Self {
        V3 { x, y, z }
    }
    /// `SIMD.sum()`: left to right.
    #[inline(always)]
    pub fn sum(self) -> f32 {
        self.x + self.y + self.z
    }
}

impl Add for V3 {
    type Output = V3;
    #[inline(always)]
    fn add(self, o: V3) -> V3 { V3::new(self.x + o.x, self.y + o.y, self.z + o.z) }
}
impl AddAssign for V3 {
    #[inline(always)]
    fn add_assign(&mut self, o: V3) { *self = *self + o; }
}
impl Sub for V3 {
    type Output = V3;
    #[inline(always)]
    fn sub(self, o: V3) -> V3 { V3::new(self.x - o.x, self.y - o.y, self.z - o.z) }
}
impl Mul for V3 {
    type Output = V3;
    #[inline(always)]
    fn mul(self, o: V3) -> V3 { V3::new(self.x * o.x, self.y * o.y, self.z * o.z) }
}
impl Mul<f32> for V3 {
    type Output = V3;
    #[inline(always)]
    fn mul(self, s: f32) -> V3 { V3::new(self.x * s, self.y * s, self.z * s) }
}
impl Div<f32> for V3 {
    type Output = V3;
    #[inline(always)]
    fn div(self, s: f32) -> V3 { V3::new(self.x / s, self.y / s, self.z / s) }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Video1Mode {
    Skip,
    Fill,
    Two,
    Eight,
}

/// The Video 1 codec's functions (the Mac's `enum Video1Codec` namespace).
pub struct Video1Codec;

impl Video1Codec {
    /// The largest mean squared error (per pixel and channel, 0–255 scale) a
    /// block may carry in a cheaper mode. Quality runs √threshold linearly,
    /// as the DCT codec runs √step: the damage changes evenly along the
    /// slider. 0 → 2,500 (nearly everything one color, frozen between
    /// keyframes), 1 → 1 (nearly every block exact to 15 bits).
    pub const THRESHOLD_ROOTS: (f64, f64) = (50.0, 1.0);

    pub fn threshold(quality: f64, squeeze: f32) -> f32 {
        let (worst, best) = Self::THRESHOLD_ROOTS;
        let q = swift_min(1.0, swift_max(0.0, quality));
        let r = worst + (best - worst) * q;
        (r * r) as f32 * squeeze * squeeze
    }

    /// 5 bits a channel.
    #[inline(always)]
    pub fn q555(v: f32) -> f32 {
        (swift_min(255.0, swift_max(0.0, v)) * 31.0 / 255.0).round() * 255.0 / 31.0
    }

    #[inline(always)]
    fn q3(c: V3) -> V3 {
        V3::new(Self::q555(c.x), Self::q555(c.y), Self::q555(c.z))
    }

    /// RGB of a picture pixel (full-resolution color: Video 1 has no
    /// subsampling, so its pictures are coded 4:4:4).
    #[inline(always)]
    pub fn rgb(p: &CodecPicture, i: usize) -> V3 {
        let y = p.y.data[i];
        let cb = p.cb.data[i] - 128.0;
        let cr = p.cr.data[i] - 128.0;
        V3::new(y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb)
    }

    #[inline(always)]
    fn store(c: V3, y: &mut f32, cb: &mut f32, cr: &mut f32) {
        *y = 0.299 * c.x + 0.587 * c.y + 0.114 * c.z;
        *cb = 128.0 - 0.168736 * c.x - 0.331264 * c.y + 0.5 * c.z;
        *cr = 128.0 + 0.5 * c.x - 0.418688 * c.y - 0.081312 * c.z;
    }

    #[inline(always)]
    pub fn luma(c: V3) -> f32 {
        0.299 * c.x + 0.587 * c.y + 0.114 * c.z
    }

    #[inline(always)]
    pub fn distance(a: V3, b: V3) -> f32 {
        let d = a - b;
        (d * d).sum()
    }

    /// Two 15-bit colors for `pixels` (indices into them in `members`), and
    /// which one each takes: split at the mean brightness, then one pass of
    /// reassigning to the nearer color. Writes the coded colors into `out`;
    /// returns the squared error.
    pub fn two_colors(pixels: &[V3], members: &[usize], out: &mut [V3]) -> f32 {
        let mut mean = 0f32;
        for &i in members {
            mean += Self::luma(pixels[i]);
        }
        mean /= members.len() as f32;
        let mut hi = [false; 16];
        for (k, &i) in members.iter().enumerate() {
            hi[k] = Self::luma(pixels[i]) > mean;
        }
        let centers = |hi: &[bool; 16]| -> Option<(V3, V3)> {
            let mut a = V3::ZERO;
            let mut b = V3::ZERO;
            let mut na = 0f32;
            let mut nb = 0f32;
            for (k, &i) in members.iter().enumerate() {
                if hi[k] {
                    b += pixels[i];
                    nb += 1.0;
                } else {
                    a += pixels[i];
                    na += 1.0;
                }
            }
            if !(na > 0.0 && nb > 0.0) {
                return None;
            }
            Some((a / na, b / nb))
        };
        let Some((mut a, mut b)) = centers(&hi) else {
            // All one brightness: one color, twice.
            let mut m = V3::ZERO;
            for &i in members {
                m += pixels[i];
            }
            let m = m / members.len() as f32;
            let c = Self::q3(m);
            let mut e = 0f32;
            for &i in members {
                out[i] = c;
                e += Self::distance(pixels[i], c);
            }
            return e;
        };
        for (k, &i) in members.iter().enumerate() {
            hi[k] = Self::distance(pixels[i], b) < Self::distance(pixels[i], a);
        }
        if let Some(c) = centers(&hi) {
            (a, b) = c;
        }
        let qa = Self::q3(a);
        let qb = Self::q3(b);
        let mut e = 0f32;
        for &i in members {
            let c = if Self::distance(pixels[i], qb) < Self::distance(pixels[i], qa) { qb } else { qa };
            out[i] = c;
            e += Self::distance(pixels[i], c);
        }
        e
    }

    pub const QUARTERS: [[usize; 4]; 4] = [[0, 1, 4, 5], [2, 3, 6, 7], [8, 9, 12, 13], [10, 11, 14, 15]];

    /// Code one block's 16 pixels the cheapest way that's within `limit`
    /// (squared error summed over the block) — or no worse than the best any
    /// mode can do: on a flat block, 15-bit rounding alone can exceed a fine
    /// limit, and spending eight colors on it would buy nothing.
    pub fn code_block(src: &[V3; 16], reference: Option<&[V3; 16]>, limit: f32) -> (Video1Mode, [V3; 16]) {
        if let Some(reference) = reference {
            let mut e = 0f32;
            for i in 0..16 {
                e += Self::distance(src[i], reference[i]);
            }
            if e <= limit {
                return (Video1Mode::Skip, *reference);
            }
        }
        let mut sum = V3::ZERO;
        for p in src {
            sum += *p;
        }
        let mean = sum / 16.0;
        let fill = Self::q3(mean);
        let mut fill_error = 0f32;
        for p in src {
            fill_error += Self::distance(*p, fill);
        }
        if fill_error <= limit {
            return (Video1Mode::Fill, [fill; 16]);
        }
        const ALL: [usize; 16] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
        let mut two = *src;
        let two_error = Self::two_colors(src, &ALL, &mut two);
        let mut eight = *src;
        let mut eight_error = 0f32;
        for q in &Self::QUARTERS {
            eight_error += Self::two_colors(src, q, &mut eight);
        }
        let good = swift_max(limit, eight_error * 1.05 + 1e-3);
        if fill_error <= good {
            return (Video1Mode::Fill, [fill; 16]);
        }
        if two_error <= good {
            return (Video1Mode::Two, two);
        }
        (Video1Mode::Eight, eight)
    }

    /// Mean absolute luma change against the reference — how much there is
    /// to code (for the fixed-bitrate squeeze).
    pub fn change(a: &CodecPicture, b: &CodecPicture, g: &CodecGeometry) -> f32 {
        let rows: Vec<f32> = (0..g.height)
            .into_par_iter()
            .map(|y| {
                let mut s = 0f32;
                for x in 0..g.width {
                    s += (a.y.data[y * a.y.width + x] - b.y.data[y * b.y.width + x]).abs();
                }
                s
            })
            .collect();
        let mut total = 0f32;
        for r in rows {
            total += r;
        }
        total / (g.width * g.height) as f32
    }

    /// Code `source` as `kind`, advancing `state` — the same contract as
    /// `DigitalCodec::step` (datamosh doesn't apply: there's no motion to
    /// drag, so a lost keyframe is coded as one that arrived).
    pub fn step(state: &mut CodecState, source: &CodecPicture, kind: CodecFrameKind, index: i64, s: &FrameSettings) -> Arc<CodecPicture> {
        let g = state.geometry;
        let lost = DigitalCodec::lost_blocks(s.data_loss, index, &g);
        let predicted = kind == CodecFrameKind::Predicted && state.encoder.is_some();
        let enc_ref: Option<Arc<CodecPicture>> = if predicted { state.encoder.clone() } else { None };
        let complexity = match &enc_ref {
            Some(r) => Self::change(source, r, &g),
            None => DigitalCodec::detail(source, &g),
        };
        let squeeze = DigitalCodec::squeeze(complexity, if predicted { 3.0 } else { 14.0 }, s.fixed_bitrate);
        let limit = Self::threshold(s.quality, squeeze) * 48.0;

        let previous = state.encoder.clone();
        let mut enc = CodecPicture::new(&g);
        // The decoder starts from what it had; coded blocks overwrite it.
        let mut dec = CodecPicture::new(&g);
        let dec_base = state.decoder.clone().or_else(|| previous.clone());
        let base: Option<&CodecPicture> =
            if kind == CodecFrameKind::IntraOnly { previous.as_deref() } else { dec_base.as_deref() };
        let w = g.luma_w();
        let cols = g.luma_w() / 4;
        let any_loss = lost.as_ref().is_some_and(|l| l.contains(&true));
        let enc_ref_pic = enc_ref.as_deref();
        let lost_ref = lost.as_deref();
        let band = 4 * w;
        {
            let CodecPicture { y: ey, cb: ecb, cr: ecr } = &mut enc;
            let CodecPicture { y: dy, cb: dcb, cr: dcr } = &mut dec;
            ey.data
                .par_chunks_mut(band)
                .zip(ecb.data.par_chunks_mut(band))
                .zip(ecr.data.par_chunks_mut(band))
                .zip(dy.data.par_chunks_mut(band))
                .zip(dcb.data.par_chunks_mut(band))
                .zip(dcr.data.par_chunks_mut(band))
                .enumerate()
                .for_each(|(by, (((((ey, ecb), ecr), dy), dcb), dcr))| {
                    let mut src = [V3::ZERO; 16];
                    let mut refb = [V3::ZERO; 16];
                    for bx in 0..cols {
                        for i in 0..16 {
                            let k = (by * 4 + i / 4) * w + bx * 4 + i % 4;
                            src[i] = Self::rgb(source, k);
                            if let Some(r) = enc_ref_pic {
                                refb[i] = Self::rgb(r, k);
                            }
                        }
                        let (mode, pixels) = Self::code_block(&src, enc_ref_pic.map(|_| &refb), limit);
                        let mb = (by * 4 / 16) * g.mb_cols() + bx * 4 / 16;
                        let block_lost = lost_ref.map(|l| l[mb]) == Some(true);
                        for i in 0..16 {
                            let k = (by * 4 + i / 4) * w + bx * 4 + i % 4;
                            let kl = k - by * band;
                            match (mode, enc_ref_pic) {
                                (Video1Mode::Skip, Some(r)) => {
                                    // Copied exactly, never re-converted: a
                                    // block can be skipped for hundreds of
                                    // frames.
                                    ey[kl] = r.y.data[k];
                                    ecb[kl] = r.cb.data[k];
                                    ecr[kl] = r.cr.data[k];
                                }
                                _ => Self::store(pixels[i], &mut ey[kl], &mut ecb[kl], &mut ecr[kl]),
                            }
                            match base {
                                Some(b) if block_lost || mode == Video1Mode::Skip => {
                                    // Nothing arrived: whatever the decoder
                                    // had stays. (Each frame on its own:
                                    // patched from the last frame as coded,
                                    // so the damage lasts one frame.)
                                    dy[kl] = b.y.data[k];
                                    dcb[kl] = b.cb.data[k];
                                    dcr[kl] = b.cr.data[k];
                                }
                                _ => Self::store(pixels[i], &mut dy[kl], &mut dcb[kl], &mut dcr[kl]),
                            }
                        }
                    }
                });
        }
        let enc = Arc::new(enc);
        state.encoder = Some(enc.clone());
        state.vectors = vec![MotionVector::default(); g.mb_count()];
        match kind {
            CodecFrameKind::Key | CodecFrameKind::DroppedKey => {
                // Keyframes arrive whole (streams protect them).
                state.decoder = Some(enc.clone());
                state.diverged = false;
            }
            CodecFrameKind::IntraOnly => {
                let d = if any_loss && previous.is_some() { Arc::new(dec) } else { enc.clone() };
                state.diverged = !Arc::ptr_eq(&d, &enc);
                state.decoder = Some(d);
            }
            CodecFrameKind::Predicted => {
                if !state.diverged && !any_loss {
                    state.decoder = Some(enc.clone());
                } else {
                    state.decoder = Some(Arc::new(dec));
                    state.diverged = true;
                }
            }
        }
        state.decoder.clone().unwrap()
    }
}
