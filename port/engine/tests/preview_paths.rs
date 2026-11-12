//! Playback's faster routes give the same pixels as the plain ones: the
//! bake and the preview in one trip to the GPU, a frame whose CPU stages ran
//! on another thread, and the codec taking frames playback skips.

use ntscrt_engine::preview;
use ntscrt_engine::{cpu_stages, digital_unseen, Engine, Image, Look};

fn picture(w: u32, h: u32, shift: u32) -> Image {
    let mut rgba = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            let stripe = if (x + y + shift) / 3 % 2 == 0 { 220 } else { 40 };
            rgba.extend_from_slice(&[stripe, ((x + shift) * 255 / w) as u8, (y * 255 / h) as u8, 255]);
        }
    }
    Image::new(w, h, rgba)
}

fn look(name: &str) -> Look {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../presets").join(format!("{name}.json"));
    Look::parse(&std::fs::read_to_string(path).expect("preset")).expect("look")
}

/// One GPU test at a time: some drivers (the VM's GL) crash creating devices on two threads at once.
static GPU: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn settings(look: &Look, size: (u32, u32), frame: usize) -> ntscrt_engine::Settings {
    let mut look = look.clone();
    // The CRT shader where the shaders are found; the paths are the same either way.
    let shaders = ntscrt_engine::find_shaders();
    if shaders.is_none() {
        look.shader_enabled = Some(false);
    }
    let shaders = shaders.unwrap_or_else(|| "/nonexistent".into());
    look.render_settings(size, &shaders, frame).expect("settings")
}

#[test]
fn one_trip_bake_and_preview_match_the_two_trip_ones() {
    let _gpu = GPU.lock().unwrap_or_else(|e| e.into_inner());
    let Ok(mut engine) = Engine::new() else {
        eprintln!("no GPU: skipped");
        return;
    };
    let size = (640, 480);
    let s = settings(&look("Medium VHS"), size, 7);
    let input = s.downscale.map_or(size, |d| (d.width, d.picture_height()));
    for (drawable, full) in [((900, 700), false), ((900, 700), true), ((333, 250), false)] {
        let plan = preview::plan(input, drawable, false);
        engine.set_source(picture(size.0, size.1, 0));
        let baked = engine.bake(&s, None).expect("bake");
        let two = engine.render_preview_baked(&s, plan, full, &baked).expect("preview");
        engine.set_source(picture(size.0, size.1, 0));
        let (baked1, one) = engine.bake_and_preview(&s, plan, full, None).expect("one trip");
        assert_eq!(baked.rgba, baked1.rgba, "baked, {drawable:?} full {full}");
        assert_eq!((two.width, two.height), (one.width, one.height));
        assert_eq!(two.rgba, one.rgba, "preview, {drawable:?} full {full}");
    }
}

#[test]
fn a_frame_prepared_on_another_thread_renders_the_same() {
    let _gpu = GPU.lock().unwrap_or_else(|e| e.into_inner());
    let Ok(mut engine) = Engine::new() else {
        eprintln!("no GPU: skipped");
        return;
    };
    let size = (640, 480);
    for name in ["Medium VHS", "Cheap camcorder"] {
        let s = settings(&look(name), size, 3);
        let input = s.downscale.map_or(size, |d| (d.width, d.picture_height()));
        let plan = preview::plan(input, (800, 600), false);
        // The engine's own CPU stages, from a fresh codec.
        let mut plain = Engine::new().expect("engine");
        plain.set_source(picture(size.0, size.1, 0));
        let (want_baked, want) = plain.bake_and_preview(&s, plan, false, None).expect("plain");
        // The producer's way: the stages run outside, the result handed in.
        let clean = picture(size.0, size.1, 0);
        let mut processed = clean.clone();
        let mut digital = ntscrt_engine::codec::DigitalVideoRenderer::new();
        cpu_stages(&mut digital, &s, &mut processed, None).expect("stages");
        engine.set_prepared(clean, &processed, &s);
        let (baked, got) = engine.bake_and_preview(&s, plan, false, None).expect("prepared");
        assert_eq!(want_baked.rgba, baked.rgba, "{name}: baked");
        assert_eq!(want.rgba, got.rgba, "{name}: preview");
    }
}

#[test]
fn frames_the_codec_takes_unseen_leave_the_next_one_as_it_would_be() {
    let s0 = settings(&look("Chunky webcam"), (320, 240), 1);
    assert!(s0.digital.is_some(), "a look with Digital video");
    let frame = |n: usize| {
        let mut s = s0.clone();
        s.frame = n + 1;
        s.digital.as_mut().unwrap().frame = n as i64;
        s
    };
    // Frames 0–4 of a moving picture, each seen, against 0–3 unseen.
    let pics: Vec<Image> = (0..5).map(|n| picture(320, 240, n * 2)).collect();
    let mut seen = ntscrt_engine::codec::DigitalVideoRenderer::new();
    let mut unseen = ntscrt_engine::codec::DigitalVideoRenderer::new();
    let mut a = None;
    for (n, pic) in pics.iter().enumerate() {
        let mut out = pic.clone();
        cpu_stages(&mut seen, &frame(n), &mut out, None).expect("seen");
        a = Some(out);
        if n < 4 {
            digital_unseen(&mut unseen, &frame(n), pic, None);
        }
    }
    let mut b = pics[4].clone();
    cpu_stages(&mut unseen, &frame(4), &mut b, None).expect("last");
    assert_eq!(a.unwrap().rgba, b.rgba, "frame 4 after unseen frames");
    // And an unseen frame leaves the picture alone.
    let mut digital = ntscrt_engine::codec::DigitalVideoRenderer::new();
    let before = pics[0].clone();
    digital_unseen(&mut digital, &frame(0), &before, None);
    assert_eq!(before.rgba, pics[0].rgba);
}
