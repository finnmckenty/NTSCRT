//! An export is the picture the preview shows (the Mac's
//! ExportMatchesPreviewTests): the real shaders down the preview's path and
//! the export's, into the same number of pixels.
//!
//! CRT shaders draw scanlines and masks in output pixels. The preview
//! rendered at 6× the picture and up; exports rendered straight at the
//! file's size — a 640-wide picture was 6× on screen and 3× in a 1920
//! export, and with the Downscale off 1× or less, where a mask shader showed
//! only its stripes and the aperture shader was black.

use ntscrt_engine::{preview, DownscaleMethod, DownscaleSpec, Engine, Image, Settings, ShaderSpec};

/// One GPU test at a time: some drivers (the VM's GL) crash creating devices on two threads at once.
static GPU: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// A picture with something for a shader to work on.
fn picture(w: u32, h: u32) -> Image {
    let mut rgba = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            let (u, v) = (x as f64 / w as f64, y as f64 / h as f64);
            let wave = 0.5 + 0.35 * (u * 19.0).sin() * (v * 13.0).cos();
            let block = if ((u * 8.0) as u32 + (v * 6.0) as u32) % 3 == 0 { 0.25 } else { 0.0 };
            let c = |x: f64| (x * 255.0).clamp(0.0, 255.0) as u8;
            rgba.extend_from_slice(&[c(wave + block * 0.5), c(0.2 + 0.6 * u), c(wave * 0.8 + block), 255]);
        }
    }
    Image::new(w, h, rgba)
}

fn settings(shader: &str, downscale: Option<DownscaleSpec>) -> Option<Settings> {
    let shaders = ntscrt_engine::find_shaders()?;
    let preset = shaders.join("crt").join(format!("{shader}.slangp"));
    preset.is_file().then(|| Settings { ntsc: None, downscale, shader: Some(ShaderSpec { preset, params: Vec::new() }), frame: 1, glitch: None, digital: None })
}

fn largest_difference(a: &Image, b: &Image) -> u8 {
    assert_eq!((a.width, a.height), (b.width, b.height));
    a.rgba.iter().zip(&b.rgba).map(|(x, y)| x.abs_diff(*y)).max().unwrap_or(0)
}

fn mean_luma(i: &Image) -> f64 {
    i.rgba.chunks_exact(4).map(|p| 0.299 * p[0] as f64 + 0.587 * p[1] as f64 + 0.114 * p[2] as f64).sum::<f64>() / (i.rgba.len() / 4) as f64
}

/// Shown and exported at the same number of pixels, the two are the same
/// picture: with a mask shader and without, a small Downscale, a large one,
/// and none.
#[test]
fn an_export_is_the_previews_picture() {
    let _gpu = GPU.lock().unwrap_or_else(|e| e.into_inner());
    let Ok(mut engine) = Engine::new() else {
        eprintln!("no GPU: skipped");
        return;
    };
    let source = (960u32, 720u32);
    let down = |w: u32| Some(DownscaleSpec::for_width(w, source, DownscaleMethod::Area));
    // (Downscale, size, integer scale in the preview): with integer scale,
    // whole even multiples of the shader's picture.
    let cases = [
        (down(256), (1920u32, 1440u32), false),
        (down(256), (1024, 768), true),
        (down(320), (1920, 1440), true),
        (down(640), (1920, 1440), false),
        (down(640), (1280, 960), true),
        (down(640), (800, 600), false),
        (None, (1920, 1440), true),
        (None, (1280, 960), false),
    ];
    for shader in ["crt-aperture", "crtglow_gauss"] {
        for (downscale, size, integer) in cases {
            let Some(s) = settings(shader, downscale) else {
                eprintln!("no shaders: skipped");
                return;
            };
            let name = format!("{shader}, downscale {:?}, {size:?}, integer {integer}", downscale.map(|d| d.width));
            let input = downscale.map_or(source, |d| (d.width, d.picture_height()));
            let plan = preview::plan(input, size, integer);
            assert_eq!((plan.display_width, plan.display_height), size, "{name}: the test's size must be the preview's");
            engine.set_source(picture(source.0, source.1));
            let shown = engine.render_preview(&s, plan, false, None).expect("preview");
            engine.set_source(picture(source.0, source.1));
            let exported = engine.render_export(&s, size, None).expect("export");
            assert!(largest_difference(&shown, &exported) <= 1, "{name}: {}", largest_difference(&shown, &exported));
            assert!(mean_luma(&exported) > 20.0, "{name}: a picture, not black");
        }
    }
}

/// A large still with the Downscale off: the shader is given at least two
/// rows a line, so there is a picture — in the preview and in an export
/// smaller than the still. (The aperture shader divides by the whole number
/// of rows a line: black below one, and at one for 2544 lines, whose
/// reciprocal rounds down.)
#[test]
fn a_large_picture_with_the_downscale_off_is_not_black() {
    let _gpu = GPU.lock().unwrap_or_else(|e| e.into_inner());
    let Ok(mut engine) = Engine::new() else {
        eprintln!("no GPU: skipped");
        return;
    };
    let source = (1904u32, 2544u32);
    for shader in ["crt-aperture", "crtglow_gauss"] {
        let Some(s) = settings(shader, None) else {
            eprintln!("no shaders: skipped");
            return;
        };
        let plan = preview::plan(source, (1436, 1920), true);
        assert!(plan.render_multiple >= 2);
        engine.set_source(picture(source.0, source.1));
        let shown = engine.render_preview(&s, plan, false, None).expect("preview");
        assert!(mean_luma(&shown) > 40.0, "{shader}: the preview ({})", mean_luma(&shown));
        for size in [(1436u32, 1920u32), (718, 960), (1904, 2544)] {
            let exported = engine.render_export(&s, size, None).expect("export");
            assert!(mean_luma(&exported) > 40.0, "{shader}: an export at {size:?} ({})", mean_luma(&exported));
        }
    }
}
