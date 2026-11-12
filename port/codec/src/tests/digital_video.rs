//! The Digital video stage: a real block codec, so the tests check codec
//! behavior — transforms, timing, the encoder/decoder split behind smearing
//! and datamoshing — and above all that a frame looks the same however it's
//! reached (played through, jumped to, re-run from a checkpoint).
//! (`DigitalVideoTests.swift`; pixels are RGBA here.)

use std::collections::{BTreeMap, HashSet};
use std::time::Instant;

use crate::codec::*;
use crate::params::*;
use crate::renderer::*;

// A synthetic clip: a textured background with a bright square moving right;
// `cut` switches to a different scene from that frame on.
pub(crate) const SIZE: (usize, usize) = (256, 192);
pub(crate) const CAPTURE: (usize, usize) = (128, 96);

pub(crate) fn frame(n: i64, cut: Option<i64>) -> Vec<u8> {
    let (w, h) = SIZE;
    let (wi, hi) = (w as i64, h as i64);
    let scene = if cut.is_some_and(|c| n >= c) { 1 } else { 0 };
    let mut px = vec![255u8; w * h * 4];
    for y in 0..hi {
        for x in 0..wi {
            let i = ((y * wi + x) * 4) as usize;
            let (mut r, mut g, mut b);
            if scene == 0 {
                r = (x * 255) / wi;
                g = ((x / 8 + y / 8) % 2) * 120 + 40;
                b = (y * 255) / hi;
            } else {
                r = 200 - (y * 150) / hi;
                g = ((x / 16) % 2) * 60 + 90;
                b = 60 + (x * 120) / wi;
            }
            let sx = 20 + 4 * n;
            let sy = 60 + 2 * n;
            if x >= sx && x < sx + 40 && y >= sy && y < sy + 40 {
                r = 250;
                g = 240;
                b = 30;
            }
            px[i] = r as u8;
            px[i + 1] = g as u8;
            px[i + 2] = b as u8;
        }
    }
    px
}

pub(crate) fn settings(format: &str, overrides: &[(&str, f64)]) -> DigitalSettings {
    let mut v = DigitalFormat::by_id(format).unwrap().values_map();
    for (k, x) in overrides {
        v.insert(k.to_string(), *x);
    }
    DigitalSettings::new(v)
}

pub(crate) fn s(values: &[(&str, f64)]) -> DigitalSettings {
    DigitalSettings::new(values.iter().map(|(k, v)| (*k, *v)))
}

pub(crate) fn render(r: &mut DigitalVideoRenderer, n: i64, s: &DigitalSettings, fps: f64, cut: Option<i64>, history: Option<&DigitalHistory>) -> Vec<u8> {
    let mut px = frame(n, cut);
    let mut visitor = |i: i64, body: &mut dyn FnMut(&[u8], usize, usize, usize)| {
        let f = frame(i, cut);
        body(&f, SIZE.0, SIZE.1, SIZE.0 * 4);
        true
    };
    r.process(n, &mut px, SIZE.0, SIZE.1, SIZE.0 * 4, CAPTURE, fps, s, history, Some(&mut visitor));
    px
}

pub(crate) fn played(s: &DigitalSettings, frames: i64, cut: Option<i64>, history: Option<&DigitalHistory>) -> Vec<Vec<u8>> {
    let mut r = DigitalVideoRenderer::new();
    (0..frames).map(|n| render(&mut r, n, s, 30.0, cut, history)).collect()
}

pub(crate) fn mean_difference(a: &[u8], b: &[u8]) -> f64 {
    let mut s = 0i64;
    for i in (0..a.len()).step_by(4) {
        for c in 0..3 {
            s += (a[i + c] as i64 - b[i + c] as i64).abs();
        }
    }
    s as f64 / (a.len() / 4 * 3) as f64
}

// MARK: - transforms

