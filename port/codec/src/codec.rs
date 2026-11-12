//! The Digital video stage's codec (`DigitalCodec.swift`): a small, real
//! block-transform video codec in the MPEG/H.263/DV family, run on the CPU at
//! the capture resolution.
//!
//! - Pictures are Y′CbCr (BT.601) with subsampled color, coded in 8×8 DCT
//!   blocks against the JPEG reference quantization tables.
//! - Keyframes are coded alone; between them each 16×16 macroblock is
//!   predicted from the previous picture by a motion vector, and only the
//!   quantized difference is sent.
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
use crate::tables::DCT_BASIS_BITS;

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
/// macroblocks (luma) and whole 8×8 blocks (color).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CodecGeometry {
    pub width: usize,
    pub height: usize,
    pub chroma: ChromaSubsampling,
}

impl CodecGeometry {
    pub fn new(width: usize, height: usize, chroma: ChromaSubsampling) -> Self {
        CodecGeometry { width, height, chroma }
    }
    pub fn luma_w(&self) -> usize { (self.width + 15) / 16 * 16 }
    pub fn luma_h(&self) -> usize { (self.height + 15) / 16 * 16 }
    pub fn sx(&self) -> usize { self.chroma.factors().0 }
    pub fn sy(&self) -> usize { self.chroma.factors().1 }
    pub fn chroma_w(&self) -> usize { (self.luma_w() / self.sx() + 7) / 8 * 8 }
    pub fn chroma_h(&self) -> usize { (self.luma_h() / self.sy() + 7) / 8 * 8 }
    pub fn mb_cols(&self) -> usize { self.luma_w() / 16 }
    pub fn mb_rows(&self) -> usize { self.luma_h() / 16 }
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
}

impl CodecState {
    pub fn new(geometry: CodecGeometry) -> Self {
        CodecState {
            geometry,
            encoder: None,
            decoder: None,
            vectors: vec![MotionVector::default(); geometry.mb_count()],
            diverged: false,
        }
    }
}

/// Swift's `Float.clamped(lo, hi)`: `min(hi, max(lo, self))`.
#[inline(always)]
pub(crate) fn clampf(v: f32, lo: f32, hi: f32) -> f32 {
    swift_min(hi, swift_max(lo, v))
}

/// Settings that act on one frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FrameSettings {
    pub quality: f64,
    pub fixed_bitrate: f64,
    pub data_loss: f64,
}

/// Step sizes for one frame. Keyframes use the perceptual tables;
/// differences use a flat step, as MPEG's non-intra matrix does.
#[derive(Clone, Debug, PartialEq)]
pub struct Steps {
    pub luma: [f32; 64],
    pub chroma: [f32; 64],
    pub inter: f32,
}

