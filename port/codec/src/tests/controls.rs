//! The controls added in 0.28: both fields of an interlaced camera, the
//! one-chip sensors and their grain, vertical smear, blocky color decode, DV
//! tape loss patterns, what lost blocks show, bit errors, added motion,
//! block size, the Bitrate limit with its Buffer, Generations, and CCD
//! response in its four parts. (`DigitalVideoControlsTests.swift`,
//! `DigitalVideoRateTests.swift` and `DigitalVideoCameraTests.swift`; the
//! Mac's own run of these, bit for bit, is `examples/parity.rs`.)

use super::digital_video::{camera, check_jumps_match_playing, frame, mean_difference, played, s, settings, CAPTURE, SIZE};
use crate::codec::*;
use crate::params::*;
use crate::renderer::*;

/// The picture the stage shows, at the capture size.
fn shrunk(px: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; CAPTURE.0 * CAPTURE.1 * 4];
    let k = SIZE.0 / CAPTURE.0;
    for y in 0..CAPTURE.1 {
        for x in 0..CAPTURE.0 {
            let from = ((y * k) * SIZE.0 + x * k) * 4;
            let to = (y * CAPTURE.0 + x) * 4;
            out[to..to + 4].copy_from_slice(&px[from..from + 4]);
        }
    }
    out
}

fn picture(w: usize, h: usize, color: impl Fn(usize, usize) -> (u8, u8, u8)) -> Vec<u8> {
    let mut px = vec![255u8; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            let c = color(x, y);
            let i = (y * w + x) * 4;
            px[i] = c.0;
            px[i + 1] = c.1;
            px[i + 2] = c.2;
        }
    }
    px
}

fn spread(px: &[u8], x: usize, y: usize, w: usize) -> i32 {
    let i = (y * w + x) * 4;
    let c = [px[i] as i32, px[i + 1] as i32, px[i + 2] as i32];
    c.iter().max().unwrap() - c.iter().min().unwrap()
}

fn clean(more: &[(&str, f64)]) -> DigitalSettings {
    let mut v = vec![
        ("frame_rate", 30.0),
        ("fields", 0.0),
        ("sensor_noise", 0.0),
        ("noise_reduction", 0.0),
        ("quality", 0.9),
        ("chroma", 2.0),
        ("keyframe_interval", 0.0),
    ];
    v.extend_from_slice(more);
    s(&v)
}

// MARK: - neutral by default

#[test]
fn new_controls_start_neutral() {
    let d = DigitalSettings::default();
    for id in ["sensor", "smear", "chroma_upsampling", "loss_pattern", "concealment", "bit_errors", "mosh_motion", "bitrate_limit", "generations"] {
        assert_eq!(d.get(id), 0.0, "{id}");
    }
    assert_eq!(d.block_size(), 8);
    assert_eq!(d.bits_per_pixel(), 0.0);
    assert_eq!(d.generations(), 0);
    assert!(d.bitrate_label(320, 240, 30.0).is_none());
    for f in DigitalFormat::all() {
        let fs = f.settings();
        assert_eq!(fs.block_size(), 8, "{}", f.id);
        assert_eq!(fs.sensor(), SensorKind::ThreeChips, "{}", f.id);
        assert!(DigitalFormat::matching(&fs.values, f.width).is_some(), "{}", f.id);
    }
    // Video 1 has neither blocks to resize nor bits to count.
    let v1 = clean(&[("codec", 1.0), ("block_size", 2.0), ("bitrate_limit", 0.8)]);
    assert_eq!(v1.block_size(), 8);
    assert_eq!(v1.bits_per_pixel(), 0.0);
}

