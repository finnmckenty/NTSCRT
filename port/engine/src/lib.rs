//! NTSCRT's still-image pipeline for Windows, in the Mac app's order:
//! source → NTSC (ntsc-rs, CPU, full resolution) → downscale (WGSL ports of
//! the Mac's Metal kernels) → CRT shader (librashader on wgpu) → pixels.
//!
//! The engine owns its own wgpu device: librashader's wgpu runtime at the
//! pinned commit is on wgpu 28, newer than nothing egui ships with, so the
//! app's window can't share a device with it. Frames come back as RGBA8.

pub mod crop;
pub mod export;
pub mod glitch;
pub mod howl;
mod look;
mod ntsc_ui;
pub mod preview;
pub mod timeline;
pub use look::{write_look, Look, LookState, TimelineState};
pub use ntsc_ui::{ntsc_default_values, ntsc_settings, ntsc_values_json, NtscKind, NtscSetting};
pub use ntscrt_codec as codec;
pub use howl::feedback::HowlRender;
pub use howl::HowlSettings;
pub use serde_json;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use librashader::presets::{get_parameter_meta, ShaderFeatures, ShaderPreset};
use librashader::runtime::wgpu::{FilterChain, WgpuOutputView};
use librashader::runtime::{FilterChainParameters, Size, Viewport};
use ntsc_rs::settings::standard::NtscEffectFullSettings;
use ntsc_rs::settings::SettingsList;
use ntsc_rs::yiq_fielding::{BlitInfo, DeinterlaceMode, Rgbx, YiqView};
use ntsc_rs::NtscEffect;

