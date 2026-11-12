//! What only the port has: the embedded tables, the vImage stand-in, the
//! RGBA order.

use super::digital_video::{frame, s, CAPTURE, SIZE};
use crate::codec::*;
use crate::renderer::*;
use crate::resample::scale_lanczos;
use crate::tables::{DCT_BASIS_BITS, SRGB_TO_LINEAR_BITS};

/// Values within one unit in the last place (or exact, where the platform's
/// math library is the Mac's).
fn close(a: f32, b: f32) -> bool {
    a == b || (a.to_bits() as i64 - b.to_bits() as i64).abs() <= 1
}

#[test]
fn embedded_tables_are_the_formulas() {
    for u in 0..8 {
        let a = if u == 0 { (1.0f64 / 8.0).sqrt() } else { (2.0f64 / 8.0).sqrt() };
        for x in 0..8 {
            let v = (a * ((2 * x + 1) as f64 * u as f64 * std::f64::consts::PI / 16.0).cos()) as f32;
            let t = f32::from_bits(DCT_BASIS_BITS[u * 8 + x]);
            assert!(close(v, t), "basis {u},{x}: {v} vs {t}");
            if cfg!(target_os = "macos") {
                assert_eq!(v, t, "basis {u},{x} on the Mac's libm");
            }
        }
    }
    for i in 0..256 {
        let c = i as f32 / 255.0;
        let v = if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) };
        let t = f32::from_bits(SRGB_TO_LINEAR_BITS[i]);
        assert!(close(v, t), "sRGB {i}: {v} vs {t}");
        if cfg!(target_os = "macos") {
            assert_eq!(v, t, "sRGB {i} on the Mac's libm");
        }
    }
}

#[test]
fn split_mix_matches_the_reference_sequence() {
    // SplitMix64's published first outputs for seed 0.
    let mut r = SplitMix::new(0);
    assert_eq!(r.next(), 0xE220_A839_7B1D_CDAF);
    assert_eq!(r.next(), 0x6E78_9E6A_A1B9_65F4);
    assert_eq!(r.next(), 0x06C4_5D18_8009_454F);
}

#[test]
fn resampler_keeps_flat_fields_and_the_mean() {
    // A flat picture stays exactly flat (weights sum to one), and a picture's
    // average survives the reduction.
    let flat = vec![77u8; 300 * 200 * 4];
    let mut out = vec![0u8; 120 * 80 * 4];
    scale_lanczos(&flat, 300, 200, 300 * 4, &mut out, 120, 80);
    assert!(out.iter().all(|&v| v == 77));
    let px = frame(5, None);
    let small = DigitalVideoRenderer::scale(&px, SIZE.0, SIZE.1, SIZE.0 * 4, CAPTURE, &s(&[("fields", 0.0)]));
    let mean = |p: &[u8], c: usize| p.iter().skip(c).step_by(4).map(|&v| v as f64).sum::<f64>() / (p.len() / 4) as f64;
    for c in 0..3 {
        assert!((mean(&px, c) - mean(&small, c)).abs() < 1.0, "channel {c}");
    }
}

#[test]
fn red_is_read_left_and_blue_right_as_on_the_mac() {
    // The Mac reads red a third of a capture pixel left of center and blue a
    // third right (in its BGRA order); RGBA must sample the same colors at
    // the same places. A single bright source column shows where each lands.
    // Capture pixel 15's center is source 46.5 (3 source pixels each): red
    // reads 45, green 46, blue 47. At 50% aliasing the point samples are
    // all there is.
    let (w, h, cw, ch) = (96usize, 8usize, 32usize, 8usize);
    for (column, lit) in [(45usize, 0usize), (46, 1), (47, 2)] {
        let mut px = vec![0u8; w * h * 4];
        for y in 0..h {
            for c in 0..3 {
                px[(y * w + column) * 4 + c] = 255;
            }
        }
        let out = DigitalVideoRenderer::scale(&px, w, h, w * 4, (cw, ch), &s(&[("aliasing", 0.5), ("fields", 0.0)]));
        let at15 = &out[(4 * cw + 15) * 4..(4 * cw + 15) * 4 + 3];
        for c in 0..3 {
            assert_eq!(at15[c], if c == lit { 255 } else { 0 }, "column {column}: {at15:?}");
        }
    }
}
