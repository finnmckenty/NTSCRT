//! Screen Loop end to end on the GPU: the run-up builds a tunnel (the TV in
//! the camera's frame shows shrinking copies), the counter draws, and the
//! same settings give the same frames.

use ntscrt_engine::{DownscaleMethod, DownscaleSpec, Engine, HowlRender, HowlSettings, Image, Settings};

fn scene(w: u32, h: u32) -> Image {
    let mut rgba = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            // A bright frame around a dark middle: copies show as nested rings.
            let edge = x < w / 10 || x >= w - w / 10 || y < h / 10 || y >= h - h / 10;
            let v = if edge { 240 } else { 20 };
            rgba.extend_from_slice(&[v, (x * 200 / w) as u8, v, 255]);
        }
    }
    Image::new(w, h, rgba)
}

fn settings() -> Settings {
    Settings {
        ntsc: None,
        downscale: Some(DownscaleSpec::for_width(320, (640, 480), DownscaleMethod::Area)),
        shader: None,
        frame: 1,
        glitch: None,
        digital: None,
    }
}

fn run(values: &[(&str, f64)]) -> Option<Vec<Image>> {
    let mut engine = Engine::new().ok()?;
    let mut s = HowlSettings::default();
    for (k, v) in values {
        s.values.insert(k.to_string(), *v);
    }
    let pic = scene(640, 480);
    engine.howl_begin(HowlRender { settings: s, length: 2.0 }, None, (320, 240)).expect("begin");
    engine.howl_run_up(&pic, &settings(), 30.0, &|| false).expect("run-up");
    let mut out = Vec::new();
    for i in 0..3 {
        let cam = engine.howl_camera(&pic, i as f64 / 30.0).expect("camera");
        engine.set_source(cam);
        let mut st = settings();
        st.frame = i + 1;
        out.push(engine.render_export(&st, (640, 480), None).expect("render"));
        engine.howl_advance();
    }
    engine.howl_end();
    Some(out)
}

#[test]
fn the_run_up_builds_a_tunnel() {
    let Some(frames) = run(&[("shake", 0.0), ("center_x", 0.0), ("center_y", 0.0), ("turn", 0.0), ("focus", 0.0)]) else {
        eprintln!("no GPU: skipped");
        return;
    };
    let f = &frames[0];
    if let Some(p) = std::env::var_os("HOWL_DUMP") {
        let mut ppm = format!("P6 {} {} 255\n", f.width, f.height).into_bytes();
        ppm.extend(f.rgba.chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]));
        std::fs::write(p, ppm).unwrap();
    }
    let g = |x: u32, y: u32| f.rgba[((y * f.width + x) * 4 + 1) as usize] as i32;
    let r = |x: u32, y: u32| f.rgba[((y * f.width + x) * 4) as usize];
    // The scene's middle is dark; the TV covers it with the copies.
    assert!(r(f.width / 2 + 20, f.height / 2) > 150, "the TV isn't in the middle of the frame");
    // Nested copies: the scene's green ramp restarts at every copy's edge,
    // so the middle row's right half has a jump per copy.
    let row = f.height / 2;
    let jumps = (f.width / 2 + 2..f.width).filter(|&x| g(x, row) - g(x - 1, row) < -6).count();
    assert!(jumps >= 6, "only {jumps} copy edges across the right half");
}

#[test]
fn the_same_settings_give_the_same_frames() {
    let values = [("shake", 0.6), ("counter", 1.0), ("auto_exposure", 0.5), ("delay", 3.0)];
    let (Some(a), Some(b)) = (run(&values), run(&values)) else { return };
    for (x, y) in a.iter().zip(&b) {
        assert_eq!(x.rgba, y.rgba);
    }
    assert_ne!(a[0].rgba, a[2].rgba, "a handheld camera moves");
}
