//! The Digital video stage's codec (`DigitalCodec.swift`): a small, real
//! block-transform video codec in the MPEG/H.263/DV family, run on the CPU at
//! the capture resolution.
//!
//! - Pictures are Y′CbCr (BT.601) with subsampled color, coded in 8×8 DCT
//!   blocks against the JPEG reference quantization tables.
//! - Keyframes are coded alone; between them each 16×16 macroblock is
//!   predicted from the previous picture by a motion vector, and only the
//!   quantized difference is sent.
//! - The Block size control scales that whole structure: 4×4 or 16×16
//!   transforms, with macroblocks always twice the transform's size.
//! - The encoder and decoder each keep their own reference picture. They
//!   agree until data is lost or a keyframe is thrown away; after that the
//!   decoder applies the encoder's motion and differences to the wrong
//!   picture — which is exactly what packet-loss smearing and datamoshing
//!   are. Neither is drawn.
//!
//! Everything is deterministic: the same captures and settings give the same
//! pictures, bit for bit, however the work is split across cores. (Rows run
//! in parallel, but every sum is taken in the Mac's order.)

use std::sync::Arc;

use rayon::prelude::*;

use crate::params::{swift_max, swift_min, ChromaSubsampling};
use crate::tables::{BLOCK_GAIN_16_BITS, BLOCK_GAIN_4_BITS, DCT_BASIS_16_BITS, DCT_BASIS_4_BITS, DCT_BASIS_BITS};

/// One plane of samples on the 0…255 scale, padded to whole blocks.
#[derive(Clone, Debug, PartialEq)]
pub struct CodecPlane {
    pub width: usize,
    pub height: usize,
    pub data: Vec<f32>,
}

impl CodecPlane {
    pub fn new(width: usize, height: usize, fill: f32) -> Self {
        CodecPlane { width, height, data: vec![fill; width * height] }
    }

    #[inline(always)]
    pub fn clamped(&self, x: isize, y: isize) -> f32 {
        let yy = swift_min(self.height as isize - 1, swift_max(0, y)) as usize;
        let xx = swift_min(self.width as isize - 1, swift_max(0, x)) as usize;
        self.data[yy * self.width + xx]
    }
}

/// A picture: brightness and two color-difference planes.
#[derive(Clone, Debug, PartialEq)]
pub struct CodecPicture {
    pub y: CodecPlane,
    pub cb: CodecPlane,
    pub cr: CodecPlane,
}

impl CodecPicture {
    pub fn new(g: &CodecGeometry) -> Self {
        CodecPicture {
            y: CodecPlane::new(g.luma_w(), g.luma_h(), 0.0),
            cb: CodecPlane::new(g.chroma_w(), g.chroma_h(), 128.0),
            cr: CodecPlane::new(g.chroma_w(), g.chroma_h(), 128.0),
        }
    }

    pub fn planes(&self) -> [&CodecPlane; 3] {
        [&self.y, &self.cb, &self.cr]
    }

    pub fn planes_mut(&mut self) -> [&mut CodecPlane; 3] {
        [&mut self.y, &mut self.cb, &mut self.cr]
    }

    /// The Mac's measure of a picture's size (Float samples), for the
    /// checkpoint budget.
    pub fn byte_count(&self) -> usize {
        (self.y.width * self.y.height + 2 * self.cb.width * self.cb.height) * std::mem::size_of::<f32>()
    }
}

/// Sizes of the coded picture: the visible capture, padded to whole
/// macroblocks (luma) and whole transform blocks (color).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CodecGeometry {
    pub width: usize,
    pub height: usize,
    pub chroma: ChromaSubsampling,
    /// The transform's size: 8 (the family's own), 4 or 16.
    pub block: usize,
}

impl CodecGeometry {
    pub fn new(width: usize, height: usize, chroma: ChromaSubsampling) -> Self {
        Self::with_block(width, height, chroma, 8)
    }
    pub fn with_block(width: usize, height: usize, chroma: ChromaSubsampling, block: usize) -> Self {
        CodecGeometry { width, height, chroma, block }
    }
    /// A macroblock (the unit of motion and of lost data): two blocks each
    /// way.
    pub fn mb(&self) -> usize { self.block * 2 }
    pub fn luma_w(&self) -> usize { (self.width + self.mb() - 1) / self.mb() * self.mb() }
    pub fn luma_h(&self) -> usize { (self.height + self.mb() - 1) / self.mb() * self.mb() }
    pub fn sx(&self) -> usize { self.chroma.factors().0 }
    pub fn sy(&self) -> usize { self.chroma.factors().1 }
    pub fn chroma_w(&self) -> usize { (self.luma_w() / self.sx() + self.block - 1) / self.block * self.block }
    pub fn chroma_h(&self) -> usize { (self.luma_h() / self.sy() + self.block - 1) / self.block * self.block }
    pub fn mb_cols(&self) -> usize { self.luma_w() / self.mb() }
    pub fn mb_rows(&self) -> usize { self.luma_h() / self.mb() }
    pub fn mb_count(&self) -> usize { self.mb_cols() * self.mb_rows() }
}

/// What a capture is coded as.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodecFrameKind {
    /// Every frame on its own (Motion JPEG, DV): no prediction at all.
    IntraOnly,
    /// A keyframe in a predicted stream.
    Key,
    /// A keyframe the decoder never receives (datamosh).
    DroppedKey,
    /// A frame predicted from the previous one.
    Predicted,
}

/// Motion vector of one macroblock, in luma pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct MotionVector {
    pub dx: i32,
    pub dy: i32,
}

/// The codec's state between frames.
///
/// Pictures are shared (`Arc`) and never changed once made, so cloning a
/// state is the Mac's `copy()`: the decoder is the encoder's picture exactly
/// when it was in the original.
#[derive(Clone, Debug)]
pub struct CodecState {
    pub geometry: CodecGeometry,
    /// The encoder's reference: what a perfect decoder would hold.
    pub encoder: Option<Arc<CodecPicture>>,
    /// The decoder's reference: what this decoder actually holds.
    pub decoder: Option<Arc<CodecPicture>>,
    /// The previous frame's vectors (the motion search's first guess).
    pub vectors: Vec<MotionVector>,
    /// The decoder's picture differs from the encoder's.
    pub diverged: bool,
    /// Bits waiting in the encoder's buffer (the Bitrate limit): what the
    /// frames since the last keyframe spent beyond their share.
    pub buffer_fill: f64,
    /// The quantizer step of the picture the decoder shows (it stays the
    /// same picture through frames the encoder skips).
    pub shown_step: f32,
}

impl CodecState {
    pub fn new(geometry: CodecGeometry) -> Self {
        CodecState {
            geometry,
            encoder: None,
            decoder: None,
            vectors: vec![MotionVector::default(); geometry.mb_count()],
            diverged: false,
            buffer_fill: 0.0,
            shown_step: 0.0,
        }
    }
}

/// Swift's `Float.clamped(lo, hi)`: `min(hi, max(lo, self))`.
#[inline(always)]
pub(crate) fn clampf(v: f32, lo: f32, hi: f32) -> f32 {
    swift_min(hi, swift_max(lo, v))
}

/// Where Data loss falls (the Loss pattern control).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LossPattern {
    /// Runs of blocks in reading order: a stream's lost packets.
    Packets = 0,
    /// DV tape dropouts: each track's blocks lie scattered over five
    /// rectangles of the picture.
    DvTape = 1,
    /// One of a DV deck's two heads clogged: every other track.
    CloggedHead = 2,
}

impl LossPattern {
    pub fn from_raw(raw: i64) -> Option<Self> {
        match raw {
            0 => Some(LossPattern::Packets),
            1 => Some(LossPattern::DvTape),
            2 => Some(LossPattern::CloggedHead),
            _ => None,
        }
    }
}

/// What the decoder puts where data was lost (Lost blocks show).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Concealment {
    /// The same place in the last picture (or, between keyframes, the last
    /// picture moved by a guessed vector).
    LastPicture = 0,
    /// Nothing: flat gray.
    Gray = 1,
    /// Nothing: an all-zero picture, which is green.
    Green = 2,
    /// The row of pixels above the gap, repeated down through it.
    Stretched = 3,
}

impl Concealment {
    pub fn from_raw(raw: i64) -> Option<Self> {
        match raw {
            0 => Some(Concealment::LastPicture),
            1 => Some(Concealment::Gray),
            2 => Some(Concealment::Green),
            3 => Some(Concealment::Stretched),
            _ => None,
        }
    }
}