/// RGBA8 pixels, rows packed.
#[derive(Clone, PartialEq)]
pub struct Image {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

impl Image {
    pub fn new(width: u32, height: u32, rgba: Vec<u8>) -> Self {
        assert_eq!(rgba.len(), (width * height * 4) as usize, "RGBA8 size");
        Self { width, height, rgba }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum NtscSettings {
    /// ntsc-rs's own defaults.
    Default,
    /// An ntsc-rs settings JSON (the same format the Mac app and ntsc-rs use).
    Json(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DownscaleMethod {
    /// "Chunky": one source pixel per block.
    Nearest,
    /// "Stabilized nearest": a narrow Gaussian (sigma 0.35 output pixels).
    NearestAA,
    Bilinear,
    /// Mitchell-Netravali.
    Bicubic,
    /// Lanczos-3.
    Lanczos,
    /// "Smooth": the average of the whole block.
    Area,
}

impl DownscaleMethod {
    pub const ALL: [DownscaleMethod; 6] = [Self::Nearest, Self::NearestAA, Self::Bilinear, Self::Bicubic, Self::Lanczos, Self::Area];

    /// The name looks store (the Mac's `DownscaleMethod.rawValue`).
    pub fn raw(self) -> &'static str {
        match self {
            Self::Nearest => "nearest",
            Self::NearestAA => "nearest+",
            Self::Bilinear => "bilinear",
            Self::Bicubic => "bicubic",
            Self::Lanczos => "lanczos",
            Self::Area => "area",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|m| m.raw() == raw)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Nearest => "Nearest",
            Self::NearestAA => "Nearest+",
            Self::Bilinear => "Bilinear",
            Self::Bicubic => "Bicubic",
            Self::Lanczos => "Lanczos",
            Self::Area => "Area",
        }
    }

    /// The separable filter's index in downscale.wgsl, if it is one.
    fn separable(self) -> Option<u32> {
        match self {
            Self::NearestAA => Some(0),
            Self::Bilinear => Some(1),
            Self::Bicubic => Some(2),
            Self::Lanczos => Some(3),
            Self::Nearest | Self::Area => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DownscaleSpec {
    pub width: u32,
    /// Lines: the picture's height, or half of it with One field on.
    pub height: u32,
    pub method: DownscaleMethod,
    /// Picture rows each line stands for (2 for One field, else 1).
    pub line_height: u32,
}

impl DownscaleSpec {
    /// The Mac app's rule: the height follows the picture's shape, even, at
    /// least 16 (`AppState.downscaleHeight`).
    pub fn for_width(width: u32, source: (u32, u32), method: DownscaleMethod) -> Self {
        let aspect = (source.0 as f64 / source.1.max(1) as f64).max(0.05);
        let height = (2.0 * (width as f64 / aspect / 2.0).round()).max(16.0) as u32;
        Self { width, height, method, line_height: 1 }
    }

    /// One field (the Digital video stage's "fields" control): half the
    /// lines, each two picture rows tall (the Mac's `downscaleSpec`).
    pub fn one_field(self) -> Self {
        Self { height: (self.height / 2).max(8), line_height: 2, ..self }
    }

    /// The picture's height (what previews and exports are sized by).
    pub fn picture_height(&self) -> u32 {
        self.height * self.line_height.max(1)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ShaderSpec {
    pub preset: PathBuf,
    /// Parameter values to set; the rest keep the preset's.
    pub params: Vec<(String, f32)>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    pub ntsc: Option<NtscSettings>,
    pub downscale: Option<DownscaleSpec>,
    pub shader: Option<ShaderSpec>,
    /// Seeds the NTSC noise and is the shader's frame count.
    pub frame: usize,
    /// The Glitch stage (between the downscale and the CRT), when on.
    pub glitch: Option<glitch::GlitchFrame>,
    /// The Digital video stage (a camera and codec ahead of NTSC), when on.
    pub digital: Option<DigitalFrame>,
}

/// The Digital video stage for one frame (the Mac's DigitalFrameInput).
#[derive(Clone, Debug, PartialEq)]
pub struct DigitalFrame {
    pub settings: codec::DigitalSettings,
    /// The clip's frame, the timeline's on a still, or the Live noise counter.
    pub frame: i64,
    /// The clip's frame rate, or the timeline's for a still.
    pub source_fps: f64,
    /// The camera's resolution: the Downscale's (picture height, so One
    /// field captures the whole frame), else the picture's capped at 1280 wide.
    pub capture: (usize, usize),
    pub history: Option<DigitalHistoryRef>,
}

impl DigitalFrame {
    /// The capture size for a picture, as the Mac's DigitalFrameInput.captureSize.
    pub fn capture_size(picture: (u32, u32), downscale: Option<(u32, u32)>) -> (usize, usize) {
        match downscale {
            Some((w, h)) => (w as usize, h as usize),
            None => codec::DigitalVideoRenderer::capture_size(picture.0 as usize, picture.1 as usize, (picture.0 as usize).min(1280)),
        }
    }
}

/// Keyframed Digital settings, compared by id.
#[derive(Clone)]
pub struct DigitalHistoryRef(pub Arc<codec::DigitalHistory>);

impl std::fmt::Debug for DigitalHistoryRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "DigitalHistory({})", self.0.id)
    }
}

impl PartialEq for DigitalHistoryRef {
    fn eq(&self, other: &Self) -> bool {
        self.0.id == other.0.id
    }
}

/// Earlier frames of the clip (cropped), for re-running the codec from a keyframe.
pub type FrameVisitor<'a> = codec::FrameVisitor<'a>;

/// A shader parameter as the preset declares it.
#[derive(Clone, Debug)]
pub struct ShaderParam {
    pub name: String,
    pub description: String,
    pub initial: f32,
    pub minimum: f32,
    pub maximum: f32,
    pub step: f32,
}

/// The preset's parameters, in pass order (what the Mac's bridge lists).
pub fn preset_parameters(preset: &Path) -> Result<Vec<ShaderParam>> {
    let preset = ShaderPreset::try_parse(preset, ShaderFeatures::NONE).map_err(|e| anyhow!("preset: {e}"))?;
    Ok(get_parameter_meta(&preset)
        .map_err(|e| anyhow!("parameters: {e}"))?
        .map(|p| ShaderParam {
            name: p.id.to_string(),
            description: p.description.to_string(),
            initial: p.initial,
            minimum: p.minimum,
            maximum: p.maximum,
            step: p.step,
        })
        .collect())
}

/// ntsc-rs on RGBA8 in place: the same calls as Vendor/ntscrs-capi's
/// `ntsc_process_frame` (the Mac runs it on BGRA; the channel order doesn't
/// matter as long as the reader and writer agree).
pub fn apply_ntsc(image: &mut Image, settings: &NtscSettings, frame: usize) -> Result<()> {
    let full = match settings {
        NtscSettings::Default => NtscEffectFullSettings::default(),
        NtscSettings::Json(json) => SettingsList::<NtscEffectFullSettings>::new()
            .from_json(json)
            .map_err(|e| anyhow!("ntsc settings: {e}"))?,
    };
    let effect: NtscEffect = (&full).into();
    let (w, h) = (image.width as usize, image.height as usize);
    let field = effect.use_field.to_yiq_field(frame);
    let mut yiq = vec![0f32; YiqView::buf_length_for((w, h), field)];
    let mut view = YiqView::from_parts(&mut yiq, (w, h), field);
    let blit = BlitInfo::from_full_frame(w, h, w * 4);
    view.set_from_strided_buffer::<Rgbx, u8, _>(&mut image.rgba, blit, ());
    effect.apply_effect_to_yiq(&mut view, frame, [1.0, 1.0]);
    view.write_to_strided_buffer::<Rgbx, u8, _>(&mut image.rgba, blit, DeinterlaceMode::Bob, ());
    Ok(())
}

struct Chain {
    preset: PathBuf,
    chain: FilterChain,
    /// The preset's own values, to put back when an override is dropped.
    initial: Vec<(String, f32)>,
}

struct Prepared {
    key: (u64, Option<NtscSettings>, usize, Option<DigitalFrame>),
    texture: wgpu::Texture,
}

pub struct Engine {
    device: Arc<wgpu::Device>,
    queue: Arc<wgpu::Queue>,
    info: wgpu::AdapterInfo,
    nearest: wgpu::ComputePipeline,
    area: wgpu::ComputePipeline,
    separable: wgpu::ComputePipeline,
    glitch_gpu: glitch::stage::Gpu,
    glitch: glitch::stage::Renderer,
    digital: codec::DigitalVideoRenderer,
    source: Option<(u64, Image)>,
    next_source: u64,
    prepared: Option<Prepared>,
    chain: Option<Chain>,
    /// A Screen Loop in progress (exports only).
    howl: Option<howl::feedback::HowlState>,
}

/// `NTSCRT_BACKEND` (or the spike's `SPIKE_BACKEND`) = gl | dx12 | vulkan | metal.
fn backends() -> wgpu::Backends {
    let pick = std::env::var("NTSCRT_BACKEND").or_else(|_| std::env::var("SPIKE_BACKEND"));
    match pick.as_deref() {
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

impl Engine {
    pub fn new() -> Result<Self> {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor { backends: backends(), ..Default::default() });
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            force_fallback_adapter: false,
            compatible_surface: None,
        }))?;
        let info = adapter.get_info();
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("ntscrt-engine"),
            required_features: wgpu::Features::empty(),
            required_limits: adapter.limits(),
            ..Default::default()
        }))?;
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("downscale"),
            source: wgpu::ShaderSource::Wgsl(include_str!("downscale.wgsl").into()),
        });
        let pipeline = |entry: &str| {
            device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(entry),
                layout: None,
                module: &module,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        };
        let (nearest, area, separable) =
            (pipeline("downscale_nearest"), pipeline("downscale_area"), pipeline("downscale_separable"));
        let glitch_gpu = glitch::stage::Gpu::new(&device);
        Ok(Self {
            device: Arc::new(device),
            queue: Arc::new(queue),
            info,
            nearest,
            area,
            separable,
            glitch_gpu,
            glitch: glitch::stage::Renderer::default(),
            digital: codec::DigitalVideoRenderer::new(),
            source: None,
            next_source: 1,
            prepared: None,
            chain: None,
            howl: None,
        })
    }

    pub fn adapter_info(&self) -> &wgpu::AdapterInfo {
        &self.info
    }

    pub fn set_source(&mut self, image: Image) {
        self.source = Some((self.next_source, image));
        self.next_source += 1;
        self.prepared = None;
    }

    pub fn source_size(&self) -> Option<(u32, u32)> {
        self.source.as_ref().map(|(_, i)| (i.width, i.height))
    }

    /// Render the source. With a shader, `output` is the picture's size on
    /// screen (the viewport the chain draws into); without one, the result
    /// is the shader's input (the downscaled picture) at its own size.
    pub fn render(&mut self, settings: &Settings, output: (u32, u32)) -> Result<Image> {
        let input = self.prepare(settings, None)?;
        let mut enc = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
        let chain_input = match settings.downscale {
            Some(spec) => self.downscale(&mut enc, &input, spec),
            None => input,
        };
        let chain_input = self.apply_glitch(&mut enc, chain_input, settings);
        let Some(shader) = &settings.shader else {
            return self.read_back(enc, &chain_input);
        };
        self.load_chain(shader)?;
        let chain = &mut self.chain.as_mut().expect("loaded").chain;
        let out = texture(
            &self.device,
            output,
            wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::TEXTURE_BINDING,
            "output",
        );
        let view = out.create_view(&Default::default());
        let size = Size::new(output.0, output.1);
        chain
            .frame(
                &chain_input,
                &Viewport { x: 0.0, y: 0.0, mvp: None, output: WgpuOutputView::new_from_raw(&view, size, out.format()), size },
                &mut enc,
                settings.frame,
                None,
            )
            .map_err(|e| anyhow!("shader: {e}"))?;
        self.read_back(enc, &out)
    }

    /// The preview: the chain at the plan's render size (the CRT shader, or
    /// without it the chain input enlarged with hard edges, as the Mac's
    /// ShaderBypass does), then box-filtered to the display size — unless
    /// `full_render` (zoomed in: the Mac samples the full render, since the
    /// box filter averages scanlines flat at small display multiples).
    pub fn render_preview(&mut self, settings: &Settings, plan: preview::PreviewPlan, full_render: bool, earlier: Option<&mut FrameVisitor<'_>>) -> Result<Image> {
        let input = self.prepare(settings, earlier)?;
        let mut enc = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
        let chain_input = match settings.downscale {
            Some(spec) => self.downscale(&mut enc, &input, spec),
            None => input,
        };
        let chain_input = self.apply_glitch(&mut enc, chain_input, settings);
        let size = (plan.render_width.max(1), plan.render_height.max(1));
        let usage = wgpu::TextureUsages::RENDER_ATTACHMENT
            | wgpu::TextureUsages::STORAGE_BINDING
            | wgpu::TextureUsages::COPY_SRC
            | wgpu::TextureUsages::TEXTURE_BINDING;
        let rendered = texture(&self.device, size, usage, "preview render");
        match &settings.shader {
            Some(shader) => {
                self.load_chain(shader)?;
                let chain = &mut self.chain.as_mut().expect("loaded").chain;
                let view = rendered.create_view(&Default::default());
                let sz = Size::new(size.0, size.1);
                chain
                    .frame(
                        &chain_input,
                        &Viewport { x: 0.0, y: 0.0, mvp: None, output: WgpuOutputView::new_from_raw(&view, sz, rendered.format()), size: sz },
                        &mut enc,
                        settings.frame,
                        None,
                    )
                    .map_err(|e| anyhow!("shader: {e}"))?;
            }
            None => {
                let (iw, ih) = (chain_input.width(), chain_input.height());
                self.dispatch(&mut enc, &self.nearest, &chain_input, &rendered, &[iw, ih, size.0, size.1], size);
            }
        }
        if full_render || !plan.needs_downsample() {
            return self.read_back(enc, &rendered);
        }
        let shown = texture(
            &self.device,
            (plan.display_width.max(1), plan.display_height.max(1)),
            wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::TEXTURE_BINDING,
            "preview display",
        );
        self.dispatch(&mut enc, &self.area, &rendered, &shown, &[size.0, size.1, shown.width(), shown.height()], (shown.width(), shown.height()));
        self.read_back(enc, &shown)
    }

    /// An exported frame at exactly `out`: the chain into `out`, or — when
    /// lines would land on a fractional number of rows — at a whole multiple
    /// of the chain input, box-filtered down (the Mac's SupersampledPass).
    /// Without the CRT, the chain input enlarged with hard edges to the next
    /// whole multiple and filtered down (the Mac's ShaderBypass).
    pub fn render_export(&mut self, settings: &Settings, out: (u32, u32), earlier: Option<&mut FrameVisitor<'_>>) -> Result<Image> {
        let input = self.prepare(settings, earlier)?;
        let mut enc = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
        let chain_input = match settings.downscale {
            Some(spec) => self.downscale(&mut enc, &input, spec),
            None => input,
        };
        let chain_input = self.apply_glitch(&mut enc, chain_input, settings);
        // A Screen Loop also draws this frame's TV picture for the camera.
        self.howl_feed(&mut enc, &chain_input, settings)?;
        let (iw, ih) = (chain_input.width(), chain_input.height());
        let render_size = match &settings.shader {
            Some(_) => {
                let k = export::supersample_factor(ih, out.1);
                if k > 1 {
                    let h = ih * k;
                    let w = (out.0 as f64 * h as f64 / out.1 as f64).round() as u32;
                    if w > out.0 && h > out.1 { (w, h) } else { out }
                } else {
                    out
                }
            }
            None => {
                let k = out.1.div_ceil(ih).max(out.0.div_ceil(iw)).max(1);
                if out.1 % ih == 0 && out.0 % iw == 0 { out } else { (iw * k, ih * k) }
            }
        };
        let usage = wgpu::TextureUsages::RENDER_ATTACHMENT
            | wgpu::TextureUsages::STORAGE_BINDING
            | wgpu::TextureUsages::COPY_SRC
            | wgpu::TextureUsages::TEXTURE_BINDING;
        let rendered = texture(&self.device, render_size, usage, "export render");
        match &settings.shader {
            Some(shader) => {
                self.load_chain(shader)?;
                let chain = &mut self.chain.as_mut().expect("loaded").chain;
                let view = rendered.create_view(&Default::default());
                let sz = Size::new(render_size.0, render_size.1);
                chain
                    .frame(
                        &chain_input,
                        &Viewport { x: 0.0, y: 0.0, mvp: None, output: WgpuOutputView::new_from_raw(&view, sz, rendered.format()), size: sz },
                        &mut enc,
                        settings.frame,
                        None,
                    )
                    .map_err(|e| anyhow!("shader: {e}"))?;
            }
            None => self.dispatch(&mut enc, &self.nearest, &chain_input, &rendered, &[iw, ih, render_size.0, render_size.1], render_size),
        }
        if render_size == out {
            return self.read_back(enc, &rendered);
        }
        let shown = texture(&self.device, out, wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::TEXTURE_BINDING, "export");
        self.dispatch(&mut enc, &self.area, &rendered, &shown, &[render_size.0, render_size.1, out.0, out.1], out);
        self.read_back(enc, &shown)
    }

    /// The source after the NTSC stage, on the GPU (cached until the source,
    /// NTSC settings or frame change).
    fn prepare(&mut self, settings: &Settings, earlier: Option<&mut FrameVisitor<'_>>) -> Result<wgpu::Texture> {
        let (id, source) = self.source.as_ref().context("no picture loaded")?;
        // Without NTSC the frame doesn't change the picture (only the
        // shader's frame count), so it isn't part of the key.
        let key = (*id, settings.ntsc.clone(), if settings.ntsc.is_some() { settings.frame } else { 0 }, settings.digital.clone());
        if let Some(p) = &self.prepared {
            if p.key == key {
                return Ok(p.texture.clone());
            }
        }
        let mut pixels = source.clone();
        // Digital video first: a camera and codec ahead of the analog signal.
        if let Some(d) = &settings.digital {
            let (w, h) = (pixels.width as usize, pixels.height as usize);
            self.digital.process(
                d.frame,
                &mut pixels.rgba,
                w,
                h,
                w * 4,
                d.capture,
                d.source_fps,
                &d.settings,
                d.history.as_ref().map(|h| h.0.as_ref()),
                earlier,
            );
        }
        if let Some(ntsc) = &settings.ntsc {
            apply_ntsc(&mut pixels, ntsc, settings.frame)?;
        }
        let tex = texture(
            &self.device,
            (pixels.width, pixels.height),
            wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST | wgpu::TextureUsages::COPY_SRC,
            "source",
        );
        self.queue.write_texture(
            tex.as_image_copy(),
            &pixels.rgba,
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(pixels.width * 4), rows_per_image: Some(pixels.height) },
            tex.size(),
        );
        self.prepared = Some(Prepared { key, texture: tex.clone() });
        Ok(tex)
    }

    fn downscale(&self, enc: &mut wgpu::CommandEncoder, src: &wgpu::Texture, spec: DownscaleSpec) -> wgpu::Texture {
        let storage = |size: (u32, u32), label: &str| {
            texture(
                &self.device,
                size,
                wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_SRC,
                label,
            )
        };
        let dst = storage((spec.width, spec.height), "downscaled");
        let (sw, sh) = (src.width(), src.height());
        match spec.method.separable() {
            None => {
                let pipeline = if spec.method == DownscaleMethod::Nearest { &self.nearest } else { &self.area };
                self.dispatch(enc, pipeline, src, &dst, &[sw, sh, spec.width, spec.height], (spec.width, spec.height));
            }
            Some(kind) => {
                // Horizontal into (dw × sh), then vertical into (dw × dh).
                let mid = storage((spec.width, sh), "downscale scratch");
                self.dispatch(enc, &self.separable, src, &mid, &[sw, sh, spec.width, spec.height, kind, 0, 0, 0], (spec.width, sh));
                self.dispatch(enc, &self.separable, &mid, &dst, &[sw, sh, spec.width, spec.height, kind, 1, 0, 0], (spec.width, spec.height));
            }
        }
        dst
    }

    fn dispatch(&self, enc: &mut wgpu::CommandEncoder, pipeline: &wgpu::ComputePipeline, src: &wgpu::Texture, dst: &wgpu::Texture, uniform: &[u32], grid: (u32, u32)) {
        let bytes: Vec<u8> = uniform.iter().flat_map(|v| v.to_le_bytes()).collect();
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: bytes.len() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        self.queue.write_buffer(&buffer, 0, &bytes);
        let bind = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &pipeline.get_bind_group_layout(0),
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&src.create_view(&Default::default())) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dst.create_view(&Default::default())) },
                wgpu::BindGroupEntry { binding: 2, resource: buffer.as_entire_binding() },
            ],
        });
        let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: None, timestamp_writes: None });
        pass.set_pipeline(pipeline);
        pass.set_bind_group(0, &bind, &[]);
        pass.dispatch_workgroups(grid.0.div_ceil(8), grid.1.div_ceil(8), 1);
    }

    /// The Glitch stage over the chain input, when on: what the simulated TV
    /// shows of it at this moment.
    fn apply_glitch(&mut self, enc: &mut wgpu::CommandEncoder, chain_input: wgpu::Texture, settings: &Settings) -> wgpu::Texture {
        let Some(frame) = &settings.glitch else { return chain_input };
        let (w, h) = (chain_input.width(), chain_input.height());
        let plan = self.glitch.plan(glitch::receiver::Raster::new(w as usize, h as usize), frame);
        let out = texture(
            &self.device,
            (w, h),
            wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_SRC,
            "glitch",
        );
        self.glitch_gpu.encode(&self.device, &self.queue, enc, &chain_input, &out, &plan);
        out
    }

    fn load_chain(&mut self, shader: &ShaderSpec) -> Result<()> {
        load_chain_into(&mut self.chain, &self.device, &self.queue, shader)
    }

    fn read_back(&self, mut enc: wgpu::CommandEncoder, tex: &wgpu::Texture) -> Result<Image> {
        let (w, h) = (tex.width(), tex.height());
        let stride = (w * 4).div_ceil(256) * 256;
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: (stride * h) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        enc.copy_texture_to_buffer(
            tex.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(stride), rows_per_image: Some(h) },
            },
            tex.size(),
        );
        self.queue.submit([enc.finish()]);
        buffer.slice(..).map_async(wgpu::MapMode::Read, |_| {});
        self.device.poll(wgpu::PollType::wait_indefinitely())?;
        let data = buffer.slice(..).get_mapped_range();
        let mut rgba = Vec::with_capacity((w * h * 4) as usize);
        for row in data.chunks(stride as usize) {
            rgba.extend_from_slice(&row[..(w * 4) as usize]);
        }
        drop(data);
        Ok(Image::new(w, h, rgba))
    }
}