#[test]
fn dct_round_trip_is_identity() {
    let c = DigitalCodec::basis();
    let mut block = [0f32; 64];
    for (i, b) in block.iter_mut().enumerate() {
        *b = ((i * 37) % 255) as f32 - 128.0;
    }
    let mut coef = [0f32; 64];
    let mut back = [0f32; 64];
    let mut tmp = [0f32; 64];
    DigitalCodec::forward_dct(&block, 8, &mut coef, &mut tmp, &c);
    DigitalCodec::inverse_dct(&coef, &mut back, 8, &mut tmp, &c);
    for i in 0..64 {
        assert!((back[i] - block[i]).abs() <= 1e-3);
    }
    // Orthonormal: a flat block of 1s has DC 8 and nothing else.
    let flat = [1f32; 64];
    DigitalCodec::forward_dct(&flat, 8, &mut coef, &mut tmp, &c);
    assert!((coef[0] - 8.0).abs() <= 1e-4);
    assert!(coef[1..].iter().map(|v| v.abs()).fold(0f32, f32::max) <= 1e-4);
}

#[test]
fn lower_quality_loses_more_of_the_picture() {
    let clean = s(&[("frame_rate", 30.0), ("sensor_noise", 0.0), ("noise_reduction", 0.0), ("chroma", 0.0), ("keyframe_interval", 0.0), ("fields", 0.0)]);
    let mut errors = vec![];
    for q in [0.95, 0.6, 0.3, 0.05] {
        let mut st = clean.clone();
        st.set("quality", q);
        let out = render(&mut DigitalVideoRenderer::new(), 0, &st, 30.0, None, None);
        // Against the stage at its finest, with nothing else in play.
        errors.push(mean_difference(&out, &frame(0, None)));
    }
    let mut sorted = errors.clone();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    assert_eq!(errors, sorted, "quality {errors:?}");
    assert!(errors[0] < 6.0, "near-lossless at 95: {errors:?}");
    assert!(errors[3] > 3.0 * errors[0], "{errors:?}");
}

#[test]
fn quality_damage_is_evenly_spaced_along_the_slider() {
    // No cliff at the bottom, no dead zone at the top. (On a real photo the
    // steps are within 2× of each other — 16.2, 14.1 … 2.6, 1.0 per tenth;
    // this synthetic frame's hard edges and checkers drop extra in the
    // near-lossless last stretch, so the bound here is looser.)
    let clean = s(&[("frame_rate", 30.0), ("sensor_noise", 0.0), ("noise_reduction", 0.0), ("chroma", 0.0), ("keyframe_interval", 0.0)]);
    let errors: Vec<f64> = [0.0, 0.1, 0.25, 0.5, 0.75, 1.0]
        .iter()
        .map(|&q| {
            let mut st = clean.clone();
            st.set("quality", q);
            mean_difference(&render(&mut DigitalVideoRenderer::new(), 0, &st, 30.0, None, None), &frame(0, None))
        })
        .collect();
    let range = errors[0] - errors[errors.len() - 1];
    assert!(errors.windows(2).all(|p| p[0] > p[1]), "damage falls as quality rises: {errors:?}");
    assert!(errors[0] - errors[1] < 0.2 * range, "the bottom tenth isn't a cliff: {errors:?}");
    assert!(errors[3] - errors[5] > 0.25 * range, "the top half still does something: {errors:?}");
}

#[test]
fn old_quality_values_keep_their_quantizer() {
    for i in 0..=20 {
        let old = i as f64 * 0.05;
        let q = 2.0 + 93.0 * old;
        let old_scale = (if q < 50.0 { 5000.0 / q } else { 200.0 - 2.0 * q }) as f32 / 100.0;
        let new = DigitalCodec::quality_from_jpeg_scale(old);
        assert!((DigitalCodec::table_scale(new) - old_scale).abs() <= old_scale * 1e-4, "{old}");
    }
    let mut v = BTreeMap::new();
    v.insert("quality".to_string(), 0.22);
    let v1 = DigitalSettings::migrated(&v, 1)["quality"];
    assert!((v1 - 0.749).abs() <= 0.001);
    assert_eq!(DigitalSettings::migrated(&v, 2)["quality"], 0.22, "today's looks are left alone");
}

// MARK: - timing