#[test]
fn the_stage_starts_as_a_minidv_camcorder() {
    let start = DigitalSettings::new(DigitalParam::starting_values());
    assert_eq!(start.sensor(), SensorKind::Complementary);
    assert_eq!(start.chroma(), ChromaSubsampling::QuarterWide);
    assert_eq!(start.codec(), DigitalCodecKind::Dct);
    assert_eq!(start.fields(), FieldMode::OneField);
    assert_eq!(start.get("chroma_upsampling"), 1.0);
    assert_eq!(start.get("frame_rate"), 24.0);
    assert!((start.get("ccd_response") - 0.1615).abs() < 1e-3);
    for p in DigitalParam::all() {
        let v = DigitalParam::starting_values()[p.id];
        match p.kind {
            DigitalParamKind::Slider { min, max, .. } => assert!((min..=max).contains(&v), "{}", p.id),
            DigitalParamKind::Choice(names) => assert!((0..names.len()).contains(&(v as usize)), "{}", p.id),
        }
    }
    assert_eq!(DigitalParam::default_values()["sensor"], 0.0);
}

// MARK: - fields and sensors

#[test]
fn woven_fields_take_alternate_lines_from_two_moments() {
    let (w, h) = (16, 8);
    let now = picture(w, h, |_, _| (200, 200, 200));
    let before = picture(w, h, |_, _| (40, 40, 40));
    let woven = DigitalVideoRenderer::fields(&now, Some(&before), (w, h), FieldMode::Woven);
    for y in 0..h {
        assert_eq!(woven[y * w * 4], if y % 2 == 0 { 200 } else { 40 }, "line {y}");
    }
    let blended = DigitalVideoRenderer::fields(&now, Some(&before), (w, h), FieldMode::Blended);
    assert_eq!(blended[3 * w * 4], 120, "(200 + 2 × 40 + 200 + 2) / 4");
    // A still has no earlier moment: whole.
    assert_eq!(DigitalVideoRenderer::fields(&now, None, (w, h), FieldMode::Woven), now);
}

#[test]
fn complementary_filters_get_flat_color_right_and_fringe_edges() {
    for color in [(200u8, 120u8, 40u8), (30, 30, 30), (255, 255, 255), (0, 180, 255)] {
        let flat = picture(32, 24, |_, _| color);
        let mut out = flat.clone();
        DigitalVideoRenderer::complementary(&mut out, 32, 24);
        assert_eq!(out, flat, "{color:?}");
    }
    // Color comes a line late: a gray edge down the picture gets a colored
    // fringe, and nothing changes away from it.
    let (w, h) = (32, 32);
    let mut out = picture(w, h, |_, y| if y < 15 { (40, 40, 40) } else { (210, 210, 210) });
    DigitalVideoRenderer::complementary(&mut out, w, h);
    let mut fringe = 0;
    for y in 0..h {
        let sp = spread(&out, 10, y, w);
        if (12..=17).contains(&y) {
            fringe = fringe.max(sp);
        } else {
            assert!(sp <= 1, "line {y}");
        }
    }
    assert!(fringe > 40);
    // A sharp edge across the line picks up false color too.
    let mut out = picture(w, 24, |x, _| if x < 15 { (40, 40, 40) } else { (210, 210, 210) });
    DigitalVideoRenderer::complementary(&mut out, w, 24);
    let across = (0..w).map(|x| spread(&out, x, 12, w)).max().unwrap();
    assert!(across > 25);
}

#[test]
fn one_chip_grain_is_blotchy_in_color() {
    let (w, h) = (96, 64);
    let (r, g, b) = DigitalVideoRenderer::sensor_grain(SensorKind::Complementary, w, h, 7).unwrap();
    let correlation = |dx: usize, dy: usize| -> f32 {
        let (mut ab, mut aa, mut bb) = (0f32, 0f32, 0f32);
        for y in 4..(h - 4) {
            for x in 4..(w - 4) {
                let a = r[y * w + x] - g[y * w + x];
                let c = r[(y + dy) * w + x + dx] - g[(y + dy) * w + x + dx];
                ab += a * c;
                aa += a * a;
                bb += c * c;
            }
        }
        ab / (aa * bb).sqrt()
    };
    assert!(correlation(1, 0) > 0.5, "blotches along the line");
    assert!(correlation(0, 2) > 0.2, "shared with the field's next line");
    assert!(correlation(0, 1).abs() < 0.15, "not with the other field's");
    let mut power = 0f32;
    for i in 0..(w * h) {
        let l = 0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i];
        power += l * l;
    }
    assert!(DigitalVideoRenderer::PHOTOSITE_NOISE * (power / (w * h) as f32).sqrt() < 7.0, "weaker brightness grain than three chips");
    assert!(DigitalVideoRenderer::sensor_grain(SensorKind::ThreeChips, w, h, 7).is_none());
    assert_eq!(DigitalVideoRenderer::sensor_grain(SensorKind::Complementary, w, h, 7).unwrap().0, r);
}