/// The folder of RetroArch's slang shaders: `NTSCRT_SHADERS`, else a
/// `shaders` folder next to the program, else `Vendor/slang-shaders` in a
/// folder above it (running from a checkout of the repo).
pub fn find_shaders() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("NTSCRT_SHADERS") {
        return Some(PathBuf::from(p));
    }
    let exe = std::env::current_exe().ok()?;
    let mut dir = exe.parent();
    if let Some(d) = dir {
        if d.join("shaders/crt").is_dir() {
            return Some(d.join("shaders"));
        }
    }
    while let Some(d) = dir {
        let candidate = d.join("Vendor/slang-shaders");
        if candidate.join("crt").is_dir() {
            return Some(candidate);
        }
        dir = d.parent();
    }
    None
}

/// The bundled presets folder: `NTSCRT_PRESETS`, else `presets` next to the
/// program, else `presets` in a folder above it (a checkout of the repo).
pub fn find_presets() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("NTSCRT_PRESETS") {
        return Some(PathBuf::from(p));
    }
    let exe = std::env::current_exe().ok()?;
    let mut dir = exe.parent();
    while let Some(d) = dir {
        let candidate = d.join("presets");
        if candidate.is_dir() && std::fs::read_dir(&candidate).ok()?.flatten().any(|e| e.path().extension().is_some_and(|x| x == "json")) {
            return Some(candidate);
        }
        dir = d.parent();
    }
    None
}