#[test]
fn capture_timing_holds_frames_and_places_keyframes() {
    let t = DigitalTiming::new(30.0, &s(&[("frame_rate", 15.0), ("keyframe_interval", 2.0)]));
    assert_eq!((0..6).map(|n| t.capture_of_frame(n)).collect::<Vec<_>>(), vec![0, 0, 1, 1, 2, 2]);
    for c in 0..50 {
        assert_eq!(t.capture_of_frame(t.frame_of_capture(c)), c);
    }
    assert_eq!(t.keyframe_every, 30);
    assert_eq!(t.kind_of_capture(0, 1.0), CodecFrameKind::Key, "the first keyframe always arrives");
    assert_eq!(t.kind_of_capture(30, 1.0), CodecFrameKind::DroppedKey);
    assert_eq!(t.kind_of_capture(31, 1.0), CodecFrameKind::Predicted);
    // Never faster than the source; 0 s means every frame on its own.
    let fast = DigitalTiming::new(24.0, &s(&[("frame_rate", 60.0), ("keyframe_interval", 0.0)]));
    assert_eq!(fast.capture_fps, 24.0);
    assert!(fast.intra_only());
    assert_eq!((0..4).map(|n| fast.capture_of_frame(n)).collect::<Vec<_>>(), vec![0, 1, 2, 3]);
}

#[test]
fn lower_frame_rate_repeats_frames() {
    let out = played(&settings("webcam", &[("sensor_noise", 0.0)]), 4, None, None); // 15 fps of 30
    assert!(out[0] == out[1]);
    assert!(out[1] != out[2]);
    assert!(out[2] == out[3]);
}

// MARK: - the same frame however it's reached

fn check_jumps_match_playing(st: &DigitalSettings, frames: i64, cut: Option<i64>, history: Option<&DigitalHistory>, label: &str) {
    let straight = played(st, frames, cut, history);
    let mut jumper = DigitalVideoRenderer::new();
    for n in [frames - 1, 3, 27, 12, frames - 2, 0, 33] {
        if n < frames {
            assert!(render(&mut jumper, n, st, 30.0, cut, history) == straight[n as usize], "{label}: frame {n} jumped to");
        }
    }
    // A fresh renderer per frame too (nothing cached at all).
    for n in [5, 19, 36] {
        if n < frames {
            assert!(render(&mut DigitalVideoRenderer::new(), n, st, 30.0, cut, history) == straight[n as usize], "{label}: frame {n} fresh");
        }
    }
}

#[test]
fn every_format_looks_the_same_jumped_to_as_played() {
    for f in DigitalFormat::all() {
        let ki = f.values_map()["keyframe_interval"];
        check_jumps_match_playing(&settings(f.id, &[("keyframe_interval", ki.min(1.0))]), 40, Some(20), None, f.id);
    }
}

#[test]
fn data_loss_and_datamosh_look_the_same_jumped_to() {
    let st = s(&[("frame_rate", 30.0), ("keyframe_interval", 0.5), ("quality", 0.4), ("data_loss", 0.6), ("datamosh", 0.6),
                 ("sensor_noise", 0.2), ("noise_reduction", 0.3), ("deblocking", 0.5), ("fixed_bitrate", 0.5)]);
    check_jumps_match_playing(&st, 40, Some(16), None, "loss + mosh");
}

#[test]
fn keyframed_settings_look_the_same_jumped_to() {
    let base = settings("video_call", &[("keyframe_interval", 0.5), ("frame_rate", 30.0)]);
    let b = base.clone();
    let history = DigitalHistory::new(7, move |n| {
        let mut st = b.clone();
        st.set("quality", 0.1 + 0.02 * n as f64);
        st.set("data_loss", if n > 15 { 0.5 } else { 0.0 });
        st
    });
    check_jumps_match_playing(&base, 40, None, Some(&history), "keyframes");
}

#[test]
fn datamosh_checkpoints_spare_the_re_run() {
    let st = settings("datamosh", &[("keyframe_interval", 0.2)]); // keyframes every 6 frames, all lost
    let mut r = DigitalVideoRenderer::new();
    for n in 0..40 {
        render(&mut r, n, &st, 30.0, None, None);
    }
    render(&mut r, 3, &st, 30.0, None, None); // jump back...
    render(&mut r, 38, &st, 30.0, None, None); // ...and forward again
    assert!(r.last_run_length <= 6, "resumed from the checkpoint at 36, not from frame 0");
}

// MARK: - errors behave like a codec's

