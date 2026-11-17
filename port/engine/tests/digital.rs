//! The Digital video stage in the pipeline: what a look with it on sets up
//! (One field's half-height lines, the camera's capture size), and that the
//! stage runs ahead of the chain. The codec itself is checked against the
//! Mac's in the codec crate.

use ntscrt_engine::Look;
use ntscrt_engine::{Engine, Image};

fn picture(w: u32, h: u32) -> Image {
    let mut rgba = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            // Diagonal stripes over a gradient: detail the codec must lose.
            let stripe = if (x + y) / 3 % 2 == 0 { 230 } else { 30 };
            rgba.extend_from_slice(&[stripe, (x * 255 / w) as u8, (y * 255 / h) as u8, 255]);
        }
    }
    Image::new(w, h, rgba)
}

fn cheap_camcorder() -> Look {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../presets/Cheap camcorder.json");
    Look::parse(&std::fs::read_to_string(root).expect("preset")).expect("look")
}

/// One GPU test at a time: some drivers (the VM's GL) crash creating devices on two threads at once.
static GPU: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[test]
fn a_digital_look_sets_up_one_field_and_the_capture() {
    let look = cheap_camcorder();
    assert!(look.unported().is_empty());
    let shaders = std::path::PathBuf::from("/nonexistent");
    let mut look_no_crt = look.clone();
    look_no_crt.shader_enabled = Some(false);
    let s = look_no_crt.render_settings((640, 480), &shaders, 0).expect("settings");
    let d = s.downscale.expect("downscale");
    // 480 wide at 4:3 is 360 rows; One field keeps 180 lines, two rows each.
    assert_eq!((d.width, d.height, d.line_height, d.picture_height()), (480, 180, 2, 360));
    let digital = s.digital.expect("digital on");
    assert_eq!(digital.capture, (480, 360), "the camera captures the whole frame");
    assert_eq!(digital.settings.get("fields"), 1.0);
}

#[test]
fn the_stage_changes_the_picture_and_its_noise_moves() {
    let _gpu = GPU.lock().unwrap_or_else(|e| e.into_inner());
    let Ok(mut engine) = Engine::new() else {
        eprintln!("no GPU: skipped");
        return;
    };
    let mut look = cheap_camcorder();
    look.shader_enabled = Some(false);
    look.ntsc_enabled = Some(false);
    look.glitch_enabled = false;
    let shaders = std::path::PathBuf::from("/nonexistent");
    engine.set_source(picture(640, 480));
    let on = look.render_settings((640, 480), &shaders, 0).expect("settings");
    let lines = on.downscale.unwrap().height;
    let out = (480, lines);
    let a = engine.render_export(&on, out, None).expect("render");
    assert_eq!((a.width, a.height), out);

    let mut off = on.clone();
    off.digital = None;
    let b = engine.render_export(&off, out, None).expect("render");
    let differ = a.rgba.iter().zip(&b.rgba).filter(|(x, y)| x != y).count();
    assert!(differ > a.rgba.len() / 10, "the codec should change the picture ({differ} bytes differ)");

    // Frame 3 of the same still: sensor noise moves from frame to frame.
    let mut later = on.clone();
    later.digital.as_mut().unwrap().frame = 3;
    let c = engine.render_export(&later, out, None).expect("render");
    assert_ne!(a.rgba, c.rgba, "noise should differ between frames");
    // And going back gives frame 0 again exactly.
    let again = engine.render_export(&on, out, None).expect("render");
    assert_eq!(a.rgba, again.rgba, "the stream should be deterministic");
}

/// A clip whose frames move: frame n is the picture shifted n pixels.
fn clip_frame(n: i64) -> Image {
    let base = picture(640, 480);
    let shift = (n.max(0) as usize % 640) * 4;
    let mut rgba = base.rgba.clone();
    for row in rgba.chunks_mut(640 * 4) {
        row.rotate_left(shift);
    }
    Image::new(640, 480, rgba)
}