/// The Mac app's seven CRT shaders (`Presets.all`), in its order.
pub const CRT_SHADERS: [(&str, &str, &str); 7] = [
    ("aperture", "CRT Aperture", "crt/crt-aperture.slangp"),
    ("easymode", "CRT Easymode", "crt/crt-easymode.slangp"),
    ("glow_gauss", "CRT Glow (Gaussian)", "crt/crtglow_gauss.slangp"),
    ("glow_lanczos", "CRT Glow (Lanczos)", "crt/crtglow_lanczos.slangp"),
    ("hyllian", "CRT Hyllian", "crt/crt-hyllian.slangp"),
    ("royale", "CRT Royale", "crt/crt-royale.slangp"),
    ("sim", "CRT Sim", "crt/crtsim.slangp"),
];

/// The Mac app's own starting values for some shaders (`AppState.appShaderDefaults`).
pub fn app_shader_defaults(id: &str) -> Vec<(String, f32)> {
    match id {
        "glow_gauss" | "glow_lanczos" => {
            vec![("BOOST".into(), 1.1), ("GLOW_ROLLOFF".into(), 2.4), ("BLOOM_STRENGTH".into(), 0.1)]
        }
        _ => Vec::new(),
    }
}

/// Load `shader`'s preset into `slot` (unless it's loaded already) and set
/// its parameters: the given values over the preset's own.
fn load_chain_into(slot: &mut Option<Chain>, device: &Arc<wgpu::Device>, queue: &Arc<wgpu::Queue>, shader: &ShaderSpec) -> Result<()> {
    if slot.as_ref().map(|c| &c.preset) != Some(&shader.preset) {
        *slot = None;
        let initial = preset_parameters(&shader.preset)?.into_iter().map(|p| (p.name, p.initial)).collect();
        let preset = ShaderPreset::try_parse(&shader.preset, ShaderFeatures::NONE).map_err(|e| anyhow!("preset: {e}"))?;
        let chain = FilterChain::load_from_preset(preset, device, queue, None).map_err(|e| anyhow!("shader {}: {e}", shader.preset.display()))?;
        *slot = Some(Chain { preset: shader.preset.clone(), chain, initial });
    }
    let c = slot.as_mut().expect("loaded");
    let params = c.chain.parameters();
    for (name, value) in &c.initial {
        let v = shader.params.iter().find(|(n, _)| n == name).map_or(*value, |(_, v)| *v);
        params.set_parameter_value(name, v);
    }
    for (name, _) in &shader.params {
        if params.parameter_value(name).is_none() {
            return Err(anyhow!("{} has no parameter {name}", shader.preset.display()));
        }
    }
    Ok(())
}
