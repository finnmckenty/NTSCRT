//! Where a video preview frame's time goes, for one look and picture size:
//! the CPU stages (Digital video, NTSC), the upload, and the GPU work with
//! its read back — the parts playback's producer and render thread split.
//!
//!   cargo run --release -p ntscrt-spike --example preview-bench -- <picture> <look.json> <width> <height> [display w h] [frames]

use std::time::Instant;

use anyhow::{Context, Result};
use ntscrt_engine::{cpu_stages, preview, Engine, Image, Look};

fn main() -> Result<()> {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let num = |i: usize, d: u32| a.get(i).and_then(|s| s.parse().ok()).unwrap_or(d);
    let (w, h) = (num(2, 1920), num(3, 1440));
    let display = (num(4, 1200), num(5, 900));
    let frames = num(6, 20) as usize;
    let img = image::open(&a[0])?.resize_exact(w, h, image::imageops::FilterType::Triangle).to_rgba8();
    let look = Look::parse(&std::fs::read_to_string(&a[1])?)?;
    let shaders = ntscrt_engine::find_shaders().context("shaders not found")?;
    let mut engine = Engine::new()?;
    println!("adapter: {:?} {}", engine.adapter_info().backend, engine.adapter_info().name);
    let mut digital = ntscrt_engine::codec::DigitalVideoRenderer::new();
    let (mut cpu, mut up, mut gpu) = (0.0, 0.0, 0.0);
    for n in 0..frames {
        let mut settings = look.render_settings((w, h), &shaders, n + 1)?;
        if std::env::var_os("BENCH_NO_NTSC").is_some() {
            settings.ntsc = None;
        }
        let input = match settings.downscale {
            Some(d) => (d.width, d.picture_height()),
            None => (w, h),
        };
        let plan = preview::plan(input, display, false);
        let clean = Image::new(w, h, img.as_raw().clone());
        let t = Instant::now();
        let mut processed = clean.clone();
        cpu_stages(&mut digital, &settings, &mut processed, None)?;
        let c = t.elapsed().as_secs_f64() * 1000.0;
        let t = Instant::now();
        engine.set_prepared(clean, &processed, &settings);
        let u = t.elapsed().as_secs_f64() * 1000.0;
        let t = Instant::now();
        let _ = engine.bake_and_preview(&settings, plan, false, None)?;
        let g = t.elapsed().as_secs_f64() * 1000.0;
        if n >= 3 {
            (cpu, up, gpu) = (cpu + c, up + u, gpu + g);
        }
    }
    if std::env::var_os("BENCH_PARTS").is_some() {
        let settings = look.render_settings((w, h), &shaders, 1)?;
        if let Some(d) = &settings.digital {
            let raw = img.as_raw();
            let t = Instant::now();
            for _ in 0..10 {
                let _ = ntscrt_engine::codec::DigitalVideoRenderer::scale(raw, w as usize, h as usize, w as usize * 4, d.capture, &d.settings);
            }
            let sc = t.elapsed().as_secs_f64() * 100.0;
            let small = ntscrt_engine::codec::DigitalVideoRenderer::scale(raw, w as usize, h as usize, w as usize * 4, d.capture, &d.settings);
            let mut big = raw.clone();
            let t = Instant::now();
            for _ in 0..10 {
                ntscrt_engine::codec::DigitalVideoRenderer::upscale(&small, d.capture, &mut big, w as usize, h as usize, w as usize * 4);
            }
            println!("capture {:?}: scale {sc:.1} ms, upscale {:.1} ms", d.capture, t.elapsed().as_secs_f64() * 100.0);
        }
    }
    let k = (frames - 3) as f64;
    println!("{w}x{h} → display {}x{}: CPU stages {:.1} ms, upload {:.1} ms, GPU + read back {:.1} ms", display.0, display.1, cpu / k, up / k, gpu / k);
    Ok(())
}
