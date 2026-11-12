//! Windows-port spike: the still-image pipeline in Rust on wgpu, mirroring
//! the Mac's `crt-smoke` so the two outputs can be compared pixel by pixel.
//!
//!   ntscrt-spike <input.png> <preset.slangp> <output.png> [outW outH] [downW downH area]
//!                [--ntsc default|<settings.json>] [--frame N] [--set NAME=VALUE ...]
//!                [--no-selftest]
//!
//! Like crt-smoke it sets the preset's first parameter to its midpoint before
//! rendering (crt-smoke's set/get self-test), unless --no-selftest.
//! SPIKE_BACKEND=gl|dx12|vulkan|metal picks the wgpu backend (default: wgpu's choice).

use std::sync::Arc;

use anyhow::{anyhow, bail, Context, Result};
use librashader::presets::{get_parameter_meta, ShaderFeatures, ShaderPreset};
use librashader::runtime::wgpu::{FilterChain, WgpuOutputView};
use librashader::runtime::{FilterChainParameters, Size, Viewport};
use ntsc_rs::settings::standard::NtscEffectFullSettings;
use ntsc_rs::settings::SettingsList;
use ntsc_rs::yiq_fielding::{BlitInfo, DeinterlaceMode, Rgbx, YiqView};
use ntsc_rs::NtscEffect;

struct Args {
    input: String,
    preset: String,
    output: String,
    out: (u32, u32),
    down: Option<(u32, u32)>,
    ntsc: Option<String>,
    frame: usize,
    sets: Vec<(String, f32)>,
    selftest: bool,
}

fn parse_args() -> Result<Args> {
    let mut pos = Vec::new();
    let (mut ntsc, mut frame, mut sets, mut selftest) = (None, 1usize, Vec::new(), true);
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--ntsc" => ntsc = Some(it.next().context("--ntsc needs a value")?),
            "--frame" => frame = it.next().context("--frame needs a value")?.parse()?,
            "--no-selftest" => selftest = false,
            "--set" => {
                let kv = it.next().context("--set needs NAME=VALUE")?;
                let (k, v) = kv.split_once('=').context("--set needs NAME=VALUE")?;
                sets.push((k.to_string(), v.parse()?));
            }
            _ => pos.push(a),
        }
    }
    if pos.len() < 3 {
        bail!("usage: ntscrt-spike <input.png> <preset.slangp> <output.png> [outW outH] [downW downH area] [--ntsc default|file] [--frame N] [--set NAME=VALUE]");
    }
    let num = |i: usize, d: u32| -> Result<u32> { Ok(pos.get(i).map(|s| s.parse()).transpose()?.unwrap_or(d)) };
    let down = if pos.len() > 7 {
        if pos[7] != "area" { bail!("only the area downscale is ported so far"); }
        Some((num(5, 0)?, num(6, 0)?))
    } else { None };
    Ok(Args {
        input: pos[0].clone(), preset: pos[1].clone(), output: pos[2].clone(),
        out: (num(3, 1920)?, num(4, 1080)?), down, ntsc, frame, sets, selftest,
    })
}

/// ntsc-rs on RGBA8 in place: the same calls as Vendor/ntscrs-capi's
/// ntsc_process_frame (which the Mac runs on BGRA; channel order doesn't
/// matter to the effect as long as the reader and writer agree).
fn apply_ntsc(px: &mut [u8], w: usize, h: usize, settings: &str, frame: usize) -> Result<()> {
    let full = if settings == "default" {
        NtscEffectFullSettings::default()
    } else {
        let json = std::fs::read_to_string(settings)?;
        SettingsList::<NtscEffectFullSettings>::new().from_json(&json).map_err(|e| anyhow!("{e}"))?
    };
    let effect: NtscEffect = (&full).into();
    let dims = (w, h);
    let field = effect.use_field.to_yiq_field(frame);
    let mut yiq = vec![0f32; YiqView::buf_length_for(dims, field)];
    let mut view = YiqView::from_parts(&mut yiq, dims, field);
    let blit = BlitInfo::from_full_frame(w, h, w * 4);
    view.set_from_strided_buffer::<Rgbx, u8, _>(px, blit, ());
    effect.apply_effect_to_yiq(&mut view, frame, [1.0, 1.0]);
    view.write_to_strided_buffer::<Rgbx, u8, _>(px, blit, DeinterlaceMode::Bob, ());
    Ok(())
}

fn backends() -> wgpu::Backends {
    match std::env::var("SPIKE_BACKEND").as_deref() {
        Ok("gl") => wgpu::Backends::GL,
        Ok("dx12") => wgpu::Backends::DX12,
        Ok("vulkan") => wgpu::Backends::VULKAN,
        Ok("metal") => wgpu::Backends::METAL,
        _ => wgpu::Backends::all(),
    }
}

fn texture(device: &wgpu::Device, (w, h): (u32, u32), usage: wgpu::TextureUsages, label: &str) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage,
        view_formats: &[],
    })
}