#[test]
fn lost_data_smears_until_the_next_keyframe() {
    let clean = settings("early_web", &[("keyframe_interval", 0.5), ("frame_rate", 30.0), ("fixed_bitrate", 0.0)]);
    let mut lossy = clean.clone();
    lossy.set("data_loss", 0.8);
    let a = played(&clean, 31, None, None);
    let b = played(&lossy, 31, None, None);
    // Keyframes at 0, 15, 30 arrive whole: the damage is gone there.
    assert!(a[0] == b[0], "frame 0");
    assert!(a[15] == b[15], "frame 15");
    assert!(a[30] == b[30], "frame 30");
    // Between them it lingers — and builds.
    assert!(mean_difference(&a[14], &b[14]) > 0.5);
    assert!(mean_difference(&a[14], &b[14]) > mean_difference(&a[2], &b[2]));
}

#[test]
fn dv_dropouts_last_one_frame() {
    let clean = settings("minidv", &[("sensor_noise", 0.0)]);
    let mut lossy = clean.clone();
    lossy.set("data_loss", 0.8);
    let a = played(&clean, 10, None, None);
    let b = played(&lossy, 10, None, None);
    let damaged: Vec<usize> = (1..10).filter(|&n| a[n] != b[n]).collect();
    assert!(!damaged.is_empty());
    // Each frame is coded alone: damage never exceeds a patch from the
    // previous frame (the moving square moves 4 px a frame).
    for n in damaged {
        assert!(mean_difference(&a[n], &b[n]) < 8.0, "frame {n}");
    }
}

#[test]
fn datamosh_drags_the_old_scene_across_a_cut() {
    let normal = settings("datamosh", &[("datamosh", 0.0), ("keyframe_interval", 0.5)]); // keys at 0, 15, 30
    let moshed = settings("datamosh", &[("datamosh", 1.0), ("keyframe_interval", 0.5)]);
    let cut = Some(15);
    let a = played(&normal, 25, cut, None);
    let b = played(&moshed, 25, cut, None);
    assert!(a[14] == b[14], "identical until the lost keyframe");
    // After the cut a normal decoder shows the new scene; the moshed one is
    // still mostly the old one.
    let new_scene = frame(20, cut);
    let old_scene = frame(20, None);
    assert!(mean_difference(&a[20], &new_scene) < mean_difference(&a[20], &old_scene));
    assert!(mean_difference(&b[20], &old_scene) < mean_difference(&b[20], &new_scene));
}

// MARK: - fitting into the chain

#[test]
fn nearest_downscale_gets_the_capture_picture_back() {
    for (w, h, cw, ch) in [(256usize, 192usize, 128usize, 96usize), (1000, 750, 320, 240), (480, 360, 320, 240), (333, 250, 320, 240)] {
        let pic: Vec<u8> = (0..cw * ch * 4).map(|i| ((i * 7919) % 251) as u8).collect();
        let mut big = vec![0u8; w * h * 4];
        DigitalVideoRenderer::upscale(&pic, (cw, ch), &mut big, w, h, w * 4);
        // The Downscaler's nearest kernel samples each pixel's center.
        for y in 0..ch {
            for x in 0..cw {
                let sx = ((x as f64 + 0.5) * w as f64 / cw as f64) as usize;
                let sy = ((y as f64 + 0.5) * h as f64 / ch as f64) as usize;
                let (s, d) = ((sy * w + sx) * 4, (y * cw + x) * 4);
                assert_eq!(&big[s..s + 4], &pic[d..d + 4], "{w}x{h}→{cw}x{ch} at {x},{y}");
            }
        }
    }
}

#[test]
fn capture_size_follows_the_downscale_rule() {
    assert_eq!(DigitalVideoRenderer::capture_size(1920, 1080, 320).1, 180);
    assert_eq!(DigitalVideoRenderer::capture_size(2048, 2048, 320).1, 320);
    assert_eq!(DigitalVideoRenderer::capture_size(200, 100, 720).0, 200, "never larger than the picture");
}