/// One piece of damage, in the terms of the coded stream. Each is what one
/// wrong bit does to a block codec's data: applied to the decoded picture,
/// which by the transform's linearity is the same as decoding the damaged
/// coefficients.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BitError {
    /// A block's coefficient (u across, v down) off by `amount`: the block
    /// shows that cosine pattern. `tile` is the tile within the plane.
    Coefficient { plane: usize, tile_x: usize, tile_y: usize, u: usize, v: usize, amount: f32 },
    /// A block's average off by `amount`. Averages are sent as the
    /// difference from the block before, so every block after it in the row
    /// is off too — or, where nothing resets the chain, the rest of the
    /// picture (`to_end`).
    Average { plane: usize, mb_x: usize, mb_y: usize, amount: f32, to_end: bool },
    /// The decoder losing its place: the rest of the row's blocks land `by`
    /// macroblocks along.
    Displaced { mb_x: usize, mb_y: usize, by: usize },
}

/// Settings that act on one frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FrameSettings {
    pub quality: f64,
    pub fixed_bitrate: f64,
    pub data_loss: f64,
    pub loss_pattern: LossPattern,
    pub concealment: Concealment,
    pub bit_errors: f64,
    /// Added motion: which (0 none) and how fast (−1…1).
    pub motion: i64,
    pub motion_speed: f64,
    /// The Bitrate limit: bits a frame may spend for each pixel of the
    /// picture (0: no limit), and the buffer's size in frames' worth.
    pub bits_per_pixel: f64,
    pub buffer_frames: f64,
}

impl FrameSettings {
    /// The three settings every frame has, the rest off.
    pub fn new(quality: f64, fixed_bitrate: f64, data_loss: f64) -> Self {
        FrameSettings {
            quality,
            fixed_bitrate,
            data_loss,
            loss_pattern: LossPattern::Packets,
            concealment: Concealment::LastPicture,
            bit_errors: 0.0,
            motion: 0,
            motion_speed: 0.0,
            bits_per_pixel: 0.0,
            buffer_frames: 0.0,
        }
    }
}

/// Step sizes for one frame. Keyframes use the perceptual tables;
/// differences use a flat step, as MPEG's non-intra matrix does.
#[derive(Clone, Debug, PartialEq)]
pub struct Steps {
    pub luma: Vec<f32>,
    pub chroma: Vec<f32>,
    pub inter: f32,
    /// The transform's size the tables are for.
    pub block: usize,
    /// The multiple of the reference tables.
    pub scale: f32,
}

impl Steps {
    pub fn new(quality: f64, squeeze: f32) -> Self {
        Self::with_block(quality, squeeze, 8)
    }

    pub fn with_block(quality: f64, squeeze: f32, block: usize) -> Self {
        Self::from_scale(DigitalCodec::table_scale(quality) * squeeze, block)
    }

    pub fn from_scale(s: f32, block: usize) -> Self {
        let luma = DigitalCodec::table(&DigitalCodec::LUMA_TABLE, block).iter().map(|t| swift_max(1.0, (t * s).round())).collect();
        let chroma = DigitalCodec::table(&DigitalCodec::CHROMA_TABLE, block).iter().map(|t| swift_max(1.0, (t * s).round())).collect();
        Steps { luma, chroma, inter: swift_max(1.0, 16.0 * s * DigitalCodec::block_gain(block)), block, scale: s }
    }
}

/// The DCT codec's functions (the Mac's `enum DigitalCodec` namespace).
pub struct DigitalCodec;

impl DigitalCodec {
    // MARK: - quantization

    /// JPEG reference tables (ITU T.81 Annex K), natural order.
    pub const LUMA_TABLE: [f32; 64] = [
        16.0, 11.0, 10.0, 16.0, 24.0, 40.0, 51.0, 61.0,
        12.0, 12.0, 14.0, 19.0, 26.0, 58.0, 60.0, 55.0,
        14.0, 13.0, 16.0, 24.0, 40.0, 57.0, 69.0, 56.0,
        14.0, 17.0, 22.0, 29.0, 51.0, 87.0, 80.0, 62.0,
        18.0, 22.0, 37.0, 56.0, 68.0, 109.0, 103.0, 77.0,
        24.0, 35.0, 55.0, 64.0, 81.0, 104.0, 113.0, 92.0,
        49.0, 64.0, 78.0, 87.0, 103.0, 121.0, 120.0, 101.0,
        72.0, 92.0, 95.0, 98.0, 112.0, 100.0, 103.0, 99.0,
    ];
    pub const CHROMA_TABLE: [f32; 64] = [
        17.0, 18.0, 24.0, 47.0, 99.0, 99.0, 99.0, 99.0,
        18.0, 21.0, 26.0, 66.0, 99.0, 99.0, 99.0, 99.0,
        24.0, 26.0, 56.0, 99.0, 99.0, 99.0, 99.0, 99.0,
        47.0, 66.0, 99.0, 99.0, 99.0, 99.0, 99.0, 99.0,
        99.0, 99.0, 99.0, 99.0, 99.0, 99.0, 99.0, 99.0,
        99.0, 99.0, 99.0, 99.0, 99.0, 99.0, 99.0, 99.0,
        99.0, 99.0, 99.0, 99.0, 99.0, 99.0, 99.0, 99.0,
        99.0, 99.0, 99.0, 99.0, 99.0, 99.0, 99.0, 99.0,
    ];

    /// The quantizer scale (a multiple of the reference tables) for the
    /// Quality control: 25× at 0 (JPEG quality 2) to 0.1× at 1 (JPEG 95).
    /// Measured damage grows with the square root of the step (mean error ∝
    /// scale^0.51 across the whole range), so the square root is what runs
    /// linearly: every step of the slider changes the damage by the same
    /// amount. JPEG's own quality number (used before 0.19) spent two thirds
    /// of the damage in its bottom tenth.
    pub fn scale_roots() -> (f64, f64) {
        (5.0, 0.1f64.sqrt())
    }

    pub fn table_scale(quality: f64) -> f32 {
        let (worst, best) = Self::scale_roots();
        let q = swift_min(1.0, swift_max(0.0, quality));
        let r = worst + (best - worst) * q;
        (r * r) as f32
    }

    /// A Quality value from before 0.19 (JPEG quality 2 + 93u), as today's
    /// slider value giving the same quantizer.
    pub fn quality_from_jpeg_scale(old: f64) -> f64 {
        let (worst, best) = Self::scale_roots();
        let q = 2.0 + 93.0 * swift_min(1.0, swift_max(0.0, old));
        let scale = (if q < 50.0 { 5000.0 / q } else { 200.0 - 2.0 * q }) / 100.0;
        swift_min(1.0, swift_max(0.0, (worst - scale.sqrt()) / (worst - best)))
    }

    /// A reference table for an n×n transform: each coefficient takes the
    /// step of the 8×8 one at the same spatial frequency (between two, for
    /// 16×16), times `block_gain`.
    pub fn table(base: &[f32; 64], n: usize) -> Vec<f32> {
        if n == 8 {
            return base.to_vec();
        }
        let gain = Self::block_gain(n);
        let mut out = vec![0f32; n * n];
        for v in 0..n {
            for u in 0..n {
                let fu = u as f32 * 8.0 / n as f32;
                let fv = v as f32 * 8.0 / n as f32;
                let u0 = swift_min(7, fu as usize);
                let v0 = swift_min(7, fv as usize);
                let u1 = swift_min(7, u0 + 1);
                let v1 = swift_min(7, v0 + 1);
                let tu = fu - u0 as f32;
                let tv = fv - v0 as f32;
                let top = base[v0 * 8 + u0] + (base[v0 * 8 + u1] - base[v0 * 8 + u0]) * tu;
                let bottom = base[v1 * 8 + u0] + (base[v1 * 8 + u1] - base[v1 * 8 + u0]) * tu;
                out[v * n + u] = (top + (bottom - top) * tv) * gain;
            }
        }
        out
    }

