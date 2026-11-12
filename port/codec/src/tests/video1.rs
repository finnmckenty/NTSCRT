//! Microsoft Video 1: 4×4 blocks of one, two or eight 15-bit colors, skipped
//! between keyframes where nothing changed. (`Video1Tests.swift`; pixels are
//! RGBA here.)

use super::digital_video::{played, s};
use crate::codec::*;
use crate::params::*;
use crate::renderer::*;
use crate::video1::*;

fn block(f: impl Fn(usize) -> V3) -> [V3; 16] {
    std::array::from_fn(f)
}

#[test]
fn flat_blocks_are_one_color_and_two_tone_blocks_are_exact() {
    let flat = block(|_| V3::new(100.0, 150.0, 200.0));
    assert_eq!(Video1Codec::code_block(&flat, None, 48.0).0, Video1Mode::Fill);
    // Half black, half white: two colors reproduce it exactly.
    let edge = block(|i| if i % 4 < 2 { V3::new(0.0, 0.0, 0.0) } else { V3::new(255.0, 255.0, 255.0) });
    let coded = Video1Codec::code_block(&edge, None, 48.0);
    assert_eq!(coded.0, Video1Mode::Two);
    assert_eq!(coded.1, edge);
    // Four different quarters need eight colors.
    let quads = block(|i| {
        let q = (i / 8) * 2 + (i % 4) / 2;
        let base = [V3::new(255.0, 0.0, 0.0), V3::new(0.0, 255.0, 0.0), V3::new(0.0, 0.0, 255.0), V3::new(255.0, 255.0, 0.0)];
        if i % 2 == 0 { base[q] } else { base[q] * 0.3 }
    });
    assert_eq!(Video1Codec::code_block(&quads, None, 48.0).0, Video1Mode::Eight);
}

#[test]
fn colors_are_fifteen_bit() {
    let px = block(|i| V3::new((i * 13 % 256) as f32, (i * 29 % 256) as f32, (i * 7 % 256) as f32));
    for c in Video1Codec::code_block(&px, None, 1.0).1 {
        for v in [c.x, c.y, c.z] {
            assert!(((v * 31.0 / 255.0).round() * 255.0 / 31.0 - v).abs() <= 1e-3);
        }
    }
}

#[test]
fn unchanged_blocks_are_skipped() {
    let px = block(|i| V3::new((i * 9) as f32, 80.0, 160.0));
    assert_eq!(Video1Codec::code_block(&px, Some(&px), 4.0).0, Video1Mode::Skip);
    let moved = block(|i| V3::new(((15 - i) * 9) as f32, 80.0, 160.0));
    assert_ne!(Video1Codec::code_block(&moved, Some(&px), 4.0).0, Video1Mode::Skip);
}

#[test]
fn the_hidden_controls_do_nothing() {
    let mut st = s(&[("codec", 1.0), ("datamosh", 1.0), ("deblocking", 1.0), ("chroma", 3.0)]);
    assert_eq!(st.chroma(), ChromaSubsampling::Full, "Video 1 keeps full color");
    assert_eq!(st.effective("datamosh"), 0.0);
    assert_eq!(st.effective("deblocking"), 0.0);
    st.set("codec", 0.0);
    assert_eq!(st.effective("datamosh"), 1.0);
    assert_eq!(st.chroma(), ChromaSubsampling::QuarterWide);
    assert!(!DigitalParam::by_id("datamosh").unwrap().applies(DigitalCodecKind::BlockColors));
    assert!(DigitalParam::by_id("quality").unwrap().applies(DigitalCodecKind::BlockColors));
}

#[test]
fn more_quality_never_hurts() {
    // Texture at several scales. (On a real frame of Finn's clip the error
    // runs 14.6, 14.0, 13.3 … 4.0, 3.6 per tenth — even along the slider;
    // real Video 1 measured 9.1 there, which the CD-ROM format's 57%
    // matches.)
    let (w, h) = (96usize, 72usize);
    let mut px = vec![255u8; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) * 4;
            let wave = |fx: f64, fy: f64, p: f64| (x as f64 * fx + y as f64 * fy + p).sin();
            let v = 0.5 * wave(0.05, 0.03, 0.0) + 0.3 * wave(0.21, -0.17, 1.0) + 0.2 * wave(0.9, 0.7, 2.0);
            px[i + 2] = (128.0 + 100.0 * v) as u8;
            px[i + 1] = (128.0 + 100.0 * (0.6 * wave(0.04, 0.08, 3.0) + 0.4 * wave(0.5, 0.3, 4.0))) as u8;
            px[i] = (128.0 + 100.0 * (0.7 * wave(0.07, -0.02, 5.0) + 0.3 * wave(1.1, 0.4, 6.0))) as u8;
        }
    }
    let g = CodecGeometry::new(w, h, ChromaSubsampling::Full);
    let src = DigitalVideoRenderer::capture(&px, &g, &s(&[("sensor_noise", 0.0), ("noise_reduction", 0.0), ("codec", 1.0)]), 0);
    let errors: Vec<f32> = [0.0, 0.1, 0.5, 1.0]
        .iter()
        .map(|&q| {
            let out = Video1Codec::step(
                &mut CodecState::new(g),
                &src,
                CodecFrameKind::Key,
                0,
                &FrameSettings { quality: q, fixed_bitrate: 0.0, data_loss: 0.0 },
            );
            let mut e = 0f32;
            for y in 0..h {
                for x in 0..w {
                    e += (out.y.data[y * out.y.width + x] - src.y.data[y * src.y.width + x]).abs();
                }
            }
            e / (w * h) as f32
        })
        .collect();
    // Thresholds are absolute, so how far down the slider blocks stay one
    // color depends on the content (this smooth texture stays one color up
    // to the middle). What holds for any picture: more quality never hurts,
    // and the slider spans a wide range.
    assert!(errors.windows(2).all(|p| p[0] >= p[1]), "{errors:?}");
    assert!(errors[0] > 2.0 * errors[3], "{errors:?}");
}

#[test]
fn lost_blocks_stay_stale_until_they_are_coded_again() {
    // Through the renderer, as the app runs it: a moving scene, keyframes
    // every 10 frames, heavy loss. Damage appears, and every keyframe (which
    // arrives whole) clears it.
    let mut clean = DigitalFormat::by_id("cd_rom").unwrap().settings();
    clean.set("frame_rate", 30.0);
    clean.set("keyframe_interval", 1.0 / 3.0);
    let mut lossy = clean.clone();
    lossy.set("data_loss", 0.8);
    let a = played(&clean, 21, None, None);
    let b = played(&lossy, 21, None, None);
    assert!(a[0] == b[0] && a[10] == b[10] && a[20] == b[20], "keyframes arrive whole");
    assert!((1..10).any(|n| a[n] != b[n]), "loss shows between keyframes");
}