#[test]
fn quarter_wide_color_smears_sideways() {
    // 4:1:1 keeps a quarter of the color across, all of it down.
    let g = CodecGeometry::new(64, 64, ChromaSubsampling::QuarterWide);
    let mut px = vec![128u8; 64 * 64 * 4];
    for y in 0..64 {
        for x in 0..64 {
            if x % 4 < 2 {
                px[(y * 64 + x) * 4] = 255; // red stripes
            }
        }
    }
    let neutral = s(&[("sensor_noise", 0.0), ("noise_reduction", 0.0)]);
    let pic = DigitalVideoRenderer::capture(&px, &g, &neutral, 0);
    assert_eq!(pic.cr.width, 16);
    let row: Vec<f32> = (0..16).map(|i| pic.cr.data[i]).collect();
    let (mx, mn) = (row.iter().cloned().fold(f32::MIN, f32::max), row.iter().cloned().fold(f32::MAX, f32::min));
    assert!(mx - mn < 0.01, "stripes 2 px wide average out");
    let g2 = CodecGeometry::new(64, 64, ChromaSubsampling::Full);
    let full = DigitalVideoRenderer::capture(&px, &g2, &neutral, 0);
    assert!(full.cr.data[0] - full.cr.data[2] > 50.0);
}

#[test]
fn formats_are_recognized_by_their_values() {
    for f in DigitalFormat::all() {
        assert_eq!(DigitalFormat::matching(&f.values_map(), f.width).map(|m| m.id), Some(f.id));
    }
    let mut v = DigitalFormat::by_id("webcam").unwrap().values_map();
    v.insert("quality".into(), 0.9);
    assert!(DigitalFormat::matching(&v, 320).is_none());
}

// MARK: - the camera

/// A capture-size picture through the camera alone.
fn camera(px: &[u8], w: usize, h: usize, values: &[(&str, f64)]) -> CodecPicture {
    let mut v: Vec<(&str, f64)> = vec![("sensor_noise", 0.0), ("noise_reduction", 0.0), ("chroma", 0.0)];
    v.extend_from_slice(values);
    DigitalVideoRenderer::capture(px, &CodecGeometry::new(w, h, ChromaSubsampling::Full), &s(&v), 0)
}

#[test]
fn picture_controls_are_neutral_by_default() {
    let px = frame(0, None);
    // (Fields default to One field — the stage's look, not neutral — so
    // they're set to Progressive here.)
    let via_resampler = DigitalVideoRenderer::scale(&px, SIZE.0, SIZE.1, SIZE.0 * 4, CAPTURE, &s(&[("fields", 0.0)]));
    let small = DigitalVideoRenderer::scale(&px, SIZE.0, SIZE.1, SIZE.0 * 4, CAPTURE, &s(&[("aliasing", 0.0), ("fields", 0.0)]));
    assert!(small == via_resampler);
    let a = camera(&small, CAPTURE.0, CAPTURE.1, &[]);
    let b = camera(&small, CAPTURE.0, CAPTURE.1, &[("ccd_response", 0.0), ("white_balance", 0.0), ("tint", 0.0), ("saturation", 1.0), ("sharpening", 0.0)]);
    assert_eq!(a.y.data[500], b.y.data[500]);
    assert_eq!(a.cr.data[777], b.cr.data[777]);
    // And neutral really is the picture as it came in.
    let i = 500;
    let (r0, g0, b0) = (small[i * 4] as f32, small[i * 4 + 1] as f32, small[i * 4 + 2] as f32);
    let y = a.y.data[(i / CAPTURE.0) * a.y.width + i % CAPTURE.0];
    assert!((y - (0.299 * r0 + 0.587 * g0 + 0.114 * b0)).abs() <= 0.01);
}

/// RGB back from a picture's first pixel (full color resolution).
fn rgb(p: &CodecPicture, k: usize) -> (f32, f32, f32) {
    let (y, cb, cr) = (p.y.data[k], p.cb.data[k] - 128.0, p.cr.data[k] - 128.0);
    (y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb)
}

fn patch(c: (u8, u8, u8), n: usize) -> Vec<u8> {
    (0..n * n).flat_map(|_| [c.0, c.1, c.2, 255]).collect()
}