    /// How the steps grow with the transform's size: (n / 8)^0.5. An
    /// orthonormal transform's coefficients grow with its size (a flat
    /// block's average is n times its level), so the same step is finer in a
    /// big block and coarser in a small one; this keeps the damage at one
    /// Quality about the same whatever the block. (The Mac's `pow`, as its
    /// exact floats.)
    pub fn block_gain(n: usize) -> f32 {
        match n {
            4 => f32::from_bits(BLOCK_GAIN_4_BITS),
            16 => f32::from_bits(BLOCK_GAIN_16_BITS),
            _ => 1.0,
        }
    }

    // MARK: - DCT

    /// Orthonormal 8-point DCT-II basis, C[u * 8 + x]: `a(u) cos((2x+1)uπ/16)`
    /// in double precision, stored as the exact floats the Mac computes (so
    /// a different platform's `cos` can't move a bit).
    pub fn basis() -> [f32; 64] {
        let mut c = [0f32; 64];
        for (k, b) in DCT_BASIS_BITS.iter().enumerate() {
            c[k] = f32::from_bits(*b);
        }
        c
    }

    /// The n-point basis, C[u * n + x], for n = 4, 8 or 16.
    pub fn basis_n(n: usize) -> Vec<f32> {
        let bits: &[u32] = match n {
            4 => &DCT_BASIS_4_BITS,
            16 => &DCT_BASIS_16_BITS,
            _ => &DCT_BASIS_BITS,
        };
        bits.iter().map(|b| f32::from_bits(*b)).collect()
    }

    /// out[u,v] = Σ C[u,x] C[v,y] in[x,y] — `input` row-major with `stride`,
    /// for an n×n block (4, 8 or 16; each compiled for its own size).
    #[inline(always)]
    pub fn forward_dct(input: &[f32], stride: usize, out: &mut [f32], tmp: &mut [f32], c: &[f32], n: usize) {
        match n {
            4 => Self::forward::<4>(input, stride, out, tmp, c),
            16 => Self::forward::<16>(input, stride, out, tmp, c),
            _ => Self::forward::<8>(input, stride, out, tmp, c),
        }
    }

    #[inline(always)]
    fn forward<const N: usize>(input: &[f32], stride: usize, out: &mut [f32], tmp: &mut [f32], c: &[f32]) {
        // Rows: tmp[y, u] = Σx C[u,x] in[y,x]
        for y in 0..N {
            let row = &input[y * stride..y * stride + N];
            for u in 0..N {
                let cu = &c[u * N..u * N + N];
                let mut s = 0f32;
                for x in 0..N {
                    s += cu[x] * row[x];
                }
                tmp[y * N + u] = s;
            }
        }
        // Columns: out[v, u] = Σy C[v,y] tmp[y,u]
        for v in 0..N {
            let cv = &c[v * N..v * N + N];
            for u in 0..N {
                let mut s = 0f32;
                for y in 0..N {
                    s += cv[y] * tmp[y * N + u];
                }
                out[v * N + u] = s;
            }
        }
    }

    /// The inverse: out[y,x] = Σ C[v,y] C[u,x] coef[v,u].
    #[inline(always)]
    pub fn inverse_dct(coef: &[f32], out: &mut [f32], stride: usize, tmp: &mut [f32], c: &[f32], n: usize) {
        match n {
            4 => Self::inverse::<4>(coef, out, stride, tmp, c),
            16 => Self::inverse::<16>(coef, out, stride, tmp, c),
            _ => Self::inverse::<8>(coef, out, stride, tmp, c),
        }
    }

    #[inline(always)]
    fn inverse<const N: usize>(coef: &[f32], out: &mut [f32], stride: usize, tmp: &mut [f32], c: &[f32]) {
        // Columns: tmp[y, u] = Σv C[v,y] coef[v,u]
        for y in 0..N {
            for u in 0..N {
                let mut s = 0f32;
                for v in 0..N {
                    s += c[v * N + y] * coef[v * N + u];
                }
                tmp[y * N + u] = s;
            }
        }
        // Rows: out[y, x] = Σu C[u,x] tmp[y,u]
        for y in 0..N {
            let row = &mut out[y * stride..y * stride + N];
            for x in 0..N {
                let mut s = 0f32;
                for u in 0..N {
                    s += c[u * N + x] * tmp[y * N + u];
                }
                row[x] = s;
            }
        }
    }

    // MARK: - keyframes

    /// Code `source` with no prediction into `recon`.
    pub fn code_intra(source: &CodecPicture, recon: &mut CodecPicture, steps: &Steps) {
        let n = steps.block;
        let nn = n * n;
        let c = Self::basis_n(n);
        for (i, (src, dst)) in source.planes().into_iter().zip(recon.planes_mut()).enumerate() {
            let t = if i == 0 { &steps.luma } else { &steps.chroma };
            let w = src.width;
            dst.data.par_chunks_mut(n * w).enumerate().for_each(|(ty, out)| {
                let mut block = [0f32; 256];
                let mut coef = [0f32; 256];
                let mut tmp = [0f32; 256];
                for tx in 0..(w / n) {
                    let origin = ty * n * w + tx * n;
                    for y in 0..n {
                        for x in 0..n {
                            block[y * n + x] = src.data[origin + y * w + x] - 128.0;
                        }
                    }
                    Self::forward_dct(&block, n, &mut coef, &mut tmp, &c, n);
                    for k in 0..nn {
                        // JPEG rounding: to the nearest step.
                        coef[k] = (coef[k] / t[k]).round() * t[k];
                    }
                    Self::inverse_dct(&coef, &mut block, n, &mut tmp, &c, n);
                    for y in 0..n {
                        for x in 0..n {
                            out[y * w + tx * n + x] = clampf((block[y * n + x] + 128.0).round(), 0.0, 255.0);
                        }
                    }
                }
            });
        }
    }

    // MARK: - prediction

    /// Sum of absolute differences between the source macroblock at (bx, by)
    /// and the reference displaced by (dx, dy), giving up past `limit`.
    #[inline(always)]
    #[allow(clippy::too_many_arguments)]
    pub fn sad(src: &CodecPlane, reference: &CodecPlane, bx: usize, by: usize, dx: isize, dy: isize, limit: f32, m: usize) -> f32 {
        let w = src.width;
        let rx = bx as isize + dx;
        let ry = by as isize + dy;
        let mut total = 0f32;
        if rx >= 0 && ry >= 0 && rx + m as isize <= reference.width as isize && ry + m as isize <= reference.height as isize {
            let (rx, ry) = (rx as usize, ry as usize);
            for y in 0..m {
                let s = &src.data[(by + y) * w + bx..(by + y) * w + bx + m];
                let r = &reference.data[(ry + y) * w + rx..(ry + y) * w + rx + m];
                for x in 0..m {
                    total += (s[x] - r[x]).abs();
                }
                if total >= limit {
                    return total;
                }
            }
        } else {
            for y in 0..m {
                let s = &src.data[(by + y) * w + bx..(by + y) * w + bx + m];
                for x in 0..m {
                    total += (s[x] - reference.clamped(rx + x as isize, ry + y as isize)).abs();
                }
                if total >= limit {
                    return total;
                }
            }
        }
        total
    }

    pub const SEARCH_RANGE: isize = 24;