fn visit_clip(n: i64, body: &mut dyn FnMut(&[u8], usize, usize, usize)) -> bool {
    let f = clip_frame(n);
    body(&f.rgba, 640, 480, 640 * 4);
    true
}

/// The preview's long Digital re-runs (a knob turned on a paused clip, a
/// jump) go to a thread of their own: meanwhile the frame shows coded on
/// its own (and isn't to be kept), and once the re-run lands the frame is
/// exactly what a straight re-run gives — the Mac's 0.26.1 fix.
#[test]
fn background_digital_reruns_land_on_the_exact_frame() {
    let _gpu = GPU.lock().unwrap_or_else(|e| e.into_inner());
    let Ok(mut engine) = Engine::new() else {
        eprintln!("no GPU: skipped");
        return;
    };
    let mut look = cheap_camcorder();
    look.shader_enabled = Some(false);
    look.ntsc_enabled = Some(false);
    look.glitch_enabled = false;
    let shaders = std::path::PathBuf::from("/nonexistent");
    let mut s = look.render_settings((640, 480), &shaders, 0).expect("settings");
    {
        let d = s.digital.as_mut().expect("digital on");
        d.settings.set("keyframe_interval", 2.0);
        d.settings.set("data_loss", 0.4);
        d.source_fps = 30.0;
        d.frame = 50;
    }
    engine.digital_in_background = true;
    let opener: ntscrt_engine::ClipOpener = std::sync::Arc::new(|| {
        let visit: Box<dyn FnMut(i64, &mut dyn FnMut(&[u8], usize, usize, usize)) -> bool> = Box::new(visit_clip);
        Some(visit)
    });
    engine.set_clip_opener(Some(opener));
    for change in [None, Some(("quality", 0.15)), Some(("data_loss", 0.7))] {
        if let Some((k, v)) = change {
            s.digital.as_mut().unwrap().settings.set(k, v); // turned while paused
        }
        engine.set_source(clip_frame(50));
        let mut visit = visit_clip;
        engine.bake(&s, Some(&mut visit)).expect("meanwhile");
        assert!(engine.last_interim(), "{change:?}: a 50-capture re-run goes to the background");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
        while !engine.take_landed() {
            assert!(std::time::Instant::now() < deadline, "background re-run never landed");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let landed = engine.bake(&s, Some(&mut visit)).expect("landed");
        assert!(!engine.last_interim());

        let mut exact = Engine::new().expect("engine");
        exact.set_source(clip_frame(50));
        let mut visit = visit_clip;
        let want = exact.bake(&s, Some(&mut visit)).expect("exact");
        assert_eq!(landed.rgba, want.rgba, "{change:?}");
    }
}

/// Issue #7: a keyframe made under CRT Sim carries its BloomPower into
/// Glow (Gaussian) when the shader changes; the Mac skips names a preset
/// doesn't have, and so must we (it was "crtglow_gauss.slangp has no
/// parameter BloomPower").
#[test]
fn a_shader_value_from_another_preset_is_skipped() {
    let _gpu = GPU.lock().unwrap_or_else(|e| e.into_inner());
    let Ok(mut engine) = Engine::new() else {
        eprintln!("no GPU: skipped");
        return;
    };
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Vendor/slang-shaders");
    let mut s = ntscrt_engine::Settings {
        ntsc: None,
        downscale: None,
        shader: Some(ntscrt_engine::ShaderSpec {
            preset: root.join("crt/crtglow_gauss.slangp"),
            params: vec![("BOOST".into(), 1.1), ("BloomPower".into(), 1.0)],
        }),
        frame: 1,
        glitch: None,
        digital: None,
    };
    engine.set_source(picture(320, 240));
    let with_stray = engine.render_export(&s, (640, 480), None).expect("renders with a stray value");
    s.shader.as_mut().unwrap().params.retain(|(n, _)| n != "BloomPower");
    let without = engine.render_export(&s, (640, 480), None).expect("renders");
    assert_eq!(with_stray.rgba, without.rgba, "the stray value changes nothing");
}