#[test]
fn smear_streaks_the_columns_of_bright_spots() {
    let (w, h) = (64, 48);
    let px = picture(w, h, |x, y| if (30..34).contains(&x) && (20..24).contains(&y) { (255, 255, 255) } else { (10, 10, 14) });
    let smear = DigitalVideoRenderer::smear(&px, w, h, 1.0).unwrap();
    assert!(smear[31] > 0.05);
    assert_eq!(smear[5], 0.0);
    assert!(DigitalVideoRenderer::smear(&px, w, h, 0.0).is_none());
}

// MARK: - CCD response

#[test]
fn ccd_response_is_four_parts_and_leaves_night_dark() {
    let camera_full = CcdResponse::new(1.0);
    // Auto exposure opens up only as far as the gain the camera has left.
    assert!((camera_full.exposure_gain(0.02, 1.0) - 4.0).abs() < 1e-4);
    assert!((camera_full.exposure_gain(0.02, 8.0) - 1.0).abs() < 1e-4);
    assert!((camera_full.exposure_gain(0.02, 4.0) - 2.0).abs() < 1e-4);
    assert!((camera_full.exposure_gain(0.8, 8.0) - 0.5).abs() < 1e-4);
    // Levels are DV's range shown as stored.
    assert_eq!(camera_full.black(), 16.0);
    assert!((camera_full.black() + 255.0 * camera_full.luma_scale() - 255.0).abs() < 1e-3);
    assert!((camera_full.black() + 255.0 / 1.09 * camera_full.luma_scale() - 235.0).abs() < 0.3);
    assert!((127.5 * camera_full.chroma_scale() - 1.09 * 112.0).abs() < 0.1);
    // The source's white is taken to be at this camera's clip.
    assert!((camera_full.clip_light() - 2.37).abs() < 0.02);
    assert_eq!(camera_full.recovered(255.0, 255.0), camera_full.clip_light());
    assert_eq!(camera_full.recovered(230.0, 230.0), 1.0);
    assert!((camera_full.recovered(255.0, 30.0) - 1.0).abs() < 0.03);
    // The parts are separate.
    let mut only_levels = CcdResponse::new(0.0);
    assert!(!only_levels.is_on());
    only_levels.levels = 1.0;
    assert_eq!(only_levels.exposure_gain(0.05, 1.0), 1.0);
    assert_eq!(only_levels.knee(240.0), 240.0);
    assert_eq!(only_levels.flare_light(0.5), 0.0);
    // A night scene stays night; its lamp stays white.
    let night = picture(64, 48, |x, y| {
        let (dx, dy) = (x as i32 - 32, y as i32 - 20);
        if dx * dx + dy * dy < 9 { (255, 250, 230) } else { (12, 12, 18) }
    });
    let out = camera(&night, 64, 48, &[("ccd_response", 1.0)]);
    let dark = out.y.data[40 * out.y.width + 6];
    assert!(dark < 40.0 && dark > 20.0, "{dark}");
    assert!(out.y.data[20 * out.y.width + 32] > 240.0);
}

// MARK: - errors

#[test]
fn dv_tracks_lie_over_five_rectangles_and_tape_reads_clean_now_and_then() {
    let g = CodecGeometry::new(720, 480, ChromaSubsampling::QuarterWide);
    let mut lost = vec![false; g.mb_count()];
    DigitalCodec::lose_dv_stretch(3, 0.0, 1.0, &g, &mut lost);
    let mut columns = std::collections::HashSet::new();
    for i in 0..g.mb_count() {
        if lost[i] {
            columns.insert((i % g.mb_cols()) / 9);
        }
    }
    assert_eq!(columns.len(), 5);
    assert_eq!(lost.iter().filter(|&&l| l).count(), 5 * 27);
    for pattern in [LossPattern::DvTape, LossPattern::CloggedHead] {
        assert!(DigitalCodec::lost_blocks(1.0, 48, &g, pattern).is_none(), "a clean read");
        assert!(DigitalCodec::lost_blocks(1.0, 5, &g, pattern).is_some());
    }
    // A clogged head only ever touches every other band.
    let mask = DigitalCodec::lost_blocks(1.0, 7, &g, LossPattern::CloggedHead).unwrap();
    for i in 0..g.mb_count() {
        if mask[i] {
            assert_eq!((i / g.mb_cols()) / 3 % 2, 1);
        }
    }
}