    /// Motion search for every macroblock: the colocated vector from the last
    /// frame, the left neighbor's and zero as starting points, then a
    /// shrinking diamond. Rows run in parallel (each only uses its own left
    /// neighbor), so the result doesn't depend on the core count. Returns the
    /// vectors and the mean absolute prediction error.
    pub fn search_motion(
        source: &CodecPicture,
        reference: &CodecPicture,
        previous: &[MotionVector],
        g: &CodecGeometry,
    ) -> (Vec<MotionVector>, f32) {
        let src = &source.y;
        let refp = &reference.y;
        let cols = g.mb_cols();
        let m = g.mb();
        // A small bias keeps still areas still (48 for a 16×16 block).
        let still_bias = (-48 * (m * m) as i64 / 256) as f32;
        let rows: Vec<(Vec<MotionVector>, f32)> = (0..g.mb_rows())
            .into_par_iter()
            .map(|my| {
                let mut out = vec![MotionVector::default(); cols];
                let mut left = MotionVector::default();
                let mut sum = 0f32;
                for mx in 0..cols {
                    let bx = mx * m;
                    let by = my * m;
                    let r = Self::SEARCH_RANGE;
                    let cost = |v: (isize, isize), limit: f32| -> f32 {
                        if !(v.0.abs() <= r && v.1.abs() <= r) {
                            return f32::INFINITY;
                        }
                        let bias: f32 = if v.0 == 0 && v.1 == 0 { still_bias } else { 0.0 };
                        Self::sad(src, refp, bx, by, v.0, v.1, limit - bias, m) + bias
                    };
                    let mut best: (isize, isize) = (0, 0);
                    let mut best_cost = cost(best, f32::INFINITY);
                    for cand in [previous[my * cols + mx], left] {
                        let v = (cand.dx as isize, cand.dy as isize);
                        if v == best {
                            continue;
                        }
                        let cst = cost(v, best_cost);
                        if cst < best_cost {
                            best_cost = cst;
                            best = v;
                        }
                    }
                    let mut step: isize = 8;
                    while step >= 1 {
                        let mut moved = true;
                        let mut guard_count = 0;
                        while moved && guard_count < 8 {
                            moved = false;
                            guard_count += 1;
                            for d in [(step, 0), (-step, 0), (0, step), (0, -step)] {
                                let v = (best.0 + d.0, best.1 + d.1);
                                let cst = cost(v, best_cost);
                                if cst < best_cost {
                                    best_cost = cst;
                                    best = v;
                                    moved = true;
                                }
                            }
                        }
                        step /= 2;
                    }
                    let mv = MotionVector { dx: best.0 as i32, dy: best.1 as i32 };
                    out[mx] = mv;
                    left = mv;
                    sum += Self::sad(src, refp, bx, by, best.0, best.1, f32::INFINITY, m);
                }
                (out, sum)
            })
            .collect();
        let mut vectors = Vec::with_capacity(g.mb_count());
        let mut total = 0f32;
        for (v, e) in rows {
            vectors.extend(v);
            total += e;
        }
        (vectors, total / (g.luma_w() * g.luma_h()) as f32)
    }

    /// Fill `prediction` with `reference` moved by each macroblock's vector.
    pub fn compensate(reference: &CodecPicture, vectors: &[MotionVector], g: &CodecGeometry, prediction: &mut CodecPicture) {
        for (i, (refp, dst)) in reference.planes().into_iter().zip(prediction.planes_mut()).enumerate() {
            let fx = if i == 0 { 1 } else { g.sx() };
            let fy = if i == 0 { 1 } else { g.sy() };
            let bw = g.mb() / fx;
            let bh = g.mb() / fy;
            let w = dst.width;
            let height = dst.height;
            let cols = g.mb_cols();
            let mb_rows = g.mb_rows();
            dst.data.par_chunks_mut(bh * w).enumerate().for_each(|(my, out)| {
                if my >= mb_rows {
                    return;
                }
                for mx in 0..cols {
                    let v = vectors[my * cols + mx];
                    let dx = (v.dx as f32 / fx as f32).round() as isize;
                    let dy = (v.dy as f32 / fy as f32).round() as isize;
                    let x0 = mx * bw;
                    let y0 = my * bh;
                    for y in y0..swift_min(height, y0 + bh) {
                        for x in x0..swift_min(w, x0 + bw) {
                            out[(y - y0) * w + x] = refp.clamped(x as isize + dx, y as isize + dy);
                        }
                    }
                }
            });
            // Color planes padded past the last macroblock follow the edge.
            if bw * cols < w || bh * mb_rows < height {
                for y in 0..height {
                    for x in 0..w {
                        if x >= bw * cols || y >= bh * mb_rows {
                            let v = dst.clamped(
                                swift_min(x, bw * cols - 1) as isize,
                                swift_min(y, bh * mb_rows - 1) as isize,
                            );
                            dst.data[y * w + x] = v;
                        }
                    }
                }
            }
        }
    }

    /// Quantize the difference between `source` and `prediction`, writing the
    /// difference the decoder reconstructs into `residual`.
    pub fn code_residual(source: &CodecPicture, prediction: &CodecPicture, step: f32, n: usize, residual: &mut CodecPicture) {
        let nn = n * n;
        let c = Self::basis_n(n);
        for (src, (pred, dst)) in source.planes().into_iter().zip(prediction.planes().into_iter().zip(residual.planes_mut())) {
            let w = src.width;
            dst.data.par_chunks_mut(n * w).enumerate().for_each(|(ty, out)| {
                let mut block = [0f32; 256];
                let mut coef = [0f32; 256];
                let mut tmp = [0f32; 256];
                for tx in 0..(w / n) {
                    let origin = ty * n * w + tx * n;
                    for y in 0..n {
                        for x in 0..n {
                            let i = origin + y * w + x;
                            block[y * n + x] = src.data[i] - pred.data[i];
                        }
                    }
                    Self::forward_dct(&block, n, &mut coef, &mut tmp, &c, n);
                    let mut any = false;
                    for k in 0..nn {
                        // A dead zone, as encoders use: small changes round
                        // to nothing, so blocks stay stale.
                        let q = coef[k] / step;
                        let level = if q < 0.0 { -(-q + 0.2).floor() } else { (q + 0.2).floor() };
                        coef[k] = level * step;
                        if level != 0.0 {
                            any = true;
                        }
                    }
                    if any {
                        Self::inverse_dct(&coef, &mut out[tx * n..], w, &mut tmp, &c, n);
                    } else {
                        for y in 0..n {
                            out[y * w + tx * n..y * w + tx * n + n].fill(0.0);
                        }
                    }
                }
            });
        }
    }

    /// recon = clamp(round(prediction + residual)), skipping lost
    /// macroblocks' residual when `lost` is given.
    pub fn reconstruct(prediction: &CodecPicture, residual: &CodecPicture, lost: Option<&[bool]>, g: &CodecGeometry, recon: &mut CodecPicture) {
        for (i, (pred, (res, dst))) in prediction
            .planes()
            .into_iter()
            .zip(residual.planes().into_iter().zip(recon.planes_mut()))
            .enumerate()
        {
            let fx = if i == 0 { 1 } else { g.sx() };
            let fy = if i == 0 { 1 } else { g.sy() };
            let w = dst.width;
            let cols = g.mb_cols();
            let rows = g.mb_rows();
            let m = g.mb();
            dst.data.par_chunks_mut(w).enumerate().for_each(|(y, out)| {
                let my = swift_min(rows - 1, y * fy / m);
                for x in 0..w {
                    let k = y * w + x;
                    let mut v = pred.data[k];
                    let mx = swift_min(cols - 1, x * fx / m);
                    if lost.map(|l| l[my * cols + mx]) != Some(true) {
                        v += res.data[k];
                    }
                    out[x] = clampf(v.round(), 0.0, 255.0);
                }
            });
        }
    }

    // MARK: - errors

    /// Which macroblocks frame `index` loses: runs of blocks (a lost packet
    /// or a damaged stretch of tape), mostly short, sometimes a row or more.
    pub fn lost_blocks(amount: f64, index: i64, g: &CodecGeometry, pattern: LossPattern) -> Option<Vec<bool>> {
        if !(amount > 0.0) {
            return None;
        }
        match pattern {
            LossPattern::Packets => {}
            LossPattern::DvTape => return Self::dv_tape_loss(amount, index, g),
            LossPattern::CloggedHead => return Self::clogged_head_loss(amount, index, g),
        }
        let count = g.mb_count();
        let mut lost = vec![false; count];
        let mut rng = SplitMix::new((index as u64).wrapping_mul(0x9E37_79B9) ^ 0x10C5);
        let mean_run = 1.0 + g.mb_cols() as f64 * 2.0 / 3.0;
        let start = swift_min(1.0, amount * 0.3 / mean_run);
        let mut i = 0usize;
        let mut any = false;
        while i < count {
            if rng.unit() < start {
                let u = rng.unit();
                let run = 1 + (u * u * (2 * g.mb_cols()) as f64) as usize;
                for j in i..swift_min(count, i + run) {
                    lost[j] = true;
                }
                any = true;
                i += run;
            } else {
                i += 1;
            }
        }
        if any { Some(lost) } else { None }
    }

