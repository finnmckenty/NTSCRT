//! The loop (the Mac's `HowlaroundLoop`): each frame the camera films the
//! scene with the TV in it, showing what the TV displayed a frame (or a few)
//! ago; that picture goes through the whole chain (NTSC, the receiver, the
//! CRT) and onto the TV for the next pass. The TV's pictures live in a ring,
//! drawn by the loop's own copy of the CRT chain at a fixed size, so the
//! loop looks the same whatever size the export (or a draft) is.

use std::path::PathBuf;

use anyhow::{anyhow, Context, Result};
use librashader::runtime::wgpu::WgpuOutputView;
use librashader::runtime::{Size, Viewport};

use super::HowlSettings;
use crate::{texture, Chain, Engine, Image, Settings, ShaderSpec};

/// A Screen Loop render: the camera's settings and the whole render's length
/// in seconds (what a move spans and a loop repeats over; a draft covering
/// only the start still uses the full length).
#[derive(Clone, Debug)]
pub struct HowlRender {
    pub settings: HowlSettings,
    pub length: f64,
}

pub(crate) struct HowlState {
    render: HowlRender,
    ring: Vec<wgpu::Texture>,
    feedback_size: (u32, u32),
    chain_input_size: (u32, u32),
    /// The loop's own copy of the CRT chain (None with the CRT off).
    chain: Option<Chain>,
    camera_pipe: wgpu::ComputePipeline,
    blur_pipe: wgpu::ComputePipeline,
    sampler: wgpu::Sampler,
    counter: Option<(String, wgpu::Texture, f64)>,
    frame: usize,
    /// How many frames back the camera's TV picture is: the delay, or one
    /// while the run-up builds the tunnel.
    lag: usize,
    exposure: f64,
    /// The exposure meter's last reading: (the room's luma, the camera's).
    measured: Option<(f64, f64)>,
}

impl HowlState {
    fn write_slot(&self) -> usize {
        self.frame % self.ring.len()
    }
    fn read_slot(&self) -> usize {
        let n = self.ring.len() as i64;
        ((self.frame as i64 - self.lag as i64) % n + n) as usize % self.ring.len()
    }
}

/// The ring's size: a whole, even multiple of the chain input (odd multiples
/// make the glow shaders' scanlines jitter), about 1280 wide, at most ~2048.
pub fn feedback_size(chain_input: (u32, u32)) -> (u32, u32) {
    let (w, h) = (chain_input.0.max(1), chain_input.1.max(1));
    let mut k = 2u32.max(2 * (640.0 / w as f64).ceil() as u32);
    while k > 1 && w * k > 2048 {
        k -= 1;
    }
    (w * k, h * k)
}

/// The Mac reads its meter's mean as if it were BGRA (it's RGBA), so red and
/// blue trade weights; kept for the same hunting.
fn meter_luma(rgba: &[u8]) -> f64 {
    let (mut r, mut g, mut b) = (0u64, 0u64, 0u64);
    for p in rgba.chunks_exact(4) {
        r += p[0] as u64;
        g += p[1] as u64;
        b += p[2] as u64;
    }
    let n = (rgba.len() / 4).max(1) as f64 * 255.0;
    0.299 * (b as f64 / n) + 0.587 * (g as f64 / n) + 0.114 * (r as f64 / n)
}