impl Steps {
    pub fn new(quality: f64, squeeze: f32) -> Self {
        let s = DigitalCodec::table_scale(quality) * squeeze;
        let mut luma = [0f32; 64];
        let mut chroma = [0f32; 64];
        for k in 0..64 {
            luma[k] = swift_max(1.0, (DigitalCodec::LUMA_TABLE[k] * s).round());
            chroma[k] = swift_max(1.0, (DigitalCodec::CHROMA_TABLE[k] * s).round());
        }
        Steps { luma, chroma, inter: swift_max(1.0, 16.0 * s) }
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

    /// out[u,v] = Σ C[u,x] C[v,y] in[x,y] — `input` row-major with `stride`.
    #[inline(always)]
    pub fn forward_dct(input: &[f32], stride: usize, out: &mut [f32; 64], tmp: &mut [f32; 64], c: &[f32; 64]) {
        // Rows: tmp[y, u] = Σx C[u,x] in[y,x]
        for y in 0..8 {
            let row = &input[y * stride..y * stride + 8];
            for u in 0..8 {
                let cu = &c[u * 8..u * 8 + 8];
                let mut s = 0f32;
                for x in 0..8 {
                    s += cu[x] * row[x];
                }
                tmp[y * 8 + u] = s;
            }
        }
        // Columns: out[v, u] = Σy C[v,y] tmp[y,u]
        for v in 0..8 {
            let cv = &c[v * 8..v * 8 + 8];
            for u in 0..8 {
                let mut s = 0f32;
                for y in 0..8 {
                    s += cv[y] * tmp[y * 8 + u];
                }
                out[v * 8 + u] = s;
            }
        }
    }

    /// The inverse: out[y,x] = Σ C[v,y] C[u,x] coef[v,u].
    #[inline(always)]
    pub fn inverse_dct(coef: &[f32; 64], out: &mut [f32], stride: usize, tmp: &mut [f32; 64], c: &[f32; 64]) {
        // Columns: tmp[y, u] = Σv C[v,y] coef[v,u]
        for y in 0..8 {
            for u in 0..8 {
                let mut s = 0f32;
                for v in 0..8 {
                    s += c[v * 8 + y] * coef[v * 8 + u];
                }
                tmp[y * 8 + u] = s;
            }
        }
        // Rows: out[y, x] = Σu C[u,x] tmp[y,u]
        for y in 0..8 {
            let row = &mut out[y * stride..y * stride + 8];
            for x in 0..8 {
                let mut s = 0f32;
                for u in 0..8 {
                    s += c[u * 8 + x] * tmp[y * 8 + u];
                }
                row[x] = s;
            }
        }
    }

    // MARK: - keyframes

    /// Code `source` with no prediction into `recon`.
    pub fn code_intra(source: &CodecPicture, recon: &mut CodecPicture, steps: &Steps) {
        let c = Self::basis();
        for (i, (src, dst)) in source.planes().into_iter().zip(recon.planes_mut()).enumerate() {
            let t = if i == 0 { &steps.luma } else { &steps.chroma };
            let w = src.width;
            dst.data.par_chunks_mut(8 * w).enumerate().for_each(|(ty, out)| {
                let mut block = [0f32; 64];
                let mut coef = [0f32; 64];
                let mut tmp = [0f32; 64];
                for tx in 0..(w / 8) {
                    let origin = ty * 8 * w + tx * 8;
                    for y in 0..8 {
                        for x in 0..8 {
                            block[y * 8 + x] = src.data[origin + y * w + x] - 128.0;
                        }
                    }
                    Self::forward_dct(&block, 8, &mut coef, &mut tmp, &c);
                    for k in 0..64 {
                        // JPEG rounding: to the nearest step.
                        coef[k] = (coef[k] / t[k]).round() * t[k];
                    }
                    Self::inverse_dct(&coef, &mut block, 8, &mut tmp, &c);
                    for y in 0..8 {
                        for x in 0..8 {
                            out[y * w + tx * 8 + x] = clampf((block[y * 8 + x] + 128.0).round(), 0.0, 255.0);
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
    pub fn sad(src: &CodecPlane, reference: &CodecPlane, bx: usize, by: usize, dx: isize, dy: isize, limit: f32) -> f32 {
        let w = src.width;
        let rx = bx as isize + dx;
        let ry = by as isize + dy;
        let mut total = 0f32;
        if rx >= 0 && ry >= 0 && rx + 16 <= reference.width as isize && ry + 16 <= reference.height as isize {
            let (rx, ry) = (rx as usize, ry as usize);
            for y in 0..16 {
                let s = &src.data[(by + y) * w + bx..(by + y) * w + bx + 16];
                let r = &reference.data[(ry + y) * w + rx..(ry + y) * w + rx + 16];
                for x in 0..16 {
                    total += (s[x] - r[x]).abs();
                }
                if total >= limit {
                    return total;
                }
            }
        } else {
            for y in 0..16 {
                let s = &src.data[(by + y) * w + bx..(by + y) * w + bx + 16];
                for x in 0..16 {
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
        let rows: Vec<(Vec<MotionVector>, f32)> = (0..g.mb_rows())
            .into_par_iter()
            .map(|my| {
                let mut out = vec![MotionVector::default(); cols];
                let mut left = MotionVector::default();
                let mut sum = 0f32;
                for mx in 0..cols {
                    let bx = mx * 16;
                    let by = my * 16;
                    let r = Self::SEARCH_RANGE;
                    let cost = |v: (isize, isize), limit: f32| -> f32 {
                        if !(v.0.abs() <= r && v.1.abs() <= r) {
                            return f32::INFINITY;
                        }
                        // A small bias keeps still areas still.
                        let bias: f32 = if v.0 == 0 && v.1 == 0 { -48.0 } else { 0.0 };
                        Self::sad(src, refp, bx, by, v.0, v.1, limit - bias) + bias
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
                    sum += Self::sad(src, refp, bx, by, best.0, best.1, f32::INFINITY);
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
            let bw = 16 / fx;
            let bh = 16 / fy;
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
    pub fn code_residual(source: &CodecPicture, prediction: &CodecPicture, step: f32, residual: &mut CodecPicture) {
        let c = Self::basis();
        for (src, (pred, dst)) in source.planes().into_iter().zip(prediction.planes().into_iter().zip(residual.planes_mut())) {
            let w = src.width;
            dst.data.par_chunks_mut(8 * w).enumerate().for_each(|(ty, out)| {
                let mut block = [0f32; 64];
                let mut coef = [0f32; 64];
                let mut tmp = [0f32; 64];
                for tx in 0..(w / 8) {
                    let origin = ty * 8 * w + tx * 8;
                    for y in 0..8 {
                        for x in 0..8 {
                            let i = origin + y * w + x;
                            block[y * 8 + x] = src.data[i] - pred.data[i];
                        }
                    }
                    Self::forward_dct(&block, 8, &mut coef, &mut tmp, &c);
                    let mut any = false;
                    for k in 0..64 {
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
                        Self::inverse_dct(&coef, &mut out[tx * 8..], w, &mut tmp, &c);
                    } else {
                        for y in 0..8 {
                            out[y * w + tx * 8..y * w + tx * 8 + 8].fill(0.0);
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
            dst.data.par_chunks_mut(w).enumerate().for_each(|(y, out)| {
                let my = swift_min(rows - 1, y * fy / 16);
                for x in 0..w {
                    let k = y * w + x;
                    let mut v = pred.data[k];
                    let mx = swift_min(cols - 1, x * fx / 16);
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
    pub fn lost_blocks(amount: f64, index: i64, g: &CodecGeometry) -> Option<Vec<bool>> {
        if !(amount > 0.0) {
            return None;
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

    // MARK: - one frame

    /// Code `source` as `kind`, advancing `state`. Returns the picture the
    /// decoder shows (its reference) and the quantizer step for the
    /// deblocking filter.
    pub fn step(state: &mut CodecState, source: &CodecPicture, kind: CodecFrameKind, index: i64, s: &FrameSettings) -> (Arc<CodecPicture>, f32) {
        let g = state.geometry;
        let lost = Self::lost_blocks(s.data_loss, index, &g);

        match kind {
            CodecFrameKind::IntraOnly | CodecFrameKind::Key | CodecFrameKind::DroppedKey => {
                let squeeze = Self::squeeze(Self::detail(source, &g), 14.0, s.fixed_bitrate);
                let steps = Steps::new(s.quality, squeeze);
                let previous = state.encoder.clone();
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
                        if let (Some(lost), Some(previous)) = (&lost, &previous) {
                            let mut shown = (*recon).clone();
                            Self::copy_blocks(previous, &mut shown, lost, &g);
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
                (state.decoder.clone().unwrap(), steps.inter)
            }

            CodecFrameKind::Predicted => {
                let Some(enc_ref) = state.encoder.clone() else {
                    return Self::step(state, source, CodecFrameKind::Key, index, s);
                };
                let (motion_vectors, motion_error) = Self::search_motion(source, &enc_ref, &state.vectors, &g);
                let squeeze = Self::squeeze(motion_error, 3.0, s.fixed_bitrate);
                let steps = Steps::new(s.quality, squeeze);
                let mut prediction = CodecPicture::new(&g);
                Self::compensate(&enc_ref, &motion_vectors, &g, &mut prediction);
                let mut residual = CodecPicture::new(&g);
                Self::code_residual(source, &prediction, steps.inter, &mut residual);
                let mut enc_recon = CodecPicture::new(&g);
                Self::reconstruct(&prediction, &residual, None, &g, &mut enc_recon);
                let enc_recon = Arc::new(enc_recon);

                if !state.diverged && lost.is_none() {
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
                    let dec_ref = state.decoder.clone().unwrap_or_else(|| enc_ref.clone());
                    let mut dec_prediction = CodecPicture::new(&g);
                    Self::compensate(&dec_ref, &vectors, &g, &mut dec_prediction);
                    let mut dec_recon = CodecPicture::new(&g);
                    Self::reconstruct(&dec_prediction, &residual, lost.as_deref(), &g, &mut dec_recon);
                    state.decoder = Some(Arc::new(dec_recon));
                    state.diverged = true;
                }
                state.encoder = Some(enc_recon);
                state.vectors = motion_vectors;
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
                let my = swift_min(g.mb_rows() - 1, y * fy / 16);
                for x in 0..w {
                    if mask[my * cols + swift_min(cols - 1, x * fx / 16)] {
                        dst.data[y * w + x] = src.data[y * w + x];
                    }
                }
            }
        }
    }

    // MARK: - deblocking (the decoder's display filter)

    /// Smooth steps across 8×8 block edges that are small enough to be
    /// quantization rather than picture edges, as H.264's loop filter does.
    pub fn deblock(p: &mut CodecPicture, strength: f64, step: f32) {
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
                let mut x = 8;
                while x < w {
                    let k = y * w + x;
                    filter(d, k - 2, k - 1, k, k + 1);
                    x += 8;
                }
            }
            let mut y = 8;
            while y < h {
                for x in 0..w {
                    let k = y * w + x;
                    filter(d, k - 2 * w, k - w, k, k + w);
                }
                y += 8;
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