    // DV's layout (SMPTE 314M, 525/60): the picture is 50 superblocks, 5
    // across and 10 down, each 27 macroblocks. A frame is 10 tracks on the
    // tape. Track i holds, block by block in step, the superblocks at rows
    // i+2, i+6, i+8, i and i+4 of columns 2, 1, 3, 0 and 4: a stretch of one
    // track is the same stretch of five rectangles spread over the picture.
    // Row i's superblocks all lie on tracks of i's parity, so a deck's two
    // heads (alternate tracks) each own every other band.
    pub const DV_ROWS: usize = 10;
    pub const DV_COLUMNS: usize = 5;
    /// On tape, a patch holds the last picture the decoder showed, which
    /// could reach back without limit. Every this many captures the tape
    /// reads clean (a clogged head clears for a moment, as they do), so a
    /// frame's picture never depends on more than that much before it.
    pub const TAPE_REFRESH: i64 = 24;
    /// (row offset, column) of a track's five superblocks.
    pub const DV_TRACK_ORDER: [(usize, usize); 5] = [(2, 2), (6, 1), (8, 3), (0, 0), (4, 4)];

    /// The macroblocks of superblock (row, column), in the order DV writes
    /// them: down the first column of blocks, up the next, and so on.
    pub fn dv_superblock(row: usize, column: usize, g: &CodecGeometry) -> Vec<usize> {
        let rows = swift_min(Self::DV_ROWS, g.mb_rows());
        let cols = swift_min(Self::DV_COLUMNS, g.mb_cols());
        if !(row < rows && column < cols) {
            return Vec::new();
        }
        let y0 = row * g.mb_rows() / rows;
        let y1 = (row + 1) * g.mb_rows() / rows;
        let x0 = column * g.mb_cols() / cols;
        let x1 = (column + 1) * g.mb_cols() / cols;
        let mut out = Vec::with_capacity((y1 - y0) * (x1 - x0));
        for x in x0..x1 {
            if (x - x0) % 2 == 0 {
                for y in y0..y1 {
                    out.push(y * g.mb_cols() + x);
                }
            } else {
                for y in (y0..y1).rev() {
                    out.push(y * g.mb_cols() + x);
                }
            }
        }
        out
    }

    /// Mark the stretch [from, to) (fractions of a track) of track `track`.
    pub fn lose_dv_stretch(track: usize, from: f64, to: f64, g: &CodecGeometry, lost: &mut [bool]) {
        let rows = swift_min(Self::DV_ROWS, g.mb_rows());
        for (offset, column) in Self::DV_TRACK_ORDER {
            let blocks = Self::dv_superblock((track + offset * rows / Self::DV_ROWS) % rows, column, g);
            if blocks.is_empty() {
                continue;
            }
            let count = blocks.len() as i64;
            let a = (from * blocks.len() as f64).floor() as i64;
            let b = swift_max(a + 1, (to * blocks.len() as f64).ceil() as i64);
            for k in a..swift_min(count, b) {
                lost[blocks[k as usize]] = true;
            }
        }
    }

    /// DV tape dropouts: short stretches of single tracks, now and then a
    /// whole track, and scratches along the tape, which cross every track at
    /// the same place and stay for a while.
    pub fn dv_tape_loss(amount: f64, index: i64, g: &CodecGeometry) -> Option<Vec<bool>> {
        if index % Self::TAPE_REFRESH == 0 {
            return None;
        }
        let mut lost = vec![false; g.mb_count()];
        let mut any = false;
        let mut rng = SplitMix::new((index as u64).wrapping_mul(0x9E37_79B9) ^ 0xD7A9E);
        for track in 0..Self::DV_ROWS {
            if !(rng.unit() < amount * 0.6) {
                continue;
            }
            let u = rng.unit();
            if u > 1.0 - 0.25 * amount {
                Self::lose_dv_stretch(track, 0.0, 1.0, g, &mut lost);
            } else {
                let start = rng.unit();
                let v = rng.unit();
                Self::lose_dv_stretch(track, start, swift_min(1.0, start + 0.04 + 0.5 * v * v * amount), g, &mut lost);
            }
            any = true;
        }
        // A scratch: the same few blocks of every track, for about half a
        // second of tape.
        let mut slow = SplitMix::new(((index / 14) as u64).wrapping_mul(0xC2B2_AE3D) ^ 0x5C4A7C);
        if slow.unit() < amount * 0.7 {
            let start = slow.unit() * 0.94;
            let width = 0.04 + 0.1 * slow.unit() * amount;
            for track in 0..Self::DV_ROWS {
                Self::lose_dv_stretch(track, start, start + width, g, &mut lost);
            }
            any = true;
        }
        if any { Some(lost) } else { None }
    }

    /// A clogged head: the odd tracks read badly, more or less so as the
    /// dirt shifts. Their bands lose runs of blocks; badly clogged, all.
    pub fn clogged_head_loss(amount: f64, index: i64, g: &CodecGeometry) -> Option<Vec<bool>> {
        if index % Self::TAPE_REFRESH == 0 {
            return None;
        }
        let mut lost = vec![false; g.mb_count()];
        let mut any = false;
        // How bad it is right now: drifting over a second or so.
        let level = |step: i64| -> f64 {
            let mut r = SplitMix::new((step as u64).wrapping_mul(0xA24B_AED4) ^ 0xC106);
            r.unit()
        };
        let t = index as f64 / 24.0;
        let i0 = t.floor() as i64;
        let f = t - i0 as f64;
        let drift = level(i0) + (level(i0 + 1) - level(i0)) * f * f * (3.0 - 2.0 * f);
        let clog = swift_min(1.0, amount * (0.7 + 0.6 * drift));
        let chance = swift_min(1.0, clog * clog * 1.6);
        let mut rng = SplitMix::new((index as u64).wrapping_mul(0x9E37_79B9) ^ 0xC106_6ED);
        let rows = swift_min(Self::DV_ROWS, g.mb_rows());
        let cols = swift_min(Self::DV_COLUMNS, g.mb_cols());
        let mut row = 1;
        while row < rows {
            for column in 0..cols {
                let blocks = Self::dv_superblock(row, column, g);
                let mut k = 0usize;
                while k < blocks.len() {
                    let run = 1 + (rng.unit() * 6.0) as usize;
                    if rng.unit() < chance {
                        for j in k..swift_min(blocks.len(), k + run) {
                            lost[blocks[j]] = true;
                        }
                        any = true;
                    }
                    k += run;
                }
            }
            row += 2;
        }
        if any { Some(lost) } else { None }
    }

    // MARK: - concealment (what the decoder puts where data was lost)

    /// Fill the lost macroblocks of `target` (modes other than the last
    /// picture, which the caller has already put there). A stretch from a
    /// lost block above carries on down; at the top edge the patch stays.
    pub fn conceal(target: &mut CodecPicture, lost: &[bool], mode: Concealment, g: &CodecGeometry) {
        if mode == Concealment::LastPicture {
            return;
        }
        for (i, plane) in target.planes_mut().into_iter().enumerate() {
            let fx = if i == 0 { 1 } else { g.sx() };
            let fy = if i == 0 { 1 } else { g.sy() };
            let bw = g.mb() / fx;
            let bh = g.mb() / fy;
            let w = plane.width;
            let fill: f32 = if mode == Concealment::Gray { 128.0 } else { 0.0 };
            for my in 0..g.mb_rows() {
                for mx in 0..g.mb_cols() {
                    if !lost[my * g.mb_cols() + mx] {
                        continue;
                    }
                    let x0 = mx * bw;
                    let y0 = my * bh;
                    let x1 = swift_min(w, x0 + bw);
                    let y1 = swift_min(plane.height, y0 + bh);
                    if !(x0 < x1 && y0 < y1) {
                        continue;
                    }
                    if mode == Concealment::Stretched {
                        if !(y0 > 0) {
                            continue;
                        }
                        for y in y0..y1 {
                            plane.data.copy_within((y0 - 1) * w + x0..(y0 - 1) * w + x1, y * w + x0);
                        }
                    } else {
                        for y in y0..y1 {
                            plane.data[y * w + x0..y * w + x1].fill(fill);
                        }
                    }
                }
            }
        }
    }

    // MARK: - bit errors (data that arrives damaged)