/// The counter's figures ("0:04"): white with a dark edge, premultiplied
/// RGBA, as camcorders burned them in. None without a usable font.
fn counter_pixels(text: &str) -> Option<(u32, u32, Vec<u8>)> {
    use ab_glyph::{Font, FontVec, PxScale, ScaleFont};
    const CANDIDATES: [(&str, u32); 5] = [
        ("C:\\Windows\\Fonts\\consolab.ttf", 0),
        ("C:\\Windows\\Fonts\\courbd.ttf", 0),
        ("C:\\Windows\\Fonts\\consola.ttf", 0),
        ("/System/Library/Fonts/Menlo.ttc", 1),
        ("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", 0),
    ];
    let font = CANDIDATES.iter().find_map(|(p, i)| FontVec::try_from_vec_and_index(std::fs::read(p).ok()?, *i).ok())?;
    let size = 96.0f32;
    let scaled = font.as_scaled(PxScale::from(size));
    // Lay out on a baseline at 0 and find the ink's bounds.
    let mut x = 0.0f32;
    let mut outlines = Vec::new();
    for ch in text.chars() {
        let glyph = scaled.scaled_glyph(ch);
        let advance = scaled.h_advance(glyph.id);
        let mut g = glyph;
        g.position = ab_glyph::point(x, 0.0);
        if let Some(o) = font.outline_glyph(g) {
            outlines.push(o);
        }
        x += advance;
    }
    let (mut x0, mut y0, mut x1, mut y1) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
    for o in &outlines {
        let b = o.px_bounds();
        x0 = x0.min(b.min.x);
        y0 = y0.min(b.min.y);
        x1 = x1.max(b.max.x);
        y1 = y1.max(b.max.y);
    }
    if outlines.is_empty() {
        return None;
    }
    let pad = 12.0f32;
    let w = (x1 - x0 + 2.0 * pad).ceil() as u32;
    let h = (size * 0.9 + 2.0 * pad).ceil() as u32;
    // The ink at the left pad, centered up and down.
    let ox = pad - x0;
    let oy = pad + ((h as f32 - 2.0 * pad) - (y1 - y0)) / 2.0 - y0;
    let mut coverage = vec![0f32; (w * h) as usize];
    for o in &outlines {
        let b = o.px_bounds();
        o.draw(|gx, gy, c| {
            let px = (b.min.x + ox) as i64 + gx as i64;
            let py = (b.min.y + oy) as i64 + gy as i64;
            if px >= 0 && py >= 0 && (px as u32) < w && (py as u32) < h {
                let i = (py as u32 * w + px as u32) as usize;
                coverage[i] = (coverage[i] + c).min(1.0);
            }
        });
    }
    let at = |x: i64, y: i64| -> f32 {
        if x < 0 || y < 0 || x >= w as i64 || y >= h as i64 { 0.0 } else { coverage[(y as u32 * w + x as u32) as usize] }
    };
    let mut out = vec![0u8; (w * h * 4) as usize];
    for y in 0..h as i64 {
        for x in 0..w as i64 {
            // Source-over, premultiplied: five shadow copies, then the white.
            let (mut c, mut a) = (0f32, 0f32);
            for (dx, dy) in [(-4, 0), (4, 0), (0, 4), (0, -4), (4, 4)] {
                let sa = 0.75 * at(x - dx, y - dy);
                c *= 1.0 - sa;
                a = sa + a * (1.0 - sa);
            }
            let wa = at(x, y);
            c = wa + c * (1.0 - wa);
            a = wa + a * (1.0 - wa);
            let i = ((y as u32 * w + x as u32) * 4) as usize;
            let v = (c * 255.0).round() as u8;
            out[i..i + 4].copy_from_slice(&[v, v, v, (a * 255.0).round() as u8]);
        }
    }
    Some((w, h, out))
}