fn main() -> Result<()> {
    let args = parse_args()?;

    // Input, then the NTSC stage at full resolution (CPU), as on the Mac.
    let img = image::open(&args.input).with_context(|| format!("open {}", args.input))?.to_rgba8();
    let (iw, ih) = img.dimensions();
    let mut px = img.into_raw();
    if let Some(s) = &args.ntsc {
        apply_ntsc(&mut px, iw as usize, ih as usize, s, args.frame)?;
        println!("ntsc stage applied at full res ({iw}x{ih}, frame {}, settings: {s})", args.frame);
    }

    // GPU.
    let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor { backends: backends(), ..Default::default() });
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        force_fallback_adapter: false,
        compatible_surface: None,
    }))?;
    let info = adapter.get_info();
    println!("adapter: {:?} | {} | {:?}", info.backend, info.name, info.device_type);
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: None,
        required_features: wgpu::Features::empty(),
        required_limits: adapter.limits(),
        ..Default::default()
    }))?;
    let (device, queue) = (Arc::new(device), Arc::new(queue));

    let input = texture(&device, (iw, ih),
        wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST | wgpu::TextureUsages::COPY_SRC, "input");
    queue.write_texture(
        input.as_image_copy(), &px,
        wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(iw * 4), rows_per_image: Some(ih) },
        input.size());

    // The shader chain, with crt-smoke's self-test and any overrides.
    let preset = ShaderPreset::try_parse(&args.preset, ShaderFeatures::NONE)
        .map_err(|e| anyhow!("preset: {e}"))?;
    let first = get_parameter_meta(&preset).map_err(|e| anyhow!("params: {e}"))?.next();
    let mut chain = FilterChain::load_from_preset(preset, &device, &queue, None)
        .map_err(|e| anyhow!("filter chain: {e}"))?;
    if args.selftest {
        if let Some(p) = first {
            let mid = (p.minimum + p.maximum) / 2.0;
            chain.parameters().set_parameter_value(&p.id, mid);
            println!("set/get {}: wrote {mid}, read back {:?}", p.id, chain.parameters().parameter_value(&p.id));
        }
    }
    for (k, v) in &args.sets {
        if chain.parameters().set_parameter_value(k, *v).is_none() { bail!("no parameter {k}"); }
        println!("override {k} = {v}");
    }

    let mut enc = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });

    // Downscale (area), a WGSL port of the Mac's Metal kernel.
    let chain_input = if let Some((dw, dh)) = args.down {
        let down = texture(&device, (dw, dh),
            wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_SRC, "down");
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("downscale"),
            source: wgpu::ShaderSource::Wgsl(include_str!("downscale_area.wgsl").into()),
        });
        let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("downscale_area"), layout: None, module: &module,
            entry_point: Some("downscale_area"), compilation_options: Default::default(), cache: None,
        });
        let dims: [u32; 4] = [iw, ih, dw, dh];
        let ubuf = device.create_buffer(&wgpu::BufferDescriptor {
            label: None, size: 16, usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        queue.write_buffer(&ubuf, 0, &dims.iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<_>>());
        let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &pipeline.get_bind_group_layout(0),
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&input.create_view(&Default::default())) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&down.create_view(&Default::default())) },
                wgpu::BindGroupEntry { binding: 2, resource: ubuf.as_entire_binding() },
            ],
        });
        {
            let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: None, timestamp_writes: None });
            pass.set_pipeline(&pipeline);
            pass.set_bind_group(0, &bind, &[]);
            pass.dispatch_workgroups(dw.div_ceil(8), dh.div_ceil(8), 1);
        }
        println!("downscaled {iw}x{ih} -> {dw}x{dh} via area");
        down
    } else {
        input
    };

    // Render the chain into the output, full-size viewport, identity MVP.
    let output = texture(&device, args.out,
        wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::TEXTURE_BINDING, "output");
    let out_view = output.create_view(&Default::default());
    chain.frame(
        &chain_input,
        &Viewport {
            x: 0.0, y: 0.0, mvp: None,
            output: WgpuOutputView::new_from_raw(&out_view, Size::new(args.out.0, args.out.1), output.format()),
            size: Size::new(args.out.0, args.out.1),
        },
        &mut enc, args.frame, None,
    ).map_err(|e| anyhow!("frame: {e}"))?;

    // Read back (rows padded to 256 bytes).
    let (ow, oh) = args.out;
    let stride = (ow * 4).div_ceil(256) * 256;
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: None, size: (stride * oh) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false,
    });
    enc.copy_texture_to_buffer(
        output.as_image_copy(),
        wgpu::TexelCopyBufferInfo { buffer: &readback, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(stride), rows_per_image: Some(oh) } },
        output.size());
    queue.submit([enc.finish()]);
    readback.slice(..).map_async(wgpu::MapMode::Read, |_| {});
    device.poll(wgpu::PollType::wait_indefinitely())?;
    let data = readback.slice(..).get_mapped_range();
    let mut out = Vec::with_capacity((ow * oh * 4) as usize);
    for row in data.chunks(stride as usize) { out.extend_from_slice(&row[..(ow * 4) as usize]); }
    drop(data);
    // As the Mac's crt-smoke writes it: the output is taken as premultiplied
    // alpha (CGImage premultipliedFirst) and stored unpremultiplied.
    for p in out.chunks_mut(4) {
        let a = p[3] as u32;
        if a > 0 && a < 255 {
            for c in 0..3 { p[c] = ((p[c] as u32 * 255 + a / 2) / a).min(255) as u8; }
        }
    }
    image::RgbaImage::from_raw(ow, oh, out).context("image")?.save(&args.output)?;
    println!("wrote {} ({ow}x{oh})", args.output);
    Ok(())
}