    /// The damage frame `index` takes.
    pub fn bit_errors(amount: f64, index: i64, g: &CodecGeometry) -> Vec<BitError> {
        if !(amount > 0.0) {
            return Vec::new();
        }
        let mut out = Vec::new();
        let mut rng = SplitMix::new((index as u64).wrapping_mul(0x8CB9_2BA7) ^ 0xB17E_44);
        let chance = 0.035 * swift_min(1.0, amount).powf(1.3);
        for my in 0..g.mb_rows() {
            for mx in 0..g.mb_cols() {
                if !(rng.unit() < chance) {
                    continue;
                }
                let kind = rng.unit();
                if kind < 0.45 {
                    // A short burst of wrong coefficients.
                    let plane = [0usize, 0, 0, 0, 0, 0, 1, 2][(rng.unit() * 8.0) as usize];
                    // The macroblock's first tile in that plane (luma has two
                    // rows of them).
                    let fx = if plane == 0 { 1 } else { g.sx() };
                    let fy = if plane == 0 { 1 } else { g.sy() };
                    let tile_x = mx * g.mb() / fx / g.block;
                    let tile_y = my * g.mb() / fy / g.block + if plane == 0 { (rng.unit() * 2.0) as usize } else { 0 };
                    let first = rng.unit();
                    let second = rng.unit();
                    let count = 1 + (first * second * 5.0) as usize;
                    for n in 0..count {
                        let a = rng.unit();
                        let b = rng.unit();
                        let u = (a * a * g.block as f64) as usize;
                        let v = (b * b * g.block as f64) as usize;
                        let magnitude = (300.0 + 700.0 * rng.unit()) as f32;
                        let size = magnitude * if rng.unit() < 0.5 { -1.0 } else { 1.0 };
                        out.push(BitError::Coefficient {
                            plane,
                            tile_x: tile_x + n,
                            tile_y,
                            u,
                            v: if u == 0 && v == 0 { 1 } else { v },
                            amount: size,
                        });
                    }
                } else if kind < 0.8 {
                    let plane = [0usize, 0, 1, 2][(rng.unit() * 4.0) as usize];
                    let magnitude = (15.0 + 75.0 * rng.unit()) as f32;
                    let size = magnitude * if rng.unit() < 0.5 { -1.0 } else { 1.0 };
                    let to_end = rng.unit() < 0.05;
                    out.push(BitError::Average { plane, mb_x: mx, mb_y: my, amount: size, to_end });
                } else {
                    out.push(BitError::Displaced { mb_x: mx, mb_y: my, by: 1 + (rng.unit() * 3.0) as usize });
                }
            }
        }
        out
    }