#[test]
fn ccd_response_clips_warm_highlights_red_first() {
    // A warm wall in sun, in the corner of a darker frame the camera exposes
    // for: red hits white while blue is still well under it.
    let mut px = patch((70, 70, 70), 32);
    for y in 0..6 {
        for x in 0..6 {
            let i = (y * 32 + x) * 4;
            px[i] = 215;
            px[i + 1] = 170;
            px[i + 2] = 120;
        }
    }
    let out = rgb(&camera(&px, 32, 32, &[("ccd_response", 1.0)]), 0);
    assert!((out.0 - 255.0).abs() <= 1.5, "red clipped");
    assert!(out.2 < 225.0, "blue under the clip: {out:?}");
    assert!(out.1 > 200.0);
}

#[test]
fn ccd_response_lifts_blacks_and_exposes_dark_scenes_up() {
    // Black stays gray-lifted (setup + flare), a dark scene is pushed up by
    // auto exposure, and the result never goes past white.
    let mut px = patch((0, 0, 0), 32);
    for i in (0..px.len() / 2).step_by(4) {
        px[i] = 60;
        px[i + 1] = 60;
        px[i + 2] = 60;
    }
    let dark = camera(&px, 32, 32, &[("ccd_response", 1.0)]);
    let black_y = dark.y.data[31 * dark.y.width + 5];
    assert!(black_y > 15.0, "black lifted");
    assert!(black_y < 45.0, "but not washed out");
    assert!(dark.y.data[2 * dark.y.width + 5] > 90.0, "60 gray exposed up: {}", dark.y.data[2 * dark.y.width + 5]);
    let half = camera(&px, 32, 32, &[("ccd_response", 0.5)]);
    assert!(half.y.data[31 * half.y.width + 5] < black_y, "strength scales it");
    let white = rgb(&camera(&patch((250, 250, 250), 32), 32, 32, &[("ccd_response", 1.0)]), 0);
    assert!(white.0.max(white.1).max(white.2) <= 255.6);
}

fn edge_picture(w: usize, h: usize) -> Vec<u8> {
    let mut px = vec![255u8; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            for c in 0..3 {
                px[(y * w + x) * 4 + c] = if x < 16 { 40 } else { 200 };
            }
        }
    }
    px
}

#[test]
fn sharpening_overshoots() {
    let (w, h) = (32, 16);
    let px = edge_picture(w, h);
    let sharp = camera(&px, w, h, &[("sharpening", 1.0)]);
    let row: Vec<f32> = (0..w).map(|x| sharp.y.data[8 * sharp.y.width + x]).collect();
    assert!(row[15] < 35.0, "dark halo before the edge: {:?}", &row[13..=18]);
    assert!(row[16] > 205.0, "bright halo after it");
    assert!((row[2] - 40.0).abs() <= 0.6, "flat areas untouched");
}

#[test]
fn frame_rate_is_whole_frames() {
    let t = DigitalTiming::new(30.0, &s(&[("frame_rate", 29.1)]));
    assert_eq!(t.capture_fps, 29.0);
    assert_eq!(DigitalTiming::new(30.0, &s(&[("frame_rate", 29.6)])).capture_fps, 30.0);
    assert_eq!(DigitalParam::by_id("frame_rate").unwrap().step, Some(1.0));
    assert_eq!(DigitalParam::starting_values()["frame_rate"], 30.0);
}

#[test]
fn halo_width() {
    let (w, h) = (32, 16);
    let px = edge_picture(w, h);
    let row = |p: &CodecPicture| -> Vec<f32> { (0..w).map(|x| p.y.data[8 * p.y.width + x]).collect() };
    let tight = camera(&px, w, h, &[("sharpening", 1.0)]);
    assert_eq!(row(&camera(&px, w, h, &[("sharpening", 1.0), ("sharpening_width", 1.0)])), row(&tight), "1 px is the sharpening as it always was");
    assert!((row(&tight)[13] - 40.0).abs() <= 0.6, "a 1 px halo doesn't reach 3 px out");
    let wide = row(&camera(&px, w, h, &[("sharpening", 1.0), ("sharpening_width", 3.0)]));
    assert!(wide[13] < 30.0, "a 3 px halo does: {:?}", &wide[10..=21]);
    assert!(wide[18] > 210.0);
    assert!((wide[2] - 40.0).abs() <= 0.6, "flat areas untouched");
    let between = row(&camera(&px, w, h, &[("sharpening", 1.0), ("sharpening_width", 2.5)]));
    assert!(between[13] < 40.0 - 0.6);
    assert!(between[13] > wide[13], "fractional widths fall between");
}

