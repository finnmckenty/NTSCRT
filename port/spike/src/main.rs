//! ntscrt-spike: a still through ntscrt-engine, mirroring the Mac's
//! `crt-smoke` so the two outputs can be compared pixel by pixel.
//!
//!   ntscrt-spike <input.png> <preset.slangp> <output.png> [outW outH] [downW downH method]
//!                [--ntsc default|<settings.json>] [--frame N] [--set NAME=VALUE ...]
//!                [--no-selftest] [--look <look.json>]
//!
//! Like crt-smoke it sets the preset's first parameter to its midpoint before
//! rendering (crt-smoke's set/get self-test), unless --no-selftest.
//! SPIKE_BACKEND (or NTSCRT_BACKEND) = gl|dx12|vulkan|metal picks the backend.

use anyhow::{bail, Context, Result};
use ntscrt_engine::{preset_parameters, DownscaleMethod, DownscaleSpec, Engine, Image, NtscSettings, Settings, ShaderSpec};

fn main() -> Result<()> {
    let mut pos = Vec::new();
    let (mut ntsc, mut frame, mut sets, mut selftest) = (None, 1usize, Vec::new(), true);
    let mut look: Option<String> = None;
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--ntsc" => ntsc = Some(it.next().context("--ntsc needs a value")?),
            "--frame" => frame = it.next().context("--frame needs a value")?.parse()?,
            "--no-selftest" => selftest = false,
            "--look" => look = Some(it.next().context("--look needs a file")?),
            "--set" => {
                let kv = it.next().context("--set needs NAME=VALUE")?;
                let (k, v) = kv.split_once('=').context("--set needs NAME=VALUE")?;
                sets.push((k.to_string(), v.parse::<f32>()?));
            }
            _ => pos.push(a),
        }
    }
    if pos.len() < 3 {
        bail!("usage: ntscrt-spike <input.png> <preset.slangp> <output.png> [outW outH] [downW downH method] [--ntsc default|file] [--frame N] [--set NAME=VALUE]");
    }
    let num = |i: usize, d: u32| -> Result<u32> { Ok(pos.get(i).map(|s| s.parse()).transpose()?.unwrap_or(d)) };
    let out = (num(3, 1920)?, num(4, 1080)?);
    let downscale = if pos.len() > 7 {
        let Some(method) = DownscaleMethod::from_raw(&pos[7]) else { bail!("unknown downscale method {}", pos[7]) };
        Some(DownscaleSpec { width: num(5, 0)?, height: num(6, 0)?, method, line_height: 1 })
    } else {
        None
    };

    let img = image::open(&pos[0]).with_context(|| format!("open {}", pos[0]))?.to_rgba8();
    let (w, h) = img.dimensions();

    let mut params = Vec::new();
    if selftest && look.is_none() {
        if let Some(p) = preset_parameters(pos[1].as_ref())?.into_iter().next() {
            let mid = (p.minimum + p.maximum) / 2.0;
            println!("set/get {}: wrote {mid}", p.name);
            params.push((p.name, mid));
        }
    }
    for (k, v) in sets {
        println!("override {k} = {v}");
        params.retain(|(n, _)| *n != k);
        params.push((k, v));
    }

    // --look: everything comes from the look (the preset argument is ignored).
    if let Some(path) = look {
        let l = ntscrt_engine::Look::parse(&std::fs::read_to_string(&path)?)?;
        let shaders = ntscrt_engine::find_shaders().context("shaders not found")?;
        let settings = l.render_settings((w, h), &shaders, frame)?;
        let mut engine = Engine::new()?;
        engine.set_source(Image::new(w, h, img.into_raw()));
        let result = engine.render(&settings, out)?;
        image::RgbaImage::from_raw(result.width, result.height, result.rgba).context("image")?.save(&pos[2])?;
        println!("wrote {} from {path} (unported: {:?})", pos[2], l.unported());
        return Ok(());
    }

    let mut engine = Engine::new()?;
    let info = engine.adapter_info();
    println!("adapter: {:?} | {} | {:?}", info.backend, info.name, info.device_type);
    engine.set_source(Image::new(w, h, img.into_raw()));
    let settings = Settings {
        ntsc: ntsc.map(|s| if s == "default" { Ok(NtscSettings::Default) } else { std::fs::read_to_string(&s).map(NtscSettings::Json) }).transpose()?,
        downscale,
        shader: Some(ShaderSpec { preset: pos[1].clone().into(), params }),
        frame,
        glitch: None,
        digital: None,
    };
    let mut result = engine.render(&settings, out)?;

    // As the Mac's crt-smoke writes it: the output is taken as premultiplied
    // alpha (CGImage premultipliedFirst) and stored unpremultiplied.
    for p in result.rgba.chunks_mut(4) {
        let a = p[3] as u32;
        if a > 0 && a < 255 {
            for c in 0..3 {
                p[c] = ((p[c] as u32 * 255 + a / 2) / a).min(255) as u8;
            }
        }
    }
    image::RgbaImage::from_raw(result.width, result.height, result.rgba).context("image")?.save(&pos[2])?;
    println!("wrote {} ({}x{})", pos[2], out.0, out.1);
    Ok(())
}