    /// Apply `errors` to a decoded picture, in place.
    pub fn damage(p: &mut CodecPicture, errors: &[BitError], g: &CodecGeometry) {
        let n = g.block;
        let basis = Self::basis_n(n);
        // (A wrong coefficient is as visible whatever the block: a bigger
        // transform spreads the same value over more pixels.)
        let gain = n as f32 / 8.0;
        for error in errors {
            match *error {
                BitError::Coefficient { plane: pl, tile_x: tx, tile_y: ty, u, v, amount } => {
                    let plane = &mut *p.planes_mut()[pl];
                    if !(tx * n + n <= plane.width && ty * n + n <= plane.height) {
                        continue;
                    }
                    for y in 0..n {
                        let cv = basis[v * n + y] * amount * gain;
                        let start = (ty * n + y) * plane.width + tx * n;
                        let row = &mut plane.data[start..start + n];
                        for x in 0..n {
                            row[x] = clampf((row[x] + cv * basis[u * n + x]).round(), 0.0, 255.0);
                        }
                    }
                }
                BitError::Average { plane: pl, mb_x: mx, mb_y: my, amount, to_end } => {
                    let plane = &mut *p.planes_mut()[pl];
                    let fx = if pl == 0 { 1 } else { g.sx() };
                    let fy = if pl == 0 { 1 } else { g.sy() };
                    let bw = g.mb() / fx;
                    let bh = g.mb() / fy;
                    let last = if to_end { g.mb_rows() } else { my + 1 };
                    for r in my..last {
                        let x0 = if r == my { mx * bw } else { 0 };
                        for y in (r * bh)..swift_min(plane.height, (r + 1) * bh) {
                            let row = &mut plane.data[y * plane.width..(y + 1) * plane.width];
                            for x in x0..row.len() {
                                row[x] = clampf(row[x] + amount, 0.0, 255.0);
                            }
                        }
                    }
                }
                BitError::Displaced { mb_x: mx, mb_y: my, by } => {
                    for (pl, plane) in p.planes_mut().into_iter().enumerate() {
                        let fx = if pl == 0 { 1 } else { g.sx() };
                        let fy = if pl == 0 { 1 } else { g.sy() };
                        let bw = g.mb() / fx;
                        let bh = g.mb() / fy;
                        let from = mx * bw;
                        let shift = by * bw;
                        if !(from + shift < plane.width) {
                            continue;
                        }
                        let width = plane.width;
                        for y in (my * bh)..swift_min(plane.height, (my + 1) * bh) {
                            let row = &mut plane.data[y * width..(y + 1) * width];
                            // Right to left, so each pixel is read before
                            // it's written over.
                            let mut x = width - 1;
                            while x >= from + shift {
                                row[x] = row[x - shift];
                                x -= 1;
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - added motion (vectors that never happened)

    /// The Added motion control's field for capture `index`: one vector a
    /// macroblock, in whole pixels. A speed below a pixel a frame moves on
    /// some frames and not others, so that on average it's right. `speed` is
    /// the fraction of 1/40 of the picture's width its edge moves per frame.
    /// Vectors point where the prediction reads from, so the picture moves
    /// the other way.
    pub fn added_motion(kind: i64, speed: f64, index: i64, g: &CodecGeometry) -> Option<Vec<MotionVector>> {
        if !(kind != 0 && speed != 0.0 && index > 0) {
            return None;
        }
        let top = speed * g.width as f64 / 40.0;
        let cx = g.width as f64 / 2.0;
        let cy = g.height as f64 / 2.0;
        let reach = swift_max(cx, cy);
        let mut out = vec![MotionVector::default(); g.mb_count()];
        let mut any = false;
        // This frame's whole-pixel share of a speed of `v` pixels a frame.
        let step = |v: f64| -> i32 { ((index as f64 * v).round() - ((index - 1) as f64 * v).round()) as i32 };
        for my in 0..g.mb_rows() {
            for mx in 0..g.mb_cols() {
                let x = ((mx * g.mb() + g.mb() / 2) as f64 - cx) / reach;
                let y = ((my * g.mb() + g.mb() / 2) as f64 - cy) / reach;
                let v: (f64, f64) = match kind {
                    1 => (top, 0.0),
                    2 => (0.0, top),
                    3 => (top * x, top * y),
                    _ => (-top * y, top * x),
                };
                let mv = MotionVector { dx: -step(v.0), dy: -step(v.1) };
                if mv.dx != 0 || mv.dy != 0 {
                    any = true;
                }
                out[my * g.mb_cols() + mx] = mv;
            }
        }
        if any { Some(out) } else { None }
    }

    /// Whether the keyframe numbered `key_index` is thrown away.
    pub fn drops_key(key_index: i64, amount: f64) -> bool {
        if !(amount > 0.0 && key_index > 0) {
            return false;
        }
        let mut rng = SplitMix::new((key_index as u64).wrapping_mul(0xD1B5_4A32_D192_ED03) ^ 0xDA7A);
        rng.unit() < amount
    }

    // MARK: - complexity (the fixed-bitrate squeeze)

    /// How much a fixed bitrate coarsens this frame's quantizer: in
    /// proportion to how much there is to code, against a typical frame.
    pub fn squeeze(complexity: f32, typical: f32, strictness: f64) -> f32 {
        if !(strictness > 0.0) {
            return 1.0;
        }
        let ratio = swift_max(0.05, complexity / typical);
        swift_min(6.0, swift_max(0.5, ratio.powf(strictness as f32)))
    }

    /// Mean absolute gradient of the luma — how much detail a keyframe holds.
    pub fn detail(p: &CodecPicture, g: &CodecGeometry) -> f32 {
        let w = p.y.width;
        let data = &p.y.data;
        let rows: Vec<f32> = (0..g.height)
            .into_par_iter()
            .map(|y| {
                let mut s = 0f32;
                let row = &data[y * w..];
                let below = &data[swift_min(g.height - 1, y + 1) * w..];
                for x in 0..(g.width - 1) {
                    s += (row[x + 1] - row[x]).abs() + (below[x] - row[x]).abs();
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

    // MARK: - a real bitrate (the Bitrate limit)

    /// The coarsest the Bitrate limit may push the quantizer (Quality 46%):
    /// about as far as real encoders' quantizers went. Blocks flatten to
    /// their averages, but the averages stay near the right color — past
    /// this, differences round to such large steps that the picture turns to
    /// posterized garbage no starved encoder ever sent. A frame that doesn't
    /// fit even so is skipped, or takes what it takes.
    pub const COARSEST_SCALE: f32 = 8.0;

    /// The transform of `source` (less 128, a keyframe) or of its difference
    /// from `prediction`: every tile's coefficients, in place of its pixels.
    /// Made once, so trying a quantizer costs only a count.
    pub fn coefficients(source: &CodecPicture, prediction: Option<&CodecPicture>, g: &CodecGeometry) -> CodecPicture {
        let mut out = CodecPicture::new(g);
        let n = g.block;
        let c = Self::basis_n(n);
        for (i, (src, dst)) in source.planes().into_iter().zip(out.planes_mut()).enumerate() {
            let pred = prediction.map(|p| p.planes()[i]);
            let w = src.width;
            dst.data.par_chunks_mut(n * w).enumerate().for_each(|(ty, row)| {
                let mut block = [0f32; 256];
                let mut coef = [0f32; 256];
                let mut tmp = [0f32; 256];
                for tx in 0..(w / n) {
                    let origin = ty * n * w + tx * n;
                    for y in 0..n {
                        for x in 0..n {
                            let k = origin + y * w + x;
                            block[y * n + x] = src.data[k] - pred.map_or(128.0, |p| p.data[k]);
                        }
                    }
                    Self::forward_dct(&block, n, &mut coef, &mut tmp, &c, n);
                    for y in 0..n {
                        row[y * w + tx * n..y * w + tx * n + n].copy_from_slice(&coef[y * n..y * n + n]);
                    }
                }
            });
        }
        out
    }

    /// Bits one quantized value costs in a run-length code: a few for where
    /// it is and its sign, and two more each time it doubles.
    #[inline(always)]
    pub fn level_bits(level: f32) -> i64 {
        let a = level.abs() as i64;
        if a == 0 { 0 } else { 2 + 2 * (64 - a.leading_zeros() as i64) }
    }

    /// An estimate of the bits a frame takes at `steps`, from its
    /// `coefficients`: each value that survives the quantizer by its size, a
    /// keyframe's block averages as their change from the block before, and
    /// a little for every block sent. The same rounding as `code_intra` and
    /// `code_residual`, so it counts exactly what they will keep.
    pub fn bits(coefficients: &CodecPicture, steps: &Steps, intra: bool) -> i64 {
        let n = steps.block;
        let nn = n * n;
        let mut total = 0i64;
        for (i, plane) in coefficients.planes().into_iter().enumerate() {
            let t = if i == 0 { &steps.luma } else { &steps.chroma };
            let w = plane.width;
            let rows = plane.height / n;
            let data = &plane.data;
            let row_bits: Vec<i64> = (0..rows)
                .into_par_iter()
                .map(|ty| {
                    let mut sum = 0i64;
                    let mut last_average = 0f32;
                    for tx in 0..(w / n) {
                        let origin = ty * n * w + tx * n;
                        let mut block = 0i64;
                        for k in 0..nn {
                            let c = data[origin + (k / n) * w + k % n];
                            if intra {
                                let level = (c / t[k]).round();
                                if k == 0 {
                                    block += 2 + Self::level_bits(level - last_average);
                                    last_average = level;
                                } else {
                                    block += Self::level_bits(level);
                                }
                            } else {
                                let q = c / steps.inter;
                                block += Self::level_bits(if q < 0.0 { -(-q + 0.2).floor() } else { (q + 0.2).floor() });
                            }
                        }
                        // The end-of-block mark; a difference block with
                        // nothing in it is one bit in its macroblock.
                        sum += if block > 0 { block + 2 } else { 0 };
                    }
                    sum
                })
                .collect();
            for r in row_bits {
                total += r;
            }
        }
        total
    }

    /// Bits for a predicted frame's vectors (each as its change from the one
    /// to its left) and its one-bit-a-macroblock map of what was sent.
    pub fn vector_bits(vectors: &[MotionVector], g: &CodecGeometry) -> i64 {
        let mut total = g.mb_count() as i64;
        for my in 0..g.mb_rows() {
            let mut left = MotionVector::default();
            for mx in 0..g.mb_cols() {
                let v = vectors[my * g.mb_cols() + mx];
                for d in [v.dx - left.dx, v.dy - left.dy] {
                    total += 1 + 2 * (64 - (d.abs() as i64).leading_zeros() as i64);
                }
                left = v;
            }
        }
        total
    }

    /// The finest quantizer, from `start` down to `COARSEST_SCALE`, at which
    /// the frame fits `budget` bits, and what it then costs.
    pub fn fit(coefficients: &CodecPicture, start: Steps, intra: bool, budget: f64) -> (Steps, i64) {
        let first = Self::bits(coefficients, &start, intra);
        if !(first as f64 > budget && start.scale < Self::COARSEST_SCALE) {
            return (start, first);
        }
        let coarsest = Steps::from_scale(Self::COARSEST_SCALE, start.block);
        let most = Self::bits(coefficients, &coarsest, intra);
        if !(most as f64 <= budget) {
            return (coarsest, most);
        }
        let mut lo = start.scale.ln();
        let mut hi = Self::COARSEST_SCALE.ln();
        let mut best = (coarsest, most);
        for _ in 0..8 {
            let mid = (lo + hi) / 2.0;
            let steps = Steps::from_scale(mid.exp(), start.block);
            let cost = Self::bits(coefficients, &steps, intra);
            if cost as f64 <= budget {
                hi = mid;
                best = (steps, cost);
            } else {
                lo = mid;
            }
        }
        best
    }

    // MARK: - one frame

    /// Code `source` as `kind`, advancing `state`. Returns the picture the
    /// decoder shows (its reference) and the quantizer step for the
    /// deblocking filter.
    pub fn step(state: &mut CodecState, source: &CodecPicture, kind: CodecFrameKind, index: i64, s: &FrameSettings) -> (Arc<CodecPicture>, f32) {
        let g = state.geometry;
        let lost = Self::lost_blocks(s.data_loss, index, &g, s.loss_pattern);

        match kind {
            CodecFrameKind::IntraOnly | CodecFrameKind::Key | CodecFrameKind::DroppedKey => {
                let squeeze = Self::squeeze(Self::detail(source, &g), 14.0, s.fixed_bitrate);
                let mut steps = Steps::with_block(s.quality, squeeze, g.block);
                if s.bits_per_pixel > 0.0 {
                    // A frame coded alone gets its own share and no more
                    // (DV: the same bits for every frame). A keyframe opens
                    // a fresh buffer and may fill it — what it takes beyond
                    // its share the frames after it have to give back.
                    let share = s.bits_per_pixel * (g.width * g.height) as f64;
                    let buffer = if kind == CodecFrameKind::IntraOnly { 0.0 } else { s.buffer_frames * share };
                    let (fitted, bits) = Self::fit(&Self::coefficients(source, None, &g), steps, true, share + buffer);
                    steps = fitted;
                    state.buffer_fill = swift_min(buffer, swift_max(0.0, bits as f64 - share));
                } else {
                    state.buffer_fill = 0.0;
                }
                // What a lost block is patched from: the previous frame as
                // coded (a stream's packets: the damage lasts one frame), or
                // on tape the picture the decoder last showed, which holds
                // until new data arrives — a clogged head's bands freeze.
                let previous = if s.loss_pattern == LossPattern::Packets {
                    state.encoder.clone()
                } else {
                    state.decoder.clone().or_else(|| state.encoder.clone())
                };
                let mut recon = CodecPicture::new(&g);
                Self::code_intra(source, &mut recon, &steps);
                let recon = Arc::new(recon);
                state.encoder = Some(recon.clone());
                state.vectors = vec![MotionVector::default(); g.mb_count()];
                match kind {
                    CodecFrameKind::IntraOnly => {
                        // Each frame stands alone; a lost block is patched
                        // from the previous frame (DV's error concealment)
                        // and the damage is gone by the next one.
                        let errors = Self::bit_errors(s.bit_errors, index, &g);
                        let patched = lost.is_some() && (previous.is_some() || s.concealment != Concealment::LastPicture);
                        if patched || !errors.is_empty() {
                            let mut shown = (*recon).clone();
                            Self::damage(&mut shown, &errors, &g);
                            if let (true, Some(lost)) = (patched, &lost) {
                                if let (Concealment::LastPicture, Some(previous)) = (s.concealment, &previous) {
                                    Self::copy_blocks(previous, &mut shown, lost, &g);
                                } else {
                                    // (Stretched leaves the top row's gaps to
                                    // the patch.)
                                    if let (Concealment::Stretched, Some(previous)) = (s.concealment, &previous) {
                                        let mut top = vec![false; g.mb_count()];
                                        for mx in 0..g.mb_cols() {
                                            top[mx] = lost[mx];
                                        }
                                        Self::copy_blocks(previous, &mut shown, &top, &g);
                                    }
                                    Self::conceal(&mut shown, lost, s.concealment, &g);
                                }
                            }
                            state.decoder = Some(Arc::new(shown));
                            state.diverged = true;
                        } else {
                            state.decoder = Some(recon.clone());
                            state.diverged = false;
                        }
                    }
                    CodecFrameKind::Key => {
                        // Keyframes arrive whole (streams protect them).
                        state.decoder = Some(recon.clone());
                        state.diverged = false;
                    }
                    _ => {
                        // Never arrives: the decoder holds its old picture.
                        if state.decoder.is_none() {
                            state.decoder = Some(Arc::new((*recon).clone()));
                        }
                        state.diverged = !Arc::ptr_eq(state.decoder.as_ref().unwrap(), &recon);
                    }
                }
                state.shown_step = steps.inter;
                (state.decoder.clone().unwrap(), steps.inter)
            }

            CodecFrameKind::Predicted => {
                let Some(enc_ref) = state.encoder.clone() else {
                    return Self::step(state, source, CodecFrameKind::Key, index, s);
                };
                let (motion_vectors, motion_error) = Self::search_motion(source, &enc_ref, &state.vectors, &g);
                let squeeze = Self::squeeze(motion_error, 3.0, s.fixed_bitrate);
                let mut steps = Steps::with_block(s.quality, squeeze, g.block);
                let mut prediction = CodecPicture::new(&g);
                Self::compensate(&enc_ref, &motion_vectors, &g, &mut prediction);
                if s.bits_per_pixel > 0.0 {
                    // Its share, plus whatever room the buffer has left. With
                    // the buffer full, a cut (a whole new picture to send as
                    // a difference) has to fit one frame's share: it lands as
                    // coarse blocks, and the frames after it sharpen them.
                    let share = s.bits_per_pixel * (g.width * g.height) as f64;
                    let buffer = s.buffer_frames * share;
                    let sent = Self::vector_bits(&motion_vectors, &g) as f64;
                    let room = share + swift_max(0.0, buffer - state.buffer_fill);
                    let (fitted, bits) = Self::fit(&Self::coefficients(source, Some(&prediction), &g), steps, false, room - sent);
                    if bits as f64 + sent > room && state.buffer_fill > 0.0 {
                        if let Some(held) = state.decoder.clone() {
                            // Too much even at the coarsest: the encoder
                            // sends nothing and waits for the buffer to
                            // drain. The picture freezes — the stutter of a
                            // starved stream.
                            state.buffer_fill = swift_max(0.0, state.buffer_fill - share);
                            return (held, state.shown_step);
                        }
                    }
                    steps = fitted;
                    state.buffer_fill = swift_min(buffer, swift_max(0.0, state.buffer_fill + bits as f64 + sent - share));
                } else {
                    state.buffer_fill = 0.0;
                }
                let mut residual = CodecPicture::new(&g);
                Self::code_residual(source, &prediction, steps.inter, g.block, &mut residual);
                let mut enc_recon = CodecPicture::new(&g);
                Self::reconstruct(&prediction, &residual, None, &g, &mut enc_recon);
                let enc_recon = Arc::new(enc_recon);

                let errors = Self::bit_errors(s.bit_errors, index, &g);
                let added = Self::added_motion(s.motion, s.motion_speed, index, &g);
                if !state.diverged && lost.is_none() && errors.is_empty() && added.is_none() {
                    state.decoder = Some(enc_recon.clone());
                } else {
                    // The decoder moves its own picture: the encoder's
                    // vectors, except where they were lost — there it
                    // guesses from the block above, and gets no difference
                    // at all.
                    let mut vectors = motion_vectors.clone();
                    if let Some(lost) = &lost {
                        let cols = g.mb_cols();
                        for i in 0..g.mb_count() {
                            if lost[i] {
                                vectors[i] = if i >= cols && !lost[i - cols] { vectors[i - cols] } else { MotionVector::default() };
                            }
                        }
                    }
                    // Motion that never happened, on top of the real one:
                    // the differences were made for the real one, so nothing
                    // puts the picture back.
                    if let Some(added) = &added {
                        for i in 0..g.mb_count() {
                            vectors[i].dx += added[i].dx;
                            vectors[i].dy += added[i].dy;
                        }
                    }
                    let dec_ref = state.decoder.clone().unwrap_or_else(|| enc_ref.clone());
                    let mut dec_prediction = CodecPicture::new(&g);
                    Self::compensate(&dec_ref, &vectors, &g, &mut dec_prediction);
                    let mut dec_recon = CodecPicture::new(&g);
                    Self::reconstruct(&dec_prediction, &residual, lost.as_deref(), &g, &mut dec_recon);
                    Self::damage(&mut dec_recon, &errors, &g);
                    if let Some(lost) = &lost {
                        Self::conceal(&mut dec_recon, lost, s.concealment, &g);
                    }
                    state.decoder = Some(Arc::new(dec_recon));
                    state.diverged = true;
                }
                state.encoder = Some(enc_recon);
                state.vectors = motion_vectors;
                state.shown_step = steps.inter;
                (state.decoder.clone().unwrap(), steps.inter)
            }
        }
    }

    /// Copy whole macroblocks of `source` over `target` where `mask` is set.
    pub fn copy_blocks(source: &CodecPicture, target: &mut CodecPicture, mask: &[bool], g: &CodecGeometry) {
        for (i, (src, dst)) in source.planes().into_iter().zip(target.planes_mut()).enumerate() {
            let fx = if i == 0 { 1 } else { g.sx() };
            let fy = if i == 0 { 1 } else { g.sy() };
            let w = dst.width;
            let cols = g.mb_cols();
            for y in 0..dst.height {
                let my = swift_min(g.mb_rows() - 1, y * fy / g.mb());
                for x in 0..w {
                    if mask[my * cols + swift_min(cols - 1, x * fx / g.mb())] {
                        dst.data[y * w + x] = src.data[y * w + x];
                    }
                }
            }
        }
    }

    // MARK: - deblocking (the decoder's display filter)

    /// Smooth steps across block edges that are small enough to be
    /// quantization rather than picture edges, as H.264's loop filter does.
    pub fn deblock(p: &mut CodecPicture, strength: f64, step: f32, n: usize) {
        if !(strength > 0.0) {
            return;
        }
        let w8 = strength as f32;
        let threshold = strength as f32 * (4.0 + 0.9 * step);
        for plane in p.planes_mut() {
            let w = plane.width;
            let h = plane.height;
            let d = &mut plane.data;
            let filter = |d: &mut [f32], a: usize, b: usize, c: usize, e: usize| {
                // a, b | c, d across the edge.
                let p1 = d[a];
                let p0 = d[b];
                let q0 = d[c];
                let q1 = d[e];
                let delta = q0 - p0;
                if !(delta.abs() < threshold && (p1 - p0).abs() < threshold / 2.0 && (q1 - q0).abs() < threshold / 2.0) {
                    return;
                }
                d[b] = p0 + delta * 0.375 * w8;
                d[c] = q0 - delta * 0.375 * w8;
                d[a] = p1 + delta * 0.125 * w8;
                d[e] = q1 - delta * 0.125 * w8;
            };
            for y in 0..h {
                let mut x = n;
                while x < w {
                    let k = y * w + x;
                    filter(d, k - 2, k - 1, k, k + 1);
                    x += n;
                }
            }
            let mut y = n;
            while y < h {
                for x in 0..w {
                    let k = y * w + x;
                    filter(d, k - 2 * w, k - w, k, k + w);
                }
                y += n;
            }
        }
    }
}

/// SplitMix64: a small, fast, seedable generator for deterministic noise and
/// error patterns.
#[derive(Clone, Copy, Debug)]
pub struct SplitMix {
    state: u64,
}

impl SplitMix {
    pub fn new(seed: u64) -> Self {
        SplitMix { state: seed }
    }

    #[inline(always)]
    pub fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    #[inline(always)]
    pub fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
}