#[test]
fn concealment_fills_lost_blocks() {
    let g = CodecGeometry::new(64, 64, ChromaSubsampling::Full);
    let mut lost = vec![false; g.mb_count()];
    lost[g.mb_cols() + 1] = true;
    for (mode, want) in [(Concealment::Gray, 128.0f32), (Concealment::Green, 0.0)] {
        let mut p = CodecPicture::new(&g);
        p.y.data.fill(77.0);
        DigitalCodec::conceal(&mut p, &lost, mode, &g);
        assert_eq!(p.y.data[20 * g.luma_w() + 20], want);
        assert_eq!(p.y.data[20 * g.luma_w() + 40], 77.0);
    }
    let mut p = CodecPicture::new(&g);
    for y in 0..g.luma_h() {
        for x in 0..g.luma_w() {
            p.y.data[y * g.luma_w() + x] = y as f32;
        }
    }
    DigitalCodec::conceal(&mut p, &lost, Concealment::Stretched, &g);
    assert_eq!(p.y.data[25 * g.luma_w() + 20], 15.0, "the row above, pulled down");
}

#[test]
fn bit_errors_and_added_motion_come_and_go_with_their_controls() {
    let g = CodecGeometry::new(320, 240, ChromaSubsampling::HalfBoth);
    assert!(DigitalCodec::bit_errors(0.0, 3, &g).is_empty());
    assert!(!DigitalCodec::bit_errors(1.0, 3, &g).is_empty());
    assert_eq!(DigitalCodec::bit_errors(1.0, 3, &g), DigitalCodec::bit_errors(1.0, 3, &g));
    assert!(DigitalCodec::added_motion(0, 1.0, 5, &g).is_none());
    assert!(DigitalCodec::added_motion(1, 0.0, 5, &g).is_none());
    let pan = DigitalCodec::added_motion(1, 1.0, 5, &g).unwrap();
    assert!(pan.iter().all(|v| v.dx == -8 && v.dy == 0), "width / 40 a frame");
    // A slow speed moves on some frames and not others, and averages out.
    let total: i32 = (1..=40).map(|k| DigitalCodec::added_motion(1, 0.1, k, &g).map_or(0, |v| v[0].dx)).sum();
    assert_eq!(total, -32);
}

#[test]
fn added_motion_melts_a_still_until_the_next_keyframe() {
    let st = clean(&[("keyframe_interval", 1.0), ("mosh_motion", 1.0), ("mosh_speed", 1.0)]);
    let plain = clean(&[("keyframe_interval", 1.0)]);
    let still = frame(0, None);
    let run = |settings: &DigitalSettings| -> Vec<Vec<u8>> {
        let mut r = DigitalVideoRenderer::new();
        (0..32)
            .map(|n| {
                let mut px = still.clone();
                r.process(n, &mut px, SIZE.0, SIZE.1, SIZE.0 * 4, CAPTURE, 30.0, settings, None, None);
                px
            })
            .collect()
    };
    let (moved, kept) = (run(&st), run(&plain));
    assert!(mean_difference(&moved[20], &kept[20]) > 5.0);
    assert!(mean_difference(&moved[25], &kept[25]) > mean_difference(&moved[5], &kept[5]));
    assert_eq!(moved[30], kept[30], "the keyframe puts it right");
}

// MARK: - block size

