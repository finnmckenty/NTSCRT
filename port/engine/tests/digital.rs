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
