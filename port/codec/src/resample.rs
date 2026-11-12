//! The camera's capture scaling: the stand-in for the Mac's
//! `vImageScale_ARGB8888(…, kvImageHighQualityResampling)`, which can't be
//! called off Apple platforms.
//!
//! What that call does was measured on the Mac — impulses, then random rows
//! and columns through it, fitted against candidate filters:
//!
//! - a separable Lanczos-5 kernel (the high-quality flag's; Lanczos-3
//!   without it), widened by the reduction factor when shrinking, so it
//!   averages over each output pixel's whole footprint (area-aware);
//! - sample centers at `(i + 0.5) · in/out − 0.5`, snapped to 1/64 of a
//!   source pixel — 1/32 from a 2× reduction, 1/16 from 4×, and so on (the
//!   kernel is tabulated in steps of the output pixel); across, rounded with
//!   exact halves going down; down, floored, with an exact step landing one
//!   lower unless the ratio is a power-of-two fraction or an enlargement;
//! - a fixed count of taps, twice the kernel radius rounded, on the source
//!   pixels nearest the center, the weights normalized to sum to one;
//! - edge pixels repeated past the border;
//! - the vertical pass first, rounded to 8 bits, then the horizontal; exact
//!   halves rounded up; the result clamped to 0…255 (the negative lobes
//!   ring, then clip).
//!
//! That reproduces single rows and columns exactly on 97–99.5% of samples,
//! the rest one code value off. Whole pictures (`examples/parity.rs`, the
//! `scale/` cases) differ from the Mac in 0.01–0.9% of values, by one code
//! value (two at most). What's left is vImage's own fixed-point arithmetic,
//! which isn't documented.

use rayon::prelude::*;

/// Lobes of the Lanczos window (vImage's high-quality kernel is Lanczos-5).
pub const LANCZOS_LOBES: f64 = 5.0;

#[inline]
fn sinc(x: f64) -> f64 {
    if x == 0.0 {
        1.0
    } else {
        let p = std::f64::consts::PI * x;
        p.sin() / p
    }
}

#[inline]
fn lanczos(x: f64, a: f64) -> f64 {
    if x.abs() >= a { 0.0 } else { sinc(x) * sinc(x / a) }
}

/// For each output sample: the first source index (unclamped) and its
/// normalized weights (`len` of them).
struct Taps {
    start: Vec<i64>,
    len: usize,
    weights: Vec<f32>,
}

/// vImage's phase resolution (steps per source pixel) for a reduction:
/// 64, halved for every doubling of the reduction factor.
fn phases(src: usize, dst: usize) -> i64 {
    let mut n = 64i64;
    let mut k = 2 * dst;
    while src >= k && n > 1 {
        n /= 2;
        k *= 2;
    }
    n
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 { a } else { gcd(b, a % b) }
}

#[derive(Clone, Copy, PartialEq)]
enum Axis {
    Across,
    Down,
}

fn taps(src: usize, dst: usize, axis: Axis) -> Taps {
    let a = LANCZOS_LOBES;
    let ratio = src as f64 / dst as f64;
    let support = ratio.max(1.0);
    let len = (2.0 * a * support + 0.5).floor() as usize;
    let n = phases(src, dst);
    let (s, d) = (src as i64, dst as i64);
    // Down the picture vImage's position lands a hair under the exact
    // value — unless the reduction is a power-of-two fraction, which it
    // represents exactly.
    let exact = (d / gcd(s, d)).count_ones() == 1;
    let mut start = Vec::with_capacity(dst);
    let mut weights = vec![0f32; dst * len];
    let mut w = vec![0f64; len];
    for i in 0..d {
        // The center c = (i + ½)·src/dst − ½ in 1/n steps, exactly:
        // c·n = num / den with num = ((2i + 1)·src − dst)·n, den = 2·dst.
        let num = ((2 * i + 1) * s - d) * n;
        let den = 2 * d;
        let q = match axis {
            // Rounded, halves down: ⌈c·n − ½⌉.
            Axis::Across => -((-(2 * num - den)).div_euclid(2 * den)),
            // Floored, exact steps one lower: ⌈c·n⌉ − 1 (an enlargement,
            // or an exact ratio, floors exactly).
            Axis::Down if src >= dst && !exact => -((-num).div_euclid(den)) - 1,
            Axis::Down => num.div_euclid(den),
        };
        let center = q as f64 / n as f64;
        // The `len` source pixels nearest the center.
        let first = (2 * q - len as i64 * n).div_euclid(2 * n) + 1;
        start.push(first);
        let mut sum = 0.0;
        for (t, wt) in w.iter_mut().enumerate() {
            *wt = lanczos(((first + t as i64) as f64 - center) / support, a);
            sum += *wt;
        }
        for t in 0..len {
            weights[i as usize * len + t] = (w[t] / sum) as f32;
        }
    }
    Taps { start, len, weights }
}

/// A filtered value to 8 bits. Exact halves go up, as vImage's fixed point
/// takes them; the small nudge keeps float noise from deciding a half that
/// is exact on paper (a 2× reduction of a ramp is full of them).
#[inline(always)]
fn to_u8(v: f32) -> u8 {
    (v + 0.5 + 1e-4).floor().clamp(0.0, 255.0) as u8
}

/// Scale 4-channel 8-bit `src` (`width` × `height`, `row_bytes` apart) to
/// `out` (`dw` × `dh`, tightly packed). Channels are treated alike, so the
/// order (RGBA or BGRA) doesn't matter.
pub fn scale_lanczos(src: &[u8], width: usize, height: usize, row_bytes: usize, out: &mut [u8], dw: usize, dh: usize) {
    let tx = taps(width, dw, Axis::Across);
    let ty = taps(height, dh, Axis::Down);
    // Down first: every source column at the output height, in 8 bits.
    let mut mid = vec![0u8; dh * width * 4];
    mid.par_chunks_mut(width * 4).enumerate().for_each(|(y, row)| {
        let first = ty.start[y];
        let w = &ty.weights[y * ty.len..(y + 1) * ty.len];
        let rows: Vec<&[u8]> = (0..ty.len)
            .map(|t| {
                let j = (first + t as i64).clamp(0, height as i64 - 1) as usize;
                &src[j * row_bytes..j * row_bytes + width * 4]
            })
            .collect();
        for x in 0..width * 4 {
            let mut acc = 0f32;
            for (r, &wt) in rows.iter().zip(w) {
                acc += wt * r[x] as f32;
            }
            row[x] = to_u8(acc);
        }
    });
    // Then across.
    out[..dw * dh * 4].par_chunks_mut(dw * 4).enumerate().for_each(|(y, row)| {
        let m = &mid[y * width * 4..(y + 1) * width * 4];
        for x in 0..dw {
            let first = tx.start[x];
            let w = &tx.weights[x * tx.len..(x + 1) * tx.len];
            let mut acc = [0f32; 4];
            for (t, &wt) in w.iter().enumerate() {
                let j = (first + t as i64).clamp(0, width as i64 - 1) as usize;
                for c in 0..4 {
                    acc[c] += wt * m[j * 4 + c] as f32;
                }
            }
            for c in 0..4 {
                row[x * 4 + c] = to_u8(acc[c]);
            }
        }
    });
}