#[test]
fn every_block_size_transforms_there_and_back() {
    for n in [4usize, 8, 16] {
        let block: Vec<f32> = (0..n * n).map(|i| ((i * 37) % 255) as f32 - 128.0).collect();
        let (mut coef, mut back, mut tmp) = (vec![0f32; n * n], vec![0f32; n * n], vec![0f32; n * n]);
        let c = DigitalCodec::basis_n(n);
        DigitalCodec::forward_dct(&block, n, &mut coef, &mut tmp, &c, n);
        DigitalCodec::inverse_dct(&coef, &mut back, n, &mut tmp, &c, n);
        for i in 0..n * n {
            assert!((back[i] - block[i]).abs() < 2e-3, "{n}");
        }
        let flat = vec![1f32; n * n];
        DigitalCodec::forward_dct(&flat, n, &mut coef, &mut tmp, &c, n);
        assert!((coef[0] - n as f32).abs() < 1e-4);
        assert!(coef[1..].iter().all(|v| v.abs() < 1e-4));
    }
}

#[test]
fn block_size_scales_the_whole_structure() {
    for (n, cols, rows) in [(4usize, 16usize, 12usize), (8, 8, 6), (16, 4, 3)] {
        let g = CodecGeometry::with_block(128, 96, ChromaSubsampling::HalfBoth, n);
        assert_eq!(g.mb(), 2 * n);
        assert_eq!((g.mb_cols(), g.mb_rows()), (cols, rows));
        assert_eq!(g.luma_w() % (2 * n), 0);
        assert_eq!(g.chroma_w() % n, 0);
    }
    let odd = CodecGeometry::with_block(100, 50, ChromaSubsampling::QuarterWide, 16);
    assert_eq!((odd.luma_w(), odd.luma_h(), odd.chroma_w()), (128, 64, 32));
    let usual = CodecGeometry::new(100, 50, ChromaSubsampling::QuarterWide);
    assert_eq!((usual.block, usual.luma_w(), usual.chroma_w()), (8, 112, 32));
    // Coded hard, a smooth picture's steps fall on the block edges.
    for n in [4usize, 8, 16] {
        let g = CodecGeometry::with_block(128, 96, ChromaSubsampling::Full, n);
        let mut src = CodecPicture::new(&g);
        for y in 0..g.luma_h() {
            for x in 0..g.luma_w() {
                let (dx, dy) = (x as f32 - 0.43 * g.luma_w() as f32, y as f32 - 0.57 * g.luma_h() as f32);
                src.y.data[y * g.luma_w() + x] = 40.0 + 0.9 * x as f32 + 0.6 * y as f32 + 70.0 * (-(dx * dx + dy * dy) / 900.0).exp();
            }
        }
        let mut out = CodecPicture::new(&g);
        DigitalCodec::code_intra(&src, &mut out, &Steps::with_block(0.05, 1.0, n));
        let (mut on_edge, mut edges, mut inside, mut insides) = (0f32, 0, 0f32, 0);
        for y in 0..g.luma_h() {
            for x in 1..g.luma_w() {
                let jump = (out.y.data[y * g.luma_w() + x] - out.y.data[y * g.luma_w() + x - 1]).abs();
                if x % n == 0 {
                    on_edge += jump;
                    edges += 1;
                } else {
                    inside += jump;
                    insides += 1;
                }
            }
        }
        assert!(on_edge / edges as f32 > 4.0 * inside / insides as f32, "{n} px");
    }
}

// MARK: - the bitrate limit

#[test]
fn fitting_finds_the_finest_quantizer_within_the_budget() {
    let g = CodecGeometry::new(128, 96, ChromaSubsampling::HalfBoth);
    let src = DigitalVideoRenderer::capture(&shrunk(&frame(3, None)), &g, &clean(&[]), 0);
    let coefs = DigitalCodec::coefficients(&src, None, &g);
    let start = Steps::new(0.9, 1.0);
    let full = DigitalCodec::bits(&coefs, &start, true);
    let (easy, easy_bits) = DigitalCodec::fit(&coefs, start.clone(), true, full as f64 * 1.5);
    assert_eq!((easy.scale, easy_bits), (start.scale, full));
    let (half, half_bits) = DigitalCodec::fit(&coefs, start.clone(), true, full as f64 / 2.0);
    assert!(half.scale > start.scale && half_bits <= full / 2 && half_bits > full / 3);
    let (none, _) = DigitalCodec::fit(&coefs, start, true, 10.0);
    assert_eq!(none.scale, DigitalCodec::COARSEST_SCALE);
    // A difference of nothing costs nothing; a finer quantizer costs more.
    let nothing = DigitalCodec::coefficients(&src, Some(&src), &g);
    assert_eq!(DigitalCodec::bits(&nothing, &Steps::new(0.9, 1.0), false), 0);
    assert!(DigitalCodec::bits(&coefs, &Steps::from_scale(0.5, 8), true) > DigitalCodec::bits(&coefs, &Steps::from_scale(2.0, 8), true));
}