impl Engine {
    /// Start a Screen Loop: every export frame from here also draws the TV's
    /// picture for the camera (see `howl_camera`), until `howl_end`.
    /// `chain_input` is the chain input's size (the Downscale's, else the
    /// picture's).
    pub fn howl_begin(&mut self, render: HowlRender, shader: Option<&ShaderSpec>, chain_input: (u32, u32)) -> Result<()> {
        let feedback_size = feedback_size(chain_input);
        let usage = wgpu::TextureUsages::RENDER_ATTACHMENT
            | wgpu::TextureUsages::STORAGE_BINDING
            | wgpu::TextureUsages::TEXTURE_BINDING
            | wgpu::TextureUsages::COPY_SRC
            | wgpu::TextureUsages::COPY_DST;
        let ring: Vec<wgpu::Texture> = (0..=render.settings.delay()).map(|_| texture(&self.device, feedback_size, usage, "screen loop")).collect();
        // The TV starts dark: nothing has gone round the loop yet.
        let black: Vec<u8> = [0u8, 0, 0, 255].repeat((feedback_size.0 * feedback_size.1) as usize);
        for t in &ring {
            self.queue.write_texture(
                t.as_image_copy(),
                &black,
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(feedback_size.0 * 4), rows_per_image: Some(feedback_size.1) },
                t.size(),
            );
        }
        let mut chain = None;
        if let Some(s) = shader {
            crate::load_chain_into(&mut chain, &self.device, &self.queue, s)?;
        }
        let module = self.device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("screen loop"),
            source: wgpu::ShaderSource::Wgsl(include_str!("howl.wgsl").into()),
        });
        let pipe = |entry: &str| {
            self.device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(entry),
                layout: None,
                module: &module,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        };
        let sampler = self.device.create_sampler(&wgpu::SamplerDescriptor {
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let lag = render.settings.delay();
        self.howl = Some(HowlState {
            render,
            ring,
            feedback_size,
            chain_input_size: chain_input,
            chain,
            camera_pipe: pipe("howl_camera"),
            blur_pipe: pipe("howl_blur"),
            sampler,
            counter: None,
            frame: 0,
            lag,
            exposure: 1.0,
            measured: None,
        });
        Ok(())
    }

    pub fn howl_end(&mut self) {
        self.howl = None;
    }

    /// What the camera sees `time` seconds into the render: the scene (the
    /// room) with the TV in it, showing the picture from `delay` frames ago.
    pub fn howl_camera(&mut self, scene: &Image, time: f64) -> Result<Image> {
        let h = self.howl.as_mut().context("no Screen Loop running")?;
        let s = h.render.settings.clone();
        let aspect = scene.width as f64 / scene.height.max(1) as f64;
        // A render repeated in passes replays a one-way move each pass; a
        // seamless loop repeats by itself.
        let l = h.render.length.max(0.1);
        let t = if time >= 0.0 && !s.looped() { time % l } else { time };
        let pose = s.pose(t, l);

        let scene_tex = texture(&self.device, (scene.width, scene.height), wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST, "scene");
        self.queue.write_texture(
            scene_tex.as_image_copy(),
            &scene.rgba,
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(scene.width * 4), rows_per_image: Some(scene.height) },
            scene_tex.size(),
        );
        let mut enc = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });

        // Defocus, in the TV picture's own pixels: a camera blur of `sigma`
        // chain-input lines is that over the screen's size in the frame.
        let mut tv = h.ring[h.read_slot()].clone();
        let sigma_lines = 2.5 * s.get("focus");
        let k = h.feedback_size.1 as f64 / h.chain_input_size.1.max(1) as f64;
        let sigma = (sigma_lines * k / pose.zoom.min(1.0).max(0.25)).min(24.0);
        if s.tv_in_view() && sigma > 0.3 {
            let usage = wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING;
            let a = texture(&self.device, h.feedback_size, usage, "blur a");
            let b = texture(&self.device, h.feedback_size, usage, "blur b");
            for (from, to, dir) in [(&tv, &a, [1.0f32, 0.0]), (&a, &b, [0.0, 1.0])] {
                let mut u = Vec::with_capacity(16);
                u.extend_from_slice(&dir[0].to_le_bytes());
                u.extend_from_slice(&dir[1].to_le_bytes());
                u.extend_from_slice(&(sigma as f32).to_le_bytes());
                u.extend_from_slice(&((2.5 * sigma).ceil().min(64.0) as i32).to_le_bytes());
                let buffer = uniform_buffer(&self.device, &self.queue, &u);
                let bind = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: None,
                    layout: &h.blur_pipe.get_bind_group_layout(0),
                    entries: &[
                        wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&from.create_view(&Default::default())) },
                        wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&to.create_view(&Default::default())) },
                        wgpu::BindGroupEntry { binding: 2, resource: buffer.as_entire_binding() },
                    ],
                });
                let mut pass = enc.begin_compute_pass(&Default::default());
                pass.set_pipeline(&h.blur_pipe);
                pass.set_bind_group(0, &bind, &[]);
                pass.dispatch_workgroups(h.feedback_size.0.div_ceil(8), h.feedback_size.1.div_ceil(8), 1);
            }
            tv = b;
        }

        let sc = HowlSettings::screen(&pose, aspect);
        // White balance: red against blue, keeping luminance where it was.
        let wb = 0.07 * s.get("color_drift");
        let (r, b) = (1.0 + wb, 1.0 - wb);
        let luma = 0.299 * r + 0.587 + 0.114 * b;
        let hue = s.get("hue_drift") * std::f64::consts::PI / 180.0;
        let mut rect = [0f32; 4];
        if s.counter() {
            let secs = time.max(0.0) as i64;
            let text = format!("{}:{:02}", secs / 60, secs % 60);
            if h.counter.as_ref().map(|c| &c.0) != Some(&text) {
                h.counter = counter_pixels(&text).map(|(w, ht, px)| {
                    let t = texture(&self.device, (w, ht), wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST, "counter");
                    self.queue.write_texture(
                        t.as_image_copy(),
                        &px,
                        wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(w * 4), rows_per_image: Some(ht) },
                        t.size(),
                    );
                    (text.clone(), t, w as f64 / ht as f64)
                });
            }
            if let Some((_, _, ca)) = &h.counter {
                let hh = 0.075;
                let ww = hh * ca / aspect;
                rect = [0.07, (0.86 - hh) as f32, (0.07 + ww) as f32, 0.86];
            }
        }
        let f4 = |v: [f64; 3], w: f64| [v[0] as f32, v[1] as f32, v[2] as f32, w as f32];
        let tv_in = if s.tv_in_view() { 1.0 } else { 0.0 };
        let uniforms: [[f32; 4]; 9] = [
            f4(sc.ax, 0.0),
            f4(sc.ay, 0.0),
            f4(sc.n, 0.0),
            f4(sc.c, 0.0),
            [(r / luma) as f32, (1.0 / luma) as f32, (b / luma) as f32, 0.0],
            rect,
            [aspect as f32, pose.zoom.max(0.001) as f32, s.get("brightness") as f32, s.get("contrast") as f32],
            [hue.cos() as f32, hue.sin() as f32, h.exposure as f32, tv_in as f32],
            [if s.tv_in_view() { s.get("key") as f32 } else { 0.0 }, if s.get("key_invert") >= 0.5 { 1.0 } else { 0.0 }, 0.0, 0.0],
        ];
        let bytes: Vec<u8> = uniforms.iter().flatten().flat_map(|v| v.to_le_bytes()).collect();
        let buffer = uniform_buffer(&self.device, &self.queue, &bytes);
        let camera = texture(
            &self.device,
            (scene.width, scene.height),
            wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC,
            "camera",
        );
        let counter_tex = h.counter.as_ref().map(|c| &c.1).unwrap_or(&tv);
        let bind = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &h.camera_pipe.get_bind_group_layout(0),
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&scene_tex.create_view(&Default::default())) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&tv.create_view(&Default::default())) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&counter_tex.create_view(&Default::default())) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(&camera.create_view(&Default::default())) },
                wgpu::BindGroupEntry { binding: 4, resource: buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::Sampler(&h.sampler) },
            ],
        });
        {
            let mut pass = enc.begin_compute_pass(&Default::default());
            pass.set_pipeline(&h.camera_pipe);
            pass.set_bind_group(0, &bind, &[]);
            pass.dispatch_workgroups(scene.width.div_ceil(8), scene.height.div_ceil(8), 1);
        }
        let auto_exposure = s.get("auto_exposure") > 0.0;
        let image = self.read_back(enc, &camera)?;
        if auto_exposure {
            // The camcorder's exposure meter: its own picture against the room's.
            let h = self.howl.as_mut().expect("running");
            h.measured = Some((meter_luma(&scene.rgba), meter_luma(&image.rgba)));
        }
        Ok(image)
    }

    /// One frame has gone round: rotate the loop, and let the auto exposure
    /// react to what it measured, a frame late (which is what makes it hunt).
    pub fn howl_advance(&mut self) {
        let Some(h) = self.howl.as_mut() else { return };
        if let Some((scene, seen)) = h.measured.take() {
            let rate = 0.6 * h.render.settings.get("auto_exposure");
            h.exposure = (h.exposure * (scene.max(0.02) / seen.max(0.02)).powf(rate)).clamp(0.25, 4.0);
        }
        h.frame += 1;
    }

    /// Draw this frame's TV picture (the chain input through the loop's copy
    /// of the CRT chain, or enlarged with hard edges without it) into the ring.
    pub(crate) fn howl_feed(&mut self, enc: &mut wgpu::CommandEncoder, chain_input: &wgpu::Texture, settings: &Settings) -> Result<()> {
        let Some(h) = self.howl.as_mut() else { return Ok(()) };
        let target = h.ring[h.write_slot()].clone();
        let size = h.feedback_size;
        match (&mut h.chain, &settings.shader) {
            (Some(_), Some(shader)) => {
                // Keyframed values reach the loop's copy too.
                crate::load_chain_into(&mut h.chain, &self.device, &self.queue, shader)?;
                let chain = &mut h.chain.as_mut().expect("loaded").chain;
                let view = target.create_view(&Default::default());
                let sz = Size::new(size.0, size.1);
                chain
                    .frame(
                        chain_input,
                        &Viewport { x: 0.0, y: 0.0, mvp: None, output: WgpuOutputView::new_from_raw(&view, sz, target.format()), size: sz },
                        enc,
                        settings.frame,
                        None,
                    )
                    .map_err(|e| anyhow!("shader: {e}"))?;
            }
            _ => {
                let (iw, ih) = (chain_input.width(), chain_input.height());
                self.dispatch(enc, &self.nearest, chain_input, &target, &[iw, ih, size.0, size.1], size);
            }
        }
        Ok(())
    }

    /// Run the loop on `scene` without writing anything, so the first frame
    /// of the render already shows the whole tunnel: `build` trips at one
    /// frame each, then `settle` at the real delay. `settings` is the
    /// export's look at its first moment (the receiver standing still).
    pub fn howl_run_up(&mut self, scene: &Image, settings: &Settings, fps: f64, cancelled: &dyn Fn() -> bool) -> Result<()> {
        let h = self.howl.as_ref().context("no Screen Loop running")?;
        let aspect = scene.width as f64 / scene.height.max(1) as f64;
        let (build, settle) = h.render.settings.run_up_plan(aspect, h.chain_input_size.1);
        let delay = h.render.settings.delay();
        let frames = build + settle;
        let result = (|| -> Result<()> {
            for k in 0..frames {
                if cancelled() {
                    anyhow::bail!("cancelled");
                }
                // Switching to the real delay: fill its history with the
                // finished tunnel, as if the TV had shown it all along.
                if k == build && build > 0 && delay > 1 {
                    self.howl_fill_history();
                }
                self.howl.as_mut().expect("running").lag = if k < build { 1 } else { delay };
                // Before the first frame, so the tunnel already carries the
                // motion that leads into it.
                let image = self.howl_camera(scene, (k as f64 - frames as f64) / fps.max(1.0))?;
                self.set_source(image);
                let mut s = settings.clone();
                s.frame = 100_000 + k;
                let input = self.prepare(&s, None)?;
                let mut enc = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
                let chain_input = match s.downscale {
                    Some(spec) => self.downscale(&mut enc, &input, spec),
                    None => input,
                };
                let chain_input = self.apply_glitch(&mut enc, chain_input, &s);
                self.howl_feed(&mut enc, &chain_input, &s)?;
                self.queue.submit([enc.finish()]);
                self.howl_advance();
            }
            Ok(())
        })();
        if let Some(h) = self.howl.as_mut() {
            h.lag = delay;
        }
        result
    }

    /// Copy the latest TV picture into every slot of the ring.
    fn howl_fill_history(&mut self) {
        let Some(h) = self.howl.as_ref() else { return };
        let n = h.ring.len();
        let latest = (h.frame + n - 1) % n;
        let mut enc = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
        for (i, slot) in h.ring.iter().enumerate() {
            if i != latest {
                enc.copy_texture_to_texture(h.ring[latest].as_image_copy(), slot.as_image_copy(), slot.size());
            }
        }
        self.queue.submit([enc.finish()]);
    }

    /// The preset the loop's chain was made from, if any (for tests).
    pub fn howl_chain_preset(&self) -> Option<PathBuf> {
        self.howl.as_ref()?.chain.as_ref().map(|c| c.preset.clone())
    }
}

fn uniform_buffer(device: &wgpu::Device, queue: &wgpu::Queue, bytes: &[u8]) -> wgpu::Buffer {
    let buffer = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: bytes.len().div_ceil(16) as u64 * 16,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    queue.write_buffer(&buffer, 0, bytes);
    buffer
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_size_is_an_even_multiple() {
        assert_eq!(feedback_size((320, 240)), (1280, 960));
        assert_eq!(feedback_size((640, 480)), (1280, 960));
        assert_eq!(feedback_size((1920, 1080)), (1920, 1080), "big inputs come down to 1×");
        assert_eq!(feedback_size((256, 224)), (1536, 1344));
    }

    #[test]
    fn the_counter_draws_when_a_font_is_there() {
        if let Some((w, h, px)) = counter_pixels("0:04") {
            assert_eq!(h, 111);
            assert!(w > 100);
            assert!(px.chunks_exact(4).any(|p| p[0] == 255 && p[3] == 255), "white figures");
            assert!(px.chunks_exact(4).any(|p| p[0] == 0 && p[3] > 100), "a dark edge");
        }
    }
}
