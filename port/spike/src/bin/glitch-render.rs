//! glitch-render <in.png> <time> <out.png> [key=value ...]: the engine's
//! Glitch stage alone (no NTSC, downscale or CRT) on a picture, to compare
//! with port/scripts/glitch-ref-render (the Mac's).
use anyhow::{Context, Result};
use ntscrt_engine::glitch::{GlitchFrame, GlitchSettings};
use ntscrt_engine::{Engine, Image, Settings};

fn main() -> Result<()> {
    let a: Vec<String> = std::env::args().collect();
    let img = image::open(&a[1])?.to_rgba8();
    let (w, h) = img.dimensions();
    let time: f64 = a[2].parse()?;
    let mut s = GlitchSettings::default();
    for kv in &a[4..] {
        let (k, v) = kv.split_once('=').context("key=value")?;
        s.values.insert(k.to_string(), v.parse()?);
    }
    let mut engine = Engine::new()?;
    engine.set_source(Image::new(w, h, img.into_raw()));
    let settings = Settings { ntsc: None, downscale: None, shader: None, frame: 0, glitch: Some(GlitchFrame { settings: s, time, history: None }) };
    let out = engine.render(&settings, (w, h))?;
    image::RgbaImage::from_raw(out.width, out.height, out.rgba).context("image")?.save(&a[3])?;
    Ok(())
}