#[test]
fn low_light_noise_grows_in_the_dark() {
    let (w, h) = (64usize, 32usize);
    let flat = |v: u8| -> Vec<u8> {
        let mut px = vec![255u8; w * h * 4];
        for i in 0..w * h {
            for c in 0..3 {
                px[i * 4 + c] = v;
            }
        }
        px
    };
    let spread = |p: &CodecPicture| -> f32 {
        let ys: Vec<f32> = (0..h).flat_map(|y| (0..w).map(move |x| (y, x))).map(|(y, x)| p.y.data[y * p.y.width + x]).collect();
        let mean = ys.iter().sum::<f32>() / ys.len() as f32;
        (ys.iter().map(|v| (v - mean) * (v - mean)).sum::<f32>() / ys.len() as f32).sqrt()
    };
    let (night, day) = (flat(25), flat(180));
    let plain = spread(&camera(&night, w, h, &[("sensor_noise", 0.1)]));
    let gained = spread(&camera(&night, w, h, &[("sensor_noise", 0.1), ("low_light_noise", 1.0)]));
    assert!(gained > plain * 3.0, "a dark scene gets the gain's noise: {plain} → {gained}");
    // Grain, not streaks: nearby rows' noise is unrelated at any shift.
    let p = camera(&night, w, h, &[("sensor_noise", 0.1), ("low_light_noise", 1.0)]);
    let ys: Vec<Vec<f32>> = (0..h).map(|y| (0..w).map(|x| p.y.data[y * p.y.width + x]).collect()).collect();
    let mean = ys.iter().flatten().sum::<f32>() / (w * h) as f32;
    let mut worst = 0f32;
    for k in 1..=8usize {
        for d in -3isize..=3 {
            let (mut sab, mut saa, mut sbb) = (0f32, 0f32, 0f32);
            for y in 0..(h - k) {
                for x in 3..(w - 3) {
                    let a = ys[y][x] - mean;
                    let b = ys[y + k][(x as isize + d) as usize] - mean;
                    sab += a * b;
                    saa += a * a;
                    sbb += b * b;
                }
            }
            worst = worst.max((sab / (saa * sbb).sqrt()).abs());
        }
    }
    assert!(worst < 0.2, "rows repeat nearby rows, shifted");
    // A flash-lit night shot: a bright subject filling the middle of a black
    // frame still reads as night (the exposure meter wouldn't).
    let mut lit = flat(20);
    for y in 0..h {
        for x in 0..w {
            if (x as isize - w as isize / 2).abs() < 14 {
                for c in 0..3 {
                    lit[(y * w + x) * 4 + c] = 235;
                }
            }
        }
    }
    assert!(DigitalVideoRenderer::metered_mean(&lit, w, h, (1.0, 1.0, 1.0)) > DigitalVideoRenderer::gain_knee(), "the scenario: meters as bright");
    assert!(DigitalVideoRenderer::sensor_gain(DigitalVideoRenderer::median_luma(&lit, w, h)) > 4.0);
    let half = spread(&camera(&night, w, h, &[("sensor_noise", 0.1), ("low_light_noise", 0.5)]));
    assert!(half > plain && half < gained);
    assert!(
        camera(&day, w, h, &[("sensor_noise", 0.1)]).y.data == camera(&day, w, h, &[("sensor_noise", 0.1), ("low_light_noise", 1.0)]).y.data,
        "daylight needs no gain"
    );
    assert!(camera(&night, w, h, &[("low_light_noise", 1.0)]).y.data == camera(&night, w, h, &[]).y.data, "nothing without sensor noise");
}

/// Fine gray stripes, finer than a 160-wide camera can hold.
fn stripes(w: usize, h: usize, period: f64) -> Vec<u8> {
    let mut px = vec![255u8; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            let v = (128.0 + 100.0 * (2.0 * std::f64::consts::PI * x as f64 / period).cos()) as u8;
            for c in 0..3 {
                px[(y * w + x) * 4 + c] = v;
            }
        }
    }
    px
}