#[test]
fn bitrate_label_is_the_real_rate() {
    let st = clean(&[("bitrate_limit", 0.5), ("frame_rate", 15.0)]);
    assert!((st.bits_per_pixel() - 0.14142).abs() < 1e-4);
    assert_eq!(st.bitrate_label(320, 240, 30.0).as_deref(), Some("≈ 163 kbps at 320 × 240, 15 fps"));
    assert_eq!(clean(&[("bitrate_limit", 0.05)]).bitrate_label(720, 480, 30.0).as_deref(), Some("≈ 16 Mbps at 720 × 480, 30 fps"));
    assert!((clean(&[("bitrate_limit", 1.0)]).bits_per_pixel() - 0.01).abs() < 1e-9);
}

#[test]
fn a_cut_collapses_and_recovers_under_a_limit_and_a_starved_stream_skips() {
    let stream = [("keyframe_interval", 3.0), ("quality", 0.95)];
    let cut = 20usize;
    let free = played(&clean(&stream), 60, Some(cut as i64), None);
    let mut tight_values = stream.to_vec();
    tight_values.extend_from_slice(&[("bitrate_limit", 0.6), ("rate_buffer", 0.1)]);
    let tight = played(&clean(&tight_values), 60, Some(cut as i64), None);
    let damage: Vec<f64> = (0..60).map(|n| mean_difference(&tight[n], &free[n])).collect();
    let before = damage[cut - 5..cut].iter().cloned().fold(0.0, f64::max);
    let after = damage[cut..cut + 4].iter().cloned().fold(0.0, f64::max);
    assert!(after > 3.0 * before + 2.0, "{damage:?}");
    assert!(damage[cut + 30..cut + 40].iter().cloned().fold(0.0, f64::max) < after / 2.0);
    // Starved past the coarsest quantizer, the encoder waits: frames repeat.
    let mut starved_values = stream.to_vec();
    starved_values.extend_from_slice(&[("bitrate_limit", 0.95), ("rate_buffer", 0.3)]);
    let starved = played(&clean(&starved_values), 40, Some(20), None);
    let frozen = (1..40).filter(|&n| starved[n] == starved[n - 1]).count();
    assert!(frozen > 5, "{frozen}");
    assert_eq!((1..40).filter(|&n| free[n] == free[n - 1]).count(), 0);
}

// MARK: - generations

#[test]
fn generations_wear_the_picture_down_and_leave_it_in_place() {
    let base = [("quality", 0.6)];
    let first = shrunk(&played(&clean(&base), 1, None, None)[0]);
    let mut last = 0.0;
    for count in [1.0, 4.0, 12.0] {
        let mut v = base.to_vec();
        v.push(("generations", count));
        let out = shrunk(&played(&clean(&v), 1, None, None)[0]);
        let damage = mean_difference(&out, &first);
        assert!(damage > last + 0.2, "{count} generations");
        last = damage;
    }
    // On the same blocks a second pass loses almost nothing; the moved grid
    // is the whole effect.
    let g = CodecGeometry::new(128, 96, ChromaSubsampling::HalfBoth);
    let st = clean(&base);
    let src = DigitalVideoRenderer::capture(&shrunk(&frame(2, None)), &g, &st, 0);
    let steps = Steps::new(0.6, 1.0);
    let (mut once, mut twice) = (CodecPicture::new(&g), CodecPicture::new(&g));
    DigitalCodec::code_intra(&src, &mut once, &steps);
    DigitalCodec::code_intra(&once, &mut twice, &steps);
    let a = DigitalVideoRenderer::render(&once, &g, &st, steps.inter);
    let same = mean_difference(&DigitalVideoRenderer::render(&twice, &g, &st, steps.inter), &a);
    let moved = mean_difference(&DigitalVideoRenderer::regenerate(&a, &g, &st, 1), &a);
    assert!(moved > 3.0 * same + 0.3, "same grid {same}, moved {moved}");
}