fn sampled(px: &[u8], aliasing: f64) -> Vec<u8> {
    DigitalVideoRenderer::scale(px, 640, 64, 640 * 4, (160, 16), &s(&[("aliasing", aliasing)]))
}

#[test]
fn aliasing_turns_fine_stripes_into_false_color() {
    let chroma = |aliasing: f64| -> f32 {
        let pic = camera(&sampled(&stripes(640, 64, 7.0 / 3.0), aliasing), 160, 16, &[]);
        let mut sum = 0f32;
        for i in 0..160 * 16 {
            sum += (pic.cb.data[i] - 128.0).abs() + (pic.cr.data[i] - 128.0).abs();
        }
        sum / (160 * 16) as f32
    };
    assert!(chroma(0.0) < 2.0, "filtered properly: gray stays gray");
    assert!(chroma(0.5) > 20.0, "aliased: false color");
    assert!(chroma(1.0) > chroma(0.5) * 1.2, "above 50% the boost makes it stronger");
}

#[test]
fn aliasing_rainbows_survive_quarter_width_color() {
    // Stripes just off the sensor's own pitch (4 source px per capture px
    // here) beat slowly: the false color there has to turn through every
    // hue, and survive DV's 4:1:1 averaging.
    let px = stripes(640, 64, 4.0 * 1.04);
    let small = sampled(&px, 1.0);
    let pic = DigitalVideoRenderer::capture(
        &small,
        &CodecGeometry::new(160, 16, ChromaSubsampling::QuarterWide),
        &s(&[("sensor_noise", 0.0), ("noise_reduction", 0.0)]),
        0,
    );
    let mut quadrants = HashSet::new();
    let mut strength = 0f32;
    for x in 0..pic.cb.width - 2 {
        let cb = pic.cb.data[4 * pic.cb.width + x] - 128.0;
        let cr = pic.cr.data[4 * pic.cr.width + x] - 128.0;
        strength += cb.abs() + cr.abs();
        if cb.abs() + cr.abs() > 8.0 {
            quadrants.insert((if cb >= 0.0 { 1 } else { 0 }) + (if cr >= 0.0 { 2 } else { 0 }));
        }
    }
    assert_eq!(quadrants.len(), 4, "hue goes all the way round: {quadrants:?}");
    assert!(strength / (pic.cb.width - 2) as f32 > 15.0);
}

#[test]
fn one_field_doubles_every_other_line() {
    let small = DigitalVideoRenderer::scale(&frame(3, None), SIZE.0, SIZE.1, SIZE.0 * 4, CAPTURE, &s(&[("fields", 1.0)]));
    let rb = CAPTURE.0 * 4;
    for y in (0..CAPTURE.1 - 1).step_by(2) {
        assert!(small[y * rb..(y + 1) * rb] == small[(y + 1) * rb..(y + 2) * rb]);
    }
}

// MARK: - cost

#[test]
fn codec_is_fast_enough_for_playback() {
    let per_frame = |format: &str, width: usize, height: usize| -> f64 {
        let mut r = DigitalVideoRenderer::new();
        let st = settings(format, &[("frame_rate", 30.0)]);
        let mut px: Vec<u8> = (0..1280 * 720 * 4).map(|i: usize| ((i * 31 + i / 5000) & 255) as u8).collect();
        let t0 = Instant::now();
        for n in 0..20 {
            r.process(n, &mut px, 1280, 720, 1280 * 4, (width, height), 30.0, &st, None, None);
        }
        t0.elapsed().as_secs_f64() / 20.0 * 1000.0
    };
    let call = per_frame("video_call", 320, 180);
    let dv = per_frame("minidv", 720, 404);
    println!("DIGITAL-PERF video call 320: {call:.1} ms/frame, MiniDV 720: {dv:.1} ms/frame (from 1280×720)");
    // Only an optimized build on a real machine says anything about real
    // cost: CI's shared runners measure 38 and 56 ms (it still prints).
    if !cfg!(debug_assertions) && std::env::var_os("CI").is_none() {
        assert!(call < 30.0);
        assert!(dv < 40.0);
    }
}