// MARK: - the same frame however it's reached

#[test]
fn the_new_controls_look_the_same_jumped_to_as_played() {
    for (label, extra) in [
        ("woven + camcorder", vec![("fields", 2.0), ("sensor", 2.0), ("sensor_noise", 0.5), ("low_light_noise", 0.5), ("aliasing", 0.4), ("ccd_response", 0.7), ("keyframe_interval", 0.5), ("data_loss", 0.3)]),
        ("tape", vec![("data_loss", 0.6), ("loss_pattern", 1.0), ("bit_errors", 0.4), ("concealment", 2.0)]),
        ("clogged, block 16", vec![("data_loss", 0.6), ("loss_pattern", 2.0), ("block_size", 2.0), ("concealment", 3.0)]),
        ("block 4 stream", vec![("block_size", 0.0), ("keyframe_interval", 0.5), ("quality", 0.5), ("data_loss", 0.5), ("datamosh", 0.5), ("bit_errors", 0.5), ("mosh_motion", 4.0), ("deblocking", 0.5), ("chroma", 3.0), ("concealment", 3.0)]),
        ("limit", vec![("keyframe_interval", 0.5), ("quality", 0.95), ("bitrate_limit", 0.65), ("rate_buffer", 0.2)]),
        ("starved + mosh", vec![("keyframe_interval", 0.5), ("quality", 0.95), ("bitrate_limit", 0.9), ("rate_buffer", 0.3), ("datamosh", 0.6), ("data_loss", 0.4), ("deblocking", 0.6), ("block_size", 2.0)]),
        ("generations", vec![("generations", 3.0), ("keyframe_interval", 0.5), ("quality", 0.5), ("data_loss", 0.4), ("chroma_upsampling", 1.0), ("chroma", 3.0)]),
    ] {
        check_jumps_match_playing(&clean(&extra), 40, Some(16), None, label);
    }
    check_jumps_match_playing(&settings("cd_rom", &[("keyframe_interval", 0.5), ("generations", 3.0), ("loss_pattern", 1.0), ("data_loss", 0.5)]), 40, Some(16), None, "Video 1");
}

/// The smallest pictures, with everything on: nothing reads past an edge.
#[test]
fn tiny_pictures_survive_every_block_size() {
    for (w, h) in [(16usize, 16usize), (40, 24), (18, 34)] {
        for block in [0.0, 1.0, 2.0] {
            for (chroma, sensor) in [(0.0, 0.0), (2.0, 1.0), (3.0, 2.0)] {
                let st = clean(&[
                    ("block_size", block), ("chroma", chroma), ("sensor", sensor), ("sensor_noise", 0.4), ("keyframe_interval", 0.2),
                    ("data_loss", 0.8), ("loss_pattern", 2.0), ("bit_errors", 1.0), ("mosh_motion", 3.0), ("mosh_speed", 1.0),
                    ("deblocking", 1.0), ("concealment", 3.0), ("generations", 2.0), ("bitrate_limit", 0.7), ("rate_buffer", 0.1),
                    ("datamosh", 0.5), ("fields", 3.0), ("smear", 0.5), ("ccd_response", 1.0),
                ]);
                let mut r = DigitalVideoRenderer::new();
                for n in 0..10 {
                    let mut px = frame(n, None);
                    let mut visitor = |i: i64, body: &mut dyn FnMut(&[u8], usize, usize, usize)| {
                        body(&frame(i, None), SIZE.0, SIZE.1, SIZE.0 * 4);
                        true
                    };
                    r.process(n, &mut px, SIZE.0, SIZE.1, SIZE.0 * 4, (w, h), 30.0, &st, None, Some(&mut visitor));
                }
            }
        }
    }
}
